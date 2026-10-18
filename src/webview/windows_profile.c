#include "windows_profile.h"
#include <wincrypt.h>
#include <assert.h>
#include <stdlib.h>
#include <string.h>
#include <wchar.h>

#define ZWPW_PATH_UNITS 4096u
#define ZWPW_CERT_BYTES 16384u
enum ContextPhase { CONTEXT_RESERVED,CONTEXT_ADMITTED,CONTEXT_PENDING,CONTEXT_ACTIVE,CONTEXT_REVOKED };
enum EnvironmentPhase { ENVIRONMENT_IDLE,ENVIRONMENT_CREATING,ENVIRONMENT_READY,ENVIRONMENT_FAILED,ENVIRONMENT_CLOSED };
struct ZwpwContext {
    LONG refs;
    ZwpwProfile *profile;
    ZwpwContext *previous,*next;
    ZwpwContextStart start;
    uint64_t process_token;
    enum ContextPhase phase;
    BOOL token_open,bound,domain_admission,environment_delivered;
};
struct ZwpwProfile {
    ICoreWebView2EnvironmentOptions options;
    ICoreWebView2EnvironmentOptions2 exclusive;
    ICoreWebView2CreateCoreWebView2EnvironmentCompletedHandler environment_handler;
    LONG refs;
    DWORD owner;
    ZwpwLifetime *domain;
    WCHAR *path;
    unsigned char *certificate;
    size_t certificate_length,allocation,owned,peak,limit;
    uint32_t context_count,context_limit,leases,lease_limit;
    BOOL accepting,owner_open;
    enum EnvironmentPhase environment_phase;
    HRESULT environment_failure;
    ICoreWebView2Environment *environment;
    ZwpwContext *contexts;
};
static ICoreWebView2CreateCoreWebView2EnvironmentCompletedHandlerVtbl environment_vtable;
static volatile LONG live_profiles,live_contexts;
static volatile LONG64 live_bytes;
#ifdef ZWPW_PROFILE_TESTING
static int fail_after=-1;
void zwpw_profile_test_fail_after(int after) { fail_after=after; }
#endif
static void *allocate(size_t bytes) {
#ifdef ZWPW_PROFILE_TESTING
    if (fail_after==0) return NULL;
    if (fail_after>0) --fail_after;
#endif
    return calloc(1,bytes);
}
static void profile_ref(ZwpwProfile *p) { InterlockedIncrement(&p->refs); }
static void profile_unref(ZwpwProfile *p) {
    if (InterlockedDecrement(&p->refs)) return;
    assert(GetCurrentThreadId()==p->owner);
    assert(!p->environment&&!p->contexts&&!p->context_count&&!p->leases);
    ZwpwLifetime *domain=p->domain;size_t bytes=p->allocation;
    free(p);
    zwpw_lifetime_unref(domain);
    InterlockedAdd64(&live_bytes,-(LONG64)bytes);
    InterlockedDecrement(&live_profiles);
}
static int owner(ZwpwProfile *p) {
    return GetCurrentThreadId()==p->owner?ZWPW_PROFILE_OK:ZWPW_PROFILE_WRONG_THREAD;
}
static int charge(ZwpwProfile *p,size_t bytes) {
    if (bytes>p->limit-p->owned) return ZWPW_PROFILE_CAPACITY;
    p->owned+=bytes;if (p->owned>p->peak) p->peak=p->owned;
    InterlockedAdd64(&live_bytes,(LONG64)bytes);return ZWPW_PROFILE_OK;
}
static void refund(ZwpwProfile *p,size_t bytes) {
    assert(p->owned>=bytes);p->owned-=bytes;
    InterlockedAdd64(&live_bytes,-(LONG64)bytes);
}
static HRESULT windows_error(void) {
    DWORD error=GetLastError();return error?HRESULT_FROM_WIN32(error):E_FAIL;
}
static int measure(const WCHAR *path,const ZwpwProfileTls *tls,size_t *bytes,DWORD *der,HRESULT *failure) {
    *bytes=0;*der=0;if (failure) *failure=S_OK;
    if (!path) return ZWPW_PROFILE_INVALID;
    size_t length=wcsnlen(path,ZWPW_PATH_UNITS+1);
    if (!length||length>ZWPW_PATH_UNITS||length>(SIZE_MAX-sizeof(ZwpwProfile))/sizeof(WCHAR)-1) return ZWPW_PROFILE_INVALID;
    *bytes=sizeof(ZwpwProfile)+(length+1)*sizeof(WCHAR);
    if (tls) {
        if (!tls->certificate_pem||!tls->certificate_length||tls->certificate_length>ZWPW_CERT_BYTES) return ZWPW_PROFILE_TLS;
        if (!CryptStringToBinaryA(tls->certificate_pem,(DWORD)tls->certificate_length,
            CRYPT_STRING_BASE64HEADER|CRYPT_STRING_STRICT,NULL,der,NULL,NULL)) {
            if (failure) *failure=windows_error();return ZWPW_PROFILE_TLS;
        }
        if (!*der||*der>ZWPW_CERT_BYTES) return ZWPW_PROFILE_TLS;
        *bytes+=*der;
    }
    return ZWPW_PROFILE_OK;
}
int zwpw_profile_measure(const WCHAR *path,const ZwpwProfileTls *tls,size_t *bytes,HRESULT *failure) {
    if (!bytes) return ZWPW_PROFILE_INVALID;
    DWORD der=0;return measure(path,tls,bytes,&der,failure);
}

