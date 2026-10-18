/* Isolated explicit-worker TLS tests. Pipes are controlled memory transports,
 * not sockets or evidence of App/HTTPS/browser integration. */
#include "../src/https_resources/windows_tls_provider.h"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#define REQUIRE(x) do{if(!(x)){fprintf(stderr,"TLS provider line %d: %s\n",__LINE__,#x);failed=1;goto done;}}while(0)
#define FATAL(x) do{if(!(x)){fprintf(stderr,"TLS provider driver line %d: %s\n",__LINE__,#x);fflush(stderr);ExitProcess(1);}}while(0)
#define BUDGET (1024u*1024u)
typedef struct Material {unsigned char certificate[16384],key[16384];size_t certificate_length,key_length;} Material;
typedef struct Pipe {unsigned char bytes[128];size_t start,used;} Pipe;
typedef struct Port {Pipe *incoming,*outgoing;size_t fragment;unsigned reads,writes,blocked;} Port;
static int send_bytes(void *context,const unsigned char *bytes,size_t n){
    Port *port=context;port->writes++;Pipe *p=port->outgoing;
    if(p->used==sizeof(p->bytes)){port->blocked++;return ZHTP_IO_AGAIN;}
    if(n>port->fragment)n=port->fragment;if(n>sizeof(p->bytes)-p->used)n=sizeof(p->bytes)-p->used;
    size_t end=(p->start+p->used)%sizeof(p->bytes);
    for(size_t i=0;i<n;i++)p->bytes[(end+i)%sizeof(p->bytes)]=bytes[i];p->used+=n;return (int)n;
}
static int receive_bytes(void *context,unsigned char *bytes,size_t n){
    Port *port=context;port->reads++;Pipe *p=port->incoming;
    if(!p->used)return ZHTP_IO_AGAIN;if(n>port->fragment)n=port->fragment;if(n>p->used)n=p->used;
    for(size_t i=0;i<n;i++)bytes[i]=p->bytes[(p->start+i)%sizeof(p->bytes)];
    p->start=(p->start+n)%sizeof(p->bytes);p->used-=n;return (int)n;
}
static ZhtpIO io(Port *port){return (ZhtpIO){port,send_bytes,receive_bytes};}
static int pending(int result){return result==ZHTP_OK||result==ZHTP_READ||result==ZHTP_WRITE;}
static int read_fixture(const char *directory,const char *name,unsigned char *output,size_t *length){
    char path[2048];int n=snprintf(path,sizeof(path),"%s/%s",directory,name);if(n<0||(size_t)n>=sizeof(path))return 1;
    FILE *file=fopen(path,"rb");if(!file)return 1;
    *length=fread(output,1,16384,file);int result=ferror(file)||!*length||!feof(file);fclose(file);return result;
}
static int zero(void){return zhtp_provider_count()==0&&zhtp_domain_count()==0;}
static unsigned char pattern(size_t i){return (unsigned char)(i*37+11);}
static int roundtrip(DWORD main,const Material *material,const Material *other,size_t fragment){
    int failed=0,error=0;ZhtpProvider *server=NULL,*client=NULL;ZhtpConnection *s=NULL,*c=NULL;
    Pipe a={0},b={0};Port sp={&a,&b,fragment,0},cp={&b,&a,fragment,0};
    REQUIRE(zhtp_create(main,material->certificate,material->certificate_length,material->key,material->key_length,BUDGET,&server,&error)==ZHTP_OK);
    REQUIRE(zhtp_client_create(main,BUDGET,&client,&error)==ZHTP_OK);
    ZhtpStats base={0};REQUIRE(zhtp_stats(server,&base)==ZHTP_OK&&base.live>0&&base.live<=base.limit);
    ZhtpStats client_base={0};REQUIRE(zhtp_stats(client,&client_base)==ZHTP_OK);
    size_t steady_live=0;
    /* Initial RSA blinding caches and their first in-place square can grow
     * Provider.key. They retire with that key, not with an SSL connection.
     * Reuse one provider: the final two independent connections must have an
     * identical live baseline, then final provider destruction must free all. */
    for(unsigned cycle=0;cycle<4;cycle++){
    memset(&a,0,sizeof(a));memset(&b,0,sizeof(b));
    sp=(Port){&a,&b,fragment,0};cp=(Port){&b,&a,fragment,0};
    REQUIRE(zhtp_connection_create(server,io(&sp),&s,&error)==ZHTP_OK);
    REQUIRE(zhtp_connection_create(client,io(&cp),&c,&error)==ZHTP_OK);
    REQUIRE(zhtp_destroy(&server)==ZHTP_BUSY&&server);
    int sd=0,cd=0,last_client=0,last_server=0;unsigned want_read=0,want_write=0,step=0;
    for(;step<25000&&(!sd||!cd);step++){
        if(!cd){int r=zhtp_handshake(c,&error);last_client=r;REQUIRE(pending(r));cd=r==ZHTP_OK;want_read+=r==ZHTP_READ;want_write+=r==ZHTP_WRITE;}
        if(!sd){int r=zhtp_handshake(s,&error);last_server=r;REQUIRE(pending(r));sd=r==ZHTP_OK;want_read+=r==ZHTP_READ;want_write+=r==ZHTP_WRITE;}
    }
    fprintf(stderr,"TLS handshake trace: steps=%u server_done=%d client_done=%d WANT_READ=%u WANT_WRITE=%u server_blocked=%u client_blocked=%u last_server=%d last_client=%d native=0x%08lx\n",step,sd,cd,want_read,want_write,sp.blocked,cp.blocked,last_server,last_client,(unsigned long)(uint32_t)error);
    REQUIRE(sd&&cd&&want_read&&want_write&&sp.blocked);
    REQUIRE(zhtp_peer_matches(c,material->certificate,material->certificate_length));
    REQUIRE(!zhtp_peer_matches(c,other->certificate,other->certificate_length));
    unsigned char payload[16384],output[97];for(size_t i=0;i<sizeof(payload);i++)payload[i]=pattern(i);
    size_t received=0;int wrote=0;
    for(unsigned step=0;step<50000&&(!wrote||received<sizeof(payload));step++){
        if(!wrote){size_t n=0;int r=zhtp_write(s,payload,sizeof(payload),&n,&error);REQUIRE(pending(r));
            if(r==ZHTP_OK){REQUIRE(n==sizeof(payload));wrote=1;}else REQUIRE(n==0);}
        size_t n=0;int r=zhtp_read(c,output,sizeof(output),&n,&error);REQUIRE(pending(r));
        if(r==ZHTP_OK){REQUIRE(n&&n<=sizeof(payload)-received);for(size_t i=0;i<n;i++)REQUIRE(output[i]==pattern(received+i));received+=n;}
    }
    REQUIRE(wrote&&received==sizeof(payload));
    /* The client handshake flight may fit entirely in this controlled128B
     * pipe. Prove the opposite-direction WANT_WRITE with a complete16KiB
     * encrypted application record instead of assuming handshake packet size. */
    for(size_t i=0;i<sizeof(payload);i++)payload[i]=(unsigned char)(pattern(i)^0xa5);
    received=0;wrote=0;unsigned client_want_write=0;
    for(unsigned step=0;step<50000&&(!wrote||received<sizeof(payload));step++){
        if(!wrote){size_t n=0;int r=zhtp_write(c,payload,sizeof(payload),&n,&error);REQUIRE(pending(r));client_want_write+=r==ZHTP_WRITE;
            if(r==ZHTP_OK){REQUIRE(n==sizeof(payload));wrote=1;}else REQUIRE(n==0);}
        size_t n=0;int r=zhtp_read(s,output,sizeof(output),&n,&error);REQUIRE(pending(r));
        if(r==ZHTP_OK){REQUIRE(n&&n<=sizeof(payload)-received);for(size_t i=0;i<n;i++)REQUIRE(output[i]==(unsigned char)(pattern(received+i)^0xa5));received+=n;}
    }
    REQUIRE(wrote&&received==sizeof(payload)&&client_want_write&&cp.blocked);
    int shutdown=0,eof=0;
    for(unsigned step=0;step<1000&&(!shutdown||!eof);step++){
        if(!shutdown){int r=zhtp_shutdown(s,&error);REQUIRE(pending(r));shutdown=r==ZHTP_OK;}
        if(!eof){size_t n=0;int r=zhtp_read(c,output,sizeof(output),&n,&error);REQUIRE(r==ZHTP_READ||r==ZHTP_EOF);REQUIRE(n==0);eof=r==ZHTP_EOF;}
    }
    REQUIRE(shutdown&&eof);
    REQUIRE(zhtp_connection_destroy(&s)==ZHTP_OK);REQUIRE(zhtp_connection_destroy(&c)==ZHTP_OK);
    ZhtpStats after={0};int stats_result=zhtp_stats(server,&after);
    fprintf(stderr,"TLS allocation trace: cycle=%u stats=%d cold_live=%zu after_live=%zu peak=%zu limit=%zu connections=%u\n",cycle,stats_result,base.live,after.live,after.peak,after.limit,after.connections);
    REQUIRE(stats_result==ZHTP_OK&&after.connections==0&&after.live>=base.live&&after.peak<=BUDGET);
    if(cycle==2)steady_live=after.live;
    if(cycle==3)REQUIRE(after.live==steady_live);
    ZhtpStats client_after={0};REQUIRE(zhtp_stats(client,&client_after)==0&&client_after.connections==0&&client_after.live==client_base.live&&client_after.peak<=BUDGET);
    fprintf(stderr,"TLS pair fragment=%zu cycle=%u: handshake WANT_READ=%u WANT_WRITE=%u client record WANT_WRITE=%u bidirectional_byte_exact=16384 peak=%zu live_after_connections=%zu\n",fragment,cycle,want_read,want_write,client_want_write,after.peak,after.live);
    }
done:
    if(failed)fprintf(stderr,"TLS roundtrip last native error=0x%08lx\n",(unsigned long)(uint32_t)error);
    if(s)zhtp_connection_destroy(&s);if(c)zhtp_connection_destroy(&c);
    if(server)zhtp_destroy(&server);if(client)zhtp_destroy(&client);return failed;
}
static int faults(DWORD main,const Material *m,const Material *other){
    int failed=0,error=0;ZhtpProvider *provider=NULL;ZhtpConnection *connection=NULL;
    REQUIRE(zhtp_create(main,m->certificate,m->certificate_length,m->key,m->key_length,1,&provider,&error)==ZHTP_BUDGET&&provider==NULL&&zero());
    int mismatch=zhtp_create(main,m->certificate,m->certificate_length,other->key,other->key_length,BUDGET,&provider,&error);
    REQUIRE(mismatch==ZHTP_NATIVE&&provider==NULL&&error!=0&&zero());
    zhtp_test_rng_fail(1);
    REQUIRE(zhtp_create(main,m->certificate,m->certificate_length,m->key,m->key_length,BUDGET,&provider,&error)==ZHTP_NATIVE&&provider==NULL&&error!=0&&zero());
    zhtp_test_rng_fail(0);
    unsigned create_failures=0;int created=0;
    for(unsigned i=0;i<256;i++){
        zhtp_test_fail_after((int)i);
        int r=zhtp_create(main,m->certificate,m->certificate_length,m->key,m->key_length,BUDGET,&provider,&error);
        if(r==ZHTP_OK){created=1;break;}
        REQUIRE(r==ZHTP_OOM&&provider==NULL&&zero());create_failures++;
    }
    zhtp_test_fail_after(-1);REQUIRE(created&&create_failures>3);
    ZhtpStats base={0};REQUIRE(zhtp_stats(provider,&base)==0);
    Pipe a={0},b={0};Port port={&a,&b,7,0};unsigned connection_failures=0;int connected=0;
    for(unsigned i=0;i<256;i++){
        zhtp_test_fail_after((int)i);int r=zhtp_connection_create(provider,io(&port),&connection,&error);
        if(r==ZHTP_OK){connected=1;break;}
        ZhtpStats stats={0};REQUIRE(r==ZHTP_OOM&&connection==NULL&&zhtp_stats(provider,&stats)==0&&stats.live==base.live&&stats.connections==0);connection_failures++;
    }
    zhtp_test_fail_after(-1);REQUIRE(connected&&connection_failures>=3);
    REQUIRE(zhtp_connection_destroy(&connection)==0);
    REQUIRE(zhtp_connection_create(provider,io(&port),&connection,&error)==0);
    const unsigned char bad[]={0x16,0x03,0x03,0,1,0xff};memcpy(a.bytes,bad,sizeof(bad));a.used=sizeof(bad);
    REQUIRE(zhtp_handshake(connection,&error)==ZHTP_NATIVE&&error!=0);
    REQUIRE(zhtp_connection_destroy(&connection)==0);
    zhtp_test_rng_fail(1);REQUIRE(zhtp_test_reseed(provider,&error)==ZHTP_NATIVE&&error!=0);zhtp_test_rng_fail(0);
    REQUIRE(zhtp_destroy(&provider)==0&&zero());
    fprintf(stderr,"TLS faults: create_oom_points=%u connection_oom_points=%u mismatch/malformed/RNG/budget closed; refs=0\n",create_failures,connection_failures);
done:
    if(failed)fprintf(stderr,"TLS faults last native error=0x%08lx\n",(unsigned long)(uint32_t)error);
    zhtp_test_fail_after(-1);zhtp_test_rng_fail(0);
    if(connection)zhtp_connection_destroy(&connection);if(provider)zhtp_destroy(&provider);return failed;
}
typedef struct Test {DWORD main;HANDLE ready,go;ZhtpProvider *borrowed;ZhtpConnection *connection;int result;} Test;
static DWORD WINAPI worker(void *context){
    Test *t=context;int failed=0,error=0;Material first={0},other={0};ZhtpProvider *provider=NULL;ZhtpConnection *connection=NULL;
    const char *root=getenv("ZIGGURAT_HTTPS_TEST_ROOT");if(!root)root="tests/fixtures/profile-https";
    REQUIRE(read_fixture(root,"server-cert.pem",first.certificate,&first.certificate_length)==0);
    REQUIRE(read_fixture(root,"server-key.pem",first.key,&first.key_length)==0);
    REQUIRE(read_fixture(root,"other-cert.pem",other.certificate,&other.certificate_length)==0);
    REQUIRE(read_fixture(root,"other-key.pem",other.key,&other.key_length)==0);
    REQUIRE(roundtrip(t->main,&first,&other,7)==0&&zero());
    REQUIRE(roundtrip(t->main,&other,&first,13)==0&&zero());
    REQUIRE(faults(t->main,&first,&other)==0&&zero());
    REQUIRE(zhtp_create(t->main,first.certificate,first.certificate_length,first.key,first.key_length,BUDGET,&provider,&error)==0);
    Pipe a={0},b={0};Port port={&a,&b,7,0};REQUIRE(zhtp_connection_create(provider,io(&port),&connection,&error)==0);
    t->borrowed=provider;t->connection=connection;SetEvent(t->ready);
    REQUIRE(WaitForSingleObject(t->go,15000)==WAIT_OBJECT_0);
    REQUIRE(provider==t->borrowed&&connection==t->connection);
done:
    if(connection)zhtp_connection_destroy(&connection);if(provider)zhtp_destroy(&provider);
    t->borrowed=NULL;t->connection=NULL;SecureZeroMemory(&first,sizeof(first));SecureZeroMemory(&other,sizeof(other));
    t->result=failed;SetEvent(t->ready);return 0;
}
int zhtp_test_provider(void){
    int native=0;ZhtpProvider *invalid=NULL;DWORD main=GetCurrentThreadId();
    FATAL(zhtp_create(main,NULL,0,NULL,0,1,&invalid,&native)==ZHTP_UI_THREAD&&invalid==NULL&&native==0);
    Test test={0};test.result=-1;test.main=main;test.ready=CreateEventW(NULL,TRUE,FALSE,NULL);test.go=CreateEventW(NULL,TRUE,FALSE,NULL);
    FATAL(test.ready&&test.go);HANDLE thread=CreateThread(NULL,0,worker,&test,0,NULL);FATAL(thread);
    FATAL(WaitForSingleObject(test.ready,30000)==WAIT_OBJECT_0);
    if(test.result!=-1){
        FATAL(WaitForSingleObject(thread,15000)==WAIT_OBJECT_0);CloseHandle(thread);CloseHandle(test.ready);CloseHandle(test.go);
        fprintf(stderr,"TLS worker failed before owner-thread stage; provider/domain refs=%u/%u\n",zhtp_provider_count(),zhtp_domain_count());return 1;
    }
    FATAL(test.borrowed&&test.connection);
    ZhtpProvider *provider=test.borrowed;ZhtpConnection *connection=test.connection;ZhtpStats stats={0};
    FATAL(zhtp_destroy(&provider)==ZHTP_THREAD&&provider==test.borrowed);
    FATAL(zhtp_connection_destroy(&connection)==ZHTP_THREAD&&connection==test.connection);
    FATAL(zhtp_stats(provider,&stats)==ZHTP_THREAD);
    FATAL(zhtp_handshake(connection,&native)==ZHTP_THREAD);
    SetEvent(test.go);FATAL(WaitForSingleObject(thread,15000)==WAIT_OBJECT_0);CloseHandle(thread);
    CloseHandle(test.ready);CloseHandle(test.go);FATAL(test.result==0&&zero());
    fprintf(stderr,"Optional Windows TLS provider: two actual fragmented handshakes/records, exact peer, WANT paths, faults and owner checks; final providers/domains=0\n");return 0;
}
