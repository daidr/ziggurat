#ifndef ZIGGURAT_WEBKIT_LOCAL_IMPL_H
#define ZIGGURAT_WEBKIT_LOCAL_IMPL_H
#include "webkit_local.h"
#include "webkit_request_policy.h"

struct ZwkLocalBudget { gint refs,live,bytes,max_live,max_bytes; };
static gint zwk_local_live_budgets,zwk_local_live_streams,zwk_local_live_bytes;
static gboolean local_reserve(gint *value,gint amount,gint limit) {
    gint previous=g_atomic_int_get(value);
    for (;;) {
        if (previous>limit || amount>limit-previous) return FALSE;
        if (g_atomic_int_compare_and_exchange(value,previous,previous+amount)) return TRUE;
        previous=g_atomic_int_get(value);
    }
}
static void local_budget_ref(ZwkLocalBudget *budget) { g_atomic_int_inc(&budget->refs); }
ZwkLocalBudget *zwk_local_budget_new(uint32_t max_live,uint32_t max_bytes) {
    if (!max_live || max_live>8 || !max_bytes || max_bytes>32*1024*1024) return NULL;
    ZwkLocalBudget *budget=g_try_new0(ZwkLocalBudget,1);
    if (!budget) return NULL;
    budget->refs=1; budget->max_live=(gint)max_live; budget->max_bytes=(gint)max_bytes;
    g_atomic_int_inc(&zwk_local_live_budgets); return budget;
}
void zwk_local_budget_limit(ZwkLocalBudget *budget,uint32_t max_live,uint32_t max_bytes) {
    g_assert(max_live && max_live<=8 && max_bytes && max_bytes<=32*1024*1024);
    g_atomic_int_set(&budget->max_live,(gint)max_live); g_atomic_int_set(&budget->max_bytes,(gint)max_bytes);
}
void zwk_local_budget_release(ZwkLocalBudget *budget) {
    if (!g_atomic_int_dec_and_test(&budget->refs)) return;
    g_assert(!g_atomic_int_get(&budget->live) && !g_atomic_int_get(&budget->bytes));
    g_free(budget); g_atomic_int_add(&zwk_local_live_budgets,-1);
}
void zwk_local_counts(uint32_t *budgets,uint32_t *streams,uint32_t *bytes) {
    *budgets=(uint32_t)g_atomic_int_get(&zwk_local_live_budgets);
    *streams=(uint32_t)g_atomic_int_get(&zwk_local_live_streams);
    *bytes=(uint32_t)g_atomic_int_get(&zwk_local_live_bytes);
}
typedef struct LocalBody { ZwkLocalBudget *budget; gint length; unsigned char bytes[]; } LocalBody;
static void local_body_free(gpointer data) {
    LocalBody *body=data;
    ZwkLocalBudget *budget=body->budget; gint length=body->length;
    g_free(body);
    g_atomic_int_add(&budget->bytes,-length); g_atomic_int_add(&budget->live,-1);
    g_atomic_int_add(&zwk_local_live_bytes,-length); g_atomic_int_add(&zwk_local_live_streams,-1);
    zwk_local_budget_release(budget);
}
static GInputStream *local_stream(ZwkLocalBudget *budget,const void *data,size_t length) {
    if (length>16*1024*1024 || !local_reserve(&zwk_local_live_streams,1,32)) return NULL;
    if (!local_reserve(&budget->live,1,g_atomic_int_get(&budget->max_live))) { g_atomic_int_add(&zwk_local_live_streams,-1); return NULL; }
    if (!local_reserve(&budget->bytes,(gint)length,g_atomic_int_get(&budget->max_bytes))) {
        g_atomic_int_add(&budget->live,-1); g_atomic_int_add(&zwk_local_live_streams,-1); return NULL;
    }
    LocalBody *body=g_try_malloc(sizeof(*body)+length);
    if (!body) {
        g_atomic_int_add(&budget->bytes,-(gint)length); g_atomic_int_add(&budget->live,-1); g_atomic_int_add(&zwk_local_live_streams,-1); return NULL;
    }
    body->budget=budget; body->length=(gint)length; local_budget_ref(budget);
    if (length) memcpy(body->bytes,data,length);
    g_atomic_int_add(&zwk_local_live_bytes,(gint)length);
    GInputStream *stream=g_memory_input_stream_new();
    GBytes *bytes=g_bytes_new_with_free_func(body->bytes,length,local_body_free,body);
    g_memory_input_stream_add_bytes(G_MEMORY_INPUT_STREAM(stream),bytes); g_bytes_unref(bytes);
    return stream;
}
static gboolean local_route(const char *path) {
    size_t length=0; if (!path || path[0]!='/') return FALSE;
    size_t segment=0;
    for (;path[length];++length) {
        unsigned char c=(unsigned char)path[length];
        if (length==4096 || (!g_ascii_isalnum(c) && !strchr("/-_.",c))) return FALSE;
        if (c=='/') {
            if ((segment==1 && path[length-1]=='.') || (segment==2 && path[length-1]=='.' && path[length-2]=='.')) return FALSE;
            segment=0;
        } else ++segment;
    }
    return !((segment==1 && path[length-1]=='.') || (segment==2 && path[length-1]=='.' && path[length-2]=='.'));
}
static size_t local_length(const char *value,size_t limit) {
    size_t length=0; if (!value) return limit;
    while (length<limit && value[length]) ++length;
    return length;
}
/* The route is copied only after the authority is parsed. Encoded separators,
 * credentials and visible ports never become an alternate route/authority. */
