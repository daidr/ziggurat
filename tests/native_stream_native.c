#define _GNU_SOURCE
#include "../src/file_stream/linux.h"
#include <errno.h>
#include <pthread.h>
#include <stdatomic.h>
#include <stdio.h>
#include <string.h>
#include <sys/mman.h>
#include <sys/syscall.h>
#include <time.h>
#include <unistd.h>

#define CHECK(x) do{if(!(x)){fprintf(stderr,"native-stream:%d: %s\n",__LINE__,#x);failed=1;goto done;}}while(0)
static uint64_t owner;
typedef struct Pair { ZwkFile *source,*writer;uint64_t length;int result,code,file; } Pair;
static void *prepare_worker(void *data){
    Pair *p=data;
    if(p->file>=0){uint64_t length=0;p->result=zwk_file_prepare(p->file,owner,ZWK_FILE_MAX_BYTES,&p->source,&p->writer,&length,&p->code);}
    else p->result=zwk_stream_prepare(owner,p->length,ZWK_FILE_MAX_BYTES,&p->source,&p->writer,&p->code);
    return NULL;
}
static int prepare(Pair *p,uint64_t length,int file){
    memset(p,0,sizeof(*p));p->length=length;p->file=file;pthread_t thread;
    if(pthread_create(&thread,NULL,prepare_worker,p))return -1;
    if(pthread_join(thread,NULL))return -1;
    return p->result;
}
static void pair_clear(Pair *p){
    if(p->source){ZwkFile *v=p->source;p->source=NULL;zwk_file_response_release(v);}
    if(p->writer){ZwkFile *v=p->writer;p->writer=NULL;zwk_file_pump_release(v);}
}
typedef struct Consumer { ZwkFileBudget *budget;ZwkFileCandidate *candidate;GInputStream *stream;ZwkFileControl *control; } Consumer;
static int admit(Pair *p,Consumer *c,int head){
    memset(c,0,sizeof(*c));int code=0;c->budget=zwk_file_budget_create(1);if(!c->budget)return -1;
    int result=zwk_file_prepare_stream(p->source,c->budget,head,&c->candidate,&code);if(result)return result;
    c->stream=g_object_ref(zwk_file_candidate_stream(c->candidate));
    zwk_file_candidate_admit(c->candidate,0,1,&c->control);c->candidate=NULL;
    zwk_file_response_release(p->source);p->source=NULL;return 0;
}
static void consumer_clear(Consumer *c){
    if(c->candidate){zwk_file_candidate_abort(c->candidate);c->candidate=NULL;}
    if(c->stream){g_input_stream_close(c->stream,NULL,NULL);g_clear_object(&c->stream);}
    if(c->control){zwk_file_control_release(c->control);c->control=NULL;}
    if(c->budget){zwk_file_budget_release(c->budget);c->budget=NULL;}
}
static int zero(void){uint32_t p,c,b,s;zwk_file_counts(&p,&c,&b,&s);if(p||c||b||s)fprintf(stderr,"native stream resources %u/%u/%u/%u\n",p,c,b,s);return !(p||c||b||s);}
enum { WRITE_NORMAL,WRITE_BIND,WRITE_BEGIN,WRITE_SHORT,WRITE_LONG,WRITE_EMPTY,WRITE_HEAD_BODY,WRITE_FILE_PUMP };
typedef struct Write { ZwkFile *writer;uint64_t length;int mode,result,code,head,accepted,finished; } Write;
static void *write_worker(void *data){
    Write *w=data;
    if(w->mode==WRITE_FILE_PUMP){w->result=zwk_file_pump(w->writer,&w->code);return NULL;}
    w->result=zwk_stream_writer_begin(w->writer,&w->head,&w->code);if(w->result)return NULL;
    w->accepted=1;if(w->mode==WRITE_BIND||w->mode==WRITE_BEGIN)return NULL;
    unsigned char bytes[ZWK_FILE_CHUNK_BYTES];uint64_t at=0;
    if(w->mode==WRITE_LONG||w->mode==WRITE_EMPTY||w->mode==WRITE_HEAD_BODY){w->result=zwk_stream_writer_write(w->writer,"xx",w->mode==WRITE_EMPTY?0:2,&w->code);return NULL;}
    if(w->mode!=WRITE_SHORT&&!w->head)while(at<w->length){
        size_t count=(size_t)MIN((uint64_t)sizeof(bytes),w->length-at);
        for(size_t i=0;i<count;i++)bytes[i]=(unsigned char)((at+i)%251);
        w->result=zwk_stream_writer_write(w->writer,bytes,count,&w->code);if(w->result)return NULL;at+=count;
    }
    w->result=zwk_stream_writer_finish(w->writer,&w->code);w->finished=!w->result;return NULL;
}
static int write_join(Write *w){pthread_t thread;return pthread_create(&thread,NULL,write_worker,w)||pthread_join(thread,NULL);}
typedef struct Read {GInputStream *stream;GMainLoop *loop;uint64_t expected,received;unsigned char bytes[5197];int failed,done,timed_out;} Read;
static gboolean expired(gpointer data){Read *r=data;r->timed_out=r->failed=1;g_input_stream_close(r->stream,NULL,NULL);return G_SOURCE_REMOVE;}
static void read_ready(GObject *object,GAsyncResult *result,gpointer data){
    Read *r=data;GError *error=NULL;gssize count=g_input_stream_read_finish(G_INPUT_STREAM(object),result,&error);
    if(count<0||error){r->failed=1;g_clear_error(&error);r->done=1;g_main_loop_quit(r->loop);return;}
    for(gssize i=0;i<count;i++)if(r->received+(uint64_t)i>=r->expected||r->bytes[i]!=(unsigned char)((r->received+(uint64_t)i)%251))r->failed=1;
    r->received+=(uint64_t)count;
    if(!count){r->done=1;g_main_loop_quit(r->loop);return;}
    g_input_stream_read_async(r->stream,r->bytes,sizeof(r->bytes),G_PRIORITY_DEFAULT,NULL,read_ready,r);
}
int zwk_stream_test_read(void *stream,uint64_t length){
    Read r={.stream=stream,.expected=length};r.loop=g_main_loop_new(NULL,FALSE);
    guint timeout=g_timeout_add_seconds(5,expired,&r);
    g_input_stream_read_async(r.stream,r.bytes,sizeof(r.bytes),G_PRIORITY_DEFAULT,NULL,read_ready,&r);
    g_main_loop_run(r.loop);if(!r.timed_out)g_source_remove(timeout);g_main_loop_unref(r.loop);
    return r.done&&!r.failed&&r.received==length;
}
void *zwk_stream_test_ref(void *stream){return g_object_ref(stream);}
void zwk_stream_test_unref(void *stream){g_input_stream_close(stream,NULL,NULL);g_object_unref(stream);}

