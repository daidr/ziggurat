/* The macOS file stream: the Linux design over a private AF_UNIX socket,
   with a pipe for the control's wakeups and a plain reader for the consumer
   in place of GIO. */
#include "macos.h"
#include <pthread.h>
#include <errno.h>
#include <fcntl.h>
#include <poll.h>
#include <stdatomic.h>
#include <stdlib.h>
#include <stddef.h>
#include <sys/socket.h>
#include <sys/stat.h>
#include <unistd.h>

enum { GATE_PREPARED, GATE_GET, GATE_HEAD };
enum { SOURCE_FILE=1, SOURCE_GENERATED=2 };
#ifndef MIN
#define MIN(a,b) ((a)<(b)?(a):(b))
#endif
struct ZwkFileControl { atomic_uint refs; atomic_int cancelled,alive,gate; int event,event_write; };
struct ZwkFileBudget { atomic_uint refs,live,limit; };
struct ZwkFile {
    atomic_uint refs;
    atomic_int binding,started,finished,pump_result,pump_errno;
    union { int file; atomic_int producer_thread; } origin;
    int reader,writer;
    unsigned kind; /* immutable; never infer a kind from descriptor state */
    uint64_t length,ui_thread;
    union { uint64_t file_offset,produced; } position;
    ZwkFileControl *control;
    ZwkFileBudget *budget;
};
struct ZwkFileCandidate { ZwkFile *file; ZwkFileReader *stream; ZwkFileBudget *budget; int head; };
static uint64_t current_thread(void){uint64_t id=0;pthread_threadid_np(NULL,&id);return id;}
static atomic_uint live_physical,live_controls,live_budgets,live_candidates;
static _Atomic uint64_t pread_count;
#ifdef ZWK_FILE_TESTING
static atomic_int allocation_left=-1;
static atomic_int next_pread_error;
static atomic_long generated_fail_after=-1;
static _Atomic uint64_t generated_sent;
static void (*generated_wait_observer)(int,void *);
static void *generated_wait_context;
void zwk_file_test_allocation_limit(int count){atomic_store_explicit(&allocation_left,count,memory_order_relaxed);}
void zwk_file_test_pread_error(int code){atomic_store_explicit(&next_pread_error,code,memory_order_relaxed);}
void zwk_stream_test_send_error_after(long bytes){atomic_store_explicit(&generated_fail_after,bytes,memory_order_relaxed);atomic_store_explicit(&generated_sent,0,memory_order_relaxed);}
uint64_t zwk_stream_test_sent(void){return atomic_load_explicit(&generated_sent,memory_order_relaxed);}
void zwk_stream_test_wait_observer(void (*observer)(int,void *),void *context){generated_wait_observer=observer;generated_wait_context=context;}
void zwk_stream_test_layout(uint32_t *bytes,uint32_t *kind,uint32_t *thread,uint32_t *produced){
    *bytes=sizeof(ZwkFile);*kind=offsetof(ZwkFile,kind);*thread=offsetof(ZwkFile,origin);*produced=offsetof(ZwkFile,position);
}
static void *file_calloc(size_t count,size_t bytes){
    int left=atomic_load_explicit(&allocation_left,memory_order_relaxed);
    if(left==0)return NULL;
    if(left>0)atomic_fetch_sub_explicit(&allocation_left,1,memory_order_relaxed);
    return calloc(count,bytes);
}
#else
#define file_calloc calloc
#endif
static ssize_t file_pread(int fd,void *bytes,size_t count,off_t offset){
#ifdef ZWK_FILE_TESTING
    int code=atomic_exchange_explicit(&next_pread_error,0,memory_order_relaxed);if(code){errno=code;return -1;}
#endif
    return pread(fd,bytes,count,offset);
}
static int reserve(atomic_uint *count,unsigned limit){
    unsigned value=atomic_load_explicit(count,memory_order_relaxed);
    while(value<limit){if(atomic_compare_exchange_weak_explicit(count,&value,value+1,memory_order_acq_rel,memory_order_relaxed))return 1;}
    return 0;
}
static void signal_control(ZwkFileControl *control){
    /* A full pipe already holds a wakeup. */
    const unsigned char one=1;ssize_t result;
    do { result=write(control->event_write,&one,1); } while(result<0&&errno==EINTR);
}
void zwk_file_control_add(ZwkFileControl *control){atomic_fetch_add_explicit(&control->refs,1,memory_order_relaxed);}
void zwk_file_control_release(ZwkFileControl *control){
    if(!control||atomic_fetch_sub_explicit(&control->refs,1,memory_order_acq_rel)!=1)return;
    close(control->event);close(control->event_write);free(control);atomic_fetch_sub_explicit(&live_controls,1,memory_order_relaxed);
}
void zwk_file_control_cancel(ZwkFileControl *control){
    if(control&&!atomic_exchange_explicit(&control->cancelled,1,memory_order_acq_rel))signal_control(control);
}
int zwk_file_control_alive(ZwkFileControl *control){return control&&atomic_load_explicit(&control->alive,memory_order_acquire);}
ZwkFileBudget *zwk_file_budget_create(uint32_t limit){
    if(!limit||limit>ZWK_FILE_VIEW_LIMIT)return NULL;
    ZwkFileBudget *budget=file_calloc(1,sizeof(*budget));if(!budget)return NULL;
    atomic_init(&budget->refs,1);atomic_init(&budget->live,0);atomic_init(&budget->limit,limit);
    atomic_fetch_add_explicit(&live_budgets,1,memory_order_relaxed);return budget;
}
void zwk_file_budget_limit(ZwkFileBudget *budget,uint32_t limit){if(budget&&limit&&limit<=ZWK_FILE_VIEW_LIMIT)atomic_store_explicit(&budget->limit,limit,memory_order_release);}
void zwk_file_budget_release(ZwkFileBudget *budget){
    if(!budget||atomic_fetch_sub_explicit(&budget->refs,1,memory_order_acq_rel)!=1)return;
    free(budget);atomic_fetch_sub_explicit(&live_budgets,1,memory_order_relaxed);
}
uint32_t zwk_file_budget_live(ZwkFileBudget *budget){return atomic_load_explicit(&budget->live,memory_order_acquire);}
static void physical_add(ZwkFile *file){atomic_fetch_add_explicit(&file->refs,1,memory_order_relaxed);}
static void physical_release(ZwkFile *file){
    if(!file||atomic_fetch_sub_explicit(&file->refs,1,memory_order_acq_rel)!=1)return;
    atomic_store_explicit(&file->control->alive,0,memory_order_release);
    if(file->kind==SOURCE_FILE)close(file->origin.file);
    if(file->reader>=0)close(file->reader);close(file->writer);
    if(file->budget){atomic_fetch_sub_explicit(&file->budget->live,1,memory_order_acq_rel);zwk_file_budget_release(file->budget);}
    zwk_file_control_release(file->control);free(file);atomic_fetch_sub_explicit(&live_physical,1,memory_order_acq_rel);
}
void zwk_file_response_release(ZwkFile *file){
    if(!file)return;
    if(atomic_load_explicit(&file->binding,memory_order_acquire)!=2)zwk_file_control_cancel(file->control);
    physical_release(file);
}
uint64_t zwk_file_length(ZwkFile *file){return file->length;}
void zwk_file_pump_release(ZwkFile *file){
    if(!file)return;
    /* A pump let go before it finished ends the body now: the reader, which
       waits only on its socket, sees the writer's end and fails the load. */
    if(!atomic_load_explicit(&file->finished,memory_order_acquire)){zwk_file_control_cancel(file->control);shutdown(file->writer,SHUT_WR);}
    physical_release(file);
}
static int native_error(int *output,int result){if(output)*output=errno;return result;}
static int private_descriptor(int fd){
    int flags=fcntl(fd,F_GETFL);
    return flags>=0&&fcntl(fd,F_SETFL,flags|O_NONBLOCK)>=0&&fcntl(fd,F_SETFD,FD_CLOEXEC)>=0;
}
static int prepare_channel(int source,uint64_t ui_thread,uint64_t maximum,int window,uint64_t offset,uint64_t count,unsigned kind,ZwkFile **response,ZwkFile **pump,uint64_t *length,int *native_errno){
    if(native_errno)*native_errno=0;
    if(!response||!pump||!length)return ZWK_FILE_INVALID;
    *response=NULL;*pump=NULL;*length=0;
    if(current_thread()==ui_thread)return ZWK_FILE_UI_THREAD;
    if(!maximum||maximum>ZWK_FILE_MAX_BYTES)return ZWK_FILE_INVALID;
    uint64_t representation=count;
    if(kind==SOURCE_FILE){
        struct stat info;if(fstat(source,&info)<0)return native_error(native_errno,ZWK_FILE_IO);
        if(!S_ISREG(info.st_mode))return ZWK_FILE_REGULAR_REQUIRED;
        if(info.st_size<0||(uint64_t)info.st_size>maximum)return ZWK_FILE_TOO_LARGE;
        if(window&&(offset>(uint64_t)info.st_size||count>(uint64_t)info.st_size-offset))return ZWK_FILE_WINDOW_INVALID;
        int mode=fcntl(source,F_GETFL);if(mode<0)return native_error(native_errno,ZWK_FILE_IO);
        if((mode&O_ACCMODE)==O_WRONLY)return ZWK_FILE_INVALID;
        representation=window?count:(uint64_t)info.st_size;
    }else if(kind!=SOURCE_GENERATED)return ZWK_FILE_INVALID;
    else if(count>maximum)return ZWK_FILE_TOO_LARGE;
    if(!reserve(&live_physical,ZWK_FILE_PROCESS_LIMIT))return ZWK_FILE_FULL;
    ZwkFile *file=file_calloc(1,sizeof(*file));ZwkFileControl *control=file_calloc(1,sizeof(*control));
    int descriptor=-1,sockets[2]={-1,-1},events[2]={-1,-1},result=ZWK_FILE_OOM;
    if(!file||!control)goto failed;
    if(kind==SOURCE_FILE){descriptor=fcntl(source,F_DUPFD_CLOEXEC,0);if(descriptor<0){result=native_error(native_errno,ZWK_FILE_IO);goto failed;}}
    if(socketpair(AF_UNIX,SOCK_STREAM,0,sockets)<0){result=native_error(native_errno,ZWK_FILE_IO);goto failed;}
    const int yes=1;
    if(!private_descriptor(sockets[0])||!private_descriptor(sockets[1])||setsockopt(sockets[1],SOL_SOCKET,SO_NOSIGPIPE,&yes,sizeof(yes))<0||setsockopt(sockets[0],SOL_SOCKET,SO_NOSIGPIPE,&yes,sizeof(yes))<0){result=native_error(native_errno,ZWK_FILE_IO);goto failed;}
    int bytes=32768;socklen_t bytes_size=sizeof(bytes);
    if(setsockopt(sockets[1],SOL_SOCKET,SO_SNDBUF,&bytes,sizeof(bytes))<0||getsockopt(sockets[1],SOL_SOCKET,SO_SNDBUF,&bytes,&bytes_size)<0){result=native_error(native_errno,ZWK_FILE_IO);goto failed;}
    if(bytes<=0||bytes>131072){result=ZWK_FILE_INVALID;goto failed;}
    if(pipe(events)<0||!private_descriptor(events[0])||!private_descriptor(events[1])){result=native_error(native_errno,ZWK_FILE_IO);goto failed;}
    atomic_init(&control->refs,1);atomic_init(&control->cancelled,0);atomic_init(&control->alive,1);atomic_init(&control->gate,GATE_PREPARED);control->event=events[0];control->event_write=events[1];
    atomic_init(&file->refs,2);atomic_init(&file->binding,0);atomic_init(&file->started,0);atomic_init(&file->finished,0);
    atomic_init(&file->pump_result,ZWK_FILE_OK);atomic_init(&file->pump_errno,0);
    file->kind=kind;
    if(kind==SOURCE_FILE){file->origin.file=descriptor;file->position.file_offset=window?offset:0;}
    else{atomic_init(&file->origin.producer_thread,0);file->position.produced=0;}
    file->reader=sockets[0];file->writer=sockets[1];file->control=control;file->length=representation;file->ui_thread=ui_thread;
    atomic_fetch_add_explicit(&live_controls,1,memory_order_relaxed);
    *response=file;*pump=file;*length=file->length;return ZWK_FILE_OK;
failed:
    if(descriptor>=0)close(descriptor);
    if(sockets[0]>=0)close(sockets[0]);
    if(sockets[1]>=0)close(sockets[1]);
    if(events[0]>=0)close(events[0]);
    if(events[1]>=0)close(events[1]);
    free(file);free(control);atomic_fetch_sub_explicit(&live_physical,1,memory_order_acq_rel);return result;
}
int zwk_file_prepare(int source,uint64_t ui_thread,uint64_t maximum,ZwkFile **response,ZwkFile **pump,uint64_t *length,int *native_errno){
    return prepare_channel(source,ui_thread,maximum,0,0,0,SOURCE_FILE,response,pump,length,native_errno);
}
int zwk_file_prepare_window(int source,uint64_t ui_thread,uint64_t maximum,uint64_t offset,uint64_t count,ZwkFile **response,ZwkFile **pump,uint64_t *length,int *native_errno){
    return prepare_channel(source,ui_thread,maximum,1,offset,count,SOURCE_FILE,response,pump,length,native_errno);
}
int zwk_stream_prepare(uint64_t ui_thread,uint64_t length,uint64_t maximum,ZwkFile **response,ZwkFile **writer,int *native_errno){
    uint64_t actual;
    return prepare_channel(-1,ui_thread,maximum,0,0,length,SOURCE_GENERATED,response,writer,&actual,native_errno);
}
static void drain_event(ZwkFileControl *control){unsigned char value[64];for(;;){ssize_t n=read(control->event,value,sizeof(value));if(n<0&&errno==EINTR)continue;if(n<(ssize_t)sizeof(value))return;}}
static int wait_for(ZwkFile *file,int socket,int *native_errno){
    struct pollfd items[2]={{file->control->event,POLLIN,0},{file->writer,POLLOUT,0}};
    for(;;){
        if(atomic_load_explicit(&file->control->cancelled,memory_order_acquire))return ZWK_FILE_CANCELLED;
#ifdef ZWK_FILE_TESTING
        if(file->kind==SOURCE_GENERATED&&generated_wait_observer)generated_wait_observer(socket,generated_wait_context);
#endif
        int result=poll(items,socket?2:1,-1);if(result<0){if(errno==EINTR)continue;return native_error(native_errno,ZWK_FILE_IO);}
        if(items[0].revents){drain_event(file->control);return ZWK_FILE_OK;}
        if(socket&&items[1].revents)return ZWK_FILE_OK;
    }
}
int zwk_file_pump(ZwkFile *file,int *native_errno){
    if(native_errno)*native_errno=0;
    if(!file)return ZWK_FILE_INVALID;
    if(file->kind!=SOURCE_FILE)return ZWK_FILE_SOURCE_KIND;
    if(current_thread()==file->ui_thread)return ZWK_FILE_UI_THREAD;
    if(atomic_exchange_explicit(&file->started,1,memory_order_acq_rel))return ZWK_FILE_BUSY;
    int result=ZWK_FILE_OK,code=0;
    while(!atomic_load_explicit(&file->control->cancelled,memory_order_acquire)&&atomic_load_explicit(&file->control->gate,memory_order_acquire)==GATE_PREPARED){result=wait_for(file,0,&code);if(result!=ZWK_FILE_OK)goto done;}
    if(atomic_load_explicit(&file->control->cancelled,memory_order_acquire)){result=ZWK_FILE_CANCELLED;goto done;}
    if(atomic_load_explicit(&file->control->gate,memory_order_acquire)==GATE_HEAD)goto done;
    unsigned char bytes[ZWK_FILE_CHUNK_BYTES];uint64_t offset=0;
    while(offset<file->length){
        if(atomic_load_explicit(&file->control->cancelled,memory_order_acquire)){result=ZWK_FILE_CANCELLED;goto done;}
        size_t count=(size_t)MIN((uint64_t)sizeof(bytes),file->length-offset);ssize_t received;
        /* Preparation bounded base+length by the small authoritative file size;
           the final read is capped to this window, never the full source tail. */
        do{atomic_fetch_add_explicit(&pread_count,1,memory_order_relaxed);received=file_pread(file->origin.file,bytes,count,(off_t)(file->position.file_offset+offset));}while(received<0&&errno==EINTR);
        if(received<0){result=native_error(&code,ZWK_FILE_IO);goto done;}
        if(!received){result=ZWK_FILE_SOURCE_CHANGED;goto done;}
        size_t sent=0;
        while(sent<(size_t)received){
            if(atomic_load_explicit(&file->control->cancelled,memory_order_acquire)){result=ZWK_FILE_CANCELLED;goto done;}
            ssize_t n=send(file->writer,bytes+sent,(size_t)received-sent,0);
            if(n>0){sent+=(size_t)n;continue;}
            if(n<0&&errno==EINTR)continue;
            if(n<0&&(errno==EAGAIN||errno==EWOULDBLOCK)){result=wait_for(file,1,&code);if(result==ZWK_FILE_OK)continue;goto done;}
            if(n<0&&(errno==EPIPE||errno==ECONNRESET)){zwk_file_control_cancel(file->control);result=ZWK_FILE_CANCELLED;goto done;}
            result=n<0?native_error(&code,ZWK_FILE_IO):ZWK_FILE_IO;goto done;
        }
        offset+=(uint64_t)received;
    }
done:
    atomic_store_explicit(&file->pump_result,result,memory_order_relaxed);atomic_store_explicit(&file->pump_errno,code,memory_order_relaxed);
    atomic_store_explicit(&file->finished,1,memory_order_release);shutdown(file->writer,SHUT_WR);
    if(native_errno)*native_errno=code;
    return result;
}

