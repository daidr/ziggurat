#ifndef ZIGGURAT_WEBKIT_REMOTE_IMPL_H
#define ZIGGURAT_WEBKIT_REMOTE_IMPL_H
#include "webkit_remote.h"
#include "webkit_request_policy.h"
#define ZWK_REMOTE_NAVIGATE 1u
#define ZWK_REMOTE_REQUESTS 2u
#define ZWK_REMOTE_IPC 4u
typedef struct RemoteData {
    ZwkRequestPolicy *requests;
    ZwkRequestOrigin origins[32];
    uint32_t flags[32],count,timeout_ms;
    guint64 id;
    char *url,*directory,*csp,*ipc_json;
    gboolean script_navigation,redirects,ready,failed,bootstrap,handshake,bootstrap_loaded;
} RemoteData;
static guint64 remote_next_id;
static void remote_free(RemoteData *data){
    if(!data)return;
    zwk_request_policy_unref(data->requests);
    g_free(data->url);g_free(data->directory);g_free(data->csp);g_free(data->ipc_json);g_free(data);
}
static char *remote_copy(const char *value){
    size_t n=strlen(value);char *copy=g_try_malloc(n+1);
    if(copy)memcpy(copy,value,n+1);return copy;
}
static uint32_t remote_grants(RemoteData *data,const char *uri){
    ZwkRequestOrigin parsed={0};
    if(!data||!zwk_policy_parse_uri(uri,FALSE,data->requests->loopback,&parsed))return 0;
    for(uint32_t i=0;i<data->count;i++){
        const ZwkRequestOrigin *origin=&data->origins[i];
        if(parsed.https==origin->https&&parsed.port==origin->port&&!strcmp(parsed.host,origin->host))return data->flags[i];
    }
    return 0;
}
static gboolean remote_navigate(RemoteData *data,const char *uri){
    const uint32_t flags=remote_grants(data,uri);
    if((flags&(ZWK_REMOTE_NAVIGATE|ZWK_REMOTE_REQUESTS))!=(ZWK_REMOTE_NAVIGATE|ZWK_REMOTE_REQUESTS))return FALSE;
    ZwkRequestOrigin parsed={0};
    if(!zwk_policy_parse_uri(uri,FALSE,data->requests->loopback,&parsed))return FALSE;
    for(uint32_t i=0;i<data->count;i++)if(parsed.https==data->origins[i].https&&parsed.port==data->origins[i].port&&!strcmp(parsed.host,data->origins[i].host))return (data->origins[i].methods&1u)!=0;
    return FALSE;
}
/* Keep path/query escapes encoded. Decoding a query before comparison could
   equate a literal delimiter with an escaped data byte. */
static gboolean remote_uri_equal(RemoteData *data,const char *a,const char *b,gboolean ignore_fragment){
    ZwkRequestOrigin left={0},right={0};
    if(!zwk_policy_parse_uri(a,FALSE,data->requests->loopback,&left)||!zwk_policy_parse_uri(b,FALSE,data->requests->loopback,&right)||
       left.https!=right.https||left.port!=right.port||strcmp(left.host,right.host))return FALSE;
    GUri *x=g_uri_parse(a,G_URI_FLAGS_ENCODED,NULL),*y=g_uri_parse(b,G_URI_FLAGS_ENCODED,NULL);
    if(!x||!y){if(x)g_uri_unref(x);if(y)g_uri_unref(y);return FALSE;}
    const char *px=g_uri_get_path(x),*py=g_uri_get_path(y);
    gboolean same=!strcmp(px&&*px?px:"/",py&&*py?py:"/")&&
        !g_strcmp0(g_uri_get_query(x),g_uri_get_query(y))&&(ignore_fragment||!g_strcmp0(g_uri_get_fragment(x),g_uri_get_fragment(y)));
    g_uri_unref(x);g_uri_unref(y);return same;
}
static gboolean remote_same_uri(RemoteData *data,const char *a,const char *b){return remote_uri_equal(data,a,b,FALSE);}
static gboolean remote_fragment_change(RemoteData *data,const char *a,const char *b){return remote_uri_equal(data,a,b,TRUE)&&!remote_uri_equal(data,a,b,FALSE);}
static gboolean remote_origin_text(const ZwkRequestOrigin *origin,char output[320]){
    const char *scheme=origin->https?"https":"http";
    const gboolean port=origin->port!=(origin->https?443:80),ipv6=strchr(origin->host,':')!=NULL;
    int n=port?g_snprintf(output,320,ipv6?"%s://[%s]:%u":"%s://%s:%u",scheme,origin->host,origin->port):
        g_snprintf(output,320,ipv6?"%s://[%s]":"%s://%s",scheme,origin->host);
    return n>0&&(size_t)n<320;
}
/* Bounded preparation. GVariant retains only its own copied metadata; no
   descriptor or string from the Zig candidate survives this function. */