static gboolean local_uri(const char *scheme,const char *host,const char *text,char path[4097]) {
    if (!text || local_length(text,16385)>16384) return FALSE;
    for (const char *p=text;*p;++p) if ((unsigned char)*p<=32 || (unsigned char)*p>=127 || *p=='\\') return FALSE;
    const char *authority=strstr(text,"://");
    if (!authority) return FALSE;
    authority+=3;
    size_t authority_length=strcspn(authority,"/?#");
    for (size_t i=0;i<authority_length;++i) if (authority[i]=='@' || authority[i]==':' || authority[i]=='%') return FALSE;
    const char *raw_path=authority+authority_length;
    size_t path_length=strcspn(raw_path,"?#");
    if (!path_length || path_length>4096) return FALSE;
    memcpy(path,raw_path,path_length); path[path_length]=0;
    if (!local_route(path)) return FALSE;
    GUri *uri=g_uri_parse(text,G_URI_FLAGS_ENCODED,NULL);
    if (!uri) return FALSE;
    const char *value=g_uri_get_path(uri),*actual_scheme=g_uri_get_scheme(uri),*actual_host=g_uri_get_host(uri);
    gboolean valid=actual_scheme && actual_host && !g_ascii_strcasecmp(actual_scheme,scheme) && !g_ascii_strcasecmp(actual_host,host) &&
        !g_uri_get_userinfo(uri) && g_uri_get_port(uri)<0 && local_route(value);
    if (valid) g_strlcpy(path,value,4097);
    g_uri_unref(uri); return valid;
}
typedef struct LocalData {
    char *storage,*url;
    const char *scheme,*host,*start_path;
    ZwkLocalResource *resources;
    unsigned count,limit;
    guint flags;
    ZwkLocalBudget *budget;
    GError *denied;
    char csp[2048];
} LocalData;
#define LOCAL_IPC 1u
#define LOCAL_EXTENDED_POLICY 2u
/* The optional typed prefix starts at the allocation root. Empty resource
 * tables say nothing about whether a policy exists. */
