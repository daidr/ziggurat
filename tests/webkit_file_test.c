#define _GNU_SOURCE
#ifdef ZWK_FILE_WINDOW_HEADER
/* An old-source diagnostic may name its preserved native header explicitly.
   Ordinary target builds always use the public module bridge below. */
#include ZWK_FILE_WINDOW_HEADER
#else
#include "../src/webview/webkit_file.h"
#endif
#include <gio/gfiledescriptorbased.h>
#include <dirent.h>
#include <errno.h>
#include <fcntl.h>
#include <pthread.h>
#include <poll.h>
#include <stdatomic.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/resource.h>
#include <sys/syscall.h>
#include <unistd.h>

#define CHECK(test) do { if(!(test)){fprintf(stderr,"webkit-file:%d: %s\n",__LINE__,#test);return 1;} } while(0)
static uint64_t owner_thread;
static int source_file;
static const size_t source_length=4*1024*1024+37;
static unsigned count_entries(const char *path){
    DIR *directory=opendir(path);if(!directory)return 0;
    unsigned count=0;struct dirent *item;
    while((item=readdir(directory)))if(item->d_name[0]!='.')count++;
    closedir(directory);return count;
}
static int counts(unsigned physical,unsigned controls,unsigned budgets,unsigned candidates){
    uint32_t p,c,b,s;zwk_file_counts(&p,&c,&b,&s);
    if(p!=physical||c!=controls||b!=budgets||s!=candidates){fprintf(stderr,"counts: %u %u %u %u expected %u %u %u %u\n",p,c,b,s,physical,controls,budgets,candidates);return 0;}
    return 1;
}
static int prepare(ZwkFile **response,ZwkFile **pump){
    uint64_t length;int code=0;
    int result=zwk_file_prepare(source_file,owner_thread,ZWK_FILE_MAX_BYTES,response,pump,&length,&code);
    if(result||length!=source_length||code)return 0;
    return 1;
}
typedef struct PumpRun { ZwkFile *file; pthread_t thread; int result,code; pthread_mutex_t lock; pthread_cond_t condition; int entered; } PumpRun;
static void *pump_thread(void *data){
    PumpRun *run=data;
    pthread_mutex_lock(&run->lock);run->entered=1;pthread_cond_signal(&run->condition);pthread_mutex_unlock(&run->lock);
    run->result=zwk_file_pump(run->file,&run->code);return NULL;
}
static int pump_start(PumpRun *run,ZwkFile *file){
    memset(run,0,sizeof(*run));run->file=file;
    if(pthread_mutex_init(&run->lock,NULL)||pthread_cond_init(&run->condition,NULL))return 0;
    if(pthread_create(&run->thread,NULL,pump_thread,run))return 0;
    pthread_mutex_lock(&run->lock);while(!run->entered)pthread_cond_wait(&run->condition,&run->lock);pthread_mutex_unlock(&run->lock);return 1;
}
static int pump_join(PumpRun *run){
    int result=pthread_join(run->thread,NULL);pthread_cond_destroy(&run->condition);pthread_mutex_destroy(&run->lock);return !result;
}
typedef struct AsyncRead { GMainLoop *loop; GInputStream *stream; unsigned char buffer[11003]; size_t received; unsigned thread_limit; int failed,done; const unsigned char *expected;size_t expected_length; } AsyncRead;
static gboolean expired(gpointer data){AsyncRead *read=data;read->failed=1;g_main_loop_quit(read->loop);return G_SOURCE_REMOVE;}
static void read_ready(GObject *object,GAsyncResult *result,gpointer data){
    AsyncRead *read=data;GError *error=NULL;
    gssize count=g_input_stream_read_finish(G_INPUT_STREAM(object),result,&error);
    if(count<0||error){read->failed=1;g_clear_error(&error);g_main_loop_quit(read->loop);return;}
    if(count_entries("/proc/self/task")>read->thread_limit)read->failed=1;
    for(gssize i=0;i<count;i++){
        size_t at=read->received+(size_t)i;
        if(read->expected){if(at>=read->expected_length||read->buffer[i]!=read->expected[at])read->failed=1;}
        else if(read->buffer[i]!=(unsigned char)(at%251))read->failed=1;
    }
    read->received+=(size_t)count;
    if(!count){read->done=1;g_main_loop_quit(read->loop);return;}
    g_input_stream_read_async(read->stream,read->buffer,sizeof(read->buffer),G_PRIORITY_DEFAULT,NULL,read_ready,read);
}
static void close_ready(GObject *object,GAsyncResult *result,gpointer data){
    AsyncRead *read=data;GError *error=NULL;
    if(!g_input_stream_close_finish(G_INPUT_STREAM(object),result,&error)||error)read->failed=1;
    if(count_entries("/proc/self/task")>read->thread_limit)read->failed=1;
    g_clear_error(&error);read->done=1;g_main_loop_quit(read->loop);
}
static void skip_ready(GObject *object,GAsyncResult *result,gpointer data){
    AsyncRead *read=data;GError *error=NULL;
    gssize count=g_input_stream_skip_finish(G_INPUT_STREAM(object),result,&error);
    if(count!=24577||error||count_entries("/proc/self/task")>read->thread_limit)read->failed=1;
    g_clear_error(&error);read->received=(size_t)MAX(count,0);read->done=1;g_main_loop_quit(read->loop);
}
static void cancel_ready(GObject *object,GAsyncResult *result,gpointer data){
    AsyncRead *read=data;GError *error=NULL;
    if(g_input_stream_read_finish(G_INPUT_STREAM(object),result,&error)!=-1||!g_error_matches(error,G_IO_ERROR,G_IO_ERROR_CANCELLED))read->failed=1;
    if(count_entries("/proc/self/task")>read->thread_limit)read->failed=1;
    g_clear_error(&error);read->done=1;g_main_loop_quit(read->loop);
}
static gboolean cancel_pollable(GObject *object,gpointer data){
    AsyncRead *read=data;GError *error=NULL;
    if(g_pollable_input_stream_read_nonblocking(G_POLLABLE_INPUT_STREAM(object),read->buffer,1,NULL,&error)!=-1||!g_error_matches(error,G_IO_ERROR,G_IO_ERROR_CANCELLED))read->failed=1;
    g_clear_error(&error);read->done=1;g_main_loop_quit(read->loop);return G_SOURCE_REMOVE;
}
typedef struct TerminalRead { AsyncRead read; int expected_error,skip; } TerminalRead;
static void terminal_ready(GObject *object,GAsyncResult *result,gpointer data){
    TerminalRead *terminal=data;AsyncRead *read=&terminal->read;GError *error=NULL;
    gssize count=terminal->skip?g_input_stream_skip_finish(G_INPUT_STREAM(object),result,&error):g_input_stream_read_finish(G_INPUT_STREAM(object),result,&error);
    if(count!=-1||!g_error_matches(error,G_IO_ERROR,terminal->expected_error))read->failed=1;
    g_clear_error(&error);read->done=1;g_main_loop_quit(read->loop);
}
static int run_async(AsyncRead *read){
    guint timeout=g_timeout_add_seconds(5,expired,read);g_main_loop_run(read->loop);
    if(read->done)g_source_remove(timeout);
    return read->done&&!read->failed;
}
static int retry_and_head(void){
    ZwkFile *response,*pump;CHECK(prepare(&response,&pump));
    CHECK(zwk_file_length(response)==source_length);
    ZwkFileBudget *budget=zwk_file_budget_create(1);CHECK(budget);
    ZwkFileCandidate *candidate=NULL;int code=0;
    CHECK(zwk_file_prepare_stream(response,budget,0,&candidate,&code)==ZWK_FILE_OK);
    CHECK(zwk_file_budget_live(budget)==1&&counts(1,1,1,1));
    ZwkFileCandidate *duplicate=NULL;
    CHECK(zwk_file_prepare_stream(response,budget,0,&duplicate,&code)==ZWK_FILE_BUSY&&!duplicate);
    ZwkFileControl *borrow=zwk_file_candidate_control(candidate);zwk_file_control_add(borrow);
    zwk_file_candidate_abort(candidate);CHECK(zwk_file_budget_live(budget)==0&&zwk_file_control_alive(borrow));
    CHECK(counts(1,1,1,0));
    /* Descriptor setup failure must leave both original owning refs retryable. */
    struct rlimit old,restricted;CHECK(!getrlimit(RLIMIT_NOFILE,&old));restricted=old;restricted.rlim_cur=0;
    CHECK(!setrlimit(RLIMIT_NOFILE,&restricted));
    int result=zwk_file_prepare_stream(response,budget,0,&candidate,&code);int restored=setrlimit(RLIMIT_NOFILE,&old);
    CHECK(!restored&&result==ZWK_FILE_IO&&code==EINVAL&&!candidate&&zwk_file_budget_live(budget)==0);
    /* Leave exactly one descriptor available: the Candidate's dup must use it
       successfully without any hidden epoll/pollability-probe descriptor. */
    int last=fcntl(source_file,F_DUPFD_CLOEXEC,0);CHECK(last>=0);close(last);restricted=old;restricted.rlim_cur=(rlim_t)last+1;
    CHECK(!setrlimit(RLIMIT_NOFILE,&restricted));
    result=zwk_file_prepare_stream(response,budget,0,&candidate,&code);restored=setrlimit(RLIMIT_NOFILE,&old);
    CHECK(!restored&&result==ZWK_FILE_OK&&candidate&&code==0);zwk_file_candidate_abort(candidate);
    CHECK(zwk_file_budget_live(budget)==0&&counts(1,1,1,0));
#ifdef ZWK_FILE_TESTING
    zwk_file_test_allocation_limit(0);
    CHECK(zwk_file_prepare_stream(response,budget,0,&candidate,&code)==ZWK_FILE_OOM&&!candidate&&code==0);
    zwk_file_test_allocation_limit(-1);
    CHECK(zwk_file_budget_live(budget)==0);
#endif
    uint64_t reads=zwk_file_pread_count();PumpRun run;CHECK(pump_start(&run,pump));
    CHECK(zwk_file_prepare_stream(response,budget,1,&candidate,&code)==ZWK_FILE_OK);
    GInputStream *stream=g_object_ref(zwk_file_candidate_stream(candidate));
    CHECK(G_IS_POLLABLE_INPUT_STREAM(stream)&&g_pollable_input_stream_can_poll(G_POLLABLE_INPUT_STREAM(stream)));
    ZwkFileControl *ticket=NULL;zwk_file_candidate_commit(candidate,0,1,&ticket);CHECK(ticket);
    CHECK(pump_join(&run)&&run.result==ZWK_FILE_OK&&run.code==0&&zwk_file_pread_count()==reads);
    unsigned char byte;GError *error=NULL;CHECK(g_input_stream_read(stream,&byte,1,NULL,&error)==0&&!error);
    CHECK(zwk_file_prepare_stream(response,budget,1,&candidate,&code)==ZWK_FILE_ALREADY_COMMITTED&&!candidate);
    zwk_file_response_release(response);zwk_file_pump_release(pump);
    CHECK(counts(1,1,1,0)&&zwk_file_budget_live(budget)==1&&zwk_file_control_alive(ticket));
    CHECK(g_input_stream_close(stream,NULL,&error)&&!error);
    /* Even closed but retained native streams keep their Physical reservation. */
    CHECK(zwk_file_budget_live(budget)==1);g_object_unref(stream);
    CHECK(counts(0,1,1,0)&&!zwk_file_control_alive(ticket)&&zwk_file_budget_live(budget)==0);
    zwk_file_control_cancel(ticket);zwk_file_control_release(ticket);zwk_file_control_release(borrow);zwk_file_budget_release(budget);
    CHECK(counts(0,0,0,0));return 0;
}
static int byte_stream(void){
    ZwkFile *response,*pump;CHECK(prepare(&response,&pump));
    ZwkFileBudget *budget=zwk_file_budget_create(1);ZwkFileCandidate *candidate=NULL;int code=0;
    CHECK(budget&&zwk_file_prepare_stream(response,budget,0,&candidate,&code)==ZWK_FILE_OK);
    GInputStream *stream=g_object_ref(zwk_file_candidate_stream(candidate));
    /* First async read is pending before acceptance; there are still no file reads. */
    unsigned threads=count_entries("/proc/self/task");uint64_t reads=zwk_file_pread_count();
    AsyncRead read={.loop=g_main_loop_new(NULL,FALSE),.stream=stream,.thread_limit=threads+1};
    g_input_stream_read_async(stream,read.buffer,sizeof(read.buffer),G_PRIORITY_DEFAULT,NULL,read_ready,&read);
    CHECK(count_entries("/proc/self/task")==threads&&zwk_file_pread_count()==reads);
    PumpRun run;CHECK(pump_start(&run,pump));
    zwk_file_candidate_commit(candidate,0,0,NULL);zwk_file_response_release(response);
    CHECK(run_async(&read));CHECK(read.received==source_length&&pump_join(&run)&&run.result==ZWK_FILE_OK);
    CHECK(zwk_file_pread_count()>reads&&lseek(source_file,0,SEEK_CUR)==7);
    read.done=0;read.thread_limit=threads;
    g_input_stream_close_async(stream,G_PRIORITY_DEFAULT,NULL,close_ready,&read);
    CHECK(count_entries("/proc/self/task")==threads&&run_async(&read));
    g_main_loop_unref(read.loop);zwk_file_pump_release(pump);g_object_unref(stream);zwk_file_budget_release(budget);
    CHECK(counts(0,0,0,0));return 0;
}
/* Reference bytes are read independently from the caller's original descriptor
   before preparation. They do not use a native file-owner field or pump helper. */