/* This immutable COM options object is embedded in the opt-in Profile. Legacy
   raw-path Views and their custom-scheme options do not acquire these fields. */
static ULONG STDMETHODCALLTYPE options_add(ICoreWebView2EnvironmentOptions *iface) {
    ZwpwProfile *p=(ZwpwProfile *)((char *)iface - offsetof(ZwpwProfile,options));
    return (ULONG)InterlockedIncrement(&p->refs);
}
static ULONG STDMETHODCALLTYPE options_release(ICoreWebView2EnvironmentOptions *iface) {
    ZwpwProfile *p=(ZwpwProfile *)((char *)iface - offsetof(ZwpwProfile,options));
    ULONG refs=(ULONG)InterlockedCompareExchange(&p->refs,0,0)-1;profile_unref(p);return refs;
}
static HRESULT STDMETHODCALLTYPE options_query(ICoreWebView2EnvironmentOptions *iface,REFIID iid,void **out) {
    if (!out) return E_POINTER;*out=NULL;
    ZwpwProfile *p=(ZwpwProfile *)((char *)iface - offsetof(ZwpwProfile,options));
    if (IsEqualIID(iid,&IID_IUnknown)||IsEqualIID(iid,&IID_ICoreWebView2EnvironmentOptions)) *out=&p->options;
    else if (IsEqualIID(iid,&IID_ICoreWebView2EnvironmentOptions2)) *out=&p->exclusive;
    else return E_NOINTERFACE;
    profile_ref(p);return S_OK;
}
static HRESULT string_copy(const WCHAR *value,WCHAR **out) {
    if (!out) return E_POINTER;*out=NULL;
    if (!value) return S_OK;
    size_t bytes=(wcslen(value)+1)*sizeof(WCHAR);
    WCHAR *copy=CoTaskMemAlloc(bytes);if (!copy) return E_OUTOFMEMORY;
    memcpy(copy,value,bytes);*out=copy;return S_OK;
}
static HRESULT STDMETHODCALLTYPE options_string(ICoreWebView2EnvironmentOptions *iface,WCHAR **out) { (void)iface;return string_copy(NULL,out); }
static HRESULT STDMETHODCALLTYPE options_version(ICoreWebView2EnvironmentOptions *iface,WCHAR **out) { (void)iface;return string_copy(L"154.0.4258.31",out); }
static HRESULT STDMETHODCALLTYPE options_set_string(ICoreWebView2EnvironmentOptions *iface,const WCHAR *value) { (void)iface;(void)value;return E_ACCESSDENIED; }
static HRESULT STDMETHODCALLTYPE options_sso(ICoreWebView2EnvironmentOptions *iface,BOOL *out) { (void)iface;if (!out) return E_POINTER;*out=FALSE;return S_OK; }
static HRESULT STDMETHODCALLTYPE options_set_bool(ICoreWebView2EnvironmentOptions *iface,BOOL value) { (void)iface;(void)value;return E_ACCESSDENIED; }
static ICoreWebView2EnvironmentOptionsVtbl options_vtable={options_query,options_add,options_release,options_string,options_set_string,options_string,options_set_string,options_version,options_set_string,options_sso,options_set_bool};
static ZwpwProfile *exclusive_profile(ICoreWebView2EnvironmentOptions2 *iface) { return (ZwpwProfile *)((char *)iface - offsetof(ZwpwProfile,exclusive)); }
static HRESULT STDMETHODCALLTYPE exclusive_query(ICoreWebView2EnvironmentOptions2 *iface,REFIID iid,void **out) { return options_query(&exclusive_profile(iface)->options,iid,out); }
static ULONG STDMETHODCALLTYPE exclusive_add(ICoreWebView2EnvironmentOptions2 *iface) { return options_add(&exclusive_profile(iface)->options); }
static ULONG STDMETHODCALLTYPE exclusive_release(ICoreWebView2EnvironmentOptions2 *iface) { return options_release(&exclusive_profile(iface)->options); }
static HRESULT STDMETHODCALLTYPE exclusive_get(ICoreWebView2EnvironmentOptions2 *iface,BOOL *out) { (void)iface;if (!out) return E_POINTER;*out=TRUE;return S_OK; }
static HRESULT STDMETHODCALLTYPE exclusive_set(ICoreWebView2EnvironmentOptions2 *iface,BOOL value) { (void)iface;(void)value;return E_ACCESSDENIED; }
static ICoreWebView2EnvironmentOptions2Vtbl exclusive_vtable={exclusive_query,exclusive_add,exclusive_release,exclusive_get,exclusive_set};

