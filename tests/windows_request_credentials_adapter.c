/* This test object compiles the real adapter once. Production never links the
   certificate exception or observation interfaces defined below. */
#include <stddef.h>
static void probe_credential_wiped(const void *,size_t);
#define ZWV_CREDENTIAL_WIPE_OBSERVER probe_credential_wiped
#include "../src/webview/webview2.c"
#include <wincrypt.h>
#include <limits.h>

static uint32_t credential_wipes;
static BOOL credential_wipes_zero=TRUE;
static void probe_credential_wiped(const void *value,size_t size){
    const unsigned char *bytes=value;
    for(size_t i=0;i<size;++i)if(bytes[i])credential_wipes_zero=FALSE;
    ++credential_wipes;
}
int zwv_test_credential_final_reference(void){
    State *state=calloc(1,sizeof(*state));if(!state)return 0;
    state->refs=1;InterlockedIncrement(&live_states);
    unsigned char secret[32];memset(secret,0x5a,sizeof(secret));
    RemoteOriginInput origin={L"https://example.test",3u,3u,NULL,0};
    RemoteCredentialInput credential={"https://example.test",20,secret};
    credential.origin_len=(uint32_t)strlen(credential.origin);
    RemoteInput input={L"https://example.test/",&origin,1,FALSE,FALSE,FALSE,&credential,1};
    HRESULT hr=remote_init(&state->remote,&input);SecureZeroMemory(secret,sizeof(secret));
    if(FAILED(hr)){release(state);return 0;}
    uint32_t before=credential_wipes;
    retain(state);state->closed=TRUE;release(state);
    BOOL retained=credential_wipes==before&&state->remote.credentials&&
        !wcsncmp(state->remote.credentials->entries[0].authorization,L"Bearer 5a5a",11);
    /* The final C reference does not have a View, App, context or callback. */
    release(state);
    return retained&&credential_wipes==before+1&&credential_wipes_zero&&live_states==0;
}

