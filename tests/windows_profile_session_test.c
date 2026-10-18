/* SDK ownership double. All callbacks/COM operations run on this test's main
   thread. The explicit worker owns only the independent retirement domain. */
#include "../src/webview/windows_profile.h"
#include <stdio.h>
#include <string.h>
#include <wchar.h>
#define CHECK(x) do { if (!(x)) { fprintf(stderr,"profile session:%d: %s\n",__LINE__,#x);return 0; } } while (0)
static const WCHAR canonical_path[]=L"D:\\ZigguratProfileDouble\\data";
typedef struct Driver {
    DWORD main;
    HANDLE ready,run,thread;
    ZwpwLifetime *domain;
    int created,result,wrong_constructor;
    uint32_t error;
} Driver;
static DWORD WINAPI worker(void *input) {
    Driver *d=input;
    HANDLE lock=CreateEventW(NULL,TRUE,FALSE,NULL);
    d->created=zwpw_lifetime_create(d->main,65536,lock,&d->domain,&d->error);
    if (lock) CloseHandle(lock);
    if (!d->created) {
        ZwpwProfile *bad=(ZwpwProfile *)(uintptr_t)8;HRESULT failure=E_FAIL;
        d->wrong_constructor=zwpw_profile_create(d->domain,(const WCHAR *)(uintptr_t)1,
            (const ZwpwProfileOptions *)(uintptr_t)1,(const ZwpwProfileTls *)(uintptr_t)1,
            &bad,&failure)==ZWPW_PROFILE_WRONG_THREAD&&!bad&&failure==S_OK;
        zwpw_lifetime_ref(d->domain); /* explicit main pin */
    }
    SetEvent(d->ready);
    if (d->created) return 0;
    WaitForSingleObject(d->run,INFINITE);
    d->result=zwpw_lifetime_run(d->domain,10000,&d->error);
    zwpw_lifetime_unref(d->domain);return 0;
}
static int driver_open(Driver *d) {
    *d=(Driver){0};d->main=GetCurrentThreadId();
    d->ready=CreateEventW(NULL,FALSE,FALSE,NULL);d->run=CreateEventW(NULL,FALSE,FALSE,NULL);
    CHECK(d->ready&&d->run);
    d->thread=CreateThread(NULL,0,worker,d,0,NULL);CHECK(d->thread);
    CHECK(WaitForSingleObject(d->ready,10000)==WAIT_OBJECT_0&&!d->created&&d->domain&&d->wrong_constructor);return 1;
}
static int driver_finish(Driver *d) {
    SetEvent(d->run);
    CHECK(WaitForSingleObject(d->thread,15000)==WAIT_OBJECT_0&&d->result==ZWPW_OK&&!d->error);
    CloseHandle(d->thread);CloseHandle(d->ready);CloseHandle(d->run);return 1;
}
static int all_zero(Driver *d) {
    uint32_t profiles=9,contexts=9;size_t bytes=9;
    zwpw_profile_counts(&profiles,&contexts,&bytes);CHECK(!profiles&&!contexts&&!bytes);
    zwpw_lifetime_unref(d->domain);d->domain=NULL;
    ZwpwLifetimeCounts counts;zwpw_lifetime_counts(&counts);
    CHECK(!counts.domains&&!counts.processes&&!counts.bytes);return 1;
}

