/* Bounded origin policy. URI parsing does not perform DNS or network I/O. */
#include <urlmon.h>
#include <oleauto.h>
#include <ctype.h>
#include <wctype.h>
#include "request_policy.h"
#define MAX_REMOTE_ORIGINS 32
#define REMOTE_NAVIGATE 1u
#define REMOTE_REQUESTS 2u
#define REMOTE_IPC 4u
typedef struct RemoteOriginInput { const WCHAR *origin; uint32_t flags,methods; const HeaderGrantInput *headers; uint32_t header_count; } RemoteOriginInput;
typedef struct RemoteCredentialInput { const char *origin; uint32_t origin_len; const unsigned char *bearer; } RemoteCredentialInput;
typedef struct RemoteInput {
    const WCHAR *url;
    const RemoteOriginInput *origins;
    uint32_t count;
    _Bool allow_loopback, allow_script_navigation, allow_redirects;
    const RemoteCredentialInput *credentials;
    uint32_t credential_count;
} RemoteInput;
typedef struct RemoteCredential { uint32_t origin_index; WCHAR authorization[72]; } RemoteCredential;
typedef struct RemoteCredentials { uint32_t count; RemoteCredential entries[8]; } RemoteCredentials;
#ifndef ZWV_CREDENTIAL_ALLOC
#define ZWV_CREDENTIAL_ALLOC calloc
#endif
typedef struct NetOrigin { WCHAR host[254]; DWORD port; BOOL https; uint32_t flags,methods; HeaderRule *headers; uint32_t header_count; } NetOrigin;
typedef struct RemotePolicy {
    NetOrigin origins[MAX_REMOTE_ORIGINS];
    uint32_t count;
    BOOL enabled, allow_loopback, allow_script_navigation, allow_redirects;
    RemoteCredentials *credentials;
} RemotePolicy;
static BOOL origin_equal(const NetOrigin *a, const NetOrigin *b) {
    return a->https==b->https && a->port==b->port && _wcsicmp(a->host,b->host)==0;
}
static void remote_deinit(RemotePolicy *policy) {
    if(policy->credentials){
        RemoteCredentials *credentials=policy->credentials;policy->credentials=NULL;
        SecureZeroMemory(credentials,sizeof(*credentials));
#ifdef ZWV_CREDENTIAL_WIPE_OBSERVER
        ZWV_CREDENTIAL_WIPE_OBSERVER(credentials,sizeof(*credentials));
#endif
        free(credentials);
    }
    for (uint32_t i=0;i<policy->count;i++) {
        NetOrigin *origin=&policy->origins[i];
        for (uint32_t j=0;j<origin->header_count;j++) free(origin->headers[j].value);
        free(origin->headers); origin->headers=NULL;origin->header_count=0;
    }
}
static HRESULT parse_net_origin(const WCHAR *text, BOOL origin_only, BOOL allow_loopback, BOOL allow_synthetic, NetOrigin *out) {
    if (!bounded_uri(text)) return E_INVALIDARG;
    /* Avoid browser/Windows disagreement on backslashes, controls and IDNA.
       International domains use explicit ASCII A-labels; paths use escapes. */
    for (const WCHAR *p=text;*p;p++) if (*p<=32 || *p>=127 || *p==L'\\') return E_INVALIDARG;
    IUri *uri=NULL;
    HRESULT hr=CreateUri(text,Uri_CREATE_CANONICALIZE|Uri_CREATE_NO_DECODE_EXTRA_INFO|Uri_CREATE_NO_IE_SETTINGS|Uri_CREATE_NO_PRE_PROCESS_HTML_URI,0,&uri);
    if (FAILED(hr)) return hr;
    BSTR scheme=NULL,host=NULL,user=NULL,path=NULL,query=NULL,fragment=NULL;
    DWORD port=0,type=0;
    hr=IUri_GetSchemeName(uri,&scheme);
    if (SUCCEEDED(hr)) hr=IUri_GetHost(uri,&host);
    if (SUCCEEDED(hr)) hr=IUri_GetUserInfo(uri,&user);
    if (SUCCEEDED(hr)) hr=IUri_GetPort(uri,&port);
    if (SUCCEEDED(hr)) hr=IUri_GetHostType(uri,&type);
    if (FAILED(hr) || !scheme || !host || (user && *user) || !*host || wcslen(host)>253 || port==0 || port>65535) { hr=E_INVALIDARG; goto done; }
    BOOL https=_wcsicmp(scheme,L"https")==0;
    if (!https && _wcsicmp(scheme,L"http")!=0) { hr=E_INVALIDARG; goto done; }
    /* No username/password delimiter, including empty userinfo. */
    const WCHAR *authority=wcsstr(text,L"://");
    if (!authority) { hr=E_INVALIDARG; goto done; }
    authority+=3;
    for (const WCHAR *p=authority;*p && *p!=L'/' && *p!=L'?' && *p!=L'#';p++) if (*p==L'@' || *p==L'%') { hr=E_INVALIDARG; goto done; }
    for (const WCHAR *p=host;*p;p++) if (!((*p>=L'a'&&*p<=L'z')||(*p>=L'A'&&*p<=L'Z')||(*p>=L'0'&&*p<=L'9')||*p==L'.'||*p==L'-'||*p==L':'||*p==L'['||*p==L']')) { hr=E_INVALIDARG; goto done; }
    if (host[wcslen(host)-1]==L'.' || (type!=Uri_HOST_DNS && type!=Uri_HOST_IPV4 && type!=Uri_HOST_IPV6)) { hr=E_INVALIDARG; goto done; }
    /* All-numeric and abbreviated IPv4 forms differ between URL parsers.
       Only canonical dotted quads are accepted for IPv4 origins. */
    if (type==Uri_HOST_IPV4) {
        const WCHAR *raw_end=authority;
        while (*raw_end && *raw_end!=L':' && *raw_end!=L'/' && *raw_end!=L'?' && *raw_end!=L'#') raw_end++;
        if ((size_t)(raw_end-authority)!=wcslen(host) || wcsncmp(authority,host,(size_t)(raw_end-authority))!=0) { hr=E_INVALIDARG; goto done; }
        unsigned parts[4]={0}; const WCHAR *p=host;
        for (unsigned i=0;i<4;i++) {
            const WCHAR *start=p;
            while (*p>=L'0'&&*p<=L'9') { parts[i]=parts[i]*10+(*p-L'0'); if (parts[i]>255) break; p++; }
            if (p==start || parts[i]>255 || (p-start>1 && *start==L'0') || (i<3?*p!=L'.':*p!=0)) { hr=E_INVALIDARG; goto done; }
            if (i<3) p++;
        }
    }
    BOOL loopback=_wcsicmp(host,L"localhost")==0 || _wcsicmp(host,L"::1")==0 || _wcsicmp(host,L"[::1]")==0 || (type==Uri_HOST_IPV4 && wcsncmp(host,L"127.",4)==0);
    /* IUri canonicalizes mapped/compatible IPv6 addresses to these dotted
       forms. They still route to IPv4 loopback and need the same opt-in. */
    if (type==Uri_HOST_IPV6 && (_wcsnicmp(host,L"::ffff:127.",11)==0 || _wcsnicmp(host,L"::127.",6)==0)) loopback=TRUE;
    size_t host_len=wcslen(host);
    if (!allow_synthetic && (_wcsicmp(host,L"ziggurat.invalid")==0 || (host_len>17 && _wcsicmp(host+host_len-17,L".ziggurat.invalid")==0))) { hr=E_ACCESSDENIED; goto done; }
    if (host_len>10 && _wcsicmp(host+host_len-10,L".localhost")==0) loopback=TRUE;
    if ((!https && !loopback) || (loopback && !allow_loopback)) { hr=E_ACCESSDENIED; goto done; }
    if (origin_only) {
        hr=IUri_GetPath(uri,&path);
        if (SUCCEEDED(hr)) hr=IUri_GetQuery(uri,&query);
        if (SUCCEEDED(hr)) hr=IUri_GetFragment(uri,&fragment);
        if (FAILED(hr) || (path && *path && wcscmp(path,L"/")!=0) || (query && *query) || (fragment && *fragment)) { hr=E_INVALIDARG; goto done; }
    }
    memset(out,0,sizeof(*out)); wcscpy(out->host,host); out->port=port; out->https=https; hr=S_OK;
done:
    SysFreeString(scheme); SysFreeString(host); SysFreeString(user); SysFreeString(path); SysFreeString(query); SysFreeString(fragment);
    IUri_Release(uri); return hr;
}
static HRESULT net_origin(const WCHAR *text,BOOL origin_only,BOOL allow_loopback,NetOrigin *out) { return parse_net_origin(text,origin_only,allow_loopback,FALSE,out); }
static uint32_t remote_grants(const RemotePolicy *policy,const WCHAR *uri) {
    if (!policy->enabled) return 0;
    NetOrigin origin;
    if (FAILED(net_origin(uri,FALSE,policy->allow_loopback,&origin))) return 0;
    for (uint32_t i=0;i<policy->count;i++) if (origin_equal(&origin,&policy->origins[i])) return policy->origins[i].flags;
    return 0;
}
static BOOL remote_request_check(const RemotePolicy *policy,const WCHAR *uri,int method,const NativeHeader *headers,uint32_t count,const WCHAR **authorization) {
    if(authorization)*authorization=NULL;
    if (!policy->enabled||method<0||method>6||count>REQUEST_HEADER_LIMIT||(count&&!headers)) return FALSE;
    NetOrigin target; if (FAILED(net_origin(uri,FALSE,policy->allow_loopback,&target))) return FALSE;
    const NetOrigin *origin=NULL;
    for (uint32_t i=0;i<policy->count;i++) if (origin_equal(&target,&policy->origins[i])) { origin=&policy->origins[i];break; }
    if (!origin||!(origin->flags&REMOTE_REQUESTS)||!(origin->methods&(1u<<method))) return FALSE;
    const WCHAR *credential=NULL;
    if(policy->credentials)for(uint32_t i=0;i<policy->credentials->count;++i){
        const RemoteCredential *entry=&policy->credentials->entries[i];
        if(origin==&policy->origins[entry->origin_index]){credential=entry->authorization;break;}
    }
    size_t budget=credential?84u:0u;
    if(credential&&count==REQUEST_HEADER_LIMIT)return FALSE;
    for (uint32_t i=0;i<count;i++) {
        if(credential&&(budget+=wcslen(headers[i].name)+wcslen(headers[i].value))>REQUEST_HEADER_BUDGET)return FALSE;
        if (header_managed(headers[i].name)) continue;
        BOOL allowed=FALSE;
        for (uint32_t j=0;j<origin->header_count;j++) {
            const HeaderRule *rule=&origin->headers[j];
            if (!header_name_equal(headers[i].name,rule->name)) continue;
            allowed=TRUE;
            if (rule->exact) {
                size_t length=wcslen(headers[i].value);
                if (length!=rule->value_len) allowed=FALSE;
                else for (size_t k=0;k<length;k++) if (headers[i].value[k]!=(unsigned char)rule->value[k]) { allowed=FALSE;break; }
            }
            break;
        }
        if (!allowed) return FALSE;
    }
    if(authorization)*authorization=credential;
    return TRUE;
}
static BOOL remote_request_allowed(const RemotePolicy *policy,const WCHAR *uri,int method,const NativeHeader *headers,uint32_t count) {
    return remote_request_check(policy,uri,method,headers,count,NULL);
}
static __declspec(noinline) HRESULT remote_credentials_init(RemotePolicy *out,const RemoteInput *input){
    if(input->credential_count>8||!input->credentials)return E_INVALIDARG;
    for(uint32_t i=0;i<out->count;++i)for(uint32_t j=0;j<out->origins[i].header_count;++j)
        if(header_ascii_equal(out->origins[i].headers[j].name,strlen(out->origins[i].headers[j].name),"Authorization",13))return E_INVALIDARG;
    RemoteCredentials *owned=ZWV_CREDENTIAL_ALLOC(1,sizeof(*owned));
    if(!owned)return E_OUTOFMEMORY;
    out->credentials=owned;
    for(uint32_t i=0;i<input->credential_count;++i){
        const RemoteCredentialInput *source=&input->credentials[i];
        if(!source->origin||!source->origin_len||source->origin_len>1024||!source->bearer)return E_INVALIDARG;
        WCHAR text[1025];
        for(uint32_t j=0;j<source->origin_len;++j){unsigned char byte=(unsigned char)source->origin[j];if(byte<=32||byte>=127||byte=='\\')return E_INVALIDARG;text[j]=(WCHAR)byte;}
        text[source->origin_len]=0;
        NetOrigin parsed;HRESULT hr=net_origin(text,TRUE,out->allow_loopback,&parsed);
        if(FAILED(hr)||!parsed.https)return E_INVALIDARG;
        uint32_t index=out->count;
        for(uint32_t j=0;j<out->count;++j)if(origin_equal(&parsed,&out->origins[j])){index=j;break;}
        if(index==out->count||!(out->origins[index].flags&REMOTE_REQUESTS))return E_ACCESSDENIED;
        for(uint32_t j=0;j<owned->count;++j)if(owned->entries[j].origin_index==index)return E_INVALIDARG;
        RemoteCredential *entry=&owned->entries[owned->count++];entry->origin_index=index;
        static const WCHAR hex[]=L"0123456789abcdef";
        memcpy(entry->authorization,L"Bearer ",7*sizeof(WCHAR));
        for(uint32_t j=0;j<32;++j){entry->authorization[7+j*2]=hex[source->bearer[j]>>4];entry->authorization[8+j*2]=hex[source->bearer[j]&15];}
        entry->authorization[71]=0;
    }
    return S_OK;
}
static BOOL remote_url_equal(const WCHAR *a,const WCHAR *b,BOOL ignore_fragment) {
    if (!bounded_uri(a) || !bounded_uri(b)) return FALSE;
    IUri *left=NULL,*right=NULL; BOOL equal=FALSE;
    DWORD flags=Uri_CREATE_CANONICALIZE|Uri_CREATE_NO_DECODE_EXTRA_INFO|Uri_CREATE_NO_IE_SETTINGS|Uri_CREATE_NO_PRE_PROCESS_HTML_URI;
    if (ignore_fragment) flags|=Uri_CREATE_NOFRAG;
    HRESULT hr=CreateUri(a,flags,0,&left);
    if (SUCCEEDED(hr)) hr=CreateUri(b,flags,0,&right);
    if (SUCCEEDED(hr)) IUri_IsEqual(left,right,&equal);
    if (left) IUri_Release(left);
    if (right) IUri_Release(right);
    return equal;
}
static HRESULT remote_init(RemotePolicy *out,const RemoteInput *input) {
    memset(out,0,sizeof(*out));
    if (!input) return S_OK;
    if (!input->count || input->count>MAX_REMOTE_ORIGINS || !input->origins) return E_INVALIDARG;
    out->enabled=TRUE; out->count=input->count; out->allow_loopback=input->allow_loopback;
    out->allow_script_navigation=input->allow_script_navigation; out->allow_redirects=input->allow_redirects;
    for (uint32_t i=0;i<input->count;i++) {
        uint32_t flags=input->origins[i].flags;
        if (!flags || (flags&~7u) || ((flags&(REMOTE_NAVIGATE|REMOTE_IPC)) && (flags&(REMOTE_NAVIGATE|REMOTE_REQUESTS))!=(REMOTE_NAVIGATE|REMOTE_REQUESTS))) { remote_deinit(out);return E_INVALIDARG; }
        HRESULT hr=net_origin(input->origins[i].origin,TRUE,input->allow_loopback,&out->origins[i]);
        if (FAILED(hr)) { remote_deinit(out);return hr; }
        out->origins[i].flags=flags;
        const RemoteOriginInput *source=&input->origins[i];NetOrigin *origin=&out->origins[i];
        if ((source->methods&~127u)||((flags&REMOTE_REQUESTS)&&!source->methods)||source->header_count>16||(source->header_count&&!source->headers)) { remote_deinit(out);return E_INVALIDARG; }
        origin->methods=source->methods;
        if (source->header_count) {
            origin->headers=calloc(source->header_count,sizeof(HeaderRule));
            if (!origin->headers) { remote_deinit(out);return E_OUTOFMEMORY; }
        }
        size_t budget=0;
        for (uint32_t k=0;k<source->header_count;k++) {
            const HeaderGrantInput *grant=&source->headers[k];HeaderRule *rule=&origin->headers[k];
            if (!header_grant_name(grant->name,grant->name_len)||grant->value_len>2048||(grant->value_len&&!grant->value)||(budget+=grant->name_len+grant->value_len)>8192) { remote_deinit(out);return E_INVALIDARG; }
            for (uint32_t n=0;n<grant->value_len;n++) if ((unsigned char)grant->value[n]<32||(unsigned char)grant->value[n]>126) { remote_deinit(out);return E_INVALIDARG; }
            memcpy(rule->name,grant->name,grant->name_len);rule->name[grant->name_len]=0;rule->exact=grant->exact;rule->value_len=grant->value_len;
            if (grant->exact) { rule->value=malloc(grant->value_len+1);if (!rule->value) { remote_deinit(out);return E_OUTOFMEMORY; } if (grant->value_len) memcpy(rule->value,grant->value,grant->value_len);rule->value[grant->value_len]=0; }
            origin->header_count++;
            for (uint32_t earlier=0;earlier<k;earlier++) if (header_ascii_equal(rule->name,strlen(rule->name),origin->headers[earlier].name,strlen(origin->headers[earlier].name))) { remote_deinit(out);return E_INVALIDARG; }
        }
        for (uint32_t j=0;j<i;j++) if (origin_equal(&out->origins[i],&out->origins[j])) { remote_deinit(out);return E_INVALIDARG; }
    }
    if (!(remote_grants(out,input->url)&REMOTE_NAVIGATE)) { remote_deinit(out);return E_ACCESSDENIED; }
    if(input->credential_count){HRESULT hr=remote_credentials_init(out,input);if(FAILED(hr)){remote_deinit(out);return hr;}}
    return S_OK;
}
HRESULT zwv_remote_validate(const RemoteInput *input) { RemotePolicy policy; HRESULT hr=remote_init(&policy,input);remote_deinit(&policy);return hr; }