typedef struct CredentialProbeRecord { uint32_t origin;int32_t method,authorization;WCHAR path[128]; } CredentialProbeRecord;
typedef struct CredentialProbe {
    ICoreWebView2WebResourceRequestedEventHandler resource;
    ICoreWebView2ServerCertificateErrorDetectedEventHandler certificate;
    LONG refs;
    NetOrigin origins[4];
    uint32_t origin_count,count,allowed_certificates,denied_certificates;
    BOOL trust,overflow;
    CredentialProbeRecord records[128];
} CredentialProbe;
static LONG credential_live_probes;
static ULONG probe_add(CredentialProbe *p){return (ULONG)InterlockedIncrement(&p->refs);}
static ULONG probe_release(CredentialProbe *p){
    LONG refs=InterlockedDecrement(&p->refs);
    if(!refs){free(p);InterlockedDecrement(&credential_live_probes);}return (ULONG)refs;
}
static HRESULT probe_query(CredentialProbe *p,REFIID id,void **out){
    if(!out)return E_POINTER;*out=NULL;
    if(IsEqualIID(id,&IID_IUnknown)||IsEqualIID(id,&IID_ICoreWebView2WebResourceRequestedEventHandler))*out=&p->resource;
    else if(IsEqualIID(id,&IID_ICoreWebView2ServerCertificateErrorDetectedEventHandler))*out=&p->certificate;
    else return E_NOINTERFACE;
    probe_add(p);return S_OK;
}
static CredentialProbe *resource_probe(ICoreWebView2WebResourceRequestedEventHandler *p){return (CredentialProbe *)((unsigned char *)p - offsetof(CredentialProbe,resource));}
static CredentialProbe *certificate_probe(ICoreWebView2ServerCertificateErrorDetectedEventHandler *p){return (CredentialProbe *)((unsigned char *)p - offsetof(CredentialProbe,certificate));}
static HRESULT STDMETHODCALLTYPE probe_resource_query(ICoreWebView2WebResourceRequestedEventHandler *p,REFIID id,void **out){return probe_query(resource_probe(p),id,out);}
static ULONG STDMETHODCALLTYPE probe_resource_add(ICoreWebView2WebResourceRequestedEventHandler *p){return probe_add(resource_probe(p));}
static ULONG STDMETHODCALLTYPE probe_resource_release(ICoreWebView2WebResourceRequestedEventHandler *p){return probe_release(resource_probe(p));}
static HRESULT STDMETHODCALLTYPE probe_certificate_query(ICoreWebView2ServerCertificateErrorDetectedEventHandler *p,REFIID id,void **out){return probe_query(certificate_probe(p),id,out);}
static ULONG STDMETHODCALLTYPE probe_certificate_add(ICoreWebView2ServerCertificateErrorDetectedEventHandler *p){return probe_add(certificate_probe(p));}
static ULONG STDMETHODCALLTYPE probe_certificate_release(ICoreWebView2ServerCertificateErrorDetectedEventHandler *p){return probe_release(certificate_probe(p));}
static uint32_t probe_origin(CredentialProbe *p,const WCHAR *uri){
    NetOrigin parsed;if(FAILED(net_origin(uri,FALSE,TRUE,&parsed)))return UINT_MAX;
    for(uint32_t i=0;i<p->origin_count;++i)if(origin_equal(&parsed,&p->origins[i]))return i;
    return UINT_MAX;
}
static int probe_authorization(const WCHAR *value){
    if(!value||!*value)return 0;
    if(wcslen(value)!=71||wcsncmp(value,L"Bearer ",7))return 3;
    BOOL a=TRUE,b=TRUE;
    for(unsigned i=0;i<32;++i){a=a&&value[7+i*2]==L'5'&&value[8+i*2]==L'a';b=b&&value[7+i*2]==L'6'&&value[8+i*2]==L'b';}
    return a?1:b?2:3;
}
static HRESULT STDMETHODCALLTYPE probe_resource_invoke(ICoreWebView2WebResourceRequestedEventHandler *iface,ICoreWebView2 *sender,ICoreWebView2WebResourceRequestedEventArgs *args){
    (void)sender;CredentialProbe *p=resource_probe(iface);
    ICoreWebView2WebResourceRequest *request=NULL;ICoreWebView2HttpRequestHeaders *headers=NULL;
    WCHAR *uri=NULL,*method=NULL,*authorization=NULL;IUri *parsed=NULL;BSTR path=NULL;
    HRESULT hr=ICoreWebView2WebResourceRequestedEventArgs_get_Request(args,&request);
    if(SUCCEEDED(hr))hr=request?ICoreWebView2WebResourceRequest_get_Uri(request,&uri):E_POINTER;
    if(SUCCEEDED(hr))hr=ICoreWebView2WebResourceRequest_get_Method(request,&method);
    if(SUCCEEDED(hr))hr=ICoreWebView2WebResourceRequest_get_Headers(request,&headers);
    BOOL has=FALSE;
    if(SUCCEEDED(hr))hr=headers?ICoreWebView2HttpRequestHeaders_Contains(headers,L"Authorization",&has):E_POINTER;
    if(SUCCEEDED(hr)&&has)hr=ICoreWebView2HttpRequestHeaders_GetHeader(headers,L"Authorization",&authorization);
    if(SUCCEEDED(hr))hr=CreateUri(uri,Uri_CREATE_CANONICALIZE|Uri_CREATE_NO_DECODE_EXTRA_INFO|Uri_CREATE_NO_IE_SETTINGS|Uri_CREATE_NO_PRE_PROCESS_HTML_URI,0,&parsed);
    if(SUCCEEDED(hr))hr=IUri_GetPath(parsed,&path);
    if(SUCCEEDED(hr)&&path&&wcslen(path)<128&&p->count<128){
        CredentialProbeRecord *record=&p->records[p->count++];
        record->origin=probe_origin(p,uri);record->method=request_method(method);record->authorization=probe_authorization(authorization);
        wcscpy(record->path,path);
    }else p->overflow=TRUE;
    if(authorization){SecureZeroMemory(authorization,(wcslen(authorization)+1)*sizeof(WCHAR));CoTaskMemFree(authorization);}
    CoTaskMemFree(uri);CoTaskMemFree(method);SysFreeString(path);
    if(parsed)IUri_Release(parsed);if(headers)ICoreWebView2HttpRequestHeaders_Release(headers);if(request)ICoreWebView2WebResourceRequest_Release(request);
    return S_OK;
}
static BOOL fixture_certificate(const WCHAR *pem){
    static const BYTE expected[32]={0x96,0xf7,0x19,0x84,0x91,0xa3,0xdc,0x45,0x75,0x0a,0x25,0xa8,0x13,0x1a,0x16,0x60,0xe7,0x2d,0x27,0xba,0x04,0xcc,0xf9,0xc4,0xec,0x5d,0x81,0x13,0x09,0x46,0x3e,0x3e};
    if(!pem||wcsnlen(pem,65537)>65536)return FALSE;
    DWORD bytes=0;
    if(!CryptStringToBinaryW(pem,0,CRYPT_STRING_BASE64HEADER,NULL,&bytes,NULL,NULL)||!bytes||bytes>16384)return FALSE;
    BYTE *der=malloc(bytes);if(!der)return FALSE;
    BYTE hash[32];DWORD length=sizeof(hash);
    BOOL valid=CryptStringToBinaryW(pem,0,CRYPT_STRING_BASE64HEADER,der,&bytes,NULL,NULL)&&
        CryptHashCertificate2(L"SHA256",0,NULL,der,bytes,hash,&length)&&length==sizeof(hash)&&!memcmp(hash,expected,sizeof(hash));
    free(der);return valid;
}
static HRESULT STDMETHODCALLTYPE probe_certificate_invoke(ICoreWebView2ServerCertificateErrorDetectedEventHandler *iface,ICoreWebView2 *sender,ICoreWebView2ServerCertificateErrorDetectedEventArgs *args){
    (void)sender;CredentialProbe *p=certificate_probe(iface);
    ICoreWebView2ServerCertificateErrorDetectedEventArgs_put_Action(args,COREWEBVIEW2_SERVER_CERTIFICATE_ERROR_ACTION_CANCEL);
    WCHAR *uri=NULL,*pem=NULL;ICoreWebView2Certificate *certificate=NULL;
    HRESULT hr=ICoreWebView2ServerCertificateErrorDetectedEventArgs_get_RequestUri(args,&uri);
    if(SUCCEEDED(hr))hr=ICoreWebView2ServerCertificateErrorDetectedEventArgs_get_ServerCertificate(args,&certificate);
    if(SUCCEEDED(hr))hr=certificate?ICoreWebView2Certificate_ToPemEncoding(certificate,&pem):E_POINTER;
    BOOL allowed=SUCCEEDED(hr)&&p->trust&&probe_origin(p,uri)!=UINT_MAX&&fixture_certificate(pem);
    if(allowed){++p->allowed_certificates;ICoreWebView2ServerCertificateErrorDetectedEventArgs_put_Action(args,COREWEBVIEW2_SERVER_CERTIFICATE_ERROR_ACTION_ALWAYS_ALLOW);}
    else ++p->denied_certificates;
    if(certificate)ICoreWebView2Certificate_Release(certificate);CoTaskMemFree(uri);CoTaskMemFree(pem);
    return S_OK;
}
static const ICoreWebView2WebResourceRequestedEventHandlerVtbl probe_resource_vtable={probe_resource_query,probe_resource_add,probe_resource_release,probe_resource_invoke};
static const ICoreWebView2ServerCertificateErrorDetectedEventHandlerVtbl probe_certificate_vtable={probe_certificate_query,probe_certificate_add,probe_certificate_release,probe_certificate_invoke};
HRESULT zwv_test_credential_probe_install(State *state,const WCHAR *const *origins,uint32_t count,int trust,CredentialProbe **out){
    if(!out)return E_POINTER;
    *out=NULL;
    if(!state||state->closed||!state->webview||!origins||!count||count>4)return E_INVALIDARG;
    CredentialProbe *p=calloc(1,sizeof(*p));if(!p)return E_OUTOFMEMORY;
    p->refs=1;p->origin_count=count;p->trust=!!trust;
    p->resource.lpVtbl=&probe_resource_vtable;p->certificate.lpVtbl=&probe_certificate_vtable;
    InterlockedIncrement(&credential_live_probes);
    for(uint32_t i=0;i<count;++i)if(FAILED(net_origin(origins[i],TRUE,TRUE,&p->origins[i]))||!p->origins[i].https){probe_release(p);return E_INVALIDARG;}
    ICoreWebView2_14 *view=NULL;
    HRESULT hr=ICoreWebView2_QueryInterface(state->webview,&IID_ICoreWebView2_14,(void **)&view);
    EventRegistrationToken resource={0},certificate={0};
    if(SUCCEEDED(hr))hr=ICoreWebView2_add_WebResourceRequested(state->webview,&p->resource,&resource);
    BOOL registered=SUCCEEDED(hr);
    if(SUCCEEDED(hr))hr=ICoreWebView2_14_add_ServerCertificateErrorDetected(view,&p->certificate,&certificate);
    if(FAILED(hr)&&registered)ICoreWebView2_remove_WebResourceRequested(state->webview,resource);
    if(view)ICoreWebView2_14_Release(view);
    if(FAILED(hr)){probe_release(p);return hr;}
    *out=p;return S_OK;
}
void zwv_test_credential_probe_counts(CredentialProbe *p,uint32_t *records,uint32_t *allowed,uint32_t *denied,uint32_t *references,uint32_t *overflow){
    *records=p->count;*allowed=p->allowed_certificates;*denied=p->denied_certificates;*references=(uint32_t)InterlockedCompareExchange(&p->refs,0,0);*overflow=!!p->overflow;
}
int zwv_test_credential_probe_record(CredentialProbe *p,uint32_t index,CredentialProbeRecord *out){if(index>=p->count)return 0;*out=p->records[index];return 1;}
void zwv_test_credential_probe_release(CredentialProbe *p){probe_release(p);}
uint32_t zwv_test_credential_live_probes(void){return (uint32_t)InterlockedCompareExchange(&credential_live_probes,0,0);}