int zwpw_profile_create(ZwpwLifetime *domain,const WCHAR *path,const ZwpwProfileOptions *options,
                        const ZwpwProfileTls *tls,ZwpwProfile **out,HRESULT *failure) {
    if (failure) *failure=S_OK;
    if (!out) return ZWPW_PROFILE_INVALID;*out=NULL;
    if (!domain) return ZWPW_PROFILE_INVALID;
    if (zwpw_lifetime_check_main(domain)!=ZWPW_OK) return ZWPW_PROFILE_WRONG_THREAD;
    if (!options||!options->contexts||options->contexts>64||!options->leases||options->leases>256||options->bytes>1024*1024) return ZWPW_PROFILE_INVALID;
    size_t bytes=0;DWORD der=0;
    int result=measure(path,tls,&bytes,&der,failure);if (result) return result;
    size_t temporary=tls?tls->temporary_bytes:0;
    if (bytes>options->bytes||temporary>options->bytes-bytes) return ZWPW_PROFILE_CAPACITY;
    /* Independent native lifetime pin precedes this first allocation. */
    zwpw_lifetime_ref(domain);
    ZwpwProfile *p=allocate(bytes);
    if (!p) { zwpw_lifetime_unref(domain);return ZWPW_PROFILE_OOM; }
    p->refs=1;p->owner=GetCurrentThreadId();p->domain=domain;
    p->allocation=bytes;p->owned=bytes;p->peak=bytes+temporary;p->limit=options->bytes;
    p->context_limit=options->contexts;p->lease_limit=options->leases;
    p->accepting=TRUE;p->owner_open=TRUE;
    p->options.lpVtbl=&options_vtable;p->exclusive.lpVtbl=&exclusive_vtable;
    p->environment_handler.lpVtbl=&environment_vtable;
    p->path=(WCHAR *)(p+1);wcscpy(p->path,path);
    if (der) {
        p->certificate=(unsigned char *)(p->path+wcslen(p->path)+1);
        p->certificate_length=der;
        if (!CryptStringToBinaryA(tls->certificate_pem,(DWORD)tls->certificate_length,
            CRYPT_STRING_BASE64HEADER|CRYPT_STRING_STRICT,p->certificate,&der,NULL,NULL)) {
            if (failure) *failure=windows_error();free(p);zwpw_lifetime_unref(domain);return ZWPW_PROFILE_TLS;
        }
        PCCERT_CONTEXT parsed=CertCreateCertificateContext(X509_ASN_ENCODING,p->certificate,der);
        if (!parsed) { if (failure) *failure=windows_error();free(p);zwpw_lifetime_unref(domain);return ZWPW_PROFILE_TLS; }
        BOOL exact=parsed->cbCertEncoded==der;
        CertFreeCertificateContext(parsed);
        if (!exact) { free(p);zwpw_lifetime_unref(domain);return ZWPW_PROFILE_TLS; }
    }
    InterlockedIncrement(&live_profiles);InterlockedAdd64(&live_bytes,(LONG64)bytes);
    *out=p;return ZWPW_PROFILE_OK;
}