/* Generated bytes use exactly the same physical channel and consumer ledger.
   Only the linear producer endpoint accesses the position union. */
static int producer_terminal(ZwkFile *file,int result,int code,int *native_errno){
    /* One owner may publish one terminal only. State 2 is a publication guard;
       readers consume the result only after the release-store of state 1. */
    int expected=0;
    if(!atomic_compare_exchange_strong_explicit(&file->finished,&expected,2,memory_order_acq_rel,memory_order_acquire))return ZWK_FILE_FINISHED;
    atomic_store_explicit(&file->pump_result,result,memory_order_relaxed);
    atomic_store_explicit(&file->pump_errno,code,memory_order_relaxed);
    atomic_store_explicit(&file->finished,1,memory_order_release);
    if(result!=ZWK_FILE_OK)zwk_file_control_cancel(file->control);
    shutdown(file->writer,SHUT_WR);
    if(native_errno)*native_errno=code;
    return result;
}
static int producer_current(ZwkFile *file,int *native_errno){
    if(native_errno)*native_errno=0;
    if(!file)return ZWK_FILE_INVALID;
    if(file->kind!=SOURCE_GENERATED)return ZWK_FILE_SOURCE_KIND;
    const uint64_t thread=current_thread();
    if(thread==file->ui_thread)return ZWK_FILE_UI_THREAD;
    /* The producer's identity, folded to a nonzero int as the slot holds. */
    const int current=(int)(uint32_t)(thread^(thread>>32))|1;
    int prior=0;
    if(!atomic_compare_exchange_strong_explicit(&file->origin.producer_thread,&prior,current,memory_order_acq_rel,memory_order_acquire)&&prior!=current)
        return ZWK_FILE_WRONG_PRODUCER;
    if(atomic_load_explicit(&file->finished,memory_order_acquire))return ZWK_FILE_FINISHED;
    if(atomic_load_explicit(&file->control->cancelled,memory_order_acquire))return producer_terminal(file,ZWK_FILE_CANCELLED,0,native_errno);
    int code=0,result;
    while(atomic_load_explicit(&file->control->gate,memory_order_acquire)==GATE_PREPARED){
        result=wait_for(file,0,&code);
        if(result!=ZWK_FILE_OK)return producer_terminal(file,result,code,native_errno);
    }
    if(atomic_load_explicit(&file->control->cancelled,memory_order_acquire))return producer_terminal(file,ZWK_FILE_CANCELLED,0,native_errno);
    return ZWK_FILE_OK;
}
static ssize_t producer_send(ZwkFile *file,const void *bytes,size_t count){
#ifdef ZWK_FILE_TESTING
    long left=atomic_load_explicit(&generated_fail_after,memory_order_relaxed);
    if(left==0){errno=EIO;return -1;}
    if(left>0&&count>(size_t)left)count=(size_t)left;
#endif
    ssize_t result=send(file->writer,bytes,count,0);
#ifdef ZWK_FILE_TESTING
    if(result>0){
        atomic_fetch_add_explicit(&generated_sent,(uint64_t)result,memory_order_relaxed);
        if(left>0)atomic_fetch_sub_explicit(&generated_fail_after,result,memory_order_relaxed);
    }
#endif
    return result;
}
int zwk_stream_writer_begin(ZwkFile *file,int *head,int *native_errno){
    if(head)*head=0;
    int result=producer_current(file,native_errno);if(result)return result;
    if(!head)return producer_terminal(file,ZWK_FILE_INVALID,0,native_errno);
    *head=atomic_load_explicit(&file->control->gate,memory_order_acquire)==GATE_HEAD;
    return ZWK_FILE_OK;
}
int zwk_stream_writer_write(ZwkFile *file,const void *bytes,size_t count,int *native_errno){
    int result=producer_current(file,native_errno);if(result)return result;
    if(atomic_load_explicit(&file->control->gate,memory_order_acquire)==GATE_HEAD)return producer_terminal(file,ZWK_FILE_UNEXPECTED_BODY,0,native_errno);
    if(!bytes||!count||count>ZWK_FILE_CHUNK_BYTES)return producer_terminal(file,ZWK_FILE_INVALID_CHUNK,0,native_errno);
    if(count>file->length-file->position.produced)return producer_terminal(file,ZWK_FILE_LENGTH_MISMATCH,0,native_errno);
    size_t sent=0;int code=0;
    while(sent<count){
        if(atomic_load_explicit(&file->control->cancelled,memory_order_acquire))return producer_terminal(file,ZWK_FILE_CANCELLED,0,native_errno);
        ssize_t value=producer_send(file,(const unsigned char *)bytes+sent,count-sent);
        if(value>0){sent+=(size_t)value;file->position.produced+=(uint64_t)value;continue;}
        if(value<0&&errno==EINTR)continue;
        if(value<0&&(errno==EAGAIN||errno==EWOULDBLOCK)){
            result=wait_for(file,1,&code);if(result==ZWK_FILE_OK)continue;
            return producer_terminal(file,result,code,native_errno);
        }
        return producer_terminal(file,ZWK_FILE_IO,value<0?errno:EIO,native_errno);
    }
    return ZWK_FILE_OK;
}
int zwk_stream_writer_finish(ZwkFile *file,int *native_errno){
    int result=producer_current(file,native_errno);if(result)return result;
    int head=atomic_load_explicit(&file->control->gate,memory_order_acquire)==GATE_HEAD;
    if(!head&&file->position.produced!=file->length)return producer_terminal(file,ZWK_FILE_LENGTH_MISMATCH,0,native_errno);
    return producer_terminal(file,ZWK_FILE_OK,0,native_errno);
}

