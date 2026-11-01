/* Two loopback HTTP servers for the macOS remote page smoke: the granted
 * origin serves the documents, a script, data and a redirect; the other
 * origin, never granted, counts every request that reaches it. A thread
 * per connection keeps an idle preconnect from holding the others. */
#include <arpa/inet.h>
#include <errno.h>
#include <netinet/in.h>
#include <pthread.h>
#include <stdatomic.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <strings.h>
#include <sys/socket.h>
#include <sys/time.h>
#include <unistd.h>

typedef struct Fixture Fixture;
typedef struct Server {
    Fixture *fixture;
    int fd, port, other;
    atomic_int stopping;
    atomic_uint requests;
    pthread_t thread;
    int started;
} Server;
struct Fixture {
    Server main, other;
    atomic_uint redirects, active;
    char origin[64], other_origin[64];
};
typedef struct Connection { Server *server; int fd; } Connection;

static const char page_format[]=
    "<!doctype html><title>remote</title><script src=\"/app.js\"></script><script>"
    "chrome.webview.addEventListener('message',e=>chrome.webview.postMessage('ack:'+e.data));"
    "addEventListener('DOMContentLoaded',async()=>{const r=[location.pathname,!!window.appLoaded];"
    "try{r.push(await (await fetch('/data')).text())}catch(e){r.push('read-failed')}"
    "r.push(await fetch('/data',{method:'POST'}).then(x=>x.text(),()=>'denied'));"
    "r.push(await new Promise(f=>{const i=new Image();i.onload=()=>f('loaded');i.onerror=()=>f('blocked');i.src='%s/pixel.gif'}));"
    "chrome.webview.postMessage('boot:'+r.join(' '))});"
    "</script>";
static const unsigned char pixel[]={0x47,0x49,0x46,0x38,0x39,0x61,1,0,1,0,0x80,0,0,0,0,0,0xff,0xff,0xff,0x21,0xf9,4,1,0,0,0,0,0x2c,0,0,0,0,1,0,1,0,0,2,2,0x44,1,0};