void zwpw_context_ref(ZwpwContext *c) { InterlockedIncrement(&c->refs); }
void zwpw_context_unref(ZwpwContext *c) {
    if (InterlockedDecrement(&c->refs)) return;
    ZwpwProfile *p=c->profile;assert(GetCurrentThreadId()==p->owner&&!c->bound&&!c->domain_admission);
    if (c->previous) c->previous->next=c->next;else p->contexts=c->next;
    if (c->next) c->next->previous=c->previous;
    size_t bytes=sizeof(*c);free(c);
    --p->context_count;refund(p,bytes);InterlockedDecrement(&live_contexts);
    profile_unref(p);
}
static void release_start(ZwpwContextStart *s) {
    if (s->release) s->release(s->context);
    *s=(ZwpwContextStart){0};
}
static void revoke_context(ZwpwContext *c,HRESULT reason,BOOL notify) {
    zwpw_context_ref(c);
    ZwpwContextStart saved=c->start;c->start=(ZwpwContextStart){0};
    c->phase=CONTEXT_REVOKED;c->bound=FALSE;
    if (c->domain_admission) { c->domain_admission=FALSE;assert(zwpw_lifetime_withdraw(c->profile->domain)==ZWPW_OK); }
    /* All logical publication is withdrawn before either foreign continuation
       or final State release. Only this independent C pin is read afterward. */
    if (notify&&saved.revoke) saved.revoke(saved.context,reason);
    release_start(&saved);
    zwpw_context_unref(c);
}
int zwpw_profile_seal(ZwpwProfile *p) {
    int result=owner(p);if (result) return result;
    profile_ref(p);
    p->accepting=FALSE;
    assert(zwpw_lifetime_seal(p->domain)==ZWPW_OK);
    ICoreWebView2Environment *environment=p->environment;p->environment=NULL;
    p->environment_phase=ENVIRONMENT_CLOSED;
    for (;;) {
        ZwpwContext *pending=NULL;
        for (ZwpwContext *c=p->contexts;c;c=c->next)
            if (c->phase!=CONTEXT_ACTIVE&&c->phase!=CONTEXT_REVOKED) { pending=c;break; }
        if (!pending) break;
        revoke_context(pending,E_ABORT,TRUE);
    }
    if (environment) ICoreWebView2Environment_Release(environment);
    profile_unref(p);return ZWPW_PROFILE_OK;
}
int zwpw_profile_close(ZwpwProfile *p) {
    int result=owner(p);if (result) return result;
    if (!p->owner_open) return ZWPW_PROFILE_CLOSED;
    p->owner_open=FALSE;
    result=zwpw_profile_seal(p);
    profile_unref(p);return result;
}
int zwpw_profile_stats(ZwpwProfile *p,ZwpwProfileStats *out) {
    int result=owner(p);if (result) return result;
    if (!out) return ZWPW_PROFILE_INVALID;
    *out=(ZwpwProfileStats){p->owned,p->peak,p->context_count,p->context_limit,p->accepting,p->leases,p->lease_limit};
    return ZWPW_PROFILE_OK;
}
int zwpw_profile_lease_check(ZwpwProfile *p) {
    int result=owner(p);if (result) return result;
    return p->accepting?ZWPW_PROFILE_OK:ZWPW_PROFILE_CLOSED;
}
int zwpw_profile_lease_retain(ZwpwProfile *p) {
    int result=zwpw_profile_lease_check(p);if (result) return result;
    if (p->leases==p->lease_limit) return ZWPW_PROFILE_FULL;
    ++p->leases;profile_ref(p);return ZWPW_PROFILE_OK;
}
int zwpw_profile_lease_release(ZwpwProfile *p) {
    int result=owner(p);if (result) return result;
    if (!p->leases) return ZWPW_PROFILE_INVALID;
    --p->leases;profile_unref(p);return ZWPW_PROFILE_OK;
}
int zwpw_profile_context_create(ZwpwProfile *p,ZwpwContext **out) {
    if (!out) return ZWPW_PROFILE_INVALID;*out=NULL;
    int result=zwpw_profile_lease_check(p);if (result) return result;
    if (p->context_count==p->context_limit) return ZWPW_PROFILE_FULL;
    result=charge(p,sizeof(ZwpwContext));if (result) return result;
    ZwpwContext *c=allocate(sizeof(*c));
    if (!c) { refund(p,sizeof(*c));return ZWPW_PROFILE_OOM; }
    c->refs=1;c->profile=p;c->token_open=TRUE;c->phase=CONTEXT_RESERVED;
    c->next=p->contexts;if (c->next) c->next->previous=c;
    p->contexts=c;++p->context_count;profile_ref(p);InterlockedIncrement(&live_contexts);
    *out=c;return ZWPW_PROFILE_OK;
}
int zwpw_profile_context_admit(ZwpwContext *c) {
    int result=zwpw_profile_lease_check(c->profile);if (result) return result;
    if (!c->token_open||c->phase!=CONTEXT_RESERVED) return ZWPW_PROFILE_CLOSED;
    c->phase=CONTEXT_ADMITTED;return ZWPW_PROFILE_OK;
}
int zwpw_profile_context_close(ZwpwContext *c) {
    int result=owner(c->profile);if (result) return result;
    if (!c->token_open) return ZWPW_PROFILE_CLOSED;
    c->token_open=FALSE;
    zwpw_context_unref(c);return ZWPW_PROFILE_OK;
}

