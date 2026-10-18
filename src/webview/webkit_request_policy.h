#ifndef ZIGGURAT_WEBKIT_REQUEST_POLICY_H
#define ZIGGURAT_WEBKIT_REQUEST_POLICY_H
#include <gio/gio.h>
#include <libsoup/soup.h>
#include <string.h>

#define ZWK_POLICY_ABI 2u
#define ZWK_POLICY_VARIANT "(utba(sua(sbs)ay))"
#define ZWK_POLICY_ORIGINS 32u
#define ZWK_POLICY_HEADERS 16u
#define ZWK_POLICY_URI_BYTES 16384u
#define ZWK_POLICY_BYTES (1024u*1024u)

typedef struct ZwkRequestHeader { const char *name,*value; gboolean exact; } ZwkRequestHeader;
typedef struct ZwkRequestOrigin {
    char host[256]; guint16 port; gboolean https;
    guint methods,header_count;
    ZwkRequestHeader headers[ZWK_POLICY_HEADERS];
    const char *authorization;
} ZwkRequestOrigin;
typedef struct ZwkRequestPolicy {
    unsigned refs,count;
    guint64 id;
    gboolean loopback,decorates;
    GVariant *storage;
    char (*authorizations)[72];
    ZwkRequestOrigin origins[ZWK_POLICY_ORIGINS];
} ZwkRequestPolicy;
typedef enum ZwkRequestDecision {
    ZWK_REQUEST_ALLOW, ZWK_REQUEST_INVALID, ZWK_REQUEST_ORIGIN,
    ZWK_REQUEST_METHOD, ZWK_REQUEST_HEADERS
} ZwkRequestDecision;

/* Only project-owned storage is wiped here. The engine/IPC/network stack may
   retain its own private copies; this is not a process-wide secure-heap claim. */
static void zwk_policy_wipe(void *value,size_t length) {
    volatile unsigned char *bytes=value;
    while (length--) *bytes++=0;
}
typedef struct ZwkPolicyBytes { size_t length; unsigned char data[]; } ZwkPolicyBytes;
static void zwk_policy_bytes_free(gpointer value) {
    ZwkPolicyBytes *bytes=value;
    zwk_policy_wipe(bytes->data,bytes->length);
#ifdef ZWK_POLICY_WIPE_OBSERVER
    ZWK_POLICY_WIPE_OBSERVER(bytes->data,bytes->length);
#endif
    g_free(bytes);
}
static inline GVariant *zwk_policy_secret(const unsigned char *secret) {
    if(!secret)return g_variant_new_fixed_array(G_VARIANT_TYPE_BYTE,NULL,0,1);
    ZwkPolicyBytes *bytes=g_try_malloc(sizeof(*bytes)+32);
    if(!bytes)return NULL;
    bytes->length=32;memcpy(bytes->data,secret,32);
    return g_variant_new_from_data(G_VARIANT_TYPE("ay"),bytes->data,32,TRUE,zwk_policy_bytes_free,bytes);
}