static int remote_create(const ZwkRemoteOptions *input,RemoteData **out){
    *out=NULL;
    if(!input||!input->origins||!input->count||input->count>32||!input->timeout_ms||input->timeout_ms>60000||
       !input->directory||!g_path_is_absolute(input->directory)||zwk_policy_length(input->directory,4097)>4096||
       !g_utf8_validate(input->directory,-1,NULL)||remote_next_id==G_MAXUINT64)return ZWK_INVALID;
    RemoteData *data=g_try_new0(RemoteData,1);if(!data)return ZWK_OOM;
    data->count=input->count;data->timeout_ms=input->timeout_ms;
    data->script_navigation=!!input->script_navigation;data->redirects=!!input->redirects;
    data->id=++remote_next_id;
    ZwkRequestOrigin initial={0};
    if(!zwk_policy_parse_uri(input->url,FALSE,!!input->loopback,&initial)){remote_free(data);return ZWK_INVALID;}
    GVariantBuilder origins;g_variant_builder_init(&origins,G_VARIANT_TYPE("a(sua(sbs)ay)"));
    int result=ZWK_INVALID;
    gboolean allowed=FALSE;
    gboolean decorates=FALSE;
    for(uint32_t i=0;i<input->count;++i)if(input->origins[i].bearer)decorates=TRUE;
    for(uint32_t i=0;i<input->count;i++){
        const ZwkRemoteOrigin *source=&input->origins[i];
        ZwkRequestOrigin *origin=&data->origins[i];
        if((source->flags&~7u)||source->header_count>16||(source->header_count&&!source->headers)||
           (source->methods&~127u)||((source->flags&ZWK_REMOTE_REQUESTS)&&!source->methods)||
           !zwk_policy_parse_uri(source->origin,TRUE,!!input->loopback,origin)||
           (source->bearer&&(!origin->https||!(source->flags&ZWK_REMOTE_REQUESTS))))goto failed;
        data->flags[i]=source->flags;origin->methods=source->methods;
        for(uint32_t j=0;j<i;j++)if(origin->https==data->origins[j].https&&origin->port==data->origins[j].port&&!strcmp(origin->host,data->origins[j].host))goto failed;
        size_t bytes=0;
        for(uint32_t j=0;j<source->header_count;j++){
            const ZwkRemoteHeader *header=&source->headers[j];
            if(!zwk_policy_grant_header(header->name)||(header->value&&!zwk_policy_header_value(header->value))||
               (decorates&&!g_ascii_strcasecmp(header->name,"Authorization")))goto failed;
            bytes+=strlen(header->name)+(header->value?strlen(header->value):0);
            if(bytes>8192)goto failed;
            for(uint32_t k=0;k<j;k++)if(!g_ascii_strcasecmp(header->name,source->headers[k].name))goto failed;
        }
        if((source->flags&3u)==3u&&(source->methods&1u)&&origin->https==initial.https&&origin->port==initial.port&&!strcmp(origin->host,initial.host))allowed=TRUE;
        if(source->flags&ZWK_REMOTE_REQUESTS){
            GVariant *secret=zwk_policy_secret(source->bearer);
            if(!secret){result=ZWK_OOM;goto failed;}
            GVariantBuilder headers;g_variant_builder_init(&headers,G_VARIANT_TYPE("a(sbs)"));
            for(uint32_t j=0;j<source->header_count;j++)g_variant_builder_add(&headers,"(sbs)",source->headers[j].name,source->headers[j].value!=NULL,source->headers[j].value?source->headers[j].value:"");
            g_variant_builder_add(&origins,"(su@a(sbs)@ay)",source->origin,source->methods,g_variant_builder_end(&headers),secret);
        }
    }
    if(!allowed)goto failed;
    GVariant *config=g_variant_ref_sink(g_variant_new("(utb@a(sua(sbs)ay))",ZWK_POLICY_ABI,data->id,!!input->loopback,g_variant_builder_end(&origins)));
    data->requests=zwk_request_policy_new(config);g_variant_unref(config);
    if(!data->requests){remote_free(data);return ZWK_INVALID;}
    data->url=remote_copy(input->url);data->directory=remote_copy(input->directory);
    /* Six resource directives repeat at most 32 serialized origins. */
    data->csp=g_try_malloc(65536);data->ipc_json=g_try_malloc(32768);
    if(!data->url||!data->directory||!data->csp||!data->ipc_json){remote_free(data);return ZWK_OOM;}
    char list[16384];size_t list_size=0,ipc_size=1;data->ipc_json[0]='[';gboolean first=TRUE;
    for(uint32_t i=0;i<data->count;i++){
        char origin[320];if(!remote_origin_text(&data->origins[i],origin)){remote_free(data);return ZWK_INVALID;}
        const size_t n=strlen(origin);
        if(data->flags[i]&ZWK_REMOTE_REQUESTS){if(list_size+n+2>sizeof(list)){remote_free(data);return ZWK_INVALID;}list[list_size++]=' ';memcpy(list+list_size,origin,n);list_size+=n;}
        if(data->flags[i]&ZWK_REMOTE_IPC){
            if(ipc_size+n+4>32768){remote_free(data);return ZWK_INVALID;}
            if(!first)data->ipc_json[ipc_size++]=',';first=FALSE;
            data->ipc_json[ipc_size++]='\'';memcpy(data->ipc_json+ipc_size,origin,n);ipc_size+=n;data->ipc_json[ipc_size++]='\'';
        }
    }
    list[list_size]=0;data->ipc_json[ipc_size++]=']';data->ipc_json[ipc_size]=0;
    int n=g_snprintf(data->csp,65536,"default-src 'none'; script-src 'unsafe-inline' 'unsafe-eval'%s; style-src 'unsafe-inline'%s; img-src data: blob:%s; font-src%s; media-src%s; connect-src%s; worker-src 'none'; frame-src 'none'; object-src 'none'; base-uri 'none'; form-action 'none'",list,list,list,list,list,list);
    if(n<=0||n>=65536){remote_free(data);return ZWK_INVALID;}
    *out=data;return ZWK_OK;
failed:
    g_variant_builder_clear(&origins);remote_free(data);return result;
}
#endif
