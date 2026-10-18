#ifndef ZIGGURAT_REQUEST_POLICY_H
#define ZIGGURAT_REQUEST_POLICY_H
#include <string.h>
#define REQUEST_HEADER_LIMIT 64u
#define REQUEST_HEADER_BUDGET 16384u
typedef struct HeaderGrantInput { const char *name; uint32_t name_len; const char *value; uint32_t value_len; _Bool exact; } HeaderGrantInput;
typedef struct HeaderRule { char name[65]; char *value; uint32_t value_len; BOOL exact; } HeaderRule;
typedef struct NativeHeader { WCHAR *name,*value; } NativeHeader;
static BOOL header_token_char(unsigned c) {
    return (c>='a'&&c<='z')||(c>='A'&&c<='Z')||(c>='0'&&c<='9')||(c&&strchr("!#$%&'*+-.^_`|~",(int)c)!=NULL);
}
static unsigned header_lower(unsigned c) { return c>='A'&&c<='Z'?c+('a'-'A'):c; }
static BOOL header_ascii_equal(const char *a,size_t a_length,const char *b,size_t b_length) {
    if (a_length!=b_length) return FALSE;
    for (size_t i=0;i<a_length;i++) if (header_lower((unsigned char)a[i])!=header_lower((unsigned char)b[i])) return FALSE;
    return TRUE;
}
static BOOL header_name_equal(const WCHAR *wide,const char *ascii) {
    for (;*wide&&*ascii;wide++,ascii++) if (header_lower(*wide)!=header_lower((unsigned char)*ascii)) return FALSE;
    return !*wide&&!*ascii;
}
static BOOL header_managed(const WCHAR *name) {
    if (wcslen(name)>=4&&header_lower(name[0])=='s'&&header_lower(name[1])=='e'&&header_lower(name[2])=='c'&&name[3]=='-') return TRUE;
    static const char *names[]={"accept","accept-encoding","accept-language","user-agent","origin","referer","cookie","host","connection","content-length","cache-control","pragma","dnt","priority","upgrade-insecure-requests","if-match","if-none-match","if-modified-since","if-unmodified-since","if-range","access-control-request-method","access-control-request-headers"};
    for (size_t i=0;i<sizeof(names)/sizeof(names[0]);i++) if (header_name_equal(name,names[i])) return TRUE;
    return FALSE;
}
static BOOL header_grant_name(const char *name,uint32_t length) {
    WCHAR wide[65];
    if (!name||!length||length>64) return FALSE;
    for (uint32_t i=0;i<length;i++) {
        unsigned c=(unsigned char)name[i];
        if (c>126||!header_token_char(c)) return FALSE;
        wide[i]=(WCHAR)c;
    }
    wide[length]=0;
    return !header_managed(wide)&&!(length>=6&&header_ascii_equal(name,6,"proxy-",6))&&!header_name_equal(wide,"transfer-encoding")&&!header_name_equal(wide,"upgrade")&&!header_name_equal(wide,"te")&&!header_name_equal(wide,"trailer")&&!header_name_equal(wide,"keep-alive");
}
static BOOL valid_header(const WCHAR *name,const WCHAR *value,size_t *bytes) {
    if (!name||!value) return FALSE;
    size_t n=wcsnlen(name,65),v=wcsnlen(value,2049);
    if (!n||n>64||v>2048) return FALSE;
    for (size_t i=0;i<n;i++) if (name[i]>126||!header_token_char(name[i])) return FALSE;
    for (size_t i=0;i<v;i++) if (value[i]<32||value[i]>126) return FALSE;
    *bytes=n+v; return TRUE;
}
static void headers_free(NativeHeader *headers,uint32_t count) {
    for (uint32_t i=0;i<count;i++) { CoTaskMemFree(headers[i].name);CoTaskMemFree(headers[i].value); }
}
static HRESULT headers_collect(ICoreWebView2WebResourceRequest *request,NativeHeader *out,uint32_t *count) {
    *count=0;
    ICoreWebView2HttpRequestHeaders *headers=NULL; ICoreWebView2HttpHeadersCollectionIterator *iterator=NULL;
    HRESULT hr=ICoreWebView2WebResourceRequest_get_Headers(request,&headers);
    if (SUCCEEDED(hr)) hr=headers?ICoreWebView2HttpRequestHeaders_GetIterator(headers,&iterator):E_POINTER;
    if (SUCCEEDED(hr)&&!iterator) hr=E_POINTER;
    size_t budget=0; BOOL more=FALSE;
    if (SUCCEEDED(hr)) hr=ICoreWebView2HttpHeadersCollectionIterator_get_HasCurrentHeader(iterator,&more);
    while (SUCCEEDED(hr)&&more) {
        if (*count==REQUEST_HEADER_LIMIT) { hr=E_ACCESSDENIED;break; }
        NativeHeader *entry=&out[*count]; memset(entry,0,sizeof(*entry)); (*count)++;
        hr=ICoreWebView2HttpHeadersCollectionIterator_GetCurrentHeader(iterator,&entry->name,&entry->value);
        size_t bytes=0;
        if (SUCCEEDED(hr)&&(!valid_header(entry->name,entry->value,&bytes)||(budget+=bytes)>REQUEST_HEADER_BUDGET)) hr=E_ACCESSDENIED;
        if (SUCCEEDED(hr)) hr=ICoreWebView2HttpHeadersCollectionIterator_MoveNext(iterator,&more);
    }
    if (iterator) ICoreWebView2HttpHeadersCollectionIterator_Release(iterator);
    if (headers) ICoreWebView2HttpRequestHeaders_Release(headers);
    if (FAILED(hr)) { headers_free(out,*count);*count=0; }
    return hr;
}
static int request_method(const WCHAR *method) {
    static const WCHAR *names[]={L"GET",L"HEAD",L"POST",L"PUT",L"PATCH",L"DELETE",L"OPTIONS"};
    if (!method||wcsnlen(method,8)>7) return -1;
    for (int i=0;i<7;i++) if (wcscmp(method,names[i])==0) return i;
    return -1;
}
#endif
