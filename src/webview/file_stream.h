#ifndef ZIGGURAT_FILE_STREAM_H
#define ZIGGURAT_FILE_STREAM_H
#include "../file_stream/windows_istream.h"
static void file_controls_close(State *s) {
    FileControl *snapshot[FILE_STREAM_LIMIT];
    memcpy(snapshot,s->file_controls,sizeof(snapshot));memset(s->file_controls,0,sizeof(s->file_controls));
    for(unsigned i=0;i<FILE_STREAM_LIMIT;i++)if(snapshot[i]){zwv_file_control_cancel(snapshot[i]);zwv_file_control_release(snapshot[i]);}
}
void zwv_file_cancel_all(State *s) { file_controls_close(s); }
static void file_controls_sweep(State *s) {
    for(unsigned i=0;i<FILE_STREAM_LIMIT;i++){
        FileControl *control=s->file_controls[i];
        if(control&&!InterlockedCompareExchange(&control->alive,0,0)) { s->file_controls[i]=NULL;zwv_file_control_release(control); }
    }
}
static void file_control_unlink(State *s,FileControl *control) {
    for(unsigned i=0;i<FILE_STREAM_LIMIT;i++)if(s->file_controls[i]==control){s->file_controls[i]=NULL;zwv_file_control_release(control);return;}
}
/* Payload metadata remains bounded and uses the same validation/defaults as a
 * buffered response. This helper never reads or stats the file on the UI. */
static HRESULT file_respond(ResourceCall *call,HANDLE file,uint64_t size,FileBudget *budget,unsigned status,const char *mime,size_t mime_len,const ResponseHeader *extra,uint32_t count,BOOL want_ticket,FileControl **ticket) {
    *ticket=NULL;if(!call||call->responded||call->state->closed||call->state->recovering)return E_ABORT;
    if(size>FILE_STREAM_MAX_BYTES||!file||!budget)return E_INVALIDARG;
    if(size&&(status==204||status==205||status==304))return E_INVALIDARG;
    State *s=call->state;retain(s);uint64_t navigation=s->navigation_id;
    WCHAR response_headers_buffer[8704];
    HRESULT hr=response_headers(status,mime,mime_len,size,extra,count,response_headers_buffer);
    ICoreWebView2WebResourceResponse *response=NULL;IStream *stream=NULL;FileControl *control=NULL;
    if(SUCCEEDED(hr)&&!call->head&&size){
        hr=file_stream_create(file,size,budget,&stream);
        if(SUCCEEDED(hr)){
            control=((FileStream *)stream)->physical.control;
            if(s->closed||s->recovering||s->navigation_id!=navigation)hr=E_ABORT;
            else {
                file_controls_sweep(s);
                unsigned index=0;while(index<FILE_STREAM_LIMIT&&s->file_controls[index])index++;
                if(index==FILE_STREAM_LIMIT)hr=E_PENDING;
                else {zwv_file_control_add(control);s->file_controls[index]=control;}
            }
        }
    }
    if(SUCCEEDED(hr)&&(s->closed||s->recovering||s->navigation_id!=navigation))hr=E_ABORT;
    if(SUCCEEDED(hr))hr=ICoreWebView2Environment_CreateWebResourceResponse(s->environment,stream,(int)status,L"Response",response_headers_buffer,&response);
    if(SUCCEEDED(hr)&&!response)hr=E_POINTER;
    if(SUCCEEDED(hr)&&(s->closed||s->recovering||s->navigation_id!=navigation))hr=E_ABORT;
    if(SUCCEEDED(hr))hr=ICoreWebView2WebResourceRequestedEventArgs_put_Response(call->args,response);
    if(SUCCEEDED(hr)&&(s->closed||s->recovering||s->navigation_id!=navigation))hr=E_ABORT;
    if(SUCCEEDED(hr)){
        call->responded=TRUE;
        if(control&&want_ticket){zwv_file_control_add(control);*ticket=control;}
    }else if(control){zwv_file_control_cancel(control);file_control_unlink(s,control);}
    if(stream)IStream_Release(stream);if(response)ICoreWebView2WebResourceResponse_Release(response);release(s);return hr;
}
HRESULT zwv_respond_file(ResourceCall *call,HANDLE file,uint64_t size,FileBudget *budget,unsigned status,const char *mime,size_t mime_len,const ResponseHeader *headers,uint32_t count,BOOL want_ticket,FileControl **ticket) {
    return file_respond(call,file,size,budget,status,mime,mime_len,headers,count,want_ticket,ticket);
}
HRESULT zwv_respond_file_deferred(State *s,uint64_t token,HANDLE file,uint64_t size,FileBudget *budget,unsigned status,const char *mime,size_t mime_len,const ResponseHeader *headers,uint32_t count,BOOL want_ticket,FileControl **ticket) {
    *ticket=NULL;DeferredResource *pending=deferred_take(s,token);if(!pending)return E_ABORT;
    ResourceCall call={s,pending->args,FALSE,pending->head};
    /* Hold an independent control across Complete even when the host did not
       request a ticket, so a failed completion still cancels the physical IO. */
    HRESULT hr=file_respond(&call,file,size,budget,status,mime,mime_len,headers,count,TRUE,ticket);
    HRESULT completed=ICoreWebView2Deferral_Complete(pending->deferral);deferred_release(pending);
    if(FAILED(hr)||FAILED(completed)){if(*ticket){zwv_file_control_cancel(*ticket);zwv_file_control_release(*ticket);*ticket=NULL;}return FAILED(hr)?hr:completed;}
    if(*ticket&&!want_ticket){zwv_file_control_release(*ticket);*ticket=NULL;}
    return S_OK;
}
void zwv_file_counts(uint32_t *streams,uint32_t *controls,uint32_t *budgets){ZwsCounts counts;zws_counts(&counts);*streams=counts.physical;*controls=counts.controls;*budgets=counts.budgets;}
#endif
