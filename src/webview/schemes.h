/* Immutable, independently owned environment options. No object retains a View,
   App or business context. Returned COM strings/arrays use CoTaskMemAlloc. */
#include <stddef.h>
#define SCHEME_LIMIT 4
#define SCHEME_ORIGIN_LIMIT 8
typedef struct SchemeInput { const WCHAR *name; BOOL secure; const WCHAR *const *origins; uint32_t origin_count; } SchemeInput;
typedef struct SchemeRegistration {
    ICoreWebView2CustomSchemeRegistration iface;
    LONG refs;
    WCHAR *name, *origins[SCHEME_ORIGIN_LIMIT];
    UINT32 count;
    BOOL secure;
} SchemeRegistration;
typedef struct SchemeOptions {
    ICoreWebView2EnvironmentOptions iface;
    ICoreWebView2EnvironmentOptions4 extended;
    LONG refs;
    UINT32 count;
    SchemeRegistration *items[SCHEME_LIMIT];
    WCHAR *arguments;
} SchemeOptions;
static BOOL scheme_request_origin_allowed(ICoreWebView2EnvironmentOptions *p,const WCHAR *prefix,int method,const NativeHeader *headers,uint32_t count) {
    if (!p||!prefix||method<0||method>6) return FALSE;
    SchemeOptions *options=(SchemeOptions *)p;
    const WCHAR *separator=wcsstr(prefix,L"://");if (!separator) return FALSE;
    SchemeRegistration *registration=NULL;
    for (uint32_t i=0;i<options->count;i++) {
        SchemeRegistration *item=options->items[i];
        if (wcslen(item->name)==(size_t)(separator-prefix)&&wcsncmp(item->name,prefix,(size_t)(separator-prefix))==0) { registration=item;break; }
    }
    if (!registration) return FALSE;
    const WCHAR *origin=NULL;
    for (uint32_t i=0;i<count;i++) if (_wcsicmp(headers[i].name,L"Origin")==0) {
        if (origin) return FALSE;
        origin=headers[i].value;
    }
    if (!origin) return method==0||method==1;
    for (uint32_t j=0;j<registration->count;j++) if (wcscmp(origin,registration->origins[j])==0) return TRUE;
    return FALSE;
}
static HRESULT scheme_string(const WCHAR *source, WCHAR **out) {
    if (!out) return E_POINTER;
    *out=NULL;
    if (!source) return S_OK;
    size_t bytes=(wcslen(source)+1)*sizeof(WCHAR);
    *out=CoTaskMemAlloc(bytes);
    if (!*out) return E_OUTOFMEMORY;
    memcpy(*out,source,bytes); return S_OK;
}
static BOOL scheme_name(const WCHAR *name) {
    if (!name || !*name || wcsnlen(name,33)>32 || *name<L'a' || *name>L'z') return FALSE;
    for (const WCHAR *p=name;*p;p++) if (!((*p>=L'a'&&*p<=L'z')||(*p>=L'0'&&*p<=L'9')||*p==L'+'||*p==L'-'||*p==L'.')) return FALSE;
    static const WCHAR *reserved[]={L"http",L"https",L"file",L"ftp",L"ftps",L"ws",L"wss",L"about",L"data",L"javascript",L"blob",L"filesystem",L"chrome",L"chrome-extension",L"chrome-search",L"chrome-untrusted",L"devtools",L"edge",L"view-source",L"mailto",L"tel",L"urn"};
    for (unsigned i=0;i<sizeof(reserved)/sizeof(*reserved);i++) if (wcscmp(name,reserved[i])==0) return FALSE;
    return TRUE;
}
static BOOL scheme_host(const WCHAR *host,size_t length) {
    if (!length || length>253) return FALSE;
    size_t label=0;
    for (size_t i=0;i<length;i++) {
        WCHAR c=host[i];
        if (c==L'.') { if (!label || host[i-1]==L'-') return FALSE;label=0;continue; }
        if (!((c>=L'a'&&c<=L'z')||(c>=L'0'&&c<=L'9')||c==L'-') || (!label && c==L'-') || ++label>63) return FALSE;
    }
    return label && host[length-1]!=L'-';
}
/* Match a canonical app-owned tuple. A custom origin has no port isolation;
   raw authority validation rejects userinfo, escapes, ports and opaque aliases. */