typedef struct FakeEnvironment {
    ICoreWebView2Environment base;
    ICoreWebView2Environment7 info;
    LONG refs;
    const WCHAR *path;
    ZwpwProfile *close_on_get,*close_on_release;
} FakeEnvironment;
static FakeEnvironment *base_self(ICoreWebView2Environment *iface) { return (FakeEnvironment *)((char *)iface - offsetof(FakeEnvironment,base)); }
static FakeEnvironment *info_self(ICoreWebView2Environment7 *iface) { return (FakeEnvironment *)((char *)iface - offsetof(FakeEnvironment,info)); }
static HRESULT query(FakeEnvironment *f,REFIID iid,void **out) {
    *out=NULL;
    if (IsEqualIID(iid,&IID_IUnknown)||IsEqualIID(iid,&IID_ICoreWebView2Environment)) *out=&f->base;
    else if (IsEqualIID(iid,&IID_ICoreWebView2Environment7)) *out=&f->info;
    else return E_NOINTERFACE;
    InterlockedIncrement(&f->refs);return S_OK;
}
static HRESULT STDMETHODCALLTYPE base_query(ICoreWebView2Environment *iface,REFIID iid,void **out) { return query(base_self(iface),iid,out); }
static ULONG STDMETHODCALLTYPE base_add(ICoreWebView2Environment *iface) { return (ULONG)InterlockedIncrement(&base_self(iface)->refs); }
static ULONG drop(FakeEnvironment *f) {
    LONG refs=InterlockedDecrement(&f->refs);
    ZwpwProfile *p=f->close_on_release;f->close_on_release=NULL;
    if (p) zwpw_profile_close(p);
    return (ULONG)refs;
}
static ULONG STDMETHODCALLTYPE base_release(ICoreWebView2Environment *iface) { return drop(base_self(iface)); }
static HRESULT STDMETHODCALLTYPE info_query(ICoreWebView2Environment7 *iface,REFIID iid,void **out) { return query(info_self(iface),iid,out); }
static ULONG STDMETHODCALLTYPE info_add(ICoreWebView2Environment7 *iface) { return (ULONG)InterlockedIncrement(&info_self(iface)->refs); }
static ULONG STDMETHODCALLTYPE info_release(ICoreWebView2Environment7 *iface) { return drop(info_self(iface)); }
static HRESULT STDMETHODCALLTYPE info_path(ICoreWebView2Environment7 *iface,WCHAR **out) {
    FakeEnvironment *f=info_self(iface);
    size_t bytes=(wcslen(f->path)+1)*sizeof(WCHAR);
    *out=CoTaskMemAlloc(bytes);if (!*out) return E_OUTOFMEMORY;
    memcpy(*out,f->path,bytes);
    ZwpwProfile *p=f->close_on_get;f->close_on_get=NULL;
    if (p) zwpw_profile_close(p);
    return S_OK;
}
static ICoreWebView2EnvironmentVtbl base_vtable={.QueryInterface=base_query,.AddRef=base_add,.Release=base_release};
static ICoreWebView2Environment7Vtbl info_vtable={.QueryInterface=info_query,.AddRef=info_add,.Release=info_release,.get_UserDataFolder=info_path};
static void fake_init(FakeEnvironment *f,const WCHAR *path) {
    *f=(FakeEnvironment){0};f->base.lpVtbl=&base_vtable;f->info.lpVtbl=&info_vtable;f->refs=1;f->path=path;
}
static ICoreWebView2CreateCoreWebView2EnvironmentCompletedHandler *pending;
static unsigned creates,exclusive_seen;
static HRESULT STDAPICALLTYPE fake_create(PCWSTR executable,PCWSTR path,ICoreWebView2EnvironmentOptions *options,
                                         ICoreWebView2CreateCoreWebView2EnvironmentCompletedHandler *handler) {
    (void)executable;++creates;
    ICoreWebView2EnvironmentOptions2 *exclusive=NULL;BOOL value=FALSE;
    HRESULT hr=ICoreWebView2EnvironmentOptions_QueryInterface(options,&IID_ICoreWebView2EnvironmentOptions2,(void **)&exclusive);
    if (SUCCEEDED(hr)) hr=ICoreWebView2EnvironmentOptions2_get_ExclusiveUserDataFolderAccess(exclusive,&value);
    if (exclusive) ICoreWebView2EnvironmentOptions2_Release(exclusive);
    if (FAILED(hr)||!value||wcscmp(path,canonical_path)||pending) return E_INVALIDARG;
    ++exclusive_seen;pending=handler;
    ICoreWebView2CreateCoreWebView2EnvironmentCompletedHandler_AddRef(pending);
    return S_OK;
}
static int complete(FakeEnvironment *f) {
    CHECK(pending);
    ICoreWebView2CreateCoreWebView2EnvironmentCompletedHandler *saved=pending;pending=NULL;
    CHECK(ICoreWebView2CreateCoreWebView2EnvironmentCompletedHandler_Invoke(saved,S_OK,&f->base)==S_OK);
    ICoreWebView2CreateCoreWebView2EnvironmentCompletedHandler_Release(saved);return 1;
}
typedef struct Probe {
    ZwpwContext *context;
    ZwpwProfile *profile;
    unsigned ready,revoked,released;
    HRESULT failure;
    BOOL close_context_on_revoke,close_profile_on_revoke;
} Probe;
static void received_environment(void *input,HRESULT status,ICoreWebView2Environment *environment) {
    Probe *p=input;if (SUCCEEDED(status)&&environment) ++p->ready;else p->failure=status;
}
static void revoked(void *input,HRESULT status) {
    Probe *p=input;++p->revoked;p->failure=status;
    if (p->close_context_on_revoke&&p->context) {
        ZwpwContext *c=p->context;p->context=NULL;zwpw_profile_context_close(c);
    }
    if (p->close_profile_on_revoke&&p->profile) {
        ZwpwProfile *owner=p->profile;p->profile=NULL;zwpw_profile_close(owner);
    }
}
static void released(void *input) { ++((Probe *)input)->released; }
static int context_open(ZwpwProfile *p,Probe *probe) {
    *probe=(Probe){.profile=p};
    CHECK(zwpw_profile_context_create(p,&probe->context)==ZWPW_PROFILE_OK);
    CHECK(zwpw_profile_context_admit(probe->context)==ZWPW_PROFILE_OK);return 1;
}
static int begin(Probe *p) {
    ZwpwContextStart start={p,received_environment,revoked,released};
    CHECK(zwpw_context_begin(p->context,fake_create,&start)==ZWPW_PROFILE_OK);return 1;
}
static int owner_create(Driver *d,const char *pem,size_t pem_length,ZwpwProfile **p) {
    ZwpwProfileOptions options={2,65536,1};
    ZwpwProfileTls tls={pem,pem_length,16385};HRESULT failure=S_OK;
    CHECK(zwpw_profile_create(d->domain,canonical_path,&options,pem?&tls:NULL,p,&failure)==ZWPW_PROFILE_OK&&!failure);return 1;
}
static int close_context(Probe *p) {
    if (p->context) {
        zwpw_context_detach(p->context);
        CHECK(zwpw_profile_context_close(p->context)==ZWPW_PROFILE_OK);p->context=NULL;
    }
    return 1;
}
static int allocation_and_reservations(void) {
    Driver d;CHECK(driver_open(&d));
    size_t required=0;HRESULT failure=S_OK;
    CHECK(zwpw_profile_measure(canonical_path,NULL,&required,&failure)==ZWPW_PROFILE_OK&&!failure);
    ZwpwProfileOptions options={2,required-1,1};ZwpwProfile *p=(ZwpwProfile *)(uintptr_t)8;
    CHECK(zwpw_profile_create(d.domain,canonical_path,&options,NULL,&p,&failure)==ZWPW_PROFILE_CAPACITY&&!p);
    options.bytes=65536;
    zwpw_profile_test_fail_after(0);
    CHECK(zwpw_profile_create(d.domain,canonical_path,&options,NULL,&p,&failure)==ZWPW_PROFILE_OOM&&!p);
    zwpw_profile_test_fail_after(-1);CHECK(owner_create(&d,NULL,0,&p));
    CHECK(zwpw_profile_lease_retain(p)==ZWPW_PROFILE_OK&&zwpw_profile_lease_retain(p)==ZWPW_PROFILE_FULL);
    ZwpwProfileStats before,after;CHECK(zwpw_profile_stats(p,&before)==ZWPW_PROFILE_OK);
    zwpw_profile_test_fail_after(0);ZwpwContext *bad=(ZwpwContext *)(uintptr_t)8;
    CHECK(zwpw_profile_context_create(p,&bad)==ZWPW_PROFILE_OOM&&!bad);
    zwpw_profile_test_fail_after(-1);CHECK(zwpw_profile_stats(p,&after)==ZWPW_PROFILE_OK&&before.owned_bytes==after.owned_bytes&&!after.contexts);
    Probe first,second;CHECK(context_open(p,&first)&&context_open(p,&second));
    CHECK(zwpw_profile_context_create(p,&bad)==ZWPW_PROFILE_FULL&&!bad);
    CHECK(zwpw_profile_seal(p)==ZWPW_PROFILE_OK);
    CHECK(zwpw_profile_context_admit(first.context)==ZWPW_PROFILE_CLOSED);
    CHECK(close_context(&first)&&close_context(&second));
    CHECK(zwpw_profile_lease_release(p)==ZWPW_PROFILE_OK&&zwpw_profile_close(p)==ZWPW_PROFILE_OK);
    CHECK(driver_finish(&d)&&all_zero(&d));return 1;
}
static int active_policy(const char *pem,size_t length) {
    Driver d;CHECK(driver_open(&d));ZwpwProfile *p=NULL;CHECK(owner_create(&d,pem,length,&p));
    Probe first,second;CHECK(context_open(p,&first)&&context_open(p,&second));
    creates=exclusive_seen=0;CHECK(begin(&first)&&begin(&second)&&creates==1&&exclusive_seen==1);
    FakeEnvironment environment;fake_init(&environment,canonical_path);CHECK(complete(&environment));
    CHECK(first.ready==1&&second.ready==1&&!first.revoked&&!second.revoked);
    HANDLE signal=CreateEventW(NULL,TRUE,FALSE,NULL);CHECK(signal);
    Probe *probes[]={&first,&second};
    for (unsigned i=0;i<2;++i) {
        HANDLE process=NULL;CHECK(DuplicateHandle(GetCurrentProcess(),signal,GetCurrentProcess(),&process,0,FALSE,DUPLICATE_SAME_ACCESS));
        CHECK(zwpw_context_publish_process(probes[i]->context,&process)==ZWPW_PROFILE_OK&&!process);
        CHECK(zwpw_context_activate(probes[i]->context)==ZWPW_PROFILE_OK&&probes[i]->released==1);
    }
    WCHAR wide[16385];CHECK(length<16385);
    for (size_t i=0;i<length;++i) wide[i]=(WCHAR)(unsigned char)pem[i];wide[length]=0;
    CHECK(zwpw_context_certificate_matches(first.context,wide));
    zwpw_profile_test_fail_after(0);
    CHECK(!zwpw_context_certificate_matches(first.context,wide));
    zwpw_profile_test_fail_after(-1);
    CHECK(zwpw_profile_close(p)==ZWPW_PROFILE_OK);
    CHECK(zwpw_context_is_active(first.context)&&zwpw_context_certificate_matches(first.context,wide));
    CHECK(first.released==1&&!first.revoked&&!second.revoked);
    CHECK(close_context(&first)&&close_context(&second));
    CHECK(environment.refs==1); /* one test-owned reference */
    CHECK(SetEvent(signal)&&driver_finish(&d)&&all_zero(&d));CloseHandle(signal);return 1;
}
static int pending_close_and_late(void) {
    Driver d;CHECK(driver_open(&d));ZwpwProfile *p=NULL;CHECK(owner_create(&d,NULL,0,&p));
    Probe first;CHECK(context_open(p,&first));
    first.close_context_on_revoke=TRUE;first.close_profile_on_revoke=TRUE;
    CHECK(begin(&first));
    CHECK(zwpw_profile_seal(p)==ZWPW_PROFILE_OK);
    CHECK(!first.context&&!first.profile&&first.revoked==1&&first.released==1&&!first.ready&&first.failure==E_ABORT);
    /* Worker completes before the outstanding fake SDK creation callback is
       delivered. It never needs main to pump that callback after App Stop. */
    CHECK(driver_finish(&d));
    uint32_t profiles=0,contexts=0;size_t bytes=0;
    zwpw_profile_counts(&profiles,&contexts,&bytes);CHECK(profiles==1&&!contexts&&bytes);
    FakeEnvironment environment;fake_init(&environment,canonical_path);CHECK(complete(&environment));
    CHECK(environment.refs==1&&first.revoked==1&&first.released==1&&!first.ready);
    CHECK(all_zero(&d));return 1;
}
static int udf_and_getter_reentry(BOOL close_on_get,BOOL close_on_release) {
    Driver d;CHECK(driver_open(&d));ZwpwProfile *p=NULL;CHECK(owner_create(&d,NULL,0,&p));
    Probe first;CHECK(context_open(p,&first)&&begin(&first));
    FakeEnvironment environment;fake_init(&environment,(close_on_get||close_on_release)?canonical_path:L"D:\\zigguratprofiledouble\\data");
    if (close_on_get) environment.close_on_get=p;
    if (close_on_release) environment.close_on_release=p;
    CHECK(complete(&environment));
    CHECK(!first.ready&&first.revoked==1&&first.released==1&&FAILED(first.failure));
    CHECK(close_context(&first));
    if (!close_on_get&&!close_on_release) CHECK(zwpw_profile_close(p)==ZWPW_PROFILE_OK);
    CHECK(environment.refs==1&&driver_finish(&d)&&all_zero(&d));return 1;
}
int zwpw_test_profile_session(const char *pem,size_t length) {
    CHECK(allocation_and_reservations());
    CHECK(active_policy(pem,length));
    CHECK(pending_close_and_late());
    CHECK(udf_and_getter_reentry(FALSE,FALSE));
    CHECK(udf_and_getter_reentry(TRUE,FALSE));
    CHECK(udf_and_getter_reentry(FALSE,TRUE));
    fprintf(stderr,"Windows Profile session:6 groups shared_environment/exclusive/exact_UDF/active_seal/late/getter_reentry/OOM final_refs=0\n");
    return 1;
}