static void deliver_environment(ZwpwContext *c,ICoreWebView2Environment *environment) {
    zwpw_context_ref(c);
    if (c->phase==CONTEXT_PENDING&&c->bound&&!c->environment_delivered&&c->start.environment) {
        c->environment_delivered=TRUE;
        ZwpwContextStart start=c->start;
        start.environment(start.context,S_OK,environment);
    }
    zwpw_context_unref(c);
}
static HRESULT STDMETHODCALLTYPE environment_query(ICoreWebView2CreateCoreWebView2EnvironmentCompletedHandler *iface,REFIID iid,void **out) {
    if (!out) return E_POINTER;*out=NULL;
    if (!IsEqualIID(iid,&IID_IUnknown)&&!IsEqualIID(iid,&IID_ICoreWebView2CreateCoreWebView2EnvironmentCompletedHandler)) return E_NOINTERFACE;
    *out=iface;ICoreWebView2CreateCoreWebView2EnvironmentCompletedHandler_AddRef(iface);return S_OK;
}
static ZwpwProfile *environment_profile(ICoreWebView2CreateCoreWebView2EnvironmentCompletedHandler *iface) {
    return (ZwpwProfile *)((char *)iface - offsetof(ZwpwProfile,environment_handler));
}
static ULONG STDMETHODCALLTYPE environment_add(ICoreWebView2CreateCoreWebView2EnvironmentCompletedHandler *iface) { return (ULONG)InterlockedIncrement(&environment_profile(iface)->refs); }
static ULONG STDMETHODCALLTYPE environment_release(ICoreWebView2CreateCoreWebView2EnvironmentCompletedHandler *iface) {
    ZwpwProfile *p=environment_profile(iface);
    ULONG refs=(ULONG)InterlockedCompareExchange(&p->refs,0,0)-1;profile_unref(p);return refs;
}
static HRESULT STDMETHODCALLTYPE environment_invoke(ICoreWebView2CreateCoreWebView2EnvironmentCompletedHandler *iface,HRESULT status,ICoreWebView2Environment *environment) {
    ZwpwProfile *p=environment_profile(iface);profile_ref(p);
    if (!p->accepting||p->environment_phase!=ENVIRONMENT_CREATING) { profile_unref(p);return S_OK; }
    ICoreWebView2Environment7 *info=NULL;WCHAR *path=NULL;
    HRESULT hr=FAILED(status)?status:(!environment?E_POINTER:S_OK);
    if (SUCCEEDED(hr)) hr=ICoreWebView2Environment_QueryInterface(environment,&IID_ICoreWebView2Environment7,(void **)&info);
    if (SUCCEEDED(hr)&&!info) hr=E_POINTER;
    if (SUCCEEDED(hr)&&p->accepting) hr=ICoreWebView2Environment7_get_UserDataFolder(info,&path);
    if (SUCCEEDED(hr)&&(!p->accepting||!path||wcsnlen(path,ZWPW_PATH_UNITS+1)>ZWPW_PATH_UNITS||wcscmp(path,p->path))) hr=E_ACCESSDENIED;
    if (SUCCEEDED(hr)) {
        ICoreWebView2Environment_AddRef(environment);
        if (p->accepting&&p->environment_phase==ENVIRONMENT_CREATING) {
            p->environment=environment;p->environment_phase=ENVIRONMENT_READY;
        } else { ICoreWebView2Environment_Release(environment);hr=E_ABORT; }
    }
    if (info) ICoreWebView2Environment7_Release(info);
    CoTaskMemFree(path);
    if (p->accepting&&p->environment_phase==ENVIRONMENT_READY) {
        /* No borrowed next pointer crosses a foreign callback: scan again and
           deliver only records still exact/pending/not previously delivered. */
        for (;;) {
            ZwpwContext *pending=NULL;
            for (ZwpwContext *c=p->contexts;c;c=c->next)
                if (c->phase==CONTEXT_PENDING&&c->bound&&!c->environment_delivered) { pending=c;break; }
            if (!pending) break;
            zwpw_context_ref(pending);
            ICoreWebView2Environment_AddRef(environment);
            deliver_environment(pending,environment);
            ICoreWebView2Environment_Release(environment);
            zwpw_context_unref(pending);
            if (!p->accepting||p->environment_phase!=ENVIRONMENT_READY) break;
        }
    } else if (p->accepting&&p->environment_phase==ENVIRONMENT_CREATING) {
        p->environment_phase=ENVIRONMENT_FAILED;p->environment_failure=FAILED(hr)?hr:E_FAIL;
        for (;;) {
            ZwpwContext *pending=NULL;
            for (ZwpwContext *c=p->contexts;c;c=c->next) if (c->phase==CONTEXT_PENDING) { pending=c;break; }
            if (!pending) break;
            revoke_context(pending,p->environment_failure,TRUE);
        }
    }
    profile_unref(p);return S_OK;
}
static ICoreWebView2CreateCoreWebView2EnvironmentCompletedHandlerVtbl environment_vtable={environment_query,environment_add,environment_release,environment_invoke};