/* Terminal result must remain immutable while the successful bytes are still
   unread. A second worker has no authority to cancel the first one's result. */
static int terminal_monotonic(void){
    int failed=0;Pair p={0};Consumer c={0};
    CHECK(prepare(&p,10007,-1)==0);CHECK(admit(&p,&c,0)==0);
    Write first={.writer=p.writer,.length=p.length,.mode=WRITE_NORMAL};CHECK(!write_join(&first));CHECK(first.result==0&&first.finished);
    Write wrong={.writer=p.writer,.mode=WRITE_BEGIN};CHECK(!write_join(&wrong));CHECK(wrong.result==ZWK_FILE_WRONG_PRODUCER);
    int head=0,code=0;CHECK(zwk_stream_writer_begin(p.writer,&head,&code)==ZWK_FILE_UI_THREAD);
    CHECK(zwk_stream_test_read(c.stream,p.length));
done:consumer_clear(&c);pair_clear(&p);return failed||!zero();
}
static int generated_bytes(void){
    int failed=0,started=0;Pair p={0};Consumer c={0};pthread_t thread;Write w={0};
    CHECK(prepare(&p,4*1024*1024+37,-1)==0);CHECK(admit(&p,&c,0)==0);
    w=(Write){.writer=p.writer,.length=p.length,.mode=WRITE_NORMAL};CHECK(!pthread_create(&thread,NULL,write_worker,&w));started=1;
    CHECK(zwk_stream_test_read(c.stream,p.length));
done:
    if(failed&&c.control)zwk_file_control_cancel(c.control);
    if(started){if(pthread_join(thread,NULL))failed=1;if(w.result||!w.finished)failed=1;}
    consumer_clear(&c);pair_clear(&p);return failed||!zero();
}
static int head_and_zero(void){
    int failed=0;Pair p={0};Consumer c={0};
    for(int head=0;head<2;head++){
        CHECK(prepare(&p,head?10007:0,-1)==0);CHECK(admit(&p,&c,head)==0);
        Write w={.writer=p.writer,.length=p.length,.mode=WRITE_NORMAL};CHECK(!write_join(&w));CHECK(!w.result&&w.finished&&w.head==head);
        CHECK(zwk_stream_test_read(c.stream,0));consumer_clear(&c);pair_clear(&p);CHECK(zero());
    }
done:consumer_clear(&c);pair_clear(&p);return failed||!zero();
}
typedef struct Wait {pthread_mutex_t lock;pthread_cond_t condition;int seen[2];} Wait;
static void wait_observer(int stage,void *data){Wait *w=data;pthread_mutex_lock(&w->lock);w->seen[stage]=1;pthread_cond_signal(&w->condition);pthread_mutex_unlock(&w->lock);}
static int observe_wait(Wait *w,int stage){
    struct timespec until;clock_gettime(CLOCK_REALTIME,&until);until.tv_sec+=5;
    pthread_mutex_lock(&w->lock);int result=0;while(!w->seen[stage]&&!result)result=pthread_cond_timedwait(&w->condition,&w->lock,&until);
    int seen=w->seen[stage];pthread_mutex_unlock(&w->lock);return seen;
}
static int blocked_cancel(void){
    int failed=0,started=0;Pair p={0};Consumer c={0};pthread_t thread;Write w={0};Wait wait={.lock=PTHREAD_MUTEX_INITIALIZER,.condition=PTHREAD_COND_INITIALIZER};
    for(int stage=0;stage<2;stage++){
        CHECK(prepare(&p,4*1024*1024,-1)==0);
        if(stage)CHECK(admit(&p,&c,0)==0);
        zwk_stream_test_wait_observer(wait_observer,&wait);
        w=(Write){.writer=p.writer,.length=p.length,.mode=WRITE_NORMAL};CHECK(!pthread_create(&thread,NULL,write_worker,&w));started=1;
        CHECK(observe_wait(&wait,stage));
        if(stage)zwk_file_control_cancel(c.control);else{zwk_file_response_release(p.source);p.source=NULL;}
        CHECK(!pthread_join(thread,NULL));started=0;CHECK(w.result==ZWK_FILE_CANCELLED);
        zwk_stream_test_wait_observer(NULL,NULL);consumer_clear(&c);pair_clear(&p);CHECK(zero());
    }
done:
    if(started){if(c.control)zwk_file_control_cancel(c.control);else if(p.source){zwk_file_response_release(p.source);p.source=NULL;}pthread_join(thread,NULL);}
    zwk_stream_test_wait_observer(NULL,NULL);consumer_clear(&c);pair_clear(&p);pthread_cond_destroy(&wait.condition);pthread_mutex_destroy(&wait.lock);return failed||!zero();
}
static int failure_terminal(void){
    int failed=0;Pair p={0};Consumer c={0};
    const int modes[]={WRITE_SHORT,WRITE_LONG,WRITE_EMPTY,WRITE_HEAD_BODY};
    const int expected[]={ZWK_FILE_LENGTH_MISMATCH,ZWK_FILE_LENGTH_MISMATCH,ZWK_FILE_INVALID_CHUNK,ZWK_FILE_UNEXPECTED_BODY};
    for(unsigned i=0;i<G_N_ELEMENTS(modes);i++){
        CHECK(prepare(&p,1,-1)==0);CHECK(admit(&p,&c,modes[i]==WRITE_HEAD_BODY)==0);
        Write w={.writer=p.writer,.length=1,.mode=modes[i]};CHECK(!write_join(&w));CHECK(w.result==expected[i]);
        consumer_clear(&c);pair_clear(&p);CHECK(zero());
    }
    CHECK(prepare(&p,16,-1)==0);CHECK(admit(&p,&c,0)==0);zwk_stream_test_send_error_after(7);
    Write w={.writer=p.writer,.length=16,.mode=WRITE_NORMAL};CHECK(!write_join(&w));CHECK(w.result==ZWK_FILE_IO&&w.code==EIO&&zwk_stream_test_sent()==7);
done:zwk_stream_test_send_error_after(-1);consumer_clear(&c);pair_clear(&p);return failed||!zero();
}
static int wrong_kind(void){
    int failed=0,fd=-1;Pair p={0};Consumer c={0};
    CHECK(prepare(&p,0,-1)==0);Write generated={.writer=p.writer,.mode=WRITE_FILE_PUMP};CHECK(!write_join(&generated));CHECK(generated.result==ZWK_FILE_SOURCE_KIND);
    CHECK(admit(&p,&c,0)==0);Write finish={.writer=p.writer,.mode=WRITE_NORMAL};CHECK(!write_join(&finish));CHECK(!finish.result);consumer_clear(&c);pair_clear(&p);
    fd=memfd_create("native-stream-private",MFD_CLOEXEC);CHECK(fd>=0&&write(fd,"abc",3)==3);
    CHECK(prepare(&p,0,fd)==0);Write file={.writer=p.writer,.mode=WRITE_BEGIN};CHECK(!write_join(&file));CHECK(file.result==ZWK_FILE_SOURCE_KIND);
    CHECK(admit(&p,&c,1)==0);file.mode=WRITE_FILE_PUMP;CHECK(!write_join(&file));CHECK(!file.result);CHECK(zwk_stream_test_read(c.stream,0));
done:consumer_clear(&c);pair_clear(&p);if(fd>=0)close(fd);return failed||!zero();
}
static int oom_and_retry(void){
    int failed=0;Pair p={0};Consumer c={0};int code=0;
    for(int limit=0;limit<2;limit++){
        zwk_file_test_allocation_limit(limit);CHECK(prepare(&p,8,-1)==ZWK_FILE_OOM);CHECK(!p.source&&!p.writer&&zero());
    }
    zwk_file_test_allocation_limit(-1);CHECK(prepare(&p,8,-1)==0);c.budget=zwk_file_budget_create(1);CHECK(c.budget);
    zwk_file_test_allocation_limit(0);CHECK(zwk_file_prepare_stream(p.source,c.budget,0,&c.candidate,&code)==ZWK_FILE_OOM);CHECK(!c.candidate&&zwk_file_budget_live(c.budget)==0);
    zwk_file_test_allocation_limit(-1);CHECK(zwk_file_prepare_stream(p.source,c.budget,0,&c.candidate,&code)==0);zwk_file_candidate_abort(c.candidate);c.candidate=NULL;CHECK(zwk_file_budget_live(c.budget)==0);
    CHECK(zwk_file_prepare_stream(p.source,c.budget,1,&c.candidate,&code)==0);c.stream=g_object_ref(zwk_file_candidate_stream(c.candidate));zwk_file_candidate_admit(c.candidate,0,1,&c.control);c.candidate=NULL;
    Write w={.writer=p.writer,.mode=WRITE_NORMAL};CHECK(!write_join(&w));CHECK(!w.result&&w.head);
done:zwk_file_test_allocation_limit(-1);consumer_clear(&c);pair_clear(&p);return failed||!zero();
}
static int shared_capacity(void){
    int failed=0,fd=-1;Pair p[ZWK_FILE_PROCESS_LIMIT+1]={{0}};Consumer c={0};
    fd=memfd_create("native-stream-capacity",MFD_CLOEXEC);CHECK(fd>=0&&write(fd,"abc",3)==3);
    for(unsigned i=0;i<ZWK_FILE_PROCESS_LIMIT;i++)CHECK(prepare(&p[i],3,i%2?fd:-1)==0);
    CHECK(prepare(&p[ZWK_FILE_PROCESS_LIMIT],3,-1)==ZWK_FILE_FULL);
    CHECK(admit(&p[0],&c,0)==0);pair_clear(&p[0]);
    for(unsigned i=1;i<ZWK_FILE_PROCESS_LIMIT;i++)pair_clear(&p[i]);
    for(unsigned i=1;i<ZWK_FILE_PROCESS_LIMIT;i++)CHECK(prepare(&p[i],3,-1)==0);
    CHECK(prepare(&p[ZWK_FILE_PROCESS_LIMIT],3,-1)==ZWK_FILE_FULL);
    consumer_clear(&c);CHECK(prepare(&p[0],3,-1)==0);
done:consumer_clear(&c);for(unsigned i=0;i<G_N_ELEMENTS(p);i++)pair_clear(&p[i]);if(fd>=0)close(fd);return failed||!zero();
}
int zwk_native_stream_test_run(void){
    owner=(uint64_t)syscall(SYS_gettid);
    int (*groups[])(void)={terminal_monotonic,generated_bytes,head_and_zero,blocked_cancel,failure_terminal,wrong_kind,oom_and_retry,shared_capacity};
    for(unsigned i=0;i<G_N_ELEMENTS(groups);i++){if(groups[i]()){fprintf(stderr,"native stream group %u failed\n",i+1);return 1;}}
    uint32_t bytes,kind,thread,produced;zwk_stream_test_layout(&bytes,&kind,&thread,&produced);
    fprintf(stderr,"native stream: 8 groups; physical bytes=%u kind/thread/position=%u/%u/%u; resources0\n",bytes,kind,thread,produced);return 0;
}