static size_t zwk_policy_length(const char *value,size_t limit) {
    size_t length=0; if (!value) return limit;
    while (length<limit && value[length]) ++length;
    return length;
}
static gboolean zwk_policy_token(unsigned c) {
    return g_ascii_isalnum(c) || (c && strchr("!#$%&'*+-.^_`|~",(int)c));
}
static gboolean zwk_policy_header_name(const char *value) {
    size_t n=zwk_policy_length(value,65);
    if (!n || n>64) return FALSE;
    for (size_t i=0;i<n;++i) if ((unsigned char)value[i]>126 || !zwk_policy_token((unsigned char)value[i])) return FALSE;
    return TRUE;
}
static gboolean zwk_policy_header_value(const char *value) {
    size_t n=zwk_policy_length(value,2049);
    if (n>2048) return FALSE;
    for (size_t i=0;i<n;++i) if ((unsigned char)value[i]<32 || (unsigned char)value[i]>126) return FALSE;
    return TRUE;
}
static gboolean zwk_policy_managed_header(const char *name) {
    if (!g_ascii_strncasecmp(name,"sec-",4)) return TRUE;
    static const char *const names[]={"accept","accept-encoding","accept-language","user-agent","origin","referer","cookie","host","connection","content-length","cache-control","pragma","dnt","priority","upgrade-insecure-requests","if-match","if-none-match","if-modified-since","if-unmodified-since","if-range","access-control-request-method","access-control-request-headers"};
    for (size_t i=0;i<G_N_ELEMENTS(names);++i) if (!g_ascii_strcasecmp(name,names[i])) return TRUE;
    return FALSE;
}
static gboolean zwk_policy_grant_header(const char *name) {
    if (!zwk_policy_header_name(name) || zwk_policy_managed_header(name) || !g_ascii_strncasecmp(name,"proxy-",6)) return FALSE;
    static const char *const denied[]={"transfer-encoding","upgrade","te","trailer","keep-alive"};
    for (size_t i=0;i<G_N_ELEMENTS(denied);++i) if (!g_ascii_strcasecmp(name,denied[i])) return FALSE;
    return TRUE;
}
static gboolean zwk_policy_ipv4(const char *host,char output[256]) {
    const char *p=host;
    for (unsigned part=0;part<4;++part) {
        if (!g_ascii_isdigit(*p)) return FALSE;
        const char *start=p; unsigned number=0;
        while (g_ascii_isdigit(*p)) { number=number*10+(unsigned)(*p++-'0'); if (number>255) return FALSE; }
        if ((p-start>1 && *start=='0') || (part<3?*p++!='.':*p!=0)) return FALSE;
    }
    g_strlcpy(output,host,256); return TRUE;
}
static gboolean zwk_policy_host(const char *host,char output[256],gboolean *loopback) {
    size_t length=zwk_policy_length(host,256);
    if (!length || length>253) return FALSE;
    *loopback=FALSE;
    if (strchr(host,':')) {
        GInetAddress *address=g_inet_address_new_from_string(host);
        if (!address || g_inet_address_get_family(address)!=G_SOCKET_FAMILY_IPV6) { g_clear_object(&address); return FALSE; }
        char *canonical=g_inet_address_to_string(address);
        g_strlcpy(output,canonical,256); g_free(canonical);
        const guint8 *bytes=g_inet_address_to_bytes(address);
        gboolean zero10=TRUE,zero12=TRUE;
        for(unsigned i=0;i<12;i++){if(bytes[i]){zero12=FALSE;if(i<10)zero10=FALSE;}}
        const gboolean mapped=zero10&&bytes[10]==255&&bytes[11]==255;
        *loopback=g_inet_address_get_is_loopback(address)||((mapped||zero12)&&bytes[12]==127);
        g_object_unref(address); return TRUE;
    }
    if (zwk_policy_ipv4(host,output)) { *loopback=!strncmp(host,"127.",4); return TRUE; }
    const char *last=strrchr(host,'.'); last=last?last+1:host;
    gboolean numeric=*last!=0;
    for (const char *p=last;*p;++p) if (!g_ascii_isdigit(*p)) numeric=FALSE;
    if (numeric || !g_ascii_strncasecmp(last,"0x",2)) return FALSE;
    size_t label=0;
    for (size_t i=0;i<length;++i) {
        unsigned c=(unsigned char)host[i];
        if (c=='.') { if (!label || host[i-1]=='-') return FALSE; label=0; }
        else { if ((!g_ascii_isalnum(c) && c!='-') || (!label && c=='-') || ++label>63) return FALSE; }
        output[i]=(char)g_ascii_tolower((gchar)c);
    }
    if (!label || host[length-1]=='-') return FALSE;
    output[length]=0;
    *loopback=!strcmp(output,"localhost") || (length>10 && !strcmp(output+length-10,".localhost"));
    return TRUE;
}
static gboolean zwk_policy_parse_uri(const char *text,gboolean origin,gboolean allow_loopback,ZwkRequestOrigin *out) {
    size_t length=zwk_policy_length(text,ZWK_POLICY_URI_BYTES+1);
    if (!length || length>ZWK_POLICY_URI_BYTES || (origin && length>1024)) return FALSE;
    for (size_t i=0;i<length;++i) if ((unsigned char)text[i]<=32 || (unsigned char)text[i]>=127 || text[i]=='\\') return FALSE;
    const char *authority=strstr(text,"://");
    if (!authority) return FALSE;
    authority+=3;
    size_t authority_length=strcspn(authority,"/?#");
    for (size_t i=0;i<authority_length;++i) if (authority[i]=='%' || authority[i]=='@') return FALSE;
    GUri *uri=g_uri_parse(text,G_URI_FLAGS_NONE,NULL);
    if (!uri) return FALSE;
    const char *scheme=g_uri_get_scheme(uri),*host=g_uri_get_host(uri),*path=g_uri_get_path(uri);
    gboolean https=scheme && !g_ascii_strcasecmp(scheme,"https");
    gboolean http=scheme && !g_ascii_strcasecmp(scheme,"http"),local=FALSE;
    int port=g_uri_get_port(uri);
    gboolean valid=(http || https) && !g_uri_get_userinfo(uri) && port!=0 &&
        (!origin || ((!path || !*path || !strcmp(path,"/")) && !g_uri_get_query(uri) && !g_uri_get_fragment(uri))) &&
        zwk_policy_host(host,out->host,&local) && (!local || allow_loopback) && (!http || (local && allow_loopback));
    if(valid){
        size_t n=strlen(out->host);
        if(!strcmp(out->host,"ziggurat.invalid")||(n>17&&!strcmp(out->host+n-17,".ziggurat.invalid")))valid=FALSE;
    }
    if (valid) { out->https=https; out->port=(guint16)(port<0?(https?443:80):port); }
    g_uri_unref(uri); return valid;
}
static void zwk_request_policy_unref(gpointer value) {
    ZwkRequestPolicy *policy=value;
    if (!policy || --policy->refs) return;
    g_variant_unref(policy->storage);
    if(policy->authorizations){
        zwk_policy_wipe(policy->authorizations,8*72);
#ifdef ZWK_POLICY_WIPE_OBSERVER
        ZWK_POLICY_WIPE_OBSERVER(policy->authorizations,8*72);
#endif
        g_free(policy->authorizations);
    }
    g_free(policy);
}
static inline ZwkRequestPolicy *zwk_request_policy_ref(ZwkRequestPolicy *policy) { if (policy) ++policy->refs; return policy; }
static inline ZwkRequestPolicy *zwk_request_policy_new(GVariant *value) {
    if (!value || !g_variant_is_of_type(value,G_VARIANT_TYPE(ZWK_POLICY_VARIANT)) ||
        g_variant_get_size(value)>ZWK_POLICY_BYTES || !g_variant_is_normal_form(value)) return NULL;
    guint abi; guint64 id; gboolean loopback; GVariant *origins;
    g_variant_get(value,"(utb@a(sua(sbs)ay))",&abi,&id,&loopback,&origins);
    gsize count=g_variant_n_children(origins);
    if (abi!=ZWK_POLICY_ABI || !id || count>ZWK_POLICY_ORIGINS) { g_variant_unref(origins); return NULL; }
    ZwkRequestPolicy *policy=g_try_new0(ZwkRequestPolicy,1);
    if (!policy) { g_variant_unref(origins); return NULL; }
    policy->refs=1; policy->id=id; policy->loopback=loopback; policy->count=(unsigned)count;policy->storage=g_variant_ref(value);
    gboolean valid=TRUE;
    unsigned secrets=0;
    for (gsize i=0;i<count && valid;++i) {
        GVariant *item=g_variant_get_child_value(origins,i),*headers,*secret; const char *text; guint methods;
        g_variant_get(item,"(&su@a(sbs)@ay)",&text,&methods,&headers,&secret);
        ZwkRequestOrigin *out=&policy->origins[i];
        valid=zwk_policy_parse_uri(text,TRUE,loopback,out) && methods && !(methods&~127u) && g_variant_n_children(headers)<=ZWK_POLICY_HEADERS;
        gsize secret_length=0;
        const unsigned char *secret_data=g_variant_get_fixed_array(secret,&secret_length,1);
        if(secret_length){
            if(secret_length!=32||!out->https||++secrets>8)valid=FALSE;
            else {
                static const char hex[]="0123456789abcdef";
                if(!policy->authorizations)policy->authorizations=g_try_malloc0(8*72);
                if(!policy->authorizations)valid=FALSE;
                else {
                    char *authorization=policy->authorizations[secrets-1];
                    memcpy(authorization,"Bearer ",7);
                    for(size_t n=0;n<32;++n){authorization[7+n*2]=hex[secret_data[n]>>4];authorization[8+n*2]=hex[secret_data[n]&15];}
                    authorization[71]=0;out->authorization=authorization;policy->decorates=TRUE;
                }
            }
        }
        g_variant_unref(secret);
        out->methods=methods;
        for (gsize j=0;j<i && valid;++j) if (out->https==policy->origins[j].https && out->port==policy->origins[j].port && !strcmp(out->host,policy->origins[j].host)) valid=FALSE;
        size_t bytes=0;
        for (gsize j=0;j<g_variant_n_children(headers) && valid;++j) {
            GVariant *header=g_variant_get_child_value(headers,j);
            ZwkRequestHeader *rule=&out->headers[j];
            g_variant_get(header,"(&sb&s)",&rule->name,&rule->exact,&rule->value);
            valid=zwk_policy_grant_header(rule->name) && zwk_policy_header_value(rule->value) && (rule->exact || !*rule->value);
            bytes+=strlen(rule->name)+strlen(rule->value);
            if (bytes>8192) valid=FALSE;
            for (gsize k=0;k<j && valid;++k) if (!g_ascii_strcasecmp(out->headers[k].name,rule->name)) valid=FALSE;
            ++out->header_count; g_variant_unref(header);
        }
        g_variant_unref(headers); g_variant_unref(item);
    }
    if(policy->decorates)for(unsigned i=0;i<policy->count;++i)for(unsigned j=0;j<policy->origins[i].header_count;++j)
        if(!g_ascii_strcasecmp(policy->origins[i].headers[j].name,"Authorization"))valid=FALSE;
    g_variant_unref(origins);
    if (!valid) { zwk_request_policy_unref(policy); return NULL; }
    if(policy->decorates){
        /* Only decorated policies add a separately wiped serialized owner.
           Rebind borrowed header strings before releasing the old backing. */
        const size_t serialized=g_variant_get_size(value);
        ZwkPolicyBytes *bytes=g_try_malloc(sizeof(*bytes)+serialized);
        if(!bytes){zwk_request_policy_unref(policy);return NULL;}
        bytes->length=serialized;g_variant_store(value,bytes->data);
        GVariant *owned=g_variant_ref_sink(g_variant_new_from_data(G_VARIANT_TYPE(ZWK_POLICY_VARIANT),bytes->data,serialized,TRUE,zwk_policy_bytes_free,bytes));
        GVariant *rows=g_variant_get_child_value(owned,3);
        for(unsigned i=0;i<policy->count;++i){
            GVariant *item=g_variant_get_child_value(rows,i),*headers=g_variant_get_child_value(item,2);
            for(unsigned j=0;j<policy->origins[i].header_count;++j){
                GVariant *header=g_variant_get_child_value(headers,j);ZwkRequestHeader *rule=&policy->origins[i].headers[j];
                g_variant_get(header,"(&sb&s)",&rule->name,&rule->exact,&rule->value);g_variant_unref(header);
            }
            g_variant_unref(headers);g_variant_unref(item);
        }
        g_variant_unref(rows);g_variant_unref(policy->storage);policy->storage=owned;
    }
    return policy;
}
static int zwk_policy_method(const char *value) {
    static const char *const methods[]={"GET","HEAD","POST","PUT","PATCH","DELETE","OPTIONS"};
    for (size_t i=0;i<G_N_ELEMENTS(methods);++i) if (value && !strcmp(value,methods[i])) return (int)i;
    return -1;
}
static inline ZwkRequestDecision zwk_request_policy_check(ZwkRequestPolicy *policy,const char *uri,const char *method,SoupMessageHeaders *headers) {
    ZwkRequestOrigin parsed={0};
    if (!policy || !zwk_policy_parse_uri(uri,FALSE,policy->loopback,&parsed)) return ZWK_REQUEST_INVALID;
    const ZwkRequestOrigin *grant=NULL;
    for (unsigned i=0;i<policy->count;++i) if (parsed.https==policy->origins[i].https && parsed.port==policy->origins[i].port && !strcmp(parsed.host,policy->origins[i].host)) { grant=&policy->origins[i]; break; }
    if (!grant) return ZWK_REQUEST_ORIGIN;
    int verb=zwk_policy_method(method);
    if (verb<0 || !(grant->methods&(1u<<(unsigned)verb))) return ZWK_REQUEST_METHOD;
    if (!headers) return ZWK_REQUEST_HEADERS;
    SoupMessageHeadersIter iter; const char *name,*value; unsigned count=0; size_t bytes=0;
    soup_message_headers_iter_init(&iter,headers);
    while (soup_message_headers_iter_next(&iter,&name,&value)) {
        if (++count>64 || !zwk_policy_header_name(name) || !zwk_policy_header_value(value) || (bytes+=strlen(name)+strlen(value))>16384) return ZWK_REQUEST_HEADERS;
        if (zwk_policy_managed_header(name)) continue;
        gboolean allowed=FALSE;
        for (unsigned i=0;i<grant->header_count;++i) if (!g_ascii_strcasecmp(name,grant->headers[i].name) && (!grant->headers[i].exact || !strcmp(value,grant->headers[i].value))) { allowed=TRUE; break; }
        if (!allowed) return ZWK_REQUEST_HEADERS;
    }
    return ZWK_REQUEST_ALLOW;
}
/* Explicit decorated policies own Authorization for every target, including
   redirects. A plain policy retains its original observation-only behavior. */
