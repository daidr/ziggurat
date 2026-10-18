#define _GNU_SOURCE
#include <libsoup/soup.h>
#include <sys/mman.h>
#include <fcntl.h>
#include <unistd.h>
#include <sys/socket.h>
#include <netinet/in.h>
#include <sys/time.h>
#include <errno.h>
#include "../src/https_resources/transport_linux.h"

/* Test-only observation of the actual public Transport's peer. Independent C
 * refs/closure; no App/Zig pointer, body read, header mutation or secret copy. */
typedef struct PageObserver { unsigned refs,requests,authorization; } PageObserver;
static unsigned observers;
static void observer_unref(PageObserver *value){if(!--value->refs){--observers;g_free(value);}}
static void observer_closure(gpointer pointer,GClosure *closure){(void)closure;observer_unref(pointer);}
static void observed_request(SoupServer *server,SoupServerMessage *message,gpointer pointer){
    (void)server;PageObserver *value=pointer;++value->requests;
    if(soup_message_headers_get_one(soup_server_message_get_request_headers(message),"Authorization"))++value->authorization;
}
void *zhr_page_observer_new(void *transport){
    ZhtLease lease={0};if(zht_lease_begin(transport,&lease))return NULL;
    PageObserver *value=g_new0(PageObserver,1);value->refs=2;++observers;
    g_signal_connect_data(lease.server,"request-read",G_CALLBACK(observed_request),value,observer_closure,0);
    if(zht_lease_finish(&lease)){observer_unref(value);return NULL;}
    return value;
}
void zhr_page_observer_read(void *pointer,unsigned *requests,unsigned *authorization){PageObserver *value=pointer;*requests=value->requests;*authorization=value->authorization;}
void zhr_page_observer_release(void *pointer){observer_unref(pointer);}
unsigned zhr_page_observer_count(void){return observers;}
/* Explicit test worker only, after App.run returned. No GTK/main-thread wait.
 * Socket timeout bounds this own-loopback diagnostic if refusal regresses. */
int zhr_page_connect_refused(unsigned port){
    int fd=socket(AF_INET,SOCK_STREAM|SOCK_CLOEXEC,0);if(fd<0)return errno;
    struct timeval timeout={2,0};
    if(setsockopt(fd,SOL_SOCKET,SO_SNDTIMEO,&timeout,sizeof(timeout))){int failure=errno;close(fd);return failure;}
    struct sockaddr_in address={.sin_family=AF_INET,.sin_port=htons((uint16_t)port),.sin_addr={htonl(INADDR_LOOPBACK)}};
    int result=connect(fd,(struct sockaddr *)&address,sizeof(address));int failure=errno;close(fd);
    return result<0 && failure==ECONNREFUSED?0:result==0?-1:failure;
}
int zhr_page_file(void){
    int fd=memfd_create("https-page-private",MFD_CLOEXEC|MFD_ALLOW_SEALING);
    if(fd<0)return -1;
    unsigned char bytes[4096];size_t offset=0,total=524325;
    while(offset<total){
        size_t count=total-offset;if(count>sizeof(bytes))count=sizeof(bytes);
        for(size_t i=0;i<count;++i)bytes[i]=(unsigned char)((offset+i)%251);
        ssize_t wrote=write(fd,bytes,count);
        if(wrote<=0){close(fd);return -1;}
        offset+=(size_t)wrote;
    }
    if(fcntl(fd,F_ADD_SEALS,F_SEAL_WRITE|F_SEAL_GROW|F_SEAL_SHRINK|F_SEAL_SEAL)<0){close(fd);return -1;}
    return fd;
}
int zhr_page_empty_file(void){
    int fd=memfd_create("https-page-empty",MFD_CLOEXEC|MFD_ALLOW_SEALING);
    if(fd<0)return -1;
    if(fcntl(fd,F_ADD_SEALS,F_SEAL_WRITE|F_SEAL_GROW|F_SEAL_SHRINK|F_SEAL_SEAL)<0){close(fd);return -1;}
    return fd;
}