static BOOL scheme_uri_matches(const WCHAR *text,const WCHAR *prefix) {
    if (!bounded_uri(text)||!prefix) return FALSE;
    const WCHAR *separator=wcsstr(text,L"://"), *expected=wcsstr(prefix,L"://");
    if (!separator||!expected||separator-text!=expected-prefix || wcsncmp(text,prefix,(size_t)(separator-text))!=0) return FALSE;
    const WCHAR *host=separator+3,*end=host;
    while (*end && *end!=L'/' && *end!=L'?' && *end!=L'#') end++;
    if (!scheme_host(host,(size_t)(end-host))) return FALSE;
    const WCHAR *expected_end=expected+3;
    while (*expected_end && *expected_end!=L'/') expected_end++;
    if (end-host!=expected_end-(expected+3) || wcsncmp(host,expected+3,(size_t)(end-host))!=0) return FALSE;
    for (const WCHAR *p=text;*p;p++) if (*p<=32||*p>=127||*p==L'\\') return FALSE;
    IUri *uri=NULL; BSTR parsed_scheme=NULL,parsed_host=NULL,user=NULL;
    HRESULT hr=CreateUri(text,Uri_CREATE_CANONICALIZE|Uri_CREATE_NO_DECODE_EXTRA_INFO|Uri_CREATE_NO_IE_SETTINGS|Uri_CREATE_NO_PRE_PROCESS_HTML_URI,0,&uri);
    if (SUCCEEDED(hr)) hr=IUri_GetSchemeName(uri,&parsed_scheme);
    if (SUCCEEDED(hr)) hr=IUri_GetHost(uri,&parsed_host);
    if (SUCCEEDED(hr)) hr=IUri_GetUserInfo(uri,&user);
    BOOL valid=SUCCEEDED(hr)&&parsed_scheme&&parsed_host&&(!user||!*user)&&wcslen(parsed_scheme)==(size_t)(separator-text)&&wcsncmp(parsed_scheme,text,(size_t)(separator-text))==0&&wcslen(parsed_host)==(size_t)(end-host)&&wcsncmp(parsed_host,host,(size_t)(end-host))==0;
    SysFreeString(parsed_scheme);SysFreeString(parsed_host);SysFreeString(user);if (uri) IUri_Release(uri);return valid;
}
static ULONG STDMETHODCALLTYPE scheme_add(ICoreWebView2CustomSchemeRegistration *p) { return InterlockedIncrement(&((SchemeRegistration *)p)->refs); }
static ULONG STDMETHODCALLTYPE scheme_release(ICoreWebView2CustomSchemeRegistration *p) {
    SchemeRegistration *item=(SchemeRegistration *)p; LONG refs=InterlockedDecrement(&item->refs);
    if (!refs) { for (UINT32 i=0;i<item->count;i++) free(item->origins[i]);free(item->name);free(item);InterlockedDecrement(&live_handlers); }
    return refs;
}
static HRESULT STDMETHODCALLTYPE scheme_query(ICoreWebView2CustomSchemeRegistration *p,REFIID iid,void **out) {
    if (!out) return E_POINTER;*out=NULL;
    if (!IsEqualIID(iid,&IID_IUnknown)&&!IsEqualIID(iid,&IID_ICoreWebView2CustomSchemeRegistration)) return E_NOINTERFACE;
    *out=p;scheme_add(p);return S_OK;
}
static HRESULT STDMETHODCALLTYPE scheme_get_name(ICoreWebView2CustomSchemeRegistration *p,WCHAR **out) { return scheme_string(((SchemeRegistration *)p)->name,out); }
static HRESULT STDMETHODCALLTYPE scheme_get_secure(ICoreWebView2CustomSchemeRegistration *p,BOOL *out) { if (!out) return E_POINTER;*out=((SchemeRegistration *)p)->secure;return S_OK; }
static HRESULT STDMETHODCALLTYPE scheme_get_authority(ICoreWebView2CustomSchemeRegistration *p,BOOL *out) { (void)p;if (!out) return E_POINTER;*out=TRUE;return S_OK; }
static HRESULT STDMETHODCALLTYPE scheme_put_flag(ICoreWebView2CustomSchemeRegistration *p,BOOL value) { (void)p;(void)value;return E_ACCESSDENIED; }
static HRESULT STDMETHODCALLTYPE scheme_set_origins(ICoreWebView2CustomSchemeRegistration *p,UINT32 count,LPCWSTR *values) { (void)p;(void)count;(void)values;return E_ACCESSDENIED; }
static HRESULT STDMETHODCALLTYPE scheme_get_origins(ICoreWebView2CustomSchemeRegistration *p,UINT32 *count,WCHAR ***out) {
    if (!count||!out) return E_POINTER;*count=0;*out=NULL;
    SchemeRegistration *item=(SchemeRegistration *)p;
    if (!item->count) return S_OK;
    WCHAR **values=CoTaskMemAlloc(item->count*sizeof(*values));if (!values) return E_OUTOFMEMORY;
    memset(values,0,item->count*sizeof(*values));HRESULT hr=S_OK;
    for (UINT32 i=0;i<item->count;i++) if (FAILED(hr=scheme_string(item->origins[i],&values[i]))) {
        for (UINT32 j=0;j<i;j++) CoTaskMemFree(values[j]);CoTaskMemFree(values);return hr;
    }
    *out=values;*count=item->count;return S_OK;
}
static ICoreWebView2CustomSchemeRegistrationVtbl scheme_vtable={scheme_query,scheme_add,scheme_release,scheme_get_name,scheme_get_secure,scheme_put_flag,scheme_get_origins,scheme_set_origins,scheme_get_authority,scheme_put_flag};
static ULONG STDMETHODCALLTYPE scheme_options_add(ICoreWebView2EnvironmentOptions *p) { return InterlockedIncrement(&((SchemeOptions *)p)->refs); }
static ULONG STDMETHODCALLTYPE scheme_options_release(ICoreWebView2EnvironmentOptions *p) {
    SchemeOptions *options=(SchemeOptions *)p;LONG refs=InterlockedDecrement(&options->refs);
    if (!refs) { for (UINT32 i=0;i<options->count;i++) scheme_release(&options->items[i]->iface);free(options->arguments);free(options);InterlockedDecrement(&live_handlers); }
    return refs;
}
static HRESULT STDMETHODCALLTYPE scheme_options_query(ICoreWebView2EnvironmentOptions *p,REFIID iid,void **out) {
    if (!out) return E_POINTER;*out=NULL;
    if (IsEqualIID(iid,&IID_IUnknown)||IsEqualIID(iid,&IID_ICoreWebView2EnvironmentOptions)) *out=p;
    else if (IsEqualIID(iid,&IID_ICoreWebView2EnvironmentOptions4)) *out=&((SchemeOptions *)p)->extended;
    else return E_NOINTERFACE;
    scheme_options_add(p);return S_OK;
}
static HRESULT STDMETHODCALLTYPE scheme_options_string(ICoreWebView2EnvironmentOptions *p,WCHAR **out) { (void)p;return scheme_string(NULL,out); }
static HRESULT STDMETHODCALLTYPE scheme_options_arguments(ICoreWebView2EnvironmentOptions *p,WCHAR **out) { return scheme_string(((SchemeOptions *)p)->arguments,out); }
/* Matches CORE_WEBVIEW_TARGET_PRODUCT_VERSION in the pinned SDK options header.
   The loader requires a valid version when an options object is supplied. */