int zwpw_context_begin(ZwpwContext *c,ZwpwCreateEnvironment create,const ZwpwContextStart *input) {
    ZwpwProfile *p=c->profile;int result=zwpw_profile_lease_check(p);if (result) return result;
    WCHAR argument[2];SetLastError(ERROR_SUCCESS);
    DWORD argument_length=GetEnvironmentVariableW(L"WEBVIEW2_ADDITIONAL_BROWSER_ARGUMENTS",argument,2);
    if (argument_length) return ZWPW_PROFILE_INVALID;
    DWORD environment_error=GetLastError();
    if (environment_error!=ERROR_SUCCESS&&environment_error!=ERROR_ENVVAR_NOT_FOUND) return ZWPW_PROFILE_SYSTEM;
    if (c->phase!=CONTEXT_ADMITTED||c->bound||!create||!input||!input->context||!input->environment||!input->revoke||!input->release) return ZWPW_PROFILE_INVALID;
    if (p->environment_phase==ENVIRONMENT_FAILED||p->environment_phase==ENVIRONMENT_CLOSED) return ZWPW_PROFILE_CLOSED;
    result=zwpw_lifetime_admit(p->domain);if (result) return result==ZWPW_FULL?ZWPW_PROFILE_FULL:ZWPW_PROFILE_CLOSED;
    c->domain_admission=TRUE;c->bound=TRUE;c->phase=CONTEXT_PENDING;c->start=*input;
    zwpw_context_ref(c);
    if (p->environment_phase==ENVIRONMENT_READY) {
        ICoreWebView2Environment *environment=p->environment;
        ICoreWebView2Environment_AddRef(environment);
        if (p->accepting&&c->phase==CONTEXT_PENDING) deliver_environment(c,environment);
        ICoreWebView2Environment_Release(environment);
    } else if (p->environment_phase==ENVIRONMENT_IDLE) {
        p->environment_phase=ENVIRONMENT_CREATING;
        /* The one physical creation handler is embedded in this bounded
           Profile allocation. SDK references retain only this C owner. */
        profile_ref(p);
        HRESULT failure=create(NULL,p->path,&p->options,&p->environment_handler);
        profile_unref(p);
        if (FAILED(failure)&&p->accepting&&p->environment_phase==ENVIRONMENT_CREATING) {
            p->environment_phase=ENVIRONMENT_FAILED;p->environment_failure=failure;
            for (;;) {
                ZwpwContext *pending=NULL;
                for (ZwpwContext *entry=p->contexts;entry;entry=entry->next) if (entry->phase==CONTEXT_PENDING) { pending=entry;break; }
                if (!pending) break;
                revoke_context(pending,failure,TRUE);
            }
        }
    }
    zwpw_context_unref(c);return ZWPW_PROFILE_OK;
}
int zwpw_context_publish_process(ZwpwContext *c,HANDLE *handle) {
    int result=owner(c->profile);if (result) return result;
    if (c->phase!=CONTEXT_PENDING||!c->bound||!c->profile->accepting||c->process_token) return ZWPW_PROFILE_CLOSED;
    zwpw_context_ref(c);
    uint64_t token=0;
    result=zwpw_lifetime_publish(c->profile->domain,handle,&token);
    if (!result) c->process_token=token;
    zwpw_context_unref(c);
    /* Native handle publication is a commit. Reentrant teardown after that
       commit cannot turn a consumed handle back into a failed candidate. The
       following activate gate independently refuses a revoked Context. */
    return result?(result==ZWPW_FULL?ZWPW_PROFILE_FULL:ZWPW_PROFILE_CLOSED):ZWPW_PROFILE_OK;
}
int zwpw_context_activate(ZwpwContext *c) {
    int result=owner(c->profile);if (result) return result;
    if (c->phase!=CONTEXT_PENDING||!c->profile->accepting||!c->bound||!c->process_token||
        zwpw_lifetime_matches(c->profile->domain,c->process_token)!=ZWPW_OK) return ZWPW_PROFILE_CLOSED;
    zwpw_context_ref(c);
    ZwpwContextStart saved=c->start;c->start=(ZwpwContextStart){0};c->phase=CONTEXT_ACTIVE;
    release_start(&saved);
    result=zwpw_context_is_active(c)?ZWPW_PROFILE_OK:ZWPW_PROFILE_CLOSED;
    zwpw_context_unref(c);return result;
}
void zwpw_context_detach(ZwpwContext *c) {
    assert(owner(c->profile)==ZWPW_PROFILE_OK);
    revoke_context(c,E_ABORT,FALSE);
}
int zwpw_context_is_pending(ZwpwContext *c) {
    return owner(c->profile)==ZWPW_PROFILE_OK&&c->phase==CONTEXT_PENDING&&c->bound&&c->profile->accepting&&c->domain_admission;
}
void zwpw_context_fail(ZwpwContext *c,HRESULT reason) {
    assert(owner(c->profile)==ZWPW_PROFILE_OK);
    if (c->phase==CONTEXT_PENDING) revoke_context(c,reason,TRUE);
}
int zwpw_context_is_active(ZwpwContext *c) {
    if (owner(c->profile)!=ZWPW_PROFILE_OK||c->phase!=CONTEXT_ACTIVE||!c->bound||!c->domain_admission) return 0;
    return zwpw_lifetime_matches(c->profile->domain,c->process_token)==ZWPW_OK;
}
int zwpw_context_certificate_matches(ZwpwContext *c,const WCHAR *pem) {
    if (!zwpw_context_is_active(c)||!pem||!c->profile->certificate_length||wcsnlen(pem,ZWPW_CERT_BYTES+1)>ZWPW_CERT_BYTES) return 0;
    zwpw_context_ref(c);ZwpwProfile *p=c->profile;
    DWORD length=0;int matches=0;
    if (CryptStringToBinaryW(pem,0,CRYPT_STRING_BASE64HEADER|CRYPT_STRING_STRICT,NULL,&length,NULL,NULL)&&
        length==p->certificate_length&&charge(p,length)==ZWPW_PROFILE_OK) {
        size_t charged=length;
        unsigned char *der=allocate(length);
        if (der) {
            if (CryptStringToBinaryW(pem,0,CRYPT_STRING_BASE64HEADER|CRYPT_STRING_STRICT,der,&length,NULL,NULL)&&
                length==p->certificate_length&&zwpw_context_is_active(c)) matches=memcmp(der,p->certificate,length)==0;
            free(der);
        }
        refund(p,charged);
    }
    zwpw_context_unref(c);return matches;
}
void zwpw_profile_counts(uint32_t *profiles,uint32_t *contexts,size_t *bytes) {
    *profiles=(uint32_t)InterlockedCompareExchange(&live_profiles,0,0);
    *contexts=(uint32_t)InterlockedCompareExchange(&live_contexts,0,0);
    *bytes=(size_t)InterlockedCompareExchange64(&live_bytes,0,0);
}
