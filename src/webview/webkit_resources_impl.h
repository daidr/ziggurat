#ifndef ZIGGURAT_WEBKIT_RESOURCES_IMPL_H
#define ZIGGURAT_WEBKIT_RESOURCES_IMPL_H
#define ZWK_RESOURCE_CAPACITY 8u
#include "webkit_file.h"
typedef struct ResourceSlot { WebKitURISchemeRequest *request; uint64_t token,generation; gboolean head; } ResourceSlot;
struct ResourceState { ZwkResourceNotify notify; unsigned limit; gboolean dynamic_document; ResourceSlot slots[ZWK_RESOURCE_CAPACITY]; ZwkFileControl *files[ZWK_FILE_VIEW_LIMIT]; };
typedef struct ResourceCall { ZwkState *state; WebKitURISchemeRequest *request; uint64_t generation; gboolean head,responded; } ResourceCall;
static gint live_resource_requests;
uint32_t zwk_resources_pending(void) { return (uint32_t)g_atomic_int_get(&live_resource_requests); }
static void resource_reject(ZwkState *s,WebKitURISchemeRequest *request) {
    webkit_uri_scheme_request_finish_error(request,s->local.denied);
}
static ResourceSlot resource_take(ZwkState *s,uint64_t token) {
    ResourceSlot found={0};
    if (s->resources) for (unsigned i=0;i<ZWK_RESOURCE_CAPACITY;++i) {
        ResourceSlot *slot=&s->resources->slots[i];
        if (slot->request && slot->token==token) {
            found=*slot; memset(slot,0,sizeof(*slot)); g_atomic_int_add(&live_resource_requests,-1); break;
        }
    }
    return found;
}
void zwk_resource_cancel(ZwkState *s,uint64_t token) {
    retain(s); ResourceSlot slot=resource_take(s,token);
    if (slot.request) { resource_reject(s,slot.request); g_object_unref(slot.request); }
    release(s);
}
static void resources_cancel_all(ZwkState *s) {
    if (!s->resources) return;
    for (unsigned i=0;i<ZWK_RESOURCE_CAPACITY;++i) if (s->resources->slots[i].request) zwk_resource_cancel(s,s->resources->slots[i].token);
    for (unsigned i=0;i<ZWK_FILE_VIEW_LIMIT;++i) {
        ZwkFileControl *control=s->resources->files[i]; s->resources->files[i]=NULL;
        if (control) { zwk_file_control_cancel(control); zwk_file_control_release(control); }
    }
}
void zwk_resource_cancel_all(ZwkState *s) { retain(s); resources_cancel_all(s); release(s); }
int zwk_resources_enable(ZwkState *s,ZwkResourceNotify notify_value,int dynamic_document,uint32_t limit) {
    if (!live(s)) return ZWK_CLOSED;
    if (!s->local.budget || s->resources || !notify_value || !limit || limit>ZWK_RESOURCE_CAPACITY) return ZWK_INVALID;
    ResourceState *resources=g_try_new0(ResourceState,1);
    if (!resources) return ZWK_OOM;
    resources->notify=notify_value; resources->limit=limit; resources->dynamic_document=!!dynamic_document; s->resources=resources;
    return ZWK_OK;
}
static gboolean response_text(char *out,const uint8_t *input,size_t length,size_t limit,gboolean name) {
    if (length>limit || (length && !input) || (name && !length)) return FALSE;
    for (size_t i=0;i<length;++i) if (input[i]<32 || input[i]>126) return FALSE;
    if (length) memcpy(out,input,length); out[length]=0;
    return !name || zwk_policy_header_name(out);
}
static gboolean response_reserved(const char *name) {
    static const char *const reserved[]={"content-type","content-length","transfer-encoding","connection","keep-alive","te","trailer","upgrade","proxy-authenticate","proxy-authorization"};
    for (size_t i=0;i<G_N_ELEMENTS(reserved);++i) if (!g_ascii_strcasecmp(name,reserved[i])) return TRUE;
    return FALSE;
}
static int resource_response(ZwkState *s,gboolean head,uint32_t status,const uint8_t *mime,size_t mime_length,
    const uint8_t *body,size_t length,const ZwkResponseHeader *rows,uint32_t count,GInputStream *external_stream,WebKitURISchemeResponse **out) {
    *out=NULL; char mime_text[128];
    if (status<200 || status>599 || !mime_length || !response_text(mime_text,mime,mime_length,127,FALSE) || count>16 || (count && !rows) || (!external_stream && ((length && !body) || length>s->local.limit)) || ((status==204 || status==205 || status==304) && length)) return ZWK_INVALID;
    char names[16][65],values[16][2049]; size_t bytes=0;
    for (unsigned i=0;i<count;++i) {
        if (!response_text(names[i],rows[i].name,rows[i].name_length,64,TRUE) || !response_text(values[i],rows[i].value,rows[i].value_length,2048,FALSE) || response_reserved(names[i])) return ZWK_INVALID;
        bytes+=rows[i].name_length+rows[i].value_length+4; if (bytes>8192) return ZWK_INVALID;
        for (unsigned j=0;j<i;++j) if (!g_ascii_strcasecmp(names[i],names[j])) return ZWK_INVALID;
    }
    GInputStream *stream=external_stream?g_object_ref(external_stream):local_stream(s->local.budget,body,head?0:length);
    if (!stream) return ZWK_FULL;
    WebKitURISchemeResponse *response=webkit_uri_scheme_response_new(stream,head?0:(gint64)length); g_object_unref(stream);
    webkit_uri_scheme_response_set_status(response,status,NULL);
    webkit_uri_scheme_response_set_content_type(response,mime_text);
    SoupMessageHeaders *headers=soup_message_headers_new(SOUP_MESSAGE_HEADERS_RESPONSE);
    char content_length[32]; g_snprintf(content_length,sizeof(content_length),"%zu",length);
    soup_message_headers_append(headers,"Content-Length",content_length);
    soup_message_headers_append(headers,"Content-Type",mime_text);
    soup_message_headers_append(headers,"Content-Security-Policy",s->local.csp);
    soup_message_headers_append(headers,"Cache-Control","no-store");
    soup_message_headers_append(headers,"X-Content-Type-Options","nosniff");
    for (unsigned i=0;i<count;++i) soup_message_headers_append(headers,names[i],values[i]);
    webkit_uri_scheme_response_set_http_headers(response,headers); *out=response; return ZWK_OK;
}
int zwk_resource_respond(void *opaque,uint32_t status,const uint8_t *mime,size_t mime_length,
    const uint8_t *body,size_t length,const ZwkResponseHeader *headers,uint32_t count) {
    ResourceCall *call=opaque; ZwkState *s=call->state;
    if (!live(s) || call->generation!=s->generation) return ZWK_CLOSED;
    if (call->responded) return ZWK_INVALID;
    WebKitURISchemeResponse *response=NULL;
    int result=resource_response(s,call->head,status,mime,mime_length,body,length,headers,count,NULL,&response);
    if (result!=ZWK_OK) return result;
    call->responded=TRUE;
    webkit_uri_scheme_request_finish_with_response(call->request,response); g_object_unref(response); return ZWK_OK;
}
int zwk_resource_defer(void *opaque,uint64_t token) {
    ResourceCall *call=opaque; ZwkState *s=call->state;
    if (!live(s) || call->generation!=s->generation) return ZWK_CLOSED;
    if (!s->resources || call->responded || !token) return ZWK_INVALID;
    unsigned used=0;
    for (unsigned i=0;i<ZWK_RESOURCE_CAPACITY;++i) if (s->resources->slots[i].request) {
        if (s->resources->slots[i].token==token) return ZWK_INVALID;
        ++used;
    }
    if (used>=s->resources->limit) return ZWK_FULL;
    for (unsigned i=0;i<ZWK_RESOURCE_CAPACITY;++i) if (!s->resources->slots[i].request) {
        s->resources->slots[i]=(ResourceSlot){g_object_ref(call->request),token,call->generation,call->head};
        call->responded=TRUE; g_atomic_int_inc(&live_resource_requests); return ZWK_OK;
    }
    return ZWK_FULL;
}
int zwk_resource_respond_deferred(ZwkState *s,uint64_t token,uint32_t status,const uint8_t *mime,size_t mime_length,
    const uint8_t *body,size_t length,const ZwkResponseHeader *headers,uint32_t count) {
    retain(s); ResourceSlot slot=resource_take(s,token); int result=ZWK_CLOSED;
    if (slot.request) {
        WebKitURISchemeResponse *response=NULL;
        if (live(s) && slot.generation==s->generation) result=resource_response(s,slot.head,status,mime,mime_length,body,length,headers,count,NULL,&response);
        if (response) { webkit_uri_scheme_request_finish_with_response(slot.request,response); g_object_unref(response); }
        else resource_reject(s,slot.request);
        g_object_unref(slot.request);
    }
    release(s); return result;
}
static int resource_file(ZwkState *s,WebKitURISchemeRequest *request,gboolean head,uint64_t generation,
    ZwkFile *file,uint64_t length,ZwkFileBudget *budget,uint32_t status,const uint8_t *mime,size_t mime_length,
    const ZwkResponseHeader *headers,uint32_t count,int want_ticket,ZwkFileControl **ticket) {
    *ticket=NULL;
    if (!live(s) || generation!=s->generation || !s->resources) return ZWK_CLOSED;
    if (!file || length!=zwk_file_length(file) || length>ZWK_FILE_MAX_BYTES) return ZWK_INVALID;
    unsigned slot=ZWK_FILE_VIEW_LIMIT;
    for (unsigned i=0;i<ZWK_FILE_VIEW_LIMIT;++i) {
        ZwkFileControl *control=s->resources->files[i];
        if (control && !zwk_file_control_alive(control)) { s->resources->files[i]=NULL; zwk_file_control_release(control); }
        if (!s->resources->files[i] && slot==ZWK_FILE_VIEW_LIMIT) slot=i;
    }
    if (slot==ZWK_FILE_VIEW_LIMIT) return ZWK_FULL;
    ZwkFileCandidate *candidate=NULL; int native_errno=0;
    int file_result=zwk_file_prepare_stream(file,budget,head,&candidate,&native_errno);
    if (file_result!=ZWK_FILE_OK) {
        if (native_errno) {
            GError *error=g_error_new_literal(G_IO_ERROR,g_io_error_from_errno(native_errno),"File response setup failed");
            failure_set(s,error); g_error_free(error);
        }
        return file_result==ZWK_FILE_FULL?ZWK_FULL:file_result==ZWK_FILE_OOM?ZWK_OOM:file_result==ZWK_FILE_CANCELLED?ZWK_CLOSED:file_result==ZWK_FILE_IO?ZWK_NATIVE_FAILED:ZWK_INVALID;
    }
    WebKitURISchemeResponse *response=NULL;
    int result=resource_response(s,head,status,mime,mime_length,NULL,(size_t)length,headers,count,zwk_file_candidate_stream(candidate),&response);
    if (result!=ZWK_OK) { zwk_file_candidate_abort(candidate); return result; }
    ZwkFileControl *control=zwk_file_candidate_control(candidate);
    zwk_file_control_add(control); s->resources->files[slot]=control;
    webkit_uri_scheme_request_finish_with_response(request,response);
    zwk_file_candidate_commit(candidate,!live(s) || generation!=s->generation,want_ticket,ticket);
    g_object_unref(response); return ZWK_OK;
}
int zwk_resource_respond_file(void *opaque,ZwkFile *file,uint64_t length,ZwkFileBudget *budget,
    uint32_t status,const uint8_t *mime,size_t mime_length,const ZwkResponseHeader *headers,uint32_t count,int want_ticket,ZwkFileControl **ticket) {
    ResourceCall *call=opaque;
    if (call->responded) { *ticket=NULL; return ZWK_INVALID; }
    int result=resource_file(call->state,call->request,call->head,call->generation,file,length,budget,status,mime,mime_length,headers,count,want_ticket,ticket);
    if (result==ZWK_OK) call->responded=TRUE;
    return result;
}
int zwk_resource_respond_file_deferred(ZwkState *s,uint64_t token,ZwkFile *file,uint64_t length,ZwkFileBudget *budget,
    uint32_t status,const uint8_t *mime,size_t mime_length,const ZwkResponseHeader *headers,uint32_t count,int want_ticket,ZwkFileControl **ticket) {
    *ticket=NULL; retain(s); ResourceSlot slot=resource_take(s,token); int result=ZWK_CLOSED;
    if (slot.request) {
        result=resource_file(s,slot.request,slot.head,slot.generation,file,length,budget,status,mime,mime_length,headers,count,want_ticket,ticket);
        if (result!=ZWK_OK) resource_reject(s,slot.request);
        g_object_unref(slot.request);
    }
    release(s); return result;
}
static __attribute__((noinline)) gboolean resource_notify(ZwkState *s,WebKitURISchemeRequest *request,const char *method) {
    if (!s->resources) return FALSE;
    ResourceCall call={s,request,s->generation,!strcmp(method,"HEAD"),FALSE};
    ZwkResourceHeader headers[64]; unsigned count=0;
    SoupMessageHeadersIter iter; const char *name,*value;
    soup_message_headers_iter_init(&iter,webkit_uri_scheme_request_get_http_headers(request));
    while (soup_message_headers_iter_next(&iter,&name,&value)) {
        if (count==64) { resource_reject(s,request); return TRUE; }
        headers[count++]=(ZwkResourceHeader){name,value};
    }
    s->resources->notify(s->owner,webkit_uri_scheme_request_get_uri(request),method,headers,count,&call);
    /* Owner closure can make a response fail. The native call still owns its
       request and finishes it before the retained State leaves this callback. */
    if (!call.responded) resource_reject(s,request);
    return TRUE;
}
#endif