static inline ZwkRequestDecision zwk_request_policy_prepare(ZwkRequestPolicy *policy,const char *uri,const char *method,SoupMessageHeaders *headers) {
    if(policy&&policy->decorates&&headers)soup_message_headers_remove(headers,"Authorization");
    ZwkRequestDecision decision=zwk_request_policy_check(policy,uri,method,headers);
    if(decision!=ZWK_REQUEST_ALLOW||!policy->decorates)return decision;
    ZwkRequestOrigin parsed={0};
    if(!zwk_policy_parse_uri(uri,FALSE,policy->loopback,&parsed))return ZWK_REQUEST_INVALID;
    for(unsigned i=0;i<policy->count;++i){
        const ZwkRequestOrigin *origin=&policy->origins[i];
        if(parsed.https==origin->https&&parsed.port==origin->port&&!strcmp(parsed.host,origin->host)){
            if(origin->authorization){
                SoupMessageHeadersIter iter;const char *name,*value;unsigned count=1;size_t bytes=13+71;
                soup_message_headers_iter_init(&iter,headers);
                while(soup_message_headers_iter_next(&iter,&name,&value))if(++count>64||(bytes+=strlen(name)+strlen(value))>16384)return ZWK_REQUEST_HEADERS;
                soup_message_headers_replace(headers,"Authorization",origin->authorization);
            }
            break;
        }
    }
    return decision;
}
#endif