static void send_all(int fd,const void *data,size_t length) {
    const char *p=data;
    while (length) {
        const ssize_t n=send(fd,p,length,0);
        if (n<=0) { if (n<0 && errno==EINTR) continue; return; }
        p+=n; length-=(size_t)n;
    }
}
static void reply(int fd,const char *status,const char *type,const char *extra,const void *body,size_t length) {
    char head[512];
    const int n=snprintf(head,sizeof(head),"HTTP/1.1 %s\r\nContent-Type: %s\r\nContent-Length: %zu\r\nCache-Control: no-store\r\nConnection: close\r\n%s\r\n",
        status,type,length,extra?extra:"");
    if (n<=0 || (size_t)n>=sizeof(head)) return;
    send_all(fd,head,(size_t)n);
    if (length) send_all(fd,body,length);
}
static void handle(Server *server,int fd) {
    char request[8192]; size_t used=0;
    while (used<sizeof(request)-1) {
        const ssize_t n=recv(fd,request+used,sizeof(request)-1-used,0);
        if (n<=0) { if (n<0 && errno==EINTR) continue; return; }
        used+=(size_t)n; request[used]=0;
        if (strstr(request,"\r\n\r\n")) break;
    }
    char method[16], path[1024];
    if (sscanf(request,"%15s %1023s",method,path)!=2) return;
    atomic_fetch_add(&server->requests,1);
    Fixture *fixture=server->fixture;
    char *query=strpbrk(path,"?#"); if (query) *query=0;
    if (server->other) { reply(fd,"200 OK","image/gif",NULL,pixel,sizeof(pixel)); return; }
    if (!strcmp(path,"/") || !strcmp(path,"/second")) {
        char body[2048];
        const int n=snprintf(body,sizeof(body),page_format,fixture->other_origin);
        if (n>0 && (size_t)n<sizeof(body)) reply(fd,"200 OK","text/html",NULL,body,(size_t)n);
    } else if (!strcmp(path,"/app.js")) {
        static const char script[]="window.appLoaded=true";
        reply(fd,"200 OK","text/javascript",NULL,script,sizeof(script)-1);
    } else if (!strcmp(path,"/data")) {
        const int post=!strcmp(method,"POST");
        reply(fd,"200 OK","text/plain",NULL,post?"posted":"ok",post?6:2);
    } else if (!strcmp(path,"/redirect")) {
        atomic_fetch_add(&fixture->redirects,1);
        reply(fd,"302 Found","text/plain","Location: /second\r\n",NULL,0);
    } else reply(fd,"404 Not Found","text/plain",NULL,NULL,0);
}
static void *connection(void *data) {
    Connection *value=data;
    Fixture *fixture=value->server->fixture;
    handle(value->server,value->fd);
    close(value->fd); free(value);
    atomic_fetch_sub(&fixture->active,1);
    return NULL;
}
static void *serve(void *data) {
    Server *server=data;
    for (;;) {
        const int fd=accept(server->fd,NULL,NULL);
        if (atomic_load(&server->stopping)) { if (fd>=0) close(fd); return NULL; }
        if (fd<0) continue;
        struct timeval timeout={.tv_sec=5};
        setsockopt(fd,SOL_SOCKET,SO_RCVTIMEO,&timeout,sizeof(timeout));
        Connection *value=malloc(sizeof(*value));
        pthread_t thread;
        if (!value) { close(fd); continue; }
        value->server=server; value->fd=fd;
        atomic_fetch_add(&server->fixture->active,1);
        if (pthread_create(&thread,NULL,connection,value)) { atomic_fetch_sub(&server->fixture->active,1); close(fd); free(value); continue; }
        pthread_detach(thread);
    }
}
static int server_start(Fixture *fixture,Server *server,int other) {
    server->fixture=fixture; server->other=other;
    server->fd=socket(AF_INET,SOCK_STREAM,0);
    if (server->fd<0) return 0;
    const int yes=1;
    setsockopt(server->fd,SOL_SOCKET,SO_REUSEADDR,&yes,sizeof(yes));
    struct sockaddr_in address={.sin_family=AF_INET,.sin_addr.s_addr=htonl(INADDR_LOOPBACK)};
    socklen_t length=sizeof(address);
    if (bind(server->fd,(struct sockaddr *)&address,sizeof(address)) || listen(server->fd,64) ||
        getsockname(server->fd,(struct sockaddr *)&address,&length)) { close(server->fd); server->fd=-1; return 0; }
    server->port=ntohs(address.sin_port);
    if (pthread_create(&server->thread,NULL,serve,server)) { close(server->fd); server->fd=-1; return 0; }
    server->started=1;
    return 1;
}
static void server_stop(Server *server) {
    if (!server->started) return;
    atomic_store(&server->stopping,1);
    /* Wakes the accept with a connection of its own. */
    const int fd=socket(AF_INET,SOCK_STREAM,0);
    struct sockaddr_in address={.sin_family=AF_INET,.sin_port=htons((uint16_t)server->port),.sin_addr.s_addr=htonl(INADDR_LOOPBACK)};
    if (fd>=0) { (void)connect(fd,(struct sockaddr *)&address,sizeof(address)); close(fd); }
    pthread_join(server->thread,NULL);
    close(server->fd);
    server->started=0;
}

void *ztest_remote_fixture_new(void) {
    Fixture *fixture=calloc(1,sizeof(Fixture));
    if (!fixture) return NULL;
    if (!server_start(fixture,&fixture->main,0) || !server_start(fixture,&fixture->other,1)) { server_stop(&fixture->main); free(fixture); return NULL; }
    snprintf(fixture->origin,sizeof(fixture->origin),"http://127.0.0.1:%d",fixture->main.port);
    snprintf(fixture->other_origin,sizeof(fixture->other_origin),"http://127.0.0.1:%d",fixture->other.port);
    return fixture;
}
const char *ztest_remote_fixture_origin(Fixture *fixture) { return fixture->origin; }
const char *ztest_remote_fixture_other_origin(Fixture *fixture) { return fixture->other_origin; }
void ztest_remote_fixture_counts(Fixture *fixture,unsigned *requests,unsigned *other,unsigned *redirects) {
    *requests=atomic_load(&fixture->main.requests); *other=atomic_load(&fixture->other.requests); *redirects=atomic_load(&fixture->redirects);
}
void ztest_remote_fixture_free(Fixture *fixture) {
    server_stop(&fixture->main); server_stop(&fixture->other);
    while (atomic_load(&fixture->active)) usleep(1000);
    free(fixture);
}