static HRESULT STDMETHODCALLTYPE scheme_options_version(ICoreWebView2EnvironmentOptions *p,WCHAR **out) { (void)p;return scheme_string(L"154.0.4258.31",out); }
static HRESULT STDMETHODCALLTYPE scheme_options_put_string(ICoreWebView2EnvironmentOptions *p,LPCWSTR value) { (void)p;(void)value;return E_ACCESSDENIED; }
static HRESULT STDMETHODCALLTYPE scheme_options_sso(ICoreWebView2EnvironmentOptions *p,BOOL *out) { (void)p;if (!out) return E_POINTER;*out=FALSE;return S_OK; }
static HRESULT STDMETHODCALLTYPE scheme_options_put_sso(ICoreWebView2EnvironmentOptions *p,BOOL value) { (void)p;(void)value;return E_ACCESSDENIED; }
static ICoreWebView2EnvironmentOptionsVtbl scheme_options_vtable={scheme_options_query,scheme_options_add,scheme_options_release,scheme_options_arguments,scheme_options_put_string,scheme_options_string,scheme_options_put_string,scheme_options_version,scheme_options_put_string,scheme_options_sso,scheme_options_put_sso};
static SchemeOptions *scheme_options_self(ICoreWebView2EnvironmentOptions4 *p) { return (SchemeOptions *)((char *)p - offsetof(SchemeOptions,extended)); }
static HRESULT STDMETHODCALLTYPE scheme_options4_query(ICoreWebView2EnvironmentOptions4 *p,REFIID iid,void **out) { return scheme_options_query(&scheme_options_self(p)->iface,iid,out); }
static ULONG STDMETHODCALLTYPE scheme_options4_add(ICoreWebView2EnvironmentOptions4 *p) { return scheme_options_add(&scheme_options_self(p)->iface); }
static ULONG STDMETHODCALLTYPE scheme_options4_release(ICoreWebView2EnvironmentOptions4 *p) { return scheme_options_release(&scheme_options_self(p)->iface); }
static HRESULT STDMETHODCALLTYPE scheme_options4_get(ICoreWebView2EnvironmentOptions4 *p,UINT32 *count,ICoreWebView2CustomSchemeRegistration ***out) {
    if (!count||!out) return E_POINTER;*count=0;*out=NULL;SchemeOptions *options=scheme_options_self(p);
    if (!options->count) return S_OK;
    ICoreWebView2CustomSchemeRegistration **items=CoTaskMemAlloc(options->count*sizeof(*items));if (!items) return E_OUTOFMEMORY;
    for (UINT32 i=0;i<options->count;i++) { items[i]=&options->items[i]->iface;scheme_add(items[i]); }
    *out=items;*count=options->count;return S_OK;
}
static HRESULT STDMETHODCALLTYPE scheme_options4_set(ICoreWebView2EnvironmentOptions4 *p,UINT32 count,ICoreWebView2CustomSchemeRegistration **items) { (void)p;(void)count;(void)items;return E_ACCESSDENIED; }
static ICoreWebView2EnvironmentOptions4Vtbl scheme_options4_vtable={scheme_options4_query,scheme_options4_add,scheme_options4_release,scheme_options4_get,scheme_options4_set};
/* arguments: the browser's command line switches, which all Views of one
   user data folder must agree on, or NULL. */
