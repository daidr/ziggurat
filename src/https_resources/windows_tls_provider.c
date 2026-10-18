#include "windows_tls_provider.h"
#include <bcrypt.h>
#include <stdlib.h>
#include <string.h>
#include <limits.h>
#include <mbedtls/ssl.h>
#include <mbedtls/x509_crt.h>
#include <mbedtls/pk.h>
#include <mbedtls/ctr_drbg.h>
#include <mbedtls/entropy.h>

typedef struct Domain {LONG refs;DWORD worker;size_t live,peak,limit;int failure;} Domain;
typedef union Allocation {max_align_t alignment;struct {Domain *domain;size_t bytes;} owned;} Allocation;
struct ZhtpProvider {
    Domain *domain;DWORD worker;uint32_t connections;
    mbedtls_x509_crt certificate;mbedtls_pk_context key;
    mbedtls_ctr_drbg_context random;mbedtls_ssl_config configuration;
};
struct ZhtpConnection {ZhtpProvider *provider;ZhtpIO io;mbedtls_ssl_context tls;};
static _Thread_local Domain *active_domain;
static LONG providers,domains;
#ifdef ZHTP_TESTING
static LONG fail_after=-1,rng_failure;
void zhtp_test_fail_after(int n){InterlockedExchange(&fail_after,n);}
void zhtp_test_rng_fail(int value){InterlockedExchange(&rng_failure,!!value);}
#endif
static int allocation_allowed(void){
#ifdef ZHTP_TESTING
    LONG remaining=InterlockedCompareExchange(&fail_after,0,0);
    if(remaining==0)return 0;if(remaining>0)InterlockedDecrement(&fail_after);
#endif
    return 1;
}
static Domain *enter(Domain *domain){Domain *previous=active_domain;active_domain=domain;return previous;}
static void leave(Domain *previous){active_domain=previous;}
static void domain_release(Domain *d){
    if(InterlockedDecrement(&d->refs))return;
    SecureZeroMemory(d,sizeof(*d));free(d);InterlockedDecrement(&domains);
}
void *zhtp_calloc(size_t n,size_t size){
    Domain *d=active_domain;
    if(!d||d->worker!=GetCurrentThreadId())return NULL;
    if(!n||!size)return NULL;
    if(size>SIZE_MAX/n||n*size>SIZE_MAX-sizeof(Allocation)){d->failure=ZHTP_BUDGET;return NULL;}
    size_t bytes=sizeof(Allocation)+n*size;
    if(bytes>d->limit-d->live){d->failure=ZHTP_BUDGET;return NULL;}
    if(!allocation_allowed()){d->failure=ZHTP_OOM;return NULL;}
    Allocation *allocation=calloc(1,bytes);if(!allocation){d->failure=ZHTP_OOM;return NULL;}
    allocation->owned.domain=d;allocation->owned.bytes=bytes;InterlockedIncrement(&d->refs);
    d->live+=bytes;if(d->live>d->peak)d->peak=d->live;return allocation+1;
}
void zhtp_free(void *pointer){
    if(!pointer)return;Allocation *allocation=(Allocation *)pointer-1;
    Domain *d=allocation->owned.domain;size_t bytes=allocation->owned.bytes;
    /* The actual allocation owns this domain pin independently of the active
     * scope. Credit returns only after wiping/freeing the whole allocation. */
    SecureZeroMemory(allocation,bytes);free(allocation);d->live-=bytes;domain_release(d);
}
static int entropy(void *context,unsigned char *output,size_t bytes){
    (void)context;
#ifdef ZHTP_TESTING
    if(InterlockedCompareExchange(&rng_failure,0,0))return MBEDTLS_ERR_ENTROPY_SOURCE_FAILED;
#endif
    while(bytes){ULONG count=bytes>ULONG_MAX?ULONG_MAX:(ULONG)bytes;
        if(BCryptGenRandom(NULL,output,count,BCRYPT_USE_SYSTEM_PREFERRED_RNG)<0)return MBEDTLS_ERR_ENTROPY_SOURCE_FAILED;
        output+=count;bytes-=count;
    }return 0;
}
static int classify(Domain *d,int native,int *error){
    if(error)*error=native;
    if(!native)return ZHTP_OK;
    if(native==MBEDTLS_ERR_SSL_WANT_READ)return ZHTP_READ;
    if(native==MBEDTLS_ERR_SSL_WANT_WRITE)return ZHTP_WRITE;
    if(native==MBEDTLS_ERR_SSL_PEER_CLOSE_NOTIFY)return ZHTP_EOF;
    return d->failure?d->failure:ZHTP_NATIVE;
}
static int same_worker(ZhtpProvider *p){return p&&p->worker==GetCurrentThreadId();}
static void dispose(ZhtpProvider *p){
    Domain *d=p->domain,*previous=enter(d);
    mbedtls_ssl_config_free(&p->configuration);mbedtls_pk_free(&p->key);
    mbedtls_x509_crt_free(&p->certificate);mbedtls_ctr_drbg_free(&p->random);
    zhtp_free(p);leave(previous);
}
static int create(uint64_t main_thread,const unsigned char *certificate,size_t certificate_length,
    const unsigned char *key,size_t key_length,size_t budget,int client,ZhtpProvider **out,int *error){
    if(!out||!error)return ZHTP_INVALID;*out=NULL;*error=0;
    if(main_thread==GetCurrentThreadId())return ZHTP_UI_THREAD;
    if(main_thread>UINT32_MAX||(!client&&(!certificate||!key||!certificate_length||!key_length||
        certificate_length>16384||key_length>16384||memchr(certificate,0,certificate_length)||memchr(key,0,key_length))))return ZHTP_INVALID;
    if(budget<sizeof(Domain))return ZHTP_BUDGET;
    Domain *d=allocation_allowed()?calloc(1,sizeof(*d)):NULL;if(!d)return ZHTP_OOM;
    d->refs=1;d->worker=GetCurrentThreadId();d->limit=budget;d->live=d->peak=sizeof(*d);InterlockedIncrement(&domains);
    Domain *previous=enter(d);ZhtpProvider *p=zhtp_calloc(1,sizeof(*p));int result=0;
    if(!p){int failed=d->failure;leave(previous);domain_release(d);return failed;}
    p->worker=d->worker;p->domain=d;
    mbedtls_x509_crt_init(&p->certificate);mbedtls_pk_init(&p->key);
    mbedtls_ctr_drbg_init(&p->random);mbedtls_ssl_config_init(&p->configuration);
    result=mbedtls_ctr_drbg_seed(&p->random,entropy,NULL,(const unsigned char *)"ziggurat-https",14);if(result)goto failed;
    if(!client){
        unsigned char *cert_copy=zhtp_calloc(1,certificate_length+1),*key_copy=zhtp_calloc(1,key_length+1);
        if(!cert_copy||!key_copy){zhtp_free(cert_copy);zhtp_free(key_copy);result=MBEDTLS_ERR_PK_ALLOC_FAILED;goto failed;}
        memcpy(cert_copy,certificate,certificate_length);memcpy(key_copy,key,key_length);
        result=mbedtls_x509_crt_parse(&p->certificate,cert_copy,certificate_length+1);
        if(!result)result=mbedtls_pk_parse_key(&p->key,key_copy,key_length+1,NULL,0,mbedtls_ctr_drbg_random,&p->random);
        zhtp_free(cert_copy);zhtp_free(key_copy);if(result)goto failed;
        result=mbedtls_pk_check_pair(&p->certificate.pk,&p->key,mbedtls_ctr_drbg_random,&p->random);if(result)goto failed;
    }
    result=mbedtls_ssl_config_defaults(&p->configuration,client?MBEDTLS_SSL_IS_CLIENT:MBEDTLS_SSL_IS_SERVER,
        MBEDTLS_SSL_TRANSPORT_STREAM,MBEDTLS_SSL_PRESET_DEFAULT);if(result)goto failed;
    mbedtls_ssl_conf_min_tls_version(&p->configuration,MBEDTLS_SSL_VERSION_TLS1_2);
    mbedtls_ssl_conf_max_tls_version(&p->configuration,MBEDTLS_SSL_VERSION_TLS1_2);
    mbedtls_ssl_conf_rng(&p->configuration,mbedtls_ctr_drbg_random,&p->random);
    /* Servers do not request a client certificate. The isolated test client
     * additionally verifies exact peer DER; no production client bypass API. */
    mbedtls_ssl_conf_authmode(&p->configuration,MBEDTLS_SSL_VERIFY_NONE);
    static const char *protocols[]={"http/1.1",NULL};
    result=mbedtls_ssl_conf_alpn_protocols(&p->configuration,protocols);if(result)goto failed;
    if(!client){result=mbedtls_ssl_conf_own_cert(&p->configuration,&p->certificate,&p->key);if(result)goto failed;}
    leave(previous);domain_release(d);InterlockedIncrement(&providers);*out=p;return ZHTP_OK;
failed:
    {int status=classify(d,result,error);dispose(p);leave(previous);domain_release(d);return status;}
}
int zhtp_create(uint64_t main,const unsigned char *cert,size_t cert_bytes,const unsigned char *key,size_t key_bytes,
    size_t budget,ZhtpProvider **out,int *error){return create(main,cert,cert_bytes,key,key_bytes,budget,0,out,error);}
