#define _GNU_SOURCE
#include "linux.h"
#include <gio/gfiledescriptorbased.h>
#include <glib-unix.h>
#include <errno.h>
#include <fcntl.h>
#include <poll.h>
#include <stdatomic.h>
#include <stdlib.h>
#include <stddef.h>
#include <sys/eventfd.h>
#include <sys/socket.h>
#include <sys/stat.h>
#include <sys/syscall.h>
#include <unistd.h>

enum { GATE_PREPARED, GATE_GET, GATE_HEAD };
enum { SOURCE_FILE=1, SOURCE_GENERATED=2 };
struct ZwkFileControl { atomic_uint refs; atomic_int cancelled,alive,gate; int event; GCancellable *read_cancel; };
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
struct ZwkFileCandidate { ZwkFile *file; GInputStream *stream; ZwkFileBudget *budget; int head; };
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
    uint64_t one=1;ssize_t result;
    do { result=write(control->event,&one,sizeof(one)); } while(result<0&&errno==EINTR);
}
void zwk_file_control_add(ZwkFileControl *control){atomic_fetch_add_explicit(&control->refs,1,memory_order_relaxed);}
void zwk_file_control_release(ZwkFileControl *control){
    if(!control||atomic_fetch_sub_explicit(&control->refs,1,memory_order_acq_rel)!=1)return;
    close(control->event);g_object_unref(control->read_cancel);free(control);atomic_fetch_sub_explicit(&live_controls,1,memory_order_relaxed);
}
void zwk_file_control_cancel(ZwkFileControl *control){
    if(control&&!atomic_exchange_explicit(&control->cancelled,1,memory_order_acq_rel)){signal_control(control);g_cancellable_cancel(control->read_cancel);}
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
    if(!atomic_load_explicit(&file->finished,memory_order_acquire))zwk_file_control_cancel(file->control);
    physical_release(file);
}
static int native_error(int *output,int result){if(output)*output=errno;return result;}
static int prepare_channel(int source,uint64_t ui_thread,uint64_t maximum,int window,uint64_t offset,uint64_t count,unsigned kind,ZwkFile **response,ZwkFile **pump,uint64_t *length,int *native_errno){
    if(native_errno)*native_errno=0;
    if(!response||!pump||!length)return ZWK_FILE_INVALID;
    *response=NULL;*pump=NULL;*length=0;
    if((uint64_t)syscall(SYS_gettid)==ui_thread)return ZWK_FILE_UI_THREAD;
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
    int descriptor=-1,sockets[2]={-1,-1},event=-1,result=ZWK_FILE_OOM;
    if(!file||!control)goto failed;
    if(kind==SOURCE_FILE){descriptor=fcntl(source,F_DUPFD_CLOEXEC,0);if(descriptor<0){result=native_error(native_errno,ZWK_FILE_IO);goto failed;}}
    if(socketpair(AF_UNIX,SOCK_STREAM|SOCK_NONBLOCK|SOCK_CLOEXEC,0,sockets)<0){result=native_error(native_errno,ZWK_FILE_IO);goto failed;}
    int bytes=32768;socklen_t bytes_size=sizeof(bytes);
    if(setsockopt(sockets[1],SOL_SOCKET,SO_SNDBUF,&bytes,sizeof(bytes))<0||getsockopt(sockets[1],SOL_SOCKET,SO_SNDBUF,&bytes,&bytes_size)<0){result=native_error(native_errno,ZWK_FILE_IO);goto failed;}
    if(bytes<=0||bytes>131072){result=ZWK_FILE_INVALID;goto failed;}
    event=eventfd(0,EFD_CLOEXEC|EFD_NONBLOCK);if(event<0){result=native_error(native_errno,ZWK_FILE_IO);goto failed;}
    atomic_init(&control->refs,1);atomic_init(&control->cancelled,0);atomic_init(&control->alive,1);atomic_init(&control->gate,GATE_PREPARED);control->event=event;
    control->read_cancel=g_cancellable_new();
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
    if(event>=0)close(event);
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
static void drain_event(ZwkFileControl *control){uint64_t value;while(read(control->event,&value,sizeof(value))<0&&errno==EINTR){}}
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
    if((uint64_t)syscall(SYS_gettid)==file->ui_thread)return ZWK_FILE_UI_THREAD;
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
            ssize_t n=send(file->writer,bytes+sent,(size_t)received-sent,MSG_NOSIGNAL);
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
    const int current=(int)syscall(SYS_gettid);
    if((uint64_t)current==file->ui_thread)return ZWK_FILE_UI_THREAD;
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
    ssize_t result=send(file->writer,bytes,count,MSG_NOSIGNAL);
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

enum { STREAM_ACTIVE=1,STREAM_CLOSED=2 };
typedef struct ZwpInput { GInputStream parent; ZwkFile *file; atomic_int lifecycle; uint64_t received; int descriptor; } ZwpInput;
typedef struct ZwpInputClass { GInputStreamClass parent; } ZwpInputClass;
static void input_pollable_interface_init(GPollableInputStreamInterface *iface);
static void input_descriptor_interface_init(GFileDescriptorBasedIface *iface);
G_DEFINE_TYPE_WITH_CODE(ZwpInput,zwp_input,G_TYPE_INPUT_STREAM,
    G_IMPLEMENT_INTERFACE(G_TYPE_POLLABLE_INPUT_STREAM,input_pollable_interface_init)
    G_IMPLEMENT_INTERFACE(G_TYPE_FILE_DESCRIPTOR_BASED,input_descriptor_interface_init))
static gboolean input_can_poll(GPollableInputStream *stream){(void)stream;return TRUE;}
static gboolean input_readable(GPollableInputStream *stream){
    ZwpInput *input=(ZwpInput *)stream;
    if(input->file&&atomic_load_explicit(&input->file->control->cancelled,memory_order_acquire))return TRUE;
    if(input->descriptor<0)return TRUE;
    struct pollfd item={input->descriptor,POLLIN,0};int result;
    do{result=poll(&item,1,0);}while(result<0&&errno==EINTR);
    return result!=0;
}
static GSource *input_source(GPollableInputStream *stream,GCancellable *cancellable){
    GSource *source=g_pollable_source_new(G_OBJECT(stream));
    ZwpInput *input=(ZwpInput *)stream;
    if(input->descriptor>=0){
        GSource *socket=g_unix_fd_source_new(input->descriptor,G_IO_IN|G_IO_HUP|G_IO_ERR);
        g_source_set_dummy_callback(socket);g_source_add_child_source(source,socket);g_source_unref(socket);
    }else g_source_set_ready_time(source,0);
    if(cancellable){
        GSource *cancel=g_cancellable_source_new(cancellable);
        g_source_set_dummy_callback(cancel);g_source_add_child_source(source,cancel);g_source_unref(cancel);
    }
    if(input->file){
        GSource *cancel=g_cancellable_source_new(input->file->control->read_cancel);
        g_source_set_dummy_callback(cancel);g_source_add_child_source(source,cancel);g_source_unref(cancel);
    }
    return source;
}
static gssize input_nonblocking(GPollableInputStream *stream,void *buffer,gsize count,GError **error);
static void input_pollable_interface_init(GPollableInputStreamInterface *iface){
    iface->can_poll=input_can_poll;iface->is_readable=input_readable;iface->create_source=input_source;iface->read_nonblocking=input_nonblocking;
}
static int input_descriptor(GFileDescriptorBased *stream){return ((ZwpInput *)stream)->descriptor;}
static void input_descriptor_interface_init(GFileDescriptorBasedIface *iface){iface->get_fd=input_descriptor;}
static gssize input_read(GInputStream *stream,void *buffer,gsize count,GCancellable *cancellable,GError **error){
    if(g_cancellable_set_error_if_cancelled(cancellable,error))return -1;
    ZwpInput *input=(ZwpInput *)stream;
    if(input->file&&g_cancellable_set_error_if_cancelled(input->file->control->read_cancel,error))return -1;
    if(input->descriptor<0){g_set_error_literal(error,G_IO_ERROR,G_IO_ERROR_CLOSED,"File response stream is closed");return -1;}
    ssize_t result;
    do{result=recv(input->descriptor,buffer,count,MSG_DONTWAIT);}while(result<0&&errno==EINTR);
    if(result<0){int code=errno;g_set_error(error,G_IO_ERROR,g_io_error_from_errno(code),"Socket read: %s",g_strerror(code));return -1;}
    if(result>0){input->received+=(uint64_t)result;return result;}
    ZwkFile *file=input->file;
    if(file&&atomic_load_explicit(&file->finished,memory_order_acquire)==1){
        int terminal=atomic_load_explicit(&file->pump_result,memory_order_relaxed);
        int code=atomic_load_explicit(&file->pump_errno,memory_order_relaxed);
        if(terminal==ZWK_FILE_CANCELLED){g_set_error_literal(error,G_IO_ERROR,G_IO_ERROR_CANCELLED,"File transfer cancelled");return -1;}
        if(terminal==ZWK_FILE_IO){g_set_error(error,G_IO_ERROR,code?g_io_error_from_errno(code):G_IO_ERROR_FAILED,"File transfer: %s",code?g_strerror(code):"I/O failure");return -1;}
        int head=atomic_load_explicit(&file->control->gate,memory_order_acquire)==GATE_HEAD;
        if(terminal!=ZWK_FILE_OK||(!head&&input->received!=file->length)){g_set_error_literal(error,G_IO_ERROR,G_IO_ERROR_PARTIAL_INPUT,"Incomplete private file transfer");return -1;}
    }
    return result;
}
static gssize input_nonblocking(GPollableInputStream *stream,void *buffer,gsize count,GError **error){return input_read(G_INPUT_STREAM(stream),buffer,count,NULL,error);}
static gboolean input_close(GInputStream *stream,GCancellable *cancellable,GError **error){
    (void)cancellable;
    ZwpInput *input=(ZwpInput *)stream;
    int previous=atomic_fetch_or_explicit(&input->lifecycle,STREAM_CLOSED,memory_order_acq_rel);
    if(input->file&&(previous&STREAM_ACTIVE))zwk_file_control_cancel(input->file->control);
    int descriptor=input->descriptor;input->descriptor=-1;
    /* This private AF_UNIX socket has no linger and is always nonblocking.
       On Linux close(EINTR) has released the descriptor; never retry it. */
    if(descriptor>=0&&close(descriptor)<0){int code=errno;g_set_error(error,G_IO_ERROR,g_io_error_from_errno(code),"Socket close: %s",g_strerror(code));return FALSE;}
    return TRUE;
}
/* A private GAsyncResult avoids even GTask's lazy pool infrastructure. Each
   pending stream operation owns one fixed-size result and one readiness/idle
   source on the caller's context. Neither dispatch nor close touches the file. */
enum { ASYNC_READ,ASYNC_SKIP,ASYNC_CLOSE };
typedef struct ZwpAsync {
    GObject parent;
    GInputStream *stream;
    GMainContext *context;
    GCancellable *cancellable;
    GAsyncReadyCallback callback;
    gpointer data;
    void *buffer;
    gsize count;
    gssize value;
    int kind,priority,finished;
    GError *error;
} ZwpAsync;
typedef struct ZwpAsyncClass { GObjectClass parent; } ZwpAsyncClass;
static void async_interface_init(GAsyncResultIface *iface);
G_DEFINE_TYPE_WITH_CODE(ZwpAsync,zwp_async,G_TYPE_OBJECT,G_IMPLEMENT_INTERFACE(G_TYPE_ASYNC_RESULT,async_interface_init))
typedef struct ZwpSkipAsync { ZwpAsync parent; unsigned char scratch[ZWK_FILE_CHUNK_BYTES]; } ZwpSkipAsync;
typedef struct ZwpSkipAsyncClass { ZwpAsyncClass parent; } ZwpSkipAsyncClass;
G_DEFINE_TYPE(ZwpSkipAsync,zwp_skip_async,zwp_async_get_type())
static void zwp_skip_async_class_init(ZwpSkipAsyncClass *type){(void)type;}
static void zwp_skip_async_init(ZwpSkipAsync *async){(void)async;}
static gpointer async_user_data(GAsyncResult *result){return ((ZwpAsync *)result)->data;}
static GObject *async_source_object(GAsyncResult *result){return g_object_ref(G_OBJECT(((ZwpAsync *)result)->stream));}
static gboolean async_tagged(GAsyncResult *result,gpointer tag){(void)result;(void)tag;return FALSE;}
static void async_interface_init(GAsyncResultIface *iface){iface->get_user_data=async_user_data;iface->get_source_object=async_source_object;iface->is_tagged=async_tagged;}
static void async_finalize(GObject *object){
    ZwpAsync *async=(ZwpAsync *)object;
    g_clear_object(&async->stream);g_clear_object(&async->cancellable);g_clear_error(&async->error);g_main_context_unref(async->context);
    G_OBJECT_CLASS(zwp_async_parent_class)->finalize(object);
}
static void zwp_async_class_init(ZwpAsyncClass *type){G_OBJECT_CLASS(type)->finalize=async_finalize;}
static void zwp_async_init(ZwpAsync *async){(void)async;}
static ZwpAsync *async_new(GInputStream *stream,int kind,int priority,GCancellable *cancellable,GAsyncReadyCallback callback,gpointer data){
    ZwpAsync *async=g_object_new(kind==ASYNC_SKIP?zwp_skip_async_get_type():zwp_async_get_type(),NULL);
    async->stream=g_object_ref(stream);async->context=g_main_context_ref_thread_default();
    async->kind=kind;async->priority=priority;async->cancellable=cancellable?g_object_ref(cancellable):NULL;async->callback=callback;async->data=data;return async;
}
static void async_complete(ZwpAsync *async){if(async->callback)async->callback(G_OBJECT(async->stream),G_ASYNC_RESULT(async),async->data);}
static gboolean async_attempt(ZwpAsync *async){
    gsize count=async->kind==ASYNC_SKIP?MIN(ZWK_FILE_CHUNK_BYTES,async->count-(gsize)async->value):async->count;
    void *buffer=async->kind==ASYNC_SKIP?((ZwpSkipAsync *)async)->scratch:async->buffer;
    gssize value=g_pollable_input_stream_read_nonblocking(G_POLLABLE_INPUT_STREAM(async->stream),buffer,count,async->cancellable,&async->error);
    if(value<0&&g_error_matches(async->error,G_IO_ERROR,G_IO_ERROR_WOULD_BLOCK)){g_clear_error(&async->error);return FALSE;}
    if(value<0){async->value=-1;return TRUE;}
    if(async->kind==ASYNC_SKIP){async->value+=value;return !value||(gsize)async->value==async->count;}
    async->value=value;return TRUE;
}
static void async_wait(ZwpAsync *async);
static gboolean async_ready(GObject *stream,gpointer data){
    (void)stream;ZwpAsync *async=data;
    if(async_attempt(async))async_complete(async);else async_wait(g_object_ref(async));
    return G_SOURCE_REMOVE;
}
static void async_wait(ZwpAsync *async){
    GSource *source=g_pollable_input_stream_create_source(G_POLLABLE_INPUT_STREAM(async->stream),async->cancellable);
    g_source_set_priority(source,async->priority);g_source_set_callback(source,G_SOURCE_FUNC(async_ready),async,g_object_unref);
    g_source_attach(source,async->context);g_source_unref(source);
}
static gboolean async_idle(gpointer data){async_complete(data);return G_SOURCE_REMOVE;}
static void async_queue(ZwpAsync *async){
    GSource *source=g_idle_source_new();g_source_set_priority(source,async->priority);g_source_set_callback(source,async_idle,async,g_object_unref);
    g_source_attach(source,async->context);g_source_unref(source);
}
static void input_read_async(GInputStream *stream,void *buffer,gsize count,int priority,GCancellable *cancellable,GAsyncReadyCallback callback,gpointer data){
    ZwpAsync *async=async_new(stream,ASYNC_READ,priority,cancellable,callback,data);async->buffer=buffer;async->count=count;
    if(async_attempt(async))async_queue(async);else async_wait(async);
}
static void input_skip_async(GInputStream *stream,gsize count,int priority,GCancellable *cancellable,GAsyncReadyCallback callback,gpointer data){
    ZwpAsync *async=async_new(stream,ASYNC_SKIP,priority,cancellable,callback,data);async->count=count;
    if(async_attempt(async))async_queue(async);else async_wait(async);
}
static void input_close_async(GInputStream *stream,int priority,GCancellable *cancellable,GAsyncReadyCallback callback,gpointer data){
    ZwpAsync *async=async_new(stream,ASYNC_CLOSE,priority,cancellable,callback,data);
    async->value=input_close(stream,cancellable,&async->error);async_queue(async);
}
static gssize async_finish(GInputStream *stream,GAsyncResult *result,int kind,GError **error){
    if(!G_TYPE_CHECK_INSTANCE_TYPE(result,zwp_async_get_type())){g_set_error_literal(error,G_IO_ERROR,G_IO_ERROR_INVALID_ARGUMENT,"Foreign stream result");return -1;}
    ZwpAsync *async=(ZwpAsync *)result;
    if(async->stream!=stream||async->kind!=kind||async->finished){g_set_error_literal(error,G_IO_ERROR,G_IO_ERROR_INVALID_ARGUMENT,"Stale stream result");return -1;}
    async->finished=1;if(async->error){g_propagate_error(error,g_steal_pointer(&async->error));return -1;}return async->value;
}
static gssize input_read_finish(GInputStream *stream,GAsyncResult *result,GError **error){return async_finish(stream,result,ASYNC_READ,error);}
static gssize input_skip_finish(GInputStream *stream,GAsyncResult *result,GError **error){return async_finish(stream,result,ASYNC_SKIP,error);}
static gboolean input_close_finish(GInputStream *stream,GAsyncResult *result,GError **error){return async_finish(stream,result,ASYNC_CLOSE,error)>0;}
static void input_finalize(GObject *object){
    ZwpInput *input=(ZwpInput *)object;ZwkFile *file=input->file;
    (void)input_close(G_INPUT_STREAM(input),NULL,NULL);
    input->file=NULL;
    G_OBJECT_CLASS(zwp_input_parent_class)->finalize(object);physical_release(file);
}
static void zwp_input_class_init(ZwpInputClass *type){
    GInputStreamClass *stream=G_INPUT_STREAM_CLASS(type);
    stream->read_fn=input_read;
    stream->read_async=input_read_async;stream->read_finish=input_read_finish;stream->skip_async=input_skip_async;stream->skip_finish=input_skip_finish;
    stream->close_fn=input_close;stream->close_async=input_close_async;stream->close_finish=input_close_finish;
    G_OBJECT_CLASS(type)->finalize=input_finalize;
}
static void zwp_input_init(ZwpInput *input){input->file=NULL;input->received=0;input->descriptor=-1;atomic_init(&input->lifecycle,0);}
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
    if(!candidate){atomic_fetch_sub_explicit(&budget->live,1,memory_order_acq_rel);zwk_file_budget_release(budget);atomic_store_explicit(&file->binding,0,memory_order_release);return ZWK_FILE_OOM;}
    int descriptor=fcntl(file->reader,F_DUPFD_CLOEXEC,0);
    if(descriptor<0){int result=native_error(native_errno,ZWK_FILE_IO);free(candidate);atomic_fetch_sub_explicit(&budget->live,1,memory_order_acq_rel);zwk_file_budget_release(budget);atomic_store_explicit(&file->binding,0,memory_order_release);return result;}
    ZwpInput *input=g_object_new(zwp_input_get_type(),NULL);input->descriptor=descriptor;
    physical_add(file);input->file=file;
    physical_add(file);candidate->file=file;candidate->stream=G_INPUT_STREAM(input);candidate->budget=budget;candidate->head=!!head;
    atomic_fetch_add_explicit(&live_candidates,1,memory_order_relaxed);*output=candidate;return ZWK_FILE_OK;
}
GInputStream *zwk_file_candidate_stream(ZwkFileCandidate *candidate){return candidate->stream;}
ZwkFileControl *zwk_file_candidate_control(ZwkFileCandidate *candidate){return candidate->file->control;}
void zwk_file_candidate_abort(ZwkFileCandidate *candidate){
    if(!candidate)return;
    ZwkFile *file=candidate->file;
    g_object_unref(candidate->stream);atomic_fetch_sub_explicit(&candidate->budget->live,1,memory_order_acq_rel);zwk_file_budget_release(candidate->budget);
    atomic_store_explicit(&file->binding,0,memory_order_release);physical_release(file);free(candidate);atomic_fetch_sub_explicit(&live_candidates,1,memory_order_relaxed);
}
void zwk_file_candidate_admit(ZwkFileCandidate *candidate,int cancelled,int want_ticket,ZwkFileControl **ticket){
    ZwkFile *file=candidate->file;ZwkFileControl *control=file->control;
    if(ticket)*ticket=NULL;
    file->budget=candidate->budget;candidate->budget=NULL;
    int stream_state=atomic_fetch_or_explicit(&((ZwpInput *)candidate->stream)->lifecycle,STREAM_ACTIVE,memory_order_acq_rel);
    atomic_store_explicit(&file->binding,2,memory_order_release);
    if(cancelled||(stream_state&STREAM_CLOSED))zwk_file_control_cancel(control);
    atomic_store_explicit(&control->gate,candidate->head?GATE_HEAD:GATE_GET,memory_order_release);
    if(want_ticket&&ticket){zwk_file_control_add(control);*ticket=control;}
    close(file->reader);file->reader=-1;signal_control(control);
    g_object_unref(candidate->stream);physical_release(file);free(candidate);atomic_fetch_sub_explicit(&live_candidates,1,memory_order_relaxed);
}
void zwk_file_candidate_commit(ZwkFileCandidate *candidate,int cancelled,int want_ticket,ZwkFileControl **ticket){
    zwk_file_candidate_admit(candidate,cancelled,want_ticket,ticket);
}
void zwk_file_counts(uint32_t *physical,uint32_t *controls,uint32_t *budgets,uint32_t *candidates){
    *physical=atomic_load_explicit(&live_physical,memory_order_acquire);*controls=atomic_load_explicit(&live_controls,memory_order_acquire);*budgets=atomic_load_explicit(&live_budgets,memory_order_acquire);*candidates=atomic_load_explicit(&live_candidates,memory_order_acquire);
}
uint64_t zwk_file_pread_count(void){return atomic_load_explicit(&pread_count,memory_order_acquire);}