static HRESULT scheme_options_new(const SchemeInput *input,uint32_t count,const WCHAR *arguments,ICoreWebView2EnvironmentOptions **out) {
    *out=NULL;
    if (count>SCHEME_LIMIT || (count&&!input) || (arguments&&wcsnlen(arguments,1025)>1024)) return E_INVALIDARG;
    if (!count && !arguments) return S_OK;
    SchemeOptions *options=calloc(1,sizeof(*options));if (!options) return E_OUTOFMEMORY;
    options->iface.lpVtbl=&scheme_options_vtable;options->extended.lpVtbl=&scheme_options4_vtable;options->refs=1;InterlockedIncrement(&live_handlers);
    HRESULT hr=S_OK;
    if (arguments && !(options->arguments=_wcsdup(arguments))) { hr=E_OUTOFMEMORY;goto failed; }
    for (uint32_t i=0;i<count;i++) {
        const SchemeInput *source=&input[i];
        if (!scheme_name(source->name)||source->origin_count>SCHEME_ORIGIN_LIMIT||(source->origin_count&&!source->origins)) { hr=E_INVALIDARG;goto failed; }
        for (uint32_t j=0;j<i;j++) if (wcscmp(source->name,input[j].name)==0) { hr=E_INVALIDARG;goto failed; }
        SchemeRegistration *item=calloc(1,sizeof(*item));if (!item) { hr=E_OUTOFMEMORY;goto failed; }
        item->iface.lpVtbl=&scheme_vtable;item->refs=1;item->secure=source->secure;InterlockedIncrement(&live_handlers);
        options->items[options->count++]=item;
        item->name=_wcsdup(source->name);if (!item->name) { hr=E_OUTOFMEMORY;goto failed; }
        for (uint32_t j=0;j<source->origin_count;j++) {
            const WCHAR *origin=source->origins[j];
            if (!origin||!*origin||wcsnlen(origin,1025)>1024) { hr=E_INVALIDARG;goto failed; }
            for (const WCHAR *p=origin;*p;p++) if (*p<=32||*p>=127||*p==L'*'||*p==L'?'||*p==L'#'||*p==L'\\'||*p==L'%'||*p==L'@') { hr=E_INVALIDARG;goto failed; }
            /* Zig canonicalizes/validates origins before this private ABI. The
               native boundary additionally rejects patterns and owned aliases. */
            const WCHAR *separator=wcsstr(origin,L"://");
            if (!separator||separator==origin||!separator[3]) { hr=E_INVALIDARG;goto failed; }
            for (uint32_t k=0;k<j;k++) if (wcscmp(origin,source->origins[k])==0) { hr=E_INVALIDARG;goto failed; }
            item->origins[item->count]=_wcsdup(origin);if (!item->origins[item->count]) { hr=E_OUTOFMEMORY;goto failed; }item->count++;
        }
    }
    *out=&options->iface;return S_OK;
failed:
    scheme_options_release(&options->iface);return hr;
}