int zhtp_destroy(ZhtpProvider **input){
    if(!input||!*input)return ZHTP_INVALID;ZhtpProvider *p=*input;
    if(!same_worker(p))return ZHTP_THREAD;if(p->connections)return ZHTP_BUSY;
    *input=NULL;dispose(p);InterlockedDecrement(&providers);return ZHTP_OK;
}
int zhtp_stats(ZhtpProvider *p,ZhtpStats *out){
    if(!p||!out)return ZHTP_INVALID;if(!same_worker(p))return ZHTP_THREAD;
    *out=(ZhtpStats){p->domain->live,p->domain->peak,p->domain->limit,p->connections};return ZHTP_OK;
}
static int send_bytes(void *context,const unsigned char *bytes,size_t count){
    ZhtpConnection *c=context;int result=c->io.send(c->io.context,bytes,count);
    if(result==ZHTP_IO_AGAIN)return MBEDTLS_ERR_SSL_WANT_WRITE;
    return result<=0||result>(int)count?MBEDTLS_ERR_SSL_INTERNAL_ERROR:result;
}
static int receive_bytes(void *context,unsigned char *bytes,size_t count){
    ZhtpConnection *c=context;int result=c->io.receive(c->io.context,bytes,count);
    if(result==ZHTP_IO_AGAIN)return MBEDTLS_ERR_SSL_WANT_READ;
    return result<0||result>(int)count?MBEDTLS_ERR_SSL_INTERNAL_ERROR:result;
}
int zhtp_connection_create(ZhtpProvider *p,ZhtpIO io,ZhtpConnection **out,int *error){
    if(!out||!error)return ZHTP_INVALID;*out=NULL;*error=0;
    if(!p||!io.send||!io.receive)return ZHTP_INVALID;if(!same_worker(p))return ZHTP_THREAD;
    if(p->connections>=8)return ZHTP_BUSY;
    Domain *previous=enter(p->domain);p->domain->failure=0;
    ZhtpConnection *c=zhtp_calloc(1,sizeof(*c));if(!c){leave(previous);return p->domain->failure;}
    c->provider=p;c->io=io;mbedtls_ssl_init(&c->tls);
    int native=mbedtls_ssl_setup(&c->tls,&p->configuration),status=classify(p->domain,native,error);
    if(status){mbedtls_ssl_free(&c->tls);zhtp_free(c);leave(previous);return status;}
    mbedtls_ssl_set_bio(&c->tls,c,send_bytes,receive_bytes,NULL);
    p->connections++;leave(previous);*out=c;return ZHTP_OK;
}
int zhtp_connection_destroy(ZhtpConnection **input){
    if(!input||!*input)return ZHTP_INVALID;ZhtpConnection *c=*input;ZhtpProvider *p=c->provider;
    if(!same_worker(p))return ZHTP_THREAD;*input=NULL;
    Domain *previous=enter(p->domain);mbedtls_ssl_free(&c->tls);zhtp_free(c);p->connections--;leave(previous);return ZHTP_OK;
}
static int operation(ZhtpConnection *c,int kind,unsigned char *bytes,size_t count,size_t *actual,int *error){
    if(error)*error=0;if(actual)*actual=0;
    if(!c||!error||((kind==1||kind==2)&&(!actual||(!bytes&&count)||count>16384)))return ZHTP_INVALID;
    ZhtpProvider *p=c->provider;if(!same_worker(p))return ZHTP_THREAD;
    Domain *previous=enter(p->domain);p->domain->failure=0;int native;
    if(kind==0)native=mbedtls_ssl_handshake(&c->tls);
    else if(kind==1)native=mbedtls_ssl_read(&c->tls,bytes,count);
    else if(kind==2)native=mbedtls_ssl_write(&c->tls,bytes,count);
    else native=mbedtls_ssl_close_notify(&c->tls);
    int status;
    if((kind==1||kind==2)&&native>0){*actual=(size_t)native;status=ZHTP_OK;}
    else if(kind==1&&!native&&count)status=ZHTP_EOF;
    else status=classify(p->domain,native,error);
    leave(previous);return status;
}
int zhtp_handshake(ZhtpConnection *c,int *error){return operation(c,0,NULL,0,NULL,error);}
int zhtp_read(ZhtpConnection *c,unsigned char *bytes,size_t n,size_t *actual,int *error){return operation(c,1,bytes,n,actual,error);}
int zhtp_write(ZhtpConnection *c,const unsigned char *bytes,size_t n,size_t *actual,int *error){return operation(c,2,(unsigned char *)bytes,n,actual,error);}
int zhtp_shutdown(ZhtpConnection *c,int *error){return operation(c,3,NULL,0,NULL,error);}
uint32_t zhtp_provider_count(void){return (uint32_t)InterlockedCompareExchange(&providers,0,0);}
uint32_t zhtp_domain_count(void){return (uint32_t)InterlockedCompareExchange(&domains,0,0);}
#ifdef ZHTP_TESTING
int zhtp_client_create(uint64_t main,size_t budget,ZhtpProvider **out,int *error){return create(main,NULL,0,NULL,0,budget,1,out,error);}
int zhtp_test_reseed(ZhtpProvider *p,int *error){
    if(!p||!error)return ZHTP_INVALID;if(!same_worker(p))return ZHTP_THREAD;
    Domain *previous=enter(p->domain);p->domain->failure=0;
    int result=classify(p->domain,mbedtls_ctr_drbg_reseed(&p->random,NULL,0),error);leave(previous);return result;
}
int zhtp_peer_matches(ZhtpConnection *c,const unsigned char *pem,size_t bytes){
    if(!c||!pem||!bytes||bytes>16384||!same_worker(c->provider))return 0;
    ZhtpProvider *p=c->provider;Domain *previous=enter(p->domain);
    unsigned char *copy=zhtp_calloc(1,bytes+1);mbedtls_x509_crt expected;mbedtls_x509_crt_init(&expected);int match=0;
    if(copy){memcpy(copy,pem,bytes);if(!mbedtls_x509_crt_parse(&expected,copy,bytes+1)){
        const mbedtls_x509_crt *peer=mbedtls_ssl_get_peer_cert(&c->tls);
        match=peer&&peer->raw.len==expected.raw.len&&!memcmp(peer->raw.p,expected.raw.p,peer->raw.len);
    }}
    mbedtls_x509_crt_free(&expected);zhtp_free(copy);leave(previous);return match;
}
#endif