static const ZwkLocalPolicy *local_policy(const LocalData *local) {
    return local->flags&LOCAL_EXTENDED_POLICY?(const ZwkLocalPolicy *)local->storage:NULL;
}
static gboolean local_ipc(const LocalData *local) { return !!(local->flags&LOCAL_IPC); }
static gboolean local_headers_default(SoupMessageHeaders *headers) {
    if (!headers) return FALSE;
    SoupMessageHeadersIter iter; const char *name,*value; unsigned count=0; size_t bytes=0;
    soup_message_headers_iter_init(&iter,headers);
    while (soup_message_headers_iter_next(&iter,&name,&value)) {
        if (++count>64 || !zwk_policy_header_name(name) || !zwk_policy_header_value(value) ||
            (bytes+=strlen(name)+strlen(value))>16384 || !zwk_policy_managed_header(name) || !g_ascii_strcasecmp(name,"Origin")) return FALSE;
    }
    return TRUE;
}
static __attribute__((noinline)) gboolean local_headers_extended(const ZwkLocalPolicy *policy,int method,SoupMessageHeaders *headers) {
    SoupMessageHeadersIter iter; const char *name,*value; unsigned count=0; size_t bytes=0; gboolean saw_origin=FALSE;
    soup_message_headers_iter_init(&iter,headers);
    while (soup_message_headers_iter_next(&iter,&name,&value)) {
        if (++count>64 || !zwk_policy_header_name(name) || !zwk_policy_header_value(value) || (bytes+=strlen(name)+strlen(value))>16384) return FALSE;
        if (!g_ascii_strcasecmp(name,"Origin")) {
            if (saw_origin) return FALSE;
            saw_origin=TRUE; gboolean allowed=FALSE;
            for (unsigned i=0;i<policy->origin_count;++i) if (!strcmp(value,policy->origins[i])) { allowed=TRUE; break; }
            if (!allowed) return FALSE;
        }
        if (zwk_policy_managed_header(name)) continue;
        gboolean allowed=FALSE;
        for (unsigned i=0;i<policy->header_count;++i) if (!g_ascii_strcasecmp(name,policy->headers[i].name) &&
            (!policy->headers[i].value || !strcmp(value,policy->headers[i].value))) { allowed=TRUE; break; }
        if (!allowed) return FALSE;
    }
    return method<2 || saw_origin;
}
static gboolean local_request_allowed(const LocalData *local,const char *method,SoupMessageHeaders *headers) {
    int verb=zwk_policy_method(method);
    if (verb<0 || !headers) return FALSE;
    const ZwkLocalPolicy *policy=local_policy(local);
    if (!policy) return verb<2 && local_headers_default(headers);
    return !!(policy->methods&(1u<<(unsigned)verb)) && local_headers_extended(policy,verb,headers);
}
static void local_clear(LocalData *local) {
    char *storage=local->storage;
    local->storage=NULL; local->resources=NULL; local->flags=0;
    g_free(storage);
}
static void local_finish(LocalData *local) {
    local_clear(local); g_clear_error(&local->denied);
    if (local->budget) zwk_local_budget_release(local->budget);
    local->budget=NULL;
}
static char *local_copy(char **cursor,const char *text,size_t length) {
    char *result=*cursor; memcpy(result,text,length); result[length]=0; *cursor+=length+1; return result;
}
static gboolean local_add_size(size_t *value,size_t extra,size_t limit) {
    if (*value>limit || extra>limit-*value) return FALSE;
    *value+=extra; return TRUE;
}
static gboolean local_ipv6(char out[256],const char *input) {
    GInetAddress *address=g_inet_address_new_from_string(input);
    if (!address || g_inet_address_get_family(address)!=G_SOCKET_FAMILY_IPV6) { if (address) g_object_unref(address); return FALSE; }
    const guint8 *bytes=g_inet_address_to_bytes(address); guint16 words[8];
    for (unsigned i=0;i<8;++i) words[i]=(guint16)((unsigned)bytes[2*i]*256u+bytes[2*i+1]);
    unsigned best=8,best_count=0;
    for (unsigned i=0;i<8;) {
        if (words[i]) { ++i; continue; }
        unsigned end=i; while (end<8 && !words[end]) ++end;
        if (end-i>best_count && end-i>=2) { best=i; best_count=end-i; } i=end;
    }
    char *cursor=out;
    for (unsigned i=0;i<8;) {
        if (i==best) { *cursor++=':'; *cursor++=':'; i+=best_count; continue; }
        if (cursor!=out && cursor[-1]!=':') *cursor++=':';
        cursor+=g_snprintf(cursor,6,"%x",(unsigned)words[i++]);
    }
    *cursor=0; g_object_unref(address); return TRUE;
}
static gboolean local_origin(const char *scheme,const char *text) {
    size_t length=local_length(text,1025);
    if (!length || length>1024) return FALSE;
    for (size_t i=0;i<length;++i) if ((unsigned char)text[i]<=32 || (unsigned char)text[i]>=127 || strchr("\\%*?#",text[i])) return FALSE;
    GUri *uri=g_uri_parse(text,G_URI_FLAGS_NONE,NULL);
    if (!uri) return FALSE;
    const char *protocol=g_uri_get_scheme(uri),*host=g_uri_get_host(uri),*path=g_uri_get_path(uri);
    const gboolean http=protocol && !strcmp(protocol,"http"),https=protocol && !strcmp(protocol,"https");
    int port=g_uri_get_port(uri); char canonical_host[256],canonical[1025]; gboolean loopback;
    gboolean valid=protocol && (http || https || !strcmp(protocol,scheme)) && !g_uri_get_userinfo(uri) &&
        !g_uri_get_query(uri) && !g_uri_get_fragment(uri) && (!path || !*path) && port!=0 &&
        ((http || https) || port<0) && zwk_policy_host(host,canonical_host,&loopback);
    if (valid) {
        gboolean ipv6=strchr(canonical_host,':')!=NULL;
        if (ipv6 && !local_ipv6(canonical_host,host)) valid=FALSE;
        if (ipv6 && !http && !https) valid=FALSE;
        if ((http && port==80) || (https && port==443)) port=-1;
        int n=port<0?g_snprintf(canonical,sizeof(canonical),ipv6?"%s://[%s]":"%s://%s",protocol,canonical_host):
            g_snprintf(canonical,sizeof(canonical),ipv6?"%s://[%s]:%d":"%s://%s:%d",protocol,canonical_host,port);
        valid=valid && n>=0 && (size_t)n<sizeof(canonical) && !strcmp(text,canonical);
    }
    g_uri_unref(uri); return valid;
}
/* Configuration-only work. No request callback receives this scratch. */
static gboolean local_policy_size(const char *scheme,const ZwkLocalPolicy *policy,size_t *out) {
    *out=0;
    if (!policy) return TRUE;
    if (!policy->methods || (policy->methods&~127u) || policy->reserved || policy->header_count>16 || policy->origin_count>8 ||
        (policy->header_count && !policy->headers) || (policy->origin_count && !policy->origins)) return FALSE;
    size_t size=sizeof(*policy)+(size_t)policy->header_count*sizeof(ZwkLocalHeaderGrant)+(size_t)policy->origin_count*sizeof(char *),grant_bytes=0;
    for (unsigned i=0;i<policy->header_count;++i) {
        const ZwkLocalHeaderGrant *row=&policy->headers[i];
        if (!zwk_policy_grant_header(row->name) || (row->value && !zwk_policy_header_value(row->value))) return FALSE;
        size_t name=strlen(row->name),value=row->value?strlen(row->value):0;
        if (!local_add_size(&grant_bytes,name+value,8192) || !local_add_size(&size,name+1+(row->value?value+1:0),ZWK_LOCAL_POLICY_BYTES)) return FALSE;
        for (unsigned j=0;j<i;++j) if (!g_ascii_strcasecmp(row->name,policy->headers[j].name)) return FALSE;
    }
    for (unsigned i=0;i<policy->origin_count;++i) {
        size_t length=local_length(policy->origins[i],1025);
        if (length>1024 || !local_add_size(&size,length+1,ZWK_LOCAL_POLICY_BYTES)) return FALSE;
    }
    /* Aggregate preflight precedes URI parsing and the owning allocation. */
    for (unsigned i=0;i<policy->origin_count;++i) {
        if (!local_origin(scheme,policy->origins[i])) return FALSE;
        for (unsigned j=0;j<i;++j) if (!strcmp(policy->origins[i],policy->origins[j])) return FALSE;
    }
    size=(size+_Alignof(ZwkLocalResource)-1)&~((size_t)_Alignof(ZwkLocalResource)-1);
    if (size>ZWK_LOCAL_POLICY_BYTES) return FALSE;
    *out=size; return TRUE;
}
static void local_policy_copy(char *storage,const ZwkLocalPolicy *input) {
    ZwkLocalPolicy *owned=(ZwkLocalPolicy *)storage; *owned=*input;
    ZwkLocalHeaderGrant *headers=(ZwkLocalHeaderGrant *)(owned+1);
    const char **origins=(const char **)(headers+input->header_count);
    owned->headers=input->header_count?headers:NULL; owned->origins=input->origin_count?origins:NULL;
    char *cursor=(char *)(origins+input->origin_count);
    for (unsigned i=0;i<input->header_count;++i) {
        headers[i].name=local_copy(&cursor,input->headers[i].name,strlen(input->headers[i].name));
        headers[i].value=input->headers[i].value?local_copy(&cursor,input->headers[i].value,strlen(input->headers[i].value)):NULL;
    }
    for (unsigned i=0;i<input->origin_count;++i) origins[i]=local_copy(&cursor,input->origins[i],strlen(input->origins[i]));
}
static gboolean local_prepare(LocalData *local,const ZwkLocalOptions *options) {
    if (!options || !options->budget || options->count>4096 || (options->count && !options->resources) || !options->max_response_bytes || options->max_response_bytes>16*1024*1024) return FALSE;
    size_t scheme_length=local_length(options->scheme,33),host_length=local_length(options->host,254),path_length=local_length(options->start_path,4097);
    if (!scheme_length || scheme_length>32 || !host_length || host_length>253 || !local_route(options->start_path) || path_length>4096) return FALSE;
    if (!g_ascii_isalpha(options->scheme[0])) return FALSE;
    for (size_t i=0;i<scheme_length;++i) if ((!g_ascii_isalnum(options->scheme[i]) && !strchr("+-.",options->scheme[i])) || g_ascii_isupper(options->scheme[i])) return FALSE;
    if (!strcmp(options->scheme,"http") || !strcmp(options->scheme,"https") || !strcmp(options->scheme,"file") || !strcmp(options->scheme,"ws") || !strcmp(options->scheme,"wss") || !strcmp(options->scheme,"data") || !strcmp(options->scheme,"about") || !strcmp(options->scheme,"javascript") || !strcmp(options->scheme,"blob")) return FALSE;
    char host_check[256]; gboolean loopback;
    if (!zwk_policy_host(options->host,host_check,&loopback) || strcmp(host_check,options->host) || strchr(options->host,':')) return FALSE;
    size_t policy_bytes=0;
    if (!local_policy_size(options->scheme,options->policy,&policy_bytes)) return FALSE;
    /* Resource descriptors need their ordinary alignment after the optional
     * prefix; the prefix itself remains rooted at storage. */
    size_t prefix=(policy_bytes+_Alignof(ZwkLocalResource)-1)&~((size_t)_Alignof(ZwkLocalResource)-1);
    size_t length=(size_t)options->count*sizeof(ZwkLocalResource)+scheme_length+host_length+path_length+3+scheme_length+3+host_length+path_length+1;
    if (!local_add_size(&length,prefix,SIZE_MAX)) return FALSE;
    for (unsigned i=0;i<options->count;++i) {
        const ZwkLocalResource *r=&options->resources[i];
        if (!r->path || !r->mime || !r->path_length || r->path_length>4096 || !r->mime_length || r->mime_length>127 || r->length>options->max_response_bytes) return FALSE;
        if (!local_add_size(&length,r->path_length+r->mime_length+2,SIZE_MAX)) return FALSE;
    }
    local->storage=g_try_malloc(length);
    if (!local->storage) return FALSE;
    local->flags=(options->ipc?LOCAL_IPC:0)|(options->policy?LOCAL_EXTENDED_POLICY:0);
    if (options->policy) local_policy_copy(local->storage,options->policy);
    local->resources=(ZwkLocalResource *)(local->storage+prefix); local->count=options->count; local->limit=options->max_response_bytes;
    char *cursor=(char *)(local->resources+options->count);
    local->scheme=local_copy(&cursor,options->scheme,scheme_length); local->host=local_copy(&cursor,options->host,host_length);
    local->start_path=local_copy(&cursor,options->start_path,path_length);
    local->url=cursor;
    int n=g_snprintf(cursor,scheme_length+3+host_length+path_length+1,"%s://%s%s",local->scheme,local->host,local->start_path);
    if (n<0) return FALSE;
    cursor+=(size_t)n+1;
    for (unsigned i=0;i<options->count;++i) {
        local->resources[i]=options->resources[i];
        local->resources[i].path=local_copy(&cursor,options->resources[i].path,options->resources[i].path_length);
        local->resources[i].mime=local_copy(&cursor,options->resources[i].mime,options->resources[i].mime_length);
        const ZwkLocalResource *resource=&local->resources[i];
        if (!local_route(resource->path) || strlen(resource->path)!=resource->path_length || strlen(resource->mime)!=resource->mime_length || !strcmp(resource->path,local->start_path) || (i && strcmp(local->resources[i-1].path,resource->path)>=0)) return FALSE;
        for (size_t j=0;j<resource->mime_length;++j) if ((unsigned char)resource->mime[j]<32 || (unsigned char)resource->mime[j]>126) return FALSE;
    }
    g_assert((size_t)(cursor-local->storage)==length);
    n=g_snprintf(local->csp,sizeof(local->csp),"default-src 'none'; script-src %s://%s 'unsafe-inline' 'unsafe-eval'; style-src %s://%s 'unsafe-inline'; img-src %s://%s data: blob:; connect-src %s://%s; frame-src 'none'; worker-src 'none'; object-src 'none'; base-uri 'none'; form-action 'none'",local->scheme,local->host,local->scheme,local->host,local->scheme,local->host,local->scheme,local->host);
    if (n<0 || (size_t)n>=sizeof(local->csp)) return FALSE;
    local->budget=options->budget; local_budget_ref(local->budget);
    local->denied=g_error_new_literal(g_quark_from_static_string("ziggurat-local-resource"),1,"Local resource denied or full");
    return TRUE;
}
#endif