/* The consumer's end: what the Linux backend's GInputStream does, without
   GIO. Read on the owner thread when the descriptor is readable. */
enum { STREAM_ACTIVE=1,STREAM_CLOSED=2 };
struct ZwkFileReader { atomic_uint refs; ZwkFile *file; atomic_int lifecycle; uint64_t received; int descriptor; };
static atomic_uint live_readers;
void zwk_file_reader_add(ZwkFileReader *reader){atomic_fetch_add_explicit(&reader->refs,1,memory_order_relaxed);}
int zwk_file_reader_fd(ZwkFileReader *reader){return reader->descriptor;}
void zwk_file_reader_close(ZwkFileReader *reader){
    int previous=atomic_fetch_or_explicit(&reader->lifecycle,STREAM_CLOSED,memory_order_acq_rel);
    if(reader->file&&(previous&STREAM_ACTIVE)&&!(previous&STREAM_CLOSED)){
        /* A complete transfer has nothing left to cancel. */
        const int done=atomic_load_explicit(&reader->file->finished,memory_order_acquire)==1&&atomic_load_explicit(&reader->file->pump_result,memory_order_relaxed)==ZWK_FILE_OK;
        if(!done)zwk_file_control_cancel(reader->file->control);
    }
    int descriptor=reader->descriptor;reader->descriptor=-1;
    if(descriptor>=0)close(descriptor);
}
void zwk_file_reader_release(ZwkFileReader *reader){
    if(!reader||atomic_fetch_sub_explicit(&reader->refs,1,memory_order_acq_rel)!=1)return;
    ZwkFile *file=reader->file;
    zwk_file_reader_close(reader);reader->file=NULL;free(reader);
    atomic_fetch_sub_explicit(&live_readers,1,memory_order_relaxed);
    physical_release(file);
}
ssize_t zwk_file_reader_read(ZwkFileReader *reader,void *buffer,size_t count){
    ZwkFile *file=reader->file;
    if(reader->descriptor<0||(file&&atomic_load_explicit(&file->control->cancelled,memory_order_acquire)))return ZWK_FILE_READ_FAILED;
    ssize_t result;
    do{result=recv(reader->descriptor,buffer,count,0);}while(result<0&&errno==EINTR);
    if(result<0)return errno==EAGAIN||errno==EWOULDBLOCK?ZWK_FILE_READ_WAIT:ZWK_FILE_READ_FAILED;
    if(result>0){reader->received+=(uint64_t)result;return result;}
    /* The writer shut its end: the pump published its result first. */
    if(!file||atomic_load_explicit(&file->finished,memory_order_acquire)!=1)return ZWK_FILE_READ_FAILED;
    const int terminal=atomic_load_explicit(&file->pump_result,memory_order_relaxed);
    const int head=atomic_load_explicit(&file->control->gate,memory_order_acquire)==GATE_HEAD;
    if(terminal!=ZWK_FILE_OK||(!head&&reader->received!=file->length))return ZWK_FILE_READ_FAILED;
    return 0;
}
int zwk_file_prepare_stream(ZwkFile *file,ZwkFileBudget *budget,int head,ZwkFileCandidate **output,int *native_errno){
    if(native_errno)*native_errno=0;
    if(!output)return ZWK_FILE_INVALID;
    *output=NULL;
    if(!file||!budget)return ZWK_FILE_INVALID;
    if(atomic_load_explicit(&file->control->cancelled,memory_order_acquire))return ZWK_FILE_CANCELLED;
    int expected=0;if(!atomic_compare_exchange_strong_explicit(&file->binding,&expected,1,memory_order_acq_rel,memory_order_relaxed))return expected==2?ZWK_FILE_ALREADY_COMMITTED:ZWK_FILE_BUSY;
    if(!reserve(&budget->live,atomic_load_explicit(&budget->limit,memory_order_acquire))){atomic_store_explicit(&file->binding,0,memory_order_release);return ZWK_FILE_FULL;}
    atomic_fetch_add_explicit(&budget->refs,1,memory_order_relaxed);
    ZwkFileCandidate *candidate=file_calloc(1,sizeof(*candidate));
    ZwkFileReader *reader=candidate?file_calloc(1,sizeof(*reader)):NULL;
    int descriptor=reader?fcntl(file->reader,F_DUPFD_CLOEXEC,0):-1;
    if(!candidate||!reader||descriptor<0){
        int result=candidate&&reader?native_error(native_errno,ZWK_FILE_IO):ZWK_FILE_OOM;
        free(reader);free(candidate);atomic_fetch_sub_explicit(&budget->live,1,memory_order_acq_rel);zwk_file_budget_release(budget);atomic_store_explicit(&file->binding,0,memory_order_release);return result;
    }
    atomic_init(&reader->refs,1);atomic_init(&reader->lifecycle,0);reader->received=0;reader->descriptor=descriptor;
    atomic_fetch_add_explicit(&live_readers,1,memory_order_relaxed);
    physical_add(file);reader->file=file;
    physical_add(file);candidate->file=file;candidate->stream=reader;candidate->budget=budget;candidate->head=!!head;
    atomic_fetch_add_explicit(&live_candidates,1,memory_order_relaxed);*output=candidate;return ZWK_FILE_OK;
}
ZwkFileReader *zwk_file_candidate_reader(ZwkFileCandidate *candidate){return candidate->stream;}
ZwkFileControl *zwk_file_candidate_control(ZwkFileCandidate *candidate){return candidate->file->control;}
void zwk_file_candidate_abort(ZwkFileCandidate *candidate){
    if(!candidate)return;
    ZwkFile *file=candidate->file;
    zwk_file_reader_release(candidate->stream);atomic_fetch_sub_explicit(&candidate->budget->live,1,memory_order_acq_rel);zwk_file_budget_release(candidate->budget);
    atomic_store_explicit(&file->binding,0,memory_order_release);physical_release(file);free(candidate);atomic_fetch_sub_explicit(&live_candidates,1,memory_order_relaxed);
}
void zwk_file_candidate_admit(ZwkFileCandidate *candidate,int cancelled,int want_ticket,ZwkFileControl **ticket){
    ZwkFile *file=candidate->file;ZwkFileControl *control=file->control;
    if(ticket)*ticket=NULL;
    file->budget=candidate->budget;candidate->budget=NULL;
    int stream_state=atomic_fetch_or_explicit(&candidate->stream->lifecycle,STREAM_ACTIVE,memory_order_acq_rel);
    atomic_store_explicit(&file->binding,2,memory_order_release);
    if(cancelled||(stream_state&STREAM_CLOSED))zwk_file_control_cancel(control);
    atomic_store_explicit(&control->gate,candidate->head?GATE_HEAD:GATE_GET,memory_order_release);
    if(want_ticket&&ticket){zwk_file_control_add(control);*ticket=control;}
    close(file->reader);file->reader=-1;signal_control(control);
    zwk_file_reader_release(candidate->stream);physical_release(file);free(candidate);atomic_fetch_sub_explicit(&live_candidates,1,memory_order_relaxed);
}
void zwk_file_candidate_commit(ZwkFileCandidate *candidate,int cancelled,int want_ticket,ZwkFileControl **ticket){
    zwk_file_candidate_admit(candidate,cancelled,want_ticket,ticket);
}
void zwk_file_counts(uint32_t *physical,uint32_t *controls,uint32_t *budgets,uint32_t *candidates){
    *physical=atomic_load_explicit(&live_physical,memory_order_acquire);*controls=atomic_load_explicit(&live_controls,memory_order_acquire);*budgets=atomic_load_explicit(&live_budgets,memory_order_acquire);*candidates=atomic_load_explicit(&live_candidates,memory_order_acquire);
}
uint64_t zwk_file_pread_count(void){return atomic_load_explicit(&pread_count,memory_order_acquire);}
