#define COBJMACROS
#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <WebView2.h>
#include <stdint.h>
#include <stdlib.h>
#include <wchar.h>
#include <stdio.h>
static BOOL bounded_uri(const WCHAR *value){return value&&wcsnlen(value,16385)<=16384;}
static void credential_wiped(const void *,size_t);
static void *credential_alloc(size_t,size_t);
#define ZWV_CREDENTIAL_WIPE_OBSERVER credential_wiped
#define ZWV_CREDENTIAL_ALLOC credential_alloc
#include "../src/webview/remote_policy.h"
#define CHECK(x) do{if(!(x)){fprintf(stderr,"remote origin line %u: %s\n",__LINE__,#x);return 1;}}while(0)
static unsigned wipe_count;
static BOOL fail_credential_alloc;
static void *credential_alloc(size_t count,size_t size){return fail_credential_alloc?NULL:calloc(count,size);}
static void credential_wiped(const void *value,size_t size){
    const unsigned char *bytes=value;
    for(size_t i=0;i<size;++i)if(bytes[i])abort();
    ++wipe_count;
}
int main(void){
    (void)headers_collect;
    CHECK(sizeof(RemoteCredentialInput)==24&&sizeof(RemoteInput)==40&&sizeof(RemoteCredentials)==1188);
    CHECK(request_method(L"GET")==0);
    const WCHAR *loopback[]={L"https://[::1]",L"https://[::ffff:127.0.0.1]",L"https://[::127.0.0.1]",L"https://[0:0:0:0:0:ffff:7f00:1]",L"https://[0:0:0:0:0:0:7fff:ffff]",L"https://[::ffff:127.255.255.255]"};
    NetOrigin parsed;
    for(unsigned i=0;i<sizeof(loopback)/sizeof(loopback[0]);i++){
        CHECK(net_origin(loopback[i],FALSE,FALSE,&parsed)==E_ACCESSDENIED);
        CHECK(SUCCEEDED(net_origin(loopback[i],FALSE,TRUE,&parsed)));
    }
    CHECK(SUCCEEDED(net_origin(L"https://[::ffff:128.0.0.1]",FALSE,FALSE,&parsed)));
    CHECK(SUCCEEDED(net_origin(L"https://[2001:db8::1]",FALSE,FALSE,&parsed)));
    CHECK(net_origin(L"http://[::ffff:127.0.0.1]",FALSE,FALSE,&parsed)==E_ACCESSDENIED);
    CHECK(SUCCEEDED(net_origin(L"http://[::ffff:127.0.0.1]",FALSE,TRUE,&parsed)));
    CHECK(net_origin(L"https://child.ziggurat.invalid",FALSE,TRUE,&parsed)==E_ACCESSDENIED);
    CHECK(remote_url_equal(L"https://example.test",L"https://example.test:443/",FALSE));
    CHECK(!remote_url_equal(L"https://example.test/?a=%26b",L"https://example.test/?a=&b",FALSE));
    RemoteOriginInput origin={L"https://example.test",3u,3u,NULL,0};RemoteInput input={L"https://example.test/",&origin,1,FALSE,FALSE,FALSE,NULL,0};RemotePolicy policy;
    CHECK(SUCCEEDED(remote_init(&policy,&input)));
    CHECK(remote_request_allowed(&policy,L"https://example.test/data",0,NULL,0));
    CHECK(!remote_request_allowed(&policy,L"https://example.test/data",2,NULL,0));remote_deinit(&policy);
    RemoteOriginInput origins[]={{L"https://example.test",3u,3u,NULL,0},{L"https://public.test",2u,3u,NULL,0}};
    unsigned char secret[32];memset(secret,0x5a,sizeof(secret));
    RemoteCredentialInput credentials[]={{"HTTPS://EXAMPLE.test:443/",0,secret},{"https://example.test",0,secret}};
    credentials[0].origin_len=(uint32_t)strlen(credentials[0].origin);credentials[1].origin_len=(uint32_t)strlen(credentials[1].origin);
    input.origins=origins;input.count=2;input.credentials=credentials;input.credential_count=1;
    CHECK(SUCCEEDED(remote_init(&policy,&input))&&policy.credentials&&policy.credentials->count==1);
    memset(secret,0,sizeof(secret));
    const WCHAR *authorization=NULL;
    CHECK(remote_request_check(&policy,L"https://EXAMPLE.test:443/file",0,NULL,0,&authorization)&&authorization);
    CHECK(wcslen(authorization)==71&&!wcsncmp(authorization,L"Bearer 5a5a",11));
    CHECK(remote_request_check(&policy,L"https://public.test/redirect",0,NULL,0,&authorization)&&!authorization);
    CHECK(!remote_request_check(&policy,L"https://example.test/file",2,NULL,0,&authorization)&&!authorization);
    NativeHeader headers[64];WCHAR names[64][32];
    for(unsigned i=0;i<64;++i){swprintf(names[i],32,L"Sec-Budget-%u",i);headers[i]=(NativeHeader){names[i],L"v"};}
    CHECK(remote_request_check(&policy,L"https://example.test/file",0,headers,63,&authorization)&&authorization);
    CHECK(!remote_request_check(&policy,L"https://example.test/file",0,headers,64,&authorization)&&!authorization);
    WCHAR full[2049],last[2049];for(unsigned i=0;i<2048;++i)full[i]=last[i]=L'v';full[2048]=last[2048]=0;
    size_t names_budget=0;for(unsigned i=0;i<8;++i){headers[i].value=full;names_budget+=wcslen(headers[i].name);}
    size_t final_length=16300-names_budget-7*2048;CHECK(final_length<2048);
    headers[7].value=last;last[final_length]=0;
    CHECK(remote_request_check(&policy,L"https://example.test/file",0,headers,8,&authorization)&&authorization);
    last[final_length]=L'v';last[final_length+1]=0;
    CHECK(!remote_request_check(&policy,L"https://example.test/file",0,headers,8,&authorization)&&!authorization);
    unsigned before=wipe_count;remote_deinit(&policy);CHECK(wipe_count==before+1&&!policy.credentials);
    input.credential_count=2;CHECK(FAILED(remote_init(&policy,&input))&&!policy.credentials);CHECK(wipe_count==before+2);
    input.credential_count=1;credentials[0].origin="https://unknown.test";credentials[0].origin_len=(uint32_t)strlen(credentials[0].origin);
    CHECK(remote_init(&policy,&input)==E_ACCESSDENIED&&!policy.credentials);
    credentials[0].origin="http://127.0.0.1";credentials[0].origin_len=(uint32_t)strlen(credentials[0].origin);input.allow_loopback=TRUE;
    CHECK(FAILED(remote_init(&policy,&input))&&!policy.credentials);
    credentials[0].origin="https://example.test";credentials[0].origin_len=(uint32_t)strlen(credentials[0].origin);
    HeaderGrantInput header={"aUtHoRiZaTiOn",13,NULL,0,FALSE};origins[1].headers=&header;origins[1].header_count=1;
    CHECK(FAILED(remote_init(&policy,&input))&&!policy.credentials);
    origins[1].headers=NULL;origins[1].header_count=0;fail_credential_alloc=TRUE;
    CHECK(remote_init(&policy,&input)==E_OUTOFMEMORY&&!policy.credentials);fail_credential_alloc=FALSE;
    input.credential_count=9;CHECK(FAILED(remote_init(&policy,&input))&&!policy.credentials);
    input.credential_count=0;origins[1].headers=&header;origins[1].header_count=1;
    CHECK(SUCCEEDED(remote_init(&policy,&input))&&!policy.credentials);
    NativeHeader observed={L"Authorization",L"caller-owned"};
    CHECK(remote_request_check(&policy,L"https://public.test/",0,&observed,1,&authorization)&&!authorization);remote_deinit(&policy);
    puts("remote origin: exact HTTPS credentials own frozen wire, reserve final header budgets, wipe final storage, default grants observe");return 0;
}