static int window_prepare(int fd,uint64_t offset,uint64_t count,ZwkFile **response,ZwkFile **pump,uint64_t *length,int *code){
#ifdef ZWK_FILE_HAS_WINDOW
    return zwk_file_prepare_window(fd,owner_thread,ZWK_FILE_MAX_BYTES,offset,count,response,pump,length,code);
#else
    /* Test-only old-source diagnostic: the existing API can only prepare the
       whole representation. Its actual length is expected to fail the first
       window oracle; no nonexistent API or fake native result is substituted. */
    (void)offset;(void)count;
    fprintf(stderr,"file window oracle: legacy whole-file preparation diagnostic\n");
    return zwk_file_prepare(fd,owner_thread,ZWK_FILE_MAX_BYTES,response,pump,length,code);
#endif
}
static int window_bytes(void){
    const struct {uint64_t offset,count;} cases[]={
        {17,65541},{0,1},{source_length-13,13},{source_length,0},{77,0}
    };
    for(size_t which=0;which<sizeof(cases)/sizeof(cases[0]);which++){
        uint64_t offset=cases[which].offset,count=cases[which].count;
        unsigned char *expected=malloc(count?(size_t)count:1);CHECK(expected);
        size_t filled=0;
        while(filled<count){ssize_t n;do{n=pread(source_file,expected+filled,(size_t)count-filled,(off_t)(offset+filled));}while(n<0&&errno==EINTR);CHECK(n>0);filled+=(size_t)n;}
        int input=fcntl(source_file,F_DUPFD_CLOEXEC,0);CHECK(input>=0);
        ZwkFile *response=NULL,*pump=NULL;uint64_t length=0;int code=0;
        int result=window_prepare(input,offset,count,&response,&pump,&length,&code);
        CHECK(!close(input)); /* Only the actual prepared duplicate remains. */
        if(result!=ZWK_FILE_OK||code!=0||length!=count||zwk_file_length(response)!=count){
            fprintf(stderr,"file window oracle: offset=%llu expected=%llu native=%llu result=%d errno=%d\n",(unsigned long long)offset,(unsigned long long)count,(unsigned long long)length,result,code);
            zwk_file_response_release(response);zwk_file_pump_release(pump);free(expected);
            CHECK(counts(0,0,0,0));return 1;
        }
        CHECK(lseek(source_file,0,SEEK_CUR)==7);
        ZwkFileBudget *budget=zwk_file_budget_create(1);ZwkFileCandidate *candidate=NULL;
        CHECK(budget&&zwk_file_prepare_stream(response,budget,0,&candidate,&code)==ZWK_FILE_OK);
        GInputStream *stream=g_object_ref(zwk_file_candidate_stream(candidate));
        GInputStream *extra=g_object_ref(stream);
        AsyncRead read={.loop=g_main_loop_new(NULL,FALSE),.stream=stream,.thread_limit=count_entries("/proc/self/task")+1,.expected=expected,.expected_length=(size_t)count};
        uint64_t reads=zwk_file_pread_count();PumpRun run;CHECK(pump_start(&run,pump));
        g_input_stream_read_async(stream,read.buffer,sizeof(read.buffer),G_PRIORITY_DEFAULT,NULL,read_ready,&read);
        ZwkFileControl *ticket=NULL;zwk_file_candidate_admit(candidate,0,1,&ticket);CHECK(ticket);
        zwk_file_response_release(response);
        CHECK(run_async(&read)&&read.received==count&&pump_join(&run)&&run.result==ZWK_FILE_OK&&run.code==0);
        CHECK((count?zwk_file_pread_count()>reads:zwk_file_pread_count()==reads)&&lseek(source_file,0,SEEK_CUR)==7);
        zwk_file_pump_release(pump);g_object_unref(stream);g_main_loop_unref(read.loop);free(expected);
        CHECK(counts(1,1,1,0)&&zwk_file_budget_live(budget)==1&&zwk_file_control_alive(ticket));
        GError *error=NULL;CHECK(g_input_stream_close(extra,NULL,&error)&&!error);
        CHECK(counts(1,1,1,0)&&zwk_file_budget_live(budget)==1);
        g_object_unref(extra);CHECK(counts(0,1,1,0)&&!zwk_file_control_alive(ticket)&&zwk_file_budget_live(budget)==0);
        zwk_file_control_release(ticket);zwk_file_budget_release(budget);CHECK(counts(0,0,0,0));
    }
    fprintf(stderr,"file window byte oracle: five independently pread references, exact lengths/bytes/EOF, caller fd closed, seek unchanged, final physical refs=0\n");
    return 0;
}
#ifdef ZWK_FILE_HAS_WINDOW
static int window_head_and_validation(void){
    ZwkFile *response=NULL,*pump=NULL;uint64_t length=99;int code=19;
    CHECK(zwk_file_prepare_window(source_file,(uint64_t)syscall(SYS_gettid),ZWK_FILE_MAX_BYTES,UINT64_MAX,1,&response,&pump,&length,&code)==ZWK_FILE_UI_THREAD&&code==0&&!response&&!pump&&length==0);
    CHECK(zwk_file_prepare_window(-1,owner_thread,0,0,0,&response,&pump,&length,&code)==ZWK_FILE_INVALID&&code==0&&!response&&!pump&&length==0);
    CHECK(zwk_file_prepare_window(-1,owner_thread,ZWK_FILE_MAX_BYTES,0,0,&response,&pump,&length,&code)==ZWK_FILE_IO&&code==EBADF&&!response&&!pump);
    CHECK(zwk_file_prepare_window(source_file,owner_thread,1,0,1,&response,&pump,&length,&code)==ZWK_FILE_TOO_LARGE&&code==0&&!response&&!pump);
    int pipes[2];CHECK(!pipe(pipes));
    int result=zwk_file_prepare_window(pipes[0],owner_thread,ZWK_FILE_MAX_BYTES,0,0,&response,&pump,&length,&code);
    CHECK(!close(pipes[0])&&!close(pipes[1]));
    CHECK(result==ZWK_FILE_REGULAR_REQUIRED&&code==0&&!response&&!pump&&length==0);
    char descriptor[64];CHECK(snprintf(descriptor,sizeof(descriptor),"/proc/self/fd/%d",source_file)>0);
    int write_only=open(descriptor,O_WRONLY|O_CLOEXEC);CHECK(write_only>=0);
    result=zwk_file_prepare_window(write_only,owner_thread,ZWK_FILE_MAX_BYTES,0,1,&response,&pump,&length,&code);
    CHECK(!close(write_only));CHECK(result==ZWK_FILE_INVALID&&code==0&&!response&&!pump&&length==0);
    CHECK(counts(0,0,0,0));
    const struct {uint64_t offset,count;} invalid[]={{source_length+1,0},{source_length,1},{source_length-1,2},{UINT64_MAX,1},{1,UINT64_MAX}};
    for(size_t i=0;i<sizeof(invalid)/sizeof(invalid[0]);i++){
        CHECK(zwk_file_prepare_window(source_file,owner_thread,ZWK_FILE_MAX_BYTES,invalid[i].offset,invalid[i].count,&response,&pump,&length,&code)==ZWK_FILE_WINDOW_INVALID&&code==0&&!response&&!pump&&length==0);
        CHECK(counts(0,0,0,0));
    }
#ifdef ZWK_FILE_TESTING
    for(int i=0;i<2;i++){
        zwk_file_test_allocation_limit(i);
        CHECK(zwk_file_prepare_window(source_file,owner_thread,ZWK_FILE_MAX_BYTES,17,65541,&response,&pump,&length,&code)==ZWK_FILE_OOM&&code==0&&!response&&!pump);
        CHECK(counts(0,0,0,0));
    }
    zwk_file_test_allocation_limit(-1);
#endif
    CHECK(zwk_file_prepare_window(source_file,owner_thread,ZWK_FILE_MAX_BYTES,17,65541,&response,&pump,&length,&code)==ZWK_FILE_OK&&code==0&&length==65541);
    ZwkFileBudget *budget=zwk_file_budget_create(1);ZwkFileCandidate *candidate=NULL;
    CHECK(budget&&zwk_file_prepare_stream(response,budget,1,&candidate,&code)==ZWK_FILE_OK);
    GInputStream *stream=g_object_ref(zwk_file_candidate_stream(candidate));
    uint64_t reads=zwk_file_pread_count();PumpRun run;CHECK(pump_start(&run,pump));
    zwk_file_candidate_admit(candidate,0,0,NULL);
    CHECK(pump_join(&run)&&run.result==ZWK_FILE_OK&&run.code==0&&zwk_file_pread_count()==reads);
    unsigned char byte;GError *error=NULL;CHECK(g_input_stream_read(stream,&byte,1,NULL,&error)==0&&!error);
    zwk_file_response_release(response);zwk_file_pump_release(pump);g_object_unref(stream);zwk_file_budget_release(budget);
    CHECK(counts(0,0,0,0));return 0;
}
#endif
static int cancel_cases(void){
    int kinds=1;
#ifdef ZWK_FILE_HAS_WINDOW
    kinds=2;
#endif
    for(int kind=0;kind<kinds;kind++)for(int mode=0;mode<5;mode++){
        ZwkFile *response,*pump;
#ifdef ZWK_FILE_HAS_WINDOW
        if(kind){uint64_t length=0;int code=0;CHECK(zwk_file_prepare_window(source_file,owner_thread,ZWK_FILE_MAX_BYTES,17,source_length-17,&response,&pump,&length,&code)==ZWK_FILE_OK&&code==0&&length==source_length-17);}
        else
#else
        (void)kind;
#endif
        CHECK(prepare(&response,&pump));
        ZwkFileBudget *budget=zwk_file_budget_create(1);ZwkFileCandidate *candidate=NULL;int code=0;
        CHECK(budget&&zwk_file_prepare_stream(response,budget,0,&candidate,&code)==ZWK_FILE_OK);
        GInputStream *stream=g_object_ref(zwk_file_candidate_stream(candidate));
        ZwkFileControl *control=zwk_file_candidate_control(candidate);zwk_file_control_add(control);
        uint64_t reads=zwk_file_pread_count();PumpRun run;CHECK(pump_start(&run,pump));
        if(mode==0){zwk_file_control_cancel(control);zwk_file_candidate_abort(candidate);}
        else{
            if(mode==4){GError *error=NULL;CHECK(g_input_stream_close(stream,NULL,&error)&&!error);}
            zwk_file_candidate_commit(candidate,mode==1,0,NULL);
            if(mode==2){
                /* A readiness-driven small read proves the producer has started;
                   with no further consumer, its bounded socket fills. */
                struct pollfd descriptor={g_file_descriptor_based_get_fd(G_FILE_DESCRIPTOR_BASED(stream)),POLLIN,0};
                CHECK(poll(&descriptor,1,5000)==1);unsigned char bytes[1];GError *error=NULL;
                CHECK(g_input_stream_read(stream,bytes,1,NULL,&error)==1&&!error);
                zwk_file_control_cancel(control);
            }else if(mode==3){GError *error=NULL;CHECK(g_input_stream_close(stream,NULL,&error)&&!error);}
        }
        CHECK(pump_join(&run)&&run.result==ZWK_FILE_CANCELLED&&run.code==0);
        if(mode<2||mode==4)CHECK(zwk_file_pread_count()==reads);
        zwk_file_response_release(response);zwk_file_pump_release(pump);g_object_unref(stream);
        CHECK(!zwk_file_control_alive(control)&&zwk_file_budget_live(budget)==0);
        zwk_file_control_release(control);zwk_file_budget_release(budget);CHECK(counts(0,0,0,0));
    }
    return 0;
}
static int skip_and_read_cancellation(void){
    ZwkFile *response,*pump;CHECK(prepare(&response,&pump));
    ZwkFileBudget *budget=zwk_file_budget_create(1);ZwkFileCandidate *candidate=NULL;int code=0;
    CHECK(budget&&zwk_file_prepare_stream(response,budget,0,&candidate,&code)==ZWK_FILE_OK);
    GInputStream *stream=g_object_ref(zwk_file_candidate_stream(candidate));
    AsyncRead read={.loop=g_main_loop_new(NULL,FALSE),.stream=stream,.thread_limit=count_entries("/proc/self/task")};
    /* The synchronous virtual is nonblocking as well. */
    GError *error=NULL;CHECK(g_input_stream_read(stream,read.buffer,1,NULL,&error)==-1&&g_error_matches(error,G_IO_ERROR,G_IO_ERROR_WOULD_BLOCK));g_clear_error(&error);
    GCancellable *cancel=g_cancellable_new();
    g_input_stream_read_async(stream,read.buffer,1,G_PRIORITY_DEFAULT,cancel,cancel_ready,&read);g_cancellable_cancel(cancel);
    CHECK(run_async(&read));g_object_unref(cancel);
    zwk_file_candidate_abort(candidate);g_object_unref(stream);
    /* Cancelling a local uncommitted read does not consume/cancel the Pump. */
    CHECK(zwk_file_prepare_stream(response,budget,0,&candidate,&code)==ZWK_FILE_OK);
    stream=g_object_ref(zwk_file_candidate_stream(candidate));read.stream=stream;read.done=0;read.thread_limit++;
    g_input_stream_skip_async(stream,24577,G_PRIORITY_DEFAULT,NULL,skip_ready,&read);
    PumpRun run;CHECK(pump_start(&run,pump));zwk_file_candidate_commit(candidate,0,0,NULL);
    CHECK(run_async(&read));
    struct pollfd descriptor={g_file_descriptor_based_get_fd(G_FILE_DESCRIPTOR_BASED(stream)),POLLIN,0};CHECK(poll(&descriptor,1,5000)==1);
    unsigned char next;CHECK(g_input_stream_read(stream,&next,1,NULL,&error)==1&&!error&&next==(unsigned char)(24577%251));
    CHECK(g_input_stream_close(stream,NULL,&error)&&!error);CHECK(pump_join(&run)&&run.result==ZWK_FILE_CANCELLED);
    zwk_file_response_release(response);zwk_file_pump_release(pump);g_object_unref(stream);g_main_loop_unref(read.loop);zwk_file_budget_release(budget);
    CHECK(counts(0,0,0,0));return 0;
}
static int cancellation_without_pump(void){
    for(int mode=0;mode<3;mode++){
        ZwkFile *response,*pump;CHECK(prepare(&response,&pump));
        ZwkFileBudget *budget=zwk_file_budget_create(1);ZwkFileCandidate *candidate=NULL;int code=0;
        CHECK(budget&&zwk_file_prepare_stream(response,budget,0,&candidate,&code)==ZWK_FILE_OK);
        GInputStream *stream=g_object_ref(zwk_file_candidate_stream(candidate));ZwkFileControl *ticket=NULL;
        zwk_file_candidate_commit(candidate,0,1,&ticket);zwk_file_response_release(response);
        AsyncRead read={.loop=g_main_loop_new(NULL,FALSE),.stream=stream,.thread_limit=count_entries("/proc/self/task")};
        uint64_t calls=zwk_file_pread_count();GSource *source=NULL;
        if(mode==2){source=g_pollable_input_stream_create_source(G_POLLABLE_INPUT_STREAM(stream),NULL);g_source_set_callback(source,G_SOURCE_FUNC(cancel_pollable),&read,NULL);g_source_attach(source,NULL);}
        else g_input_stream_read_async(stream,read.buffer,1,G_PRIORITY_DEFAULT,NULL,cancel_ready,&read);
        if(mode==1){zwk_file_pump_release(pump);pump=NULL;}else zwk_file_control_cancel(ticket);
        CHECK(run_async(&read)&&zwk_file_pread_count()==calls);
        CHECK(g_pollable_input_stream_is_readable(G_POLLABLE_INPUT_STREAM(stream)));
        GError *error=NULL;CHECK(g_input_stream_read(stream,read.buffer,1,NULL,&error)==-1&&g_error_matches(error,G_IO_ERROR,G_IO_ERROR_CANCELLED));g_clear_error(&error);
        if(source)g_source_unref(source);
        g_main_loop_unref(read.loop);zwk_file_pump_release(pump);g_object_unref(stream);
        CHECK(!zwk_file_control_alive(ticket)&&zwk_file_budget_live(budget)==0);
        zwk_file_control_release(ticket);zwk_file_budget_release(budget);CHECK(counts(0,0,0,0));
    }
    return 0;
}
static int terminal_errors(void){
    int kinds=1;
#ifdef ZWK_FILE_HAS_WINDOW
    kinds=2;
#endif
    for(int kind=0;kind<kinds;kind++)for(int io=0;io<2;io++){
#ifndef ZWK_FILE_TESTING
        if(io)break;
#endif
        CHECK(!ftruncate(source_file,(off_t)source_length));
        ZwkFile *response,*pump;
#ifdef ZWK_FILE_HAS_WINDOW
        if(kind){uint64_t length=0;int code=0;CHECK(zwk_file_prepare_window(source_file,owner_thread,ZWK_FILE_MAX_BYTES,17,source_length-17,&response,&pump,&length,&code)==ZWK_FILE_OK&&code==0);}
        else
#else
        (void)kind;
#endif
        CHECK(prepare(&response,&pump));
        ZwkFileBudget *budget=zwk_file_budget_create(1);ZwkFileCandidate *candidate=NULL;int code=0;
        CHECK(budget&&zwk_file_prepare_stream(response,budget,0,&candidate,&code)==ZWK_FILE_OK);
        GInputStream *stream=g_object_ref(zwk_file_candidate_stream(candidate));
        if(!io)CHECK(!ftruncate(source_file,0));
#ifdef ZWK_FILE_TESTING
        else zwk_file_test_pread_error(EIO);
#endif
        zwk_file_candidate_commit(candidate,0,0,NULL);
        /* A caller may omit errno output; native stream must still retain it. */
        CHECK(zwk_file_pump(pump,io?NULL:&code)==(io?ZWK_FILE_IO:ZWK_FILE_SOURCE_CHANGED)&&code==0);
        int expected=io?g_io_error_from_errno(EIO):G_IO_ERROR_PARTIAL_INPUT;
        GError *error=NULL;unsigned char byte;
        CHECK(g_input_stream_read(stream,&byte,1,NULL,&error)==-1&&g_error_matches(error,G_IO_ERROR,expected));g_clear_error(&error);
        CHECK(g_pollable_input_stream_read_nonblocking(G_POLLABLE_INPUT_STREAM(stream),&byte,1,NULL,&error)==-1&&g_error_matches(error,G_IO_ERROR,expected));g_clear_error(&error);
        TerminalRead terminal={.read={.loop=g_main_loop_new(NULL,FALSE),.stream=stream},.expected_error=expected};
        g_input_stream_read_async(stream,terminal.read.buffer,1,G_PRIORITY_DEFAULT,NULL,terminal_ready,&terminal);CHECK(run_async(&terminal.read));
        terminal.skip=1;terminal.read.done=0;
        g_input_stream_skip_async(stream,1,G_PRIORITY_DEFAULT,NULL,terminal_ready,&terminal);CHECK(run_async(&terminal.read));
        g_main_loop_unref(terminal.read.loop);zwk_file_response_release(response);zwk_file_pump_release(pump);g_object_unref(stream);zwk_file_budget_release(budget);
        CHECK(counts(0,0,0,0));
    }
    return 0;
}
static int capacities(void){
    ZwkFile *responses[ZWK_FILE_PROCESS_LIMIT],*pumps[ZWK_FILE_PROCESS_LIMIT];
    for(unsigned i=0;i<ZWK_FILE_PROCESS_LIMIT;i++)CHECK(prepare(&responses[i],&pumps[i]));
    ZwkFile *extra=NULL,*extra_pump=NULL;uint64_t length=0;int code=0;
    CHECK(zwk_file_prepare(source_file,owner_thread,ZWK_FILE_MAX_BYTES,&extra,&extra_pump,&length,&code)==ZWK_FILE_FULL&&!extra&&!extra_pump);
    ZwkFileBudget *budget=zwk_file_budget_create(8);CHECK(budget);GInputStream *streams[8];
    for(unsigned i=0;i<8;i++){
        ZwkFileCandidate *candidate=NULL;CHECK(zwk_file_prepare_stream(responses[i],budget,1,&candidate,&code)==ZWK_FILE_OK);
        streams[i]=g_object_ref(zwk_file_candidate_stream(candidate));zwk_file_candidate_commit(candidate,0,0,NULL);
    }
    ZwkFileCandidate *candidate=NULL;CHECK(zwk_file_prepare_stream(responses[8],budget,0,&candidate,&code)==ZWK_FILE_FULL&&!candidate);
    CHECK(zwk_file_budget_live(budget)==8);
    for(unsigned i=0;i<ZWK_FILE_PROCESS_LIMIT;i++){zwk_file_response_release(responses[i]);zwk_file_pump_release(pumps[i]);}
    CHECK(counts(8,8,1,0));
    zwk_file_budget_limit(budget,1);CHECK(zwk_file_budget_live(budget)==8);
    /* Releasing the host's Budget cannot invalidate old stream ownership. */
    zwk_file_budget_release(budget);
    for(unsigned i=0;i<8;i++)g_object_unref(streams[i]);
    CHECK(counts(0,0,0,0));return 0;
}
static int shared_consumers(void){
    ZwkFile *responses[ZWK_FILE_PROCESS_LIMIT],*pumps[ZWK_FILE_PROCESS_LIMIT];
    ZwkFileBudget *budgets[2]={zwk_file_budget_create(8),zwk_file_budget_create(8)};
    CHECK(budgets[0]&&budgets[1]&&budgets[0]!=budgets[1]);
    GInputStream *streams[16];int code=0;
    for(unsigned i=0;i<ZWK_FILE_PROCESS_LIMIT;i++){
#ifdef ZWK_FILE_HAS_WINDOW
        if(i&1){uint64_t length=0;CHECK(zwk_file_prepare_window(source_file,owner_thread,ZWK_FILE_MAX_BYTES,17,1,&responses[i],&pumps[i],&length,&code)==ZWK_FILE_OK&&code==0&&length==1);}
        else
#endif
        CHECK(prepare(&responses[i],&pumps[i]));
    }
    for(unsigned i=0;i<16;i++){
        ZwkFileCandidate *candidate=NULL;
        CHECK(zwk_file_prepare_stream(responses[i],budgets[i/8],1,&candidate,&code)==ZWK_FILE_OK);
        streams[i]=g_object_ref(zwk_file_candidate_stream(candidate));
        /* Exercise the neutral admission entry as well as the old commit ABI. */
        if(i<8)zwk_file_candidate_commit(candidate,0,0,NULL);
        else zwk_file_candidate_admit(candidate,0,0,NULL);
    }
    CHECK(zwk_file_budget_live(budgets[0])==8&&zwk_file_budget_live(budgets[1])==8);
    ZwkFile *extra=NULL,*extra_pump=NULL;uint64_t length=0;
    CHECK(zwk_file_prepare(source_file,owner_thread,ZWK_FILE_MAX_BYTES,&extra,&extra_pump,&length,&code)==ZWK_FILE_FULL&&!extra&&!extra_pump);
#ifdef ZWK_FILE_HAS_WINDOW
    CHECK(zwk_file_prepare_window(source_file,owner_thread,ZWK_FILE_MAX_BYTES,17,1,&extra,&extra_pump,&length,&code)==ZWK_FILE_FULL&&!extra&&!extra_pump);
#endif
    for(unsigned i=0;i<16;i++){zwk_file_response_release(responses[i]);zwk_file_pump_release(pumps[i]);}
    /* Both logical owners withdraw their ledgers. Their actual streams still
       retain the same process-wide slots, even after native close(). */
    zwk_file_budget_release(budgets[0]);zwk_file_budget_release(budgets[1]);
    CHECK(counts(32,32,2,0));
    GError *error=NULL;CHECK(g_input_stream_close(streams[0],NULL,&error)&&!error);
    CHECK(counts(32,32,2,0));
    CHECK(zwk_file_prepare(source_file,owner_thread,ZWK_FILE_MAX_BYTES,&extra,&extra_pump,&length,&code)==ZWK_FILE_FULL&&!extra&&!extra_pump);
#ifdef ZWK_FILE_HAS_WINDOW
    CHECK(zwk_file_prepare_window(source_file,owner_thread,ZWK_FILE_MAX_BYTES,17,1,&extra,&extra_pump,&length,&code)==ZWK_FILE_FULL&&!extra&&!extra_pump);
#endif
    g_object_unref(streams[0]);CHECK(counts(31,31,2,0));
    CHECK(prepare(&extra,&extra_pump));CHECK(counts(32,32,2,0));
    zwk_file_response_release(extra);zwk_file_pump_release(extra_pump);
    for(unsigned i=16;i<ZWK_FILE_PROCESS_LIMIT;i++){zwk_file_response_release(responses[i]);zwk_file_pump_release(pumps[i]);}
    for(unsigned i=1;i<16;i++)g_object_unref(streams[i]);
    CHECK(counts(0,0,0,0));return 0;
}
static int validation(void){
    ZwkFile *response=NULL,*pump=NULL;uint64_t length=0;int code=17;
    CHECK(zwk_file_prepare(source_file,(uint64_t)syscall(SYS_gettid),ZWK_FILE_MAX_BYTES,&response,&pump,&length,&code)==ZWK_FILE_UI_THREAD&&code==0);
    CHECK(zwk_file_prepare(-1,owner_thread,ZWK_FILE_MAX_BYTES,&response,&pump,&length,&code)==ZWK_FILE_IO&&code==EBADF);
    CHECK(zwk_file_prepare(source_file,owner_thread,1,&response,&pump,&length,&code)==ZWK_FILE_TOO_LARGE&&code==0);
    int pipes[2];CHECK(!pipe(pipes));
    int result=zwk_file_prepare(pipes[0],owner_thread,ZWK_FILE_MAX_BYTES,&response,&pump,&length,&code);close(pipes[0]);close(pipes[1]);
    CHECK(result==ZWK_FILE_REGULAR_REQUIRED&&code==0);
#ifdef ZWK_FILE_TESTING
    for(int allocations=0;allocations<2;allocations++){
        zwk_file_test_allocation_limit(allocations);
        CHECK(zwk_file_prepare(source_file,owner_thread,ZWK_FILE_MAX_BYTES,&response,&pump,&length,&code)==ZWK_FILE_OOM&&code==0&&!response&&!pump);
        CHECK(counts(0,0,0,0));
    }
    zwk_file_test_allocation_limit(0);CHECK(!zwk_file_budget_create(8));zwk_file_test_allocation_limit(-1);
#endif
    CHECK(counts(0,0,0,0));return 0;
}
int zwk_file_native_test(void){
    /* Tests run on a dedicated worker, with the actual process main id passed
       into the implementation. No GTK/WebKit instance or global worker pool. */
    owner_thread=(uint64_t)getpid();
    char path[]="/tmp/ziggurat-file-pump-XXXXXX";source_file=mkstemp(path);CHECK(source_file>=0);unlink(path);
    unsigned char bytes[16384];size_t written=0;
    while(written<source_length){size_t count=MIN(sizeof(bytes),source_length-written);for(size_t i=0;i<count;i++)bytes[i]=(unsigned char)((written+i)%251);CHECK(write(source_file,bytes,count)==(ssize_t)count);written+=count;}
    CHECK(lseek(source_file,7,SEEK_SET)==7);
    g_main_context_iteration(g_main_context_default(),FALSE);
    unsigned descriptors=count_entries("/proc/self/fd");
    CHECK(!validation());CHECK(!retry_and_head());CHECK(!byte_stream());CHECK(!window_bytes());
#ifdef ZWK_FILE_HAS_WINDOW
    CHECK(!window_head_and_validation());
#endif
    CHECK(!cancel_cases());CHECK(!skip_and_read_cancellation());CHECK(!cancellation_without_pump());CHECK(!capacities());CHECK(!shared_consumers());CHECK(!terminal_errors());
    CHECK(counts(0,0,0,0)&&count_entries("/proc/self/fd")==descriptors);close(source_file);return 0;
}
#ifdef ZWK_FILE_TEST_MAIN
static void *all_tests(void *unused){(void)unused;return (void *)(intptr_t)zwk_file_native_test();}
int main(void){pthread_t worker;alarm(20);if(pthread_create(&worker,NULL,all_tests,NULL))return 2;void *result;if(pthread_join(worker,&result))return 2;return (int)(intptr_t)result;}
#endif
