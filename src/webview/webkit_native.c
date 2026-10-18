#include "webkit_native.h"
#include "../platform/linux_content.h"
#include <webkit2/webkit2.h>
#if !WEBKIT_CHECK_VERSION(2,40,0)
#error "Ziggurat requires WebKitGTK API 4.1 version 2.40 or newer"
#endif
#include <string.h>
#include <stdio.h>
#include <stdarg.h>
#include <stdatomic.h>
#include <stdlib.h>
#include "webkit_local_impl.h"
#include "webkit_remote_impl.h"

typedef struct Script Script;
typedef struct ResourceState ResourceState;
typedef struct ZwkInitializerState ZwkInitializerState;
typedef enum NavigationKind { NAV_INITIAL,NAV_BOOTSTRAP,NAV_LOCAL,NAV_REMOTE,NAV_HISTORY,NAV_REFRESH,NAV_FRAGMENT } NavigationKind;
typedef struct Navigation {
    unsigned refs;
    ZwkState *state;
    uint64_t serial;
    char *uri;
    WebKitBackForwardListItem *item;
    NavigationKind kind;
    gboolean issued,saw_loading,authorized,prepared,started,finished,cancelled;
} Navigation;
struct Script { Script *next; ZwkState *state; GCancellable *cancel; uint64_t token; gboolean cancelled; };
struct ZwkState {
    unsigned refs, pending, limit, result_limit;
    GThread *thread;
    GtkWidget *view;
    WebKitWebContext *context;
    WebKitUserContentManager *manager;
    ZlgContentHost *host;
    ZlgRegionHost *region;
    void *owner;
    ZwkNotify notify;
    ZwkPageNotify page;
    ZwkScriptNotify script;
    ZwkDeadline deadline;
    ZwkFailure failure;
    ZwkFailure loading_failure;
    Script *scripts;
    GSource *initial, *timer, *policy_timer;
    char *html;
    LocalData local;
    RemoteData *remote;
    ResourceState *resources;
    ZwkCaptureBudget *capture;
    ZwkFindGate *find;
    ZwkInitializerState *initializers;
    WebKitUserScript *private_bootstrap,*public_bootstrap;
    Navigation *navigation;
    WebKitBackForwardList *history;
    char *current_uri;
    uint64_t generation,navigation_serial,loading_generation,loading_serial,revoked_load_serial;
    unsigned navigation_objects;
    /* Opt-in Session placement has no parking GtkWindow or extra owning object. */
    void *session_parent;
    uint64_t session_epoch;
    uint32_t session_width,session_height;
    int32_t session_left,session_top,session_right,session_bottom;
    gboolean session,placement_busy,parent_destroying,session_visible;
    uint32_t policy;
    gboolean closed, committed, failed, dom_ready, recovering,load_started;
};
static gint live_states, live_callbacks, live_views;
static void capture_state_clear(ZwkState *);
static void capture_cancel_all(ZwkState *);
static void initializers_free(ZwkInitializerState *);
void zwk_counts(uint32_t *states,uint32_t *callbacks,uint32_t *views) {
    *states=(uint32_t)g_atomic_int_get(&live_states);
    *callbacks=(uint32_t)g_atomic_int_get(&live_callbacks);
    *views=(uint32_t)g_atomic_int_get(&live_views);
}
static void retain(ZwkState *s) { g_assert(s->thread==g_thread_self()); ++s->refs; }
static void release(gpointer data) {
    ZwkState *s=data; g_assert(s->thread==g_thread_self() && s->refs);
    if (--s->refs) return;
    g_assert(s->closed && !s->scripts && !s->view && !s->host && !s->region && !s->initial && !s->timer && !s->policy_timer && !s->navigation && !s->navigation_objects && !s->history && !s->find);
    capture_state_clear(s);
    initializers_free(s->initializers);
    if(s->private_bootstrap)webkit_user_script_unref(s->private_bootstrap);
    if(s->public_bootstrap)webkit_user_script_unref(s->public_bootstrap);
    local_finish(&s->local); remote_free(s->remote); g_free(s->html);g_free(s->current_uri);g_free(s->resources); g_free(s); g_atomic_int_add(&live_states,-1);
}
static gboolean live(ZwkState *s) { return !s->closed && !s->recovering && s->owner; }
static size_t bounded_length(const char *text,size_t limit) {
    size_t count=0; while (count<limit && text[count]) ++count; return count;
}
static gboolean document(ZwkState *s) {
    if (!live(s) || !s->committed || s->failed) return FALSE;
    if (s->navigation && !s->navigation->prepared) return FALSE;
    const char *uri=webkit_web_view_get_uri(WEBKIT_WEB_VIEW(s->view));
    char path[4097];
    return uri && (s->remote?(s->remote->ready && !s->remote->failed && remote_navigate(s->remote,uri)):(s->local.budget?local_uri(s->local.scheme,s->local.host,uri,path):!strcmp(uri,"about:blank")));
}
static gboolean ipc_allowed(ZwkState *s) {
    if(s->remote)return (remote_grants(s->remote,webkit_web_view_get_uri(WEBKIT_WEB_VIEW(s->view)))&ZWK_REMOTE_IPC)!=0;
    return !s->local.budget || local_ipc(&s->local);
}
static int prepare_document(ZwkState *s);
static void remote_start(ZwkState *s);
static void remote_fail(ZwkState *s,int code,const char *reason);
static void source_changed(GObject *view,GParamSpec *property,gpointer data);
static void history_changed(WebKitBackForwardList *,WebKitBackForwardListItem *,GList *,gpointer);
static void loading_changed(GObject *,GParamSpec *,gpointer);
static void navigation_fail(ZwkState *,int,const char *);
static void navigation_settle(ZwkState *);
static int session_size(ZwkState *,uint32_t,uint32_t,int,int);
static void failure_set(ZwkState *s, const GError *error) {
    if (error) s->failure=(ZwkFailure){error->domain,error->code};
}
void zwk_last_failure(ZwkState *s,ZwkFailure *value) { *value=s->failure; }
static uint16_t *wide(const char *text,size_t limit) {
    if (!text || bounded_length(text,limit+1)>limit) return NULL;
    return (uint16_t *)g_utf8_to_utf16(text,-1,NULL,NULL,NULL);
}
static void notify(ZwkState *s,int kind,const char *text,int32_t code,const ZwkFailure *failure) {
    if (!live(s) || !s->notify) return;
    uint16_t *value=wide(text,65536);
    s->notify(s->owner,kind,value,code,failure);
    g_free(value);
}
static gboolean page(ZwkState *s,int kind,uint32_t flags,int32_t status,const char *text) {
    if (!live(s) || !s->page) return FALSE;
    uint16_t *value=wide(text,16384);
    ZwkPageEvent event={kind,s->generation,flags,status,value};
    gboolean accepted=s->page(s->owner,&event)!=0;
    g_free(value);
    return accepted && live(s);
}
static void source_clear(GSource **field) {
    GSource *source=*field;
    *field=NULL;
    if (source) { g_source_destroy(source); g_source_unref(source); }
}
#include "webkit_resources_impl.h"
#include "webkit_capture_impl.h"
#include "webkit_find_impl.h"
#include "webkit_initializers_impl.h"
/* Only the active transaction owns permission. Local refs keep target strings
 * and history items alive across callbacks that stop or close the whole view. */
static void navigation_ref(Navigation *op) { ++op->refs; }
static void navigation_release(Navigation *op) {
    if (--op->refs) return;
    ZwkState *s=op->state; g_assert(s->navigation_objects); --s->navigation_objects;
    char *uri=op->uri; WebKitBackForwardListItem *item=op->item;
    g_free(op); g_free(uri); if (item) g_object_unref(item);
}
static void navigation_clear(ZwkState *s) {
    Navigation *op=s->navigation; s->navigation=NULL;
    if (op) { op->cancelled=!op->finished; navigation_release(op); }
}
static void navigation_revoke(ZwkState *s) {
    Navigation *op=s->navigation;
    if (op && op->started && s->load_started && s->loading_generation==s->generation && s->loading_serial==op->serial) {
        /* stop_loading can leave COMMITTED queued. Keep only the identity of
         * this revoked load until its terminal FINISHED; it grants no access. */
        s->revoked_load_serial=op->serial;
        s->committed=FALSE; s->failed=TRUE;
    }
    navigation_clear(s);
}
static gboolean revoked_load(ZwkState *s) {
    return !s->navigation && s->load_started && s->loading_generation==s->generation &&
        s->revoked_load_serial && s->revoked_load_serial==s->loading_serial && s->revoked_load_serial==s->navigation_serial;
}
static gboolean navigation_current(ZwkState *s,Navigation *op) { return op && live(s) && s->navigation==op && s->navigation_serial==op->serial; }
static int navigation_begin(ZwkState *s,NavigationKind kind,const char *uri,WebKitBackForwardListItem *item) {
    if(!initializers_allow_navigation(s))return ZWK_NAVIGATION_PENDING;
    if (s->navigation || s->load_started) return ZWK_NAVIGATION_PENDING;
    if (s->navigation_objects==8 || s->navigation_serial==UINT64_MAX) return ZWK_FULL;
    const size_t length=uri?bounded_length(uri,16385):16385;
    if (!length || length>16384) return ZWK_INVALID;
    Navigation *op=g_try_new0(Navigation,1); if (!op) return ZWK_OOM;
    op->uri=g_try_malloc(length+1);
    if (!op->uri) { g_free(op); return ZWK_OOM; }
    memcpy(op->uri,uri,length+1);
    op->state=s; op->refs=1; op->serial=++s->navigation_serial; op->kind=kind;
    if (item) op->item=g_object_ref(item);
    ++s->navigation_objects; s->navigation=op; return ZWK_OK;
}
static gboolean trusted_uri(ZwkState *s,const char *uri) {
    char path[4097];
    return uri && (s->remote?remote_navigate(s->remote,uri):(s->local.budget?local_uri(s->local.scheme,s->local.host,uri,path):!strcmp(uri,"about:blank")));
}
static gboolean same_uri(ZwkState *s,const char *a,const char *b) {
    if (!a || !b) return FALSE;
    if (s->remote) return remote_same_uri(s->remote,a,b);
    return trusted_uri(s,a) && trusted_uri(s,b) && !strcmp(a,b);
}
static gboolean current_uri_update(ZwkState *s) {
    const char *uri=webkit_web_view_get_uri(WEBKIT_WEB_VIEW(s->view));
    if (!trusted_uri(s,uri)) return FALSE;
    const size_t length=bounded_length(uri,16385); if (length>16384) return FALSE;
    char *copy=g_try_malloc(length+1); if (!copy) return FALSE;
    memcpy(copy,uri,length+1);
    char *old=s->current_uri; s->current_uri=copy; g_free(old); return TRUE;
}
static void history_notify(ZwkState *s) {
    if (!live(s) || !s->committed || !s->history) return;
    const uint32_t flags=(webkit_back_forward_list_get_back_item(s->history)?1u:0u)|(webkit_back_forward_list_get_forward_item(s->history)?2u:0u);
    (void)page(s,5,flags,0,NULL);
}
static void navigation_fail(ZwkState *s,int code,const char *reason) {
    if (!live(s)) return;
    const uint64_t serial=s->navigation_serial,generation=s->generation;
    GError *error=g_error_new_literal(g_quark_from_static_string("ziggurat-webkit-navigation"),code,reason);
    failure_set(s,error); const ZwkFailure failure=s->failure; g_error_free(error);
    if (s->load_started && s->loading_generation==generation && s->loading_serial==serial && !s->loading_failure.domain)
        s->loading_failure=failure;
    s->committed=FALSE; s->failed=TRUE; navigation_revoke(s);
    if (!live(s) || s->navigation_serial!=serial || s->generation!=generation) return;
    resources_cancel_all(s);
    if (live(s) && s->navigation_serial==serial && s->generation==generation) (void)page(s,6,0,0,NULL);
    if (live(s) && s->navigation_serial==serial && s->generation==generation) webkit_web_view_stop_loading(WEBKIT_WEB_VIEW(s->view));
    if (live(s) && s->navigation_serial==serial && s->generation==generation) notify(s,2,NULL,code,&failure);
}
static void navigation_settle(ZwkState *s) {
    Navigation *op=s->navigation;
    if (!live(s) || !op || !op->issued || !op->saw_loading || op->prepared || op->kind==NAV_BOOTSTRAP || webkit_web_view_is_loading(WEBKIT_WEB_VIEW(s->view))) return;
    navigation_ref(op);
    const char *uri=webkit_web_view_get_uri(WEBKIT_WEB_VIEW(s->view));
    if (op->started || !same_uri(s,uri,op->uri) || (op->item && webkit_back_forward_list_get_current_item(s->history)!=op->item)) {
        navigation_fail(s,ZWK_POLICY_PREPARATION,"Unexpected history navigation sequence");
    } else if (!current_uri_update(s)) navigation_fail(s,ZWK_POLICY_PREPARATION,"Current URI snapshot failed");
    else {
        op->finished=TRUE; navigation_clear(s);
        (void)page(s,3,1,0,s->current_uri);
        if (live(s) && !s->navigation) history_notify(s);
    }
    navigation_release(op);
}
static void view_finalized(gpointer data,GObject *object) {
    (void)object; g_atomic_int_add(&live_views,-1); release(data);
}
static gboolean permission(WebKitWebView *view,WebKitPermissionRequest *request,gpointer data) {
    (void)view; (void)data; webkit_permission_request_deny(request); return TRUE;
}
static gboolean authentication(WebKitWebView *view,WebKitAuthenticationRequest *request,gpointer data) {
    (void)view; (void)data; webkit_authentication_request_cancel(request); return TRUE;
}
static gboolean dialog(WebKitWebView *view,WebKitScriptDialog *dialog_value,gpointer data) {
    (void)view; (void)data;
    if (webkit_script_dialog_get_dialog_type(dialog_value)==WEBKIT_SCRIPT_DIALOG_CONFIRM)
        webkit_script_dialog_confirm_set_confirmed(dialog_value,FALSE);
    return TRUE;
}
static gboolean chooser(WebKitWebView *view,WebKitFileChooserRequest *request,gpointer data) {
    (void)view; (void)data; webkit_file_chooser_request_cancel(request); return TRUE;
}
static gboolean print_requested(WebKitWebView *view,WebKitPrintOperation *operation,gpointer data) {
    (void)view; (void)operation; (void)data; return TRUE;
}
static gboolean color_chooser(WebKitWebView *view,WebKitColorChooserRequest *request,gpointer data) {
    (void)view; (void)data; webkit_color_chooser_request_finish(request); return TRUE;
}
static gboolean notification(WebKitWebView *view,WebKitNotification *request,gpointer data) {
    (void)view; (void)data; webkit_notification_close(request); return TRUE;
}
static WebKitWebView *popup(WebKitWebView *view,WebKitNavigationAction *action,gpointer data) {
    (void)view; (void)action; (void)data; return NULL;
}
static gboolean context_menu(WebKitWebView *view,WebKitContextMenu *menu,GdkEvent *event,WebKitHitTestResult *hit,gpointer data) {
    (void)view; (void)menu; (void)event; (void)hit; (void)data; return TRUE;
}
static gboolean policy(WebKitWebView *view,WebKitPolicyDecision *decision,WebKitPolicyDecisionType kind,gpointer data) {
    (void)view; ZwkState *s=data; retain(s); g_object_ref(decision);
    if (kind==WEBKIT_POLICY_DECISION_TYPE_NAVIGATION_ACTION || kind==WEBKIT_POLICY_DECISION_TYPE_NEW_WINDOW_ACTION) {
        WebKitNavigationAction *action=webkit_navigation_policy_decision_get_navigation_action(WEBKIT_NAVIGATION_POLICY_DECISION(decision));
        const char *uri=webkit_uri_request_get_uri(webkit_navigation_action_get_request(action));
        const gboolean redirected=webkit_navigation_action_is_redirect(action);
        gboolean allowed=FALSE;
        Navigation *op=s->navigation;
        if (op) navigation_ref(op);
        if (kind==WEBKIT_POLICY_DECISION_TYPE_NAVIGATION_ACTION && live(s) && initializers_allow_navigation(s) && uri) {
            if (op && !op->authorized && !redirected) {
                if (op->kind==NAV_BOOTSTRAP) allowed=s->remote && !s->remote->ready && !strcmp(uri,"about:blank");
                else allowed=trusted_uri(s,uri) && same_uri(s,uri,op->uri);
                if (allowed && op->kind==NAV_HISTORY)
                    allowed=webkit_navigation_action_get_navigation_type(action)==WEBKIT_NAVIGATION_TYPE_BACK_FORWARD &&
                        webkit_back_forward_list_get_current_item(s->history)==op->item;
                if (allowed && !op->prepared && op->kind!=NAV_BOOTSTRAP && op->kind!=NAV_FRAGMENT) {
                    const int result=prepare_document(s);
                    allowed=result==ZWK_OK && navigation_current(s,op);
                    if (result!=ZWK_OK && navigation_current(s,op)) navigation_fail(s,ZWK_POLICY_PREPARATION,"Navigation document preparation failed");
                }
            } else if (s->remote && s->remote->ready && !s->remote->failed && remote_navigate(s->remote,uri)) {
                if (redirected) allowed=op && op->prepared && s->remote->redirects;
                else if (!op && s->remote->script_navigation) {
                    const NavigationKind type=s->current_uri && s->committed && remote_fragment_change(s->remote,s->current_uri,uri)?NAV_FRAGMENT:NAV_REMOTE;
                    if (navigation_begin(s,type,uri,NULL)==ZWK_OK) {
                        op=s->navigation; navigation_ref(op);
                        op->issued=TRUE; op->saw_loading=webkit_web_view_is_loading(WEBKIT_WEB_VIEW(s->view));
                        allowed=type==NAV_FRAGMENT || prepare_document(s)==ZWK_OK;
                        allowed=allowed && navigation_current(s,op);
                        if (!allowed && navigation_current(s,op)) navigation_fail(s,ZWK_POLICY_PREPARATION,"Script navigation preparation failed");
                    }
                }
            }
        }
        if (allowed && navigation_current(s,op)) {
            op->authorized=TRUE; webkit_policy_decision_use(decision);
        } else {
            webkit_policy_decision_ignore(decision);
            unsigned bit=kind==WEBKIT_POLICY_DECISION_TYPE_NEW_WINDOW_ACTION?1:0;
            if (s->policy&(1u<<bit)) notify(s,3+(int)bit,uri,0,NULL);
        }
        if (op) navigation_release(op);
    } else if (kind==WEBKIT_POLICY_DECISION_TYPE_RESPONSE) {
        WebKitResponsePolicyDecision *response=WEBKIT_RESPONSE_POLICY_DECISION(decision);
        if (!live(s) || !webkit_response_policy_decision_is_mime_type_supported(response))
            webkit_policy_decision_ignore(decision);
        else webkit_policy_decision_use(decision);
    } else webkit_policy_decision_ignore(decision);
    g_object_unref(decision); release(s); return TRUE;
}
static void downloaded(WebKitWebContext *context,WebKitDownload *download,gpointer data) {
    (void)context; (void)data; webkit_download_cancel(download);
}
static void loaded(WebKitWebView *view,WebKitLoadEvent event,gpointer data) {
    ZwkState *s=data; retain(s);
    if (!live(s)) goto done;
    if(s->remote && !s->remote->ready){
        if(!s->remote->failed && event==WEBKIT_LOAD_FINISHED){if(s->navigation)s->navigation->finished=TRUE;navigation_clear(s);s->remote->bootstrap_loaded=TRUE;remote_start(s);}
        goto done;
    }
    Navigation *op=s->navigation;
    if (op) navigation_ref(op);
    uint64_t generation=s->generation;
    const char *uri=webkit_web_view_get_uri(view);
    if (event==WEBKIT_LOAD_STARTED) {
        if (!op || !op->prepared || !op->authorized) {
            navigation_fail(s,ZWK_POLICY_PREPARATION,"Full document started without prepared authorization");
            goto op_done;
        }
        op->started=TRUE; s->load_started=TRUE; s->loading_generation=generation; s->loading_serial=op->serial;
        s->loading_failure=(ZwkFailure){0};
        s->committed=FALSE; s->failed=FALSE; s->dom_ready=FALSE;
        if (!page(s,0,0,0,uri?uri:op->uri) && navigation_current(s,op) && s->generation==generation) {
            navigation_revoke(s);
            webkit_web_view_stop_loading(view);
        }
    } else if (event==WEBKIT_LOAD_COMMITTED) {
        if (revoked_load(s) && trusted_uri(s,uri)) goto op_done;
        if (!op || !op->started || !op->prepared || !current_uri_update(s)) {
            navigation_fail(s,ZWK_POLICY_PREPARATION,"Committed document has no valid current URI snapshot");
            goto op_done;
        }
        s->committed=TRUE;
        if (!page(s,3,1,0,s->current_uri) && live(s) && s->generation==generation) s->committed=FALSE;
        if (live(s) && s->generation==generation && s->committed && s->dom_ready) (void)page(s,2,0,0,NULL);
    } else if (event==WEBKIT_LOAD_FINISHED) {
        if (s->load_started && s->loading_generation==generation && s->loading_serial==s->navigation_serial && (!op || (op->started && op->serial==s->loading_serial))) {
            const int32_t status=s->failed?s->loading_failure.code:0;
            s->load_started=FALSE;
            s->loading_serial=0; s->revoked_load_serial=0; s->loading_failure=(ZwkFailure){0};
            const gboolean success=document(s);
            if (op) { op->finished=TRUE; navigation_clear(s); }
            (void)page(s,1,success?1:0,status,NULL);
            if (live(s) && s->generation==generation) history_notify(s);
        }
    }
op_done:
    if (op) navigation_release(op);
done:
    release(s);
}
static gboolean load_failed(WebKitWebView *view,WebKitLoadEvent event,const char *uri,GError *error,gpointer data) {
    (void)view; (void)event; (void)uri;
    ZwkState *s=data; retain(s);
    if (live(s) && s->load_started && s->loading_generation==s->generation && s->loading_serial==s->navigation_serial &&
        (!s->navigation || (s->navigation->started && s->navigation->serial==s->loading_serial))) {
        if (error) { failure_set(s,error); if (!s->loading_failure.domain) s->loading_failure=s->failure; }
        s->failed=TRUE; s->committed=FALSE;
        resources_cancel_all(s);
    }
    release(s); return TRUE;
}
static void process_failed(WebKitWebView *view,WebKitWebProcessTerminationReason reason,gpointer data) {
    (void)view; ZwkState *s=data; retain(s);
    s->failed=TRUE; s->committed=FALSE;
    s->load_started=FALSE; s->loading_serial=0; s->revoked_load_serial=0; s->loading_failure=(ZwkFailure){0};
    navigation_clear(s);
    resources_cancel_all(s);
    if(s->remote){s->remote->failed=TRUE;source_clear(&s->policy_timer);}
    notify(s,8,NULL,(int32_t)reason,NULL);
    release(s);
}
static void title_changed(GObject *view,GParamSpec *property,gpointer data) {
    (void)property; ZwkState *s=data; retain(s);
    if (document(s)) (void)page(s,4,0,0,webkit_web_view_get_title(WEBKIT_WEB_VIEW(view)));
    release(s);
}
static void source_changed(GObject *view,GParamSpec *property,gpointer data) {
    (void)property;ZwkState *s=data;retain(s);
    if (live(s) && !webkit_web_view_is_loading(WEBKIT_WEB_VIEW(view))) {
        if (s->navigation) navigation_settle(s);
        else if (s->committed && g_strcmp0(s->current_uri,webkit_web_view_get_uri(WEBKIT_WEB_VIEW(view)))) {
            if (!current_uri_update(s)) navigation_fail(s,ZWK_POLICY_PREPARATION,"Same-document URI snapshot failed");
            else (void)page(s,3,1,0,s->current_uri);
        }
    }
    release(s);
}
static void history_changed(WebKitBackForwardList *list,WebKitBackForwardListItem *added,GList *removed,gpointer data) {
    (void)list; (void)added; ZwkState *s=data; retain(s);
    Navigation *op=s->navigation;
    if (op && op->item && g_list_find(removed,op->item)) navigation_fail(s,ZWK_POLICY_PREPARATION,"Pending history target was removed");
    else if (live(s)) {
        navigation_settle(s);
        if (live(s)) history_notify(s);
    }
    release(s);
}
static void loading_changed(GObject *view,GParamSpec *property,gpointer data) {
    (void)property; ZwkState *s=data; retain(s);
    if (live(s) && s->navigation && s->navigation->issued) {
        if (webkit_web_view_is_loading(WEBKIT_WEB_VIEW(view))) s->navigation->saw_loading=TRUE;
        else navigation_settle(s);
    }
    release(s);
}
static void local_resource(WebKitURISchemeRequest *request,gpointer data) {
    ZwkState *s=data; retain(s);
    LocalData *local=&s->local; char path[4097];
    const char *method=webkit_uri_scheme_request_get_http_method(request);
    if (!live(s) || s->failed || webkit_uri_scheme_request_get_web_view(request)!=WEBKIT_WEB_VIEW(s->view) ||
        !local_uri(local->scheme,local->host,webkit_uri_scheme_request_get_uri(request),path) ||
        !local_request_allowed(local,method,webkit_uri_scheme_request_get_http_headers(request))) goto denied;
    const gboolean read_method=!strcmp(method,"GET") || !strcmp(method,"HEAD");
    const void *body="Not found"; size_t length=9; const char *mime="text/plain; charset=utf-8"; unsigned status=404;
    if (read_method && !strcmp(path,local->start_path)) {
        if (s->resources && s->resources->dynamic_document) { (void)resource_notify(s,request,method); release(s); return; }
        body=s->html; length=strlen(s->html); mime="text/html; charset=utf-8"; status=200;
    }
    else if (read_method) {
        unsigned low=0,high=local->count;
        while (low<high) {
            unsigned middle=low+(high-low)/2; const ZwkLocalResource *resource=&local->resources[middle];
            int order=strcmp(path,resource->path);
            if (order<0) high=middle;
            else if (order>0) low=middle+1;
            else { body=resource->bytes; length=resource->length; mime=resource->mime; status=200; break; }
        }
    }
    if (status==404 && resource_notify(s,request,method)) { release(s); return; }
    if (length>local->limit) goto denied;
    GInputStream *stream=local_stream(local->budget,body,!strcmp(method,"HEAD")?0:length);
    if (!stream) goto denied;
    WebKitURISchemeResponse *response=webkit_uri_scheme_response_new(stream,!strcmp(method,"HEAD")?0:(gint64)length);
    webkit_uri_scheme_response_set_status(response,status,status==200?"OK":"Not Found");
    webkit_uri_scheme_response_set_content_type(response,mime);
    SoupMessageHeaders *headers=soup_message_headers_new(SOUP_MESSAGE_HEADERS_RESPONSE);
    char content_length[32]; g_snprintf(content_length,sizeof(content_length),"%zu",length);
    soup_message_headers_append(headers,"Content-Length",content_length);
    soup_message_headers_append(headers,"Content-Type",mime);
    soup_message_headers_append(headers,"Content-Security-Policy",local->csp);
    soup_message_headers_append(headers,"Cache-Control","no-store");
    soup_message_headers_append(headers,"X-Content-Type-Options","nosniff");
    webkit_uri_scheme_response_set_http_headers(response,headers);
    webkit_uri_scheme_request_finish_with_response(request,response);
    /* set_http_headers takes ownership; response owns the header reference. */
    g_object_unref(response); g_object_unref(stream);
    release(s); return;
denied:
    webkit_uri_scheme_request_finish_error(request,local->denied);
    release(s);
}
static void message(WebKitUserContentManager *manager,WebKitJavascriptResult *result,gpointer data) {
    (void)manager; ZwkState *s=data; retain(s);
    JSCValue *value=webkit_javascript_result_get_js_value(result);
    GBytes *bytes=live(s) && jsc_value_is_string(value)?jsc_value_to_string_as_bytes(value):NULL;
    if (!bytes) goto done;
    gsize length=0;
    const char *text=g_bytes_get_data(bytes,&length);
    if (!text || length>65584 || memchr(text,0,length)) goto done;
    char prefix[48]; int count=snprintf(prefix,sizeof(prefix),"%llu|",(unsigned long long)s->generation);
    if (count<0 || (size_t)count>=sizeof(prefix) || length<=(size_t)count || memcmp(text,prefix,(size_t)count)) goto done;
    const char *body=text+count;
    size_t body_length=length-(size_t)count;
    if (body_length==1 && body[0]=='D') {
        s->dom_ready=TRUE;
        if (document(s)) (void)page(s,2,0,0,NULL);
    } else if (body[0]=='M' && body_length-1<=65536 && document(s) && s->notify && ipc_allowed(s)) {
        uint16_t *message_value=(uint16_t *)g_utf8_to_utf16(body+1,(glong)(body_length-1),NULL,NULL,NULL);
        if (message_value) { s->notify(s->owner,1,message_value,0,NULL); g_free(message_value); }
    }
done:
    if (bytes) g_bytes_unref(bytes);
    release(s);
}
static char *js_quote(const char *text) {
    size_t length=strlen(text), bytes=3;
    if (length>1024*1024) return NULL;
    for (size_t i=0;i<length;i++) bytes+=(text[i]=='"' || text[i]=='\\')?2:((unsigned char)text[i]<32?6:1);
    char *output=g_try_malloc(bytes);
    if (!output) return NULL;
    char *p=output; *p++='"';
    static const char hex[]="0123456789abcdef";
    for (size_t i=0;i<length;i++) {
        unsigned char c=(unsigned char)text[i];
        if (c=='"' || c=='\\') { *p++='\\'; *p++=(char)c; }
        else if (c<32) { memcpy(p,"\\u00",4); p+=4; *p++=hex[c>>4]; *p++=hex[c&15]; }
        else *p++=(char)c;
    }
    *p++='"'; *p=0; return output;
}
static char *try_format(const char *format, ...) {
    va_list args, copy;
    va_start(args,format); va_copy(copy,args);
    int length=vsnprintf(NULL,0,format,copy); va_end(copy);
    char *output=length>=0?g_try_malloc((size_t)length+1):NULL;
    if (output) vsnprintf(output,(size_t)length+1,format,args);
    va_end(args); return output;
}
static int prepare_document(ZwkState *s) {
    Navigation *op=s->navigation;
    if (!op || !live(s)) return ZWK_CLOSED;
    if(!initializers_allow_navigation(s))return ZWK_NAVIGATION_PENDING;
    if (s->generation==UINT64_MAX) return ZWK_FULL;
    char source_check[512];
    int condition=s->remote?snprintf(source_check,sizeof(source_check),"trusted.has(location.origin)"):(s->local.budget?snprintf(source_check,sizeof(source_check),"location.protocol==='%s:'&&location.hostname==='%s'&&location.port===''",s->local.scheme,s->local.host):snprintf(source_check,sizeof(source_check),"location.href==='about:blank'"));
    if (condition<0 || (size_t)condition>=sizeof(source_check)) return ZWK_INVALID;
    const char *format=
        "(()=>{%sconst send=x=>webkit.messageHandlers.ziggurat.postMessage('%llu|'+x);"
        "const valid=x=>{if(typeof x!=='string'||x.length>65536)return false;let bytes=0;"
        "for(const c of x){const p=c.codePointAt(0);if(!p)return false;bytes+=p<128?1:p<2048?2:p<65536?3:4;"
        "if(bytes>65536)return false}return true};"
        "addEventListener('message',e=>{if(e.isTrusted&&e.source===window&&window===top&&%s&&"
        "e.data&&valid(e.data.__ziggurat))send('M'+e.data.__ziggurat)});"
        "addEventListener('DOMContentLoaded',()=>send('D'),{once:true})})()";
    char ordinary[2048];char *private_script=ordinary,*preamble=NULL;
    if(s->remote){
        preamble=try_format("const trusted=new Set(%s.map(x=>new URL(x).origin));",s->remote->ipc_json);
        if(!preamble)return ZWK_OOM;
        private_script=try_format(format,preamble,(unsigned long long)(s->generation+1),source_check);g_free(preamble);
    }else{
        int length=snprintf(ordinary,sizeof(ordinary),format,"",(unsigned long long)(s->generation+1),source_check);
        if(length<0||(size_t)length>=sizeof(ordinary))return ZWK_INVALID;
    }
    if (!private_script) return ZWK_OOM;
    WebKitUserScript *private_value=webkit_user_script_new_for_world(private_script,WEBKIT_USER_CONTENT_INJECT_TOP_FRAME,
        WEBKIT_USER_SCRIPT_INJECT_AT_DOCUMENT_START,"ziggurat-private",NULL,NULL);
    if(s->remote)g_free(private_script);
    static const char public_script[]=
        "(()=>{const listeners=new Map;const transport=Object.freeze({"
        "postMessage(value){if(typeof value!=='string'||value.length>65536||value.includes('\\0'))throw TypeError('InvalidMessage');"
        "window.postMessage({__ziggurat:value},'*')},"
        "addEventListener(type,fn){if(type!=='message'||typeof fn!=='function'||listeners.has(fn))return;"
        "const wrap=e=>{if(e.source===window&&e.data&&typeof e.data.__zigguratHost==='string')fn({data:e.data.__zigguratHost})};"
        "listeners.set(fn,wrap);window.addEventListener('message',wrap)},"
        "removeEventListener(type,fn){if(type==='message'&&listeners.has(fn)){window.removeEventListener('message',listeners.get(fn));listeners.delete(fn)}}});"
        "if(!window.chrome)window.chrome={};Object.defineProperty(window.chrome,'webview',{value:transport})})()";
    WebKitUserScript *public_value=webkit_user_script_new(public_script,WEBKIT_USER_CONTENT_INJECT_TOP_FRAME,WEBKIT_USER_SCRIPT_INJECT_AT_DOCUMENT_START,NULL,NULL);
    navigation_ref(op);
    int result=ZWK_OK;
    const uint64_t generation=s->generation;
    s->committed=FALSE;
    /* Private invalidation never manufactures public STARTED or a PageId. All
     * accepted logical slots are taken before native document work proceeds. */
    if (generation && !page(s,6,0,0,NULL)) result=live(s)?ZWK_NAVIGATION_CANCELLED:ZWK_CLOSED;
    if (result==ZWK_OK && (!navigation_current(s,op) || s->generation!=generation)) result=live(s)?ZWK_NAVIGATION_CANCELLED:ZWK_CLOSED;
    if (result==ZWK_OK) {
        resources_cancel_all(s);
        if (!navigation_current(s,op) || s->generation!=generation) result=live(s)?ZWK_NAVIGATION_CANCELLED:ZWK_CLOSED;
    }
    if (result==ZWK_OK) {
        ++s->generation; op->prepared=TRUE; s->failed=FALSE; s->dom_ready=FALSE;
        /* Get the current batch only after the invalidation callbacks above.
         * Each registration has its own retained boxed identity. No callback
         * can lend an old batch across those foreign boundaries. */
        WebKitUserScript *batch=s->initializers?s->initializers->current:NULL;
        if(batch)webkit_user_script_ref(batch);
        WebKitUserScript *old_private=s->private_bootstrap,*old_public=s->public_bootstrap;
        s->private_bootstrap=private_value;s->public_bootstrap=public_value;
        webkit_user_script_ref(private_value);webkit_user_script_ref(public_value);
        if(old_private){webkit_user_content_manager_remove_script(s->manager,old_private);webkit_user_script_unref(old_private);}
        if(old_public){webkit_user_content_manager_remove_script(s->manager,old_public);webkit_user_script_unref(old_public);}
        if(batch)webkit_user_content_manager_remove_script(s->manager,batch);
        webkit_user_content_manager_add_script(s->manager,private_value);
        webkit_user_content_manager_add_script(s->manager,public_value);
        if(batch){webkit_user_content_manager_add_script(s->manager,batch);webkit_user_script_unref(batch);}
    }
    webkit_user_script_unref(public_value); webkit_user_script_unref(private_value);
    navigation_release(op); return result;
}
static void remote_fail(ZwkState *s,int code,const char *reason) {
    if(!live(s)||!s->remote||s->remote->failed)return;
    s->remote->failed=TRUE;s->failed=TRUE;s->committed=FALSE;
    s->load_started=FALSE;s->loading_serial=0;s->revoked_load_serial=0;s->loading_failure=(ZwkFailure){0};
    navigation_clear(s);
    source_clear(&s->initial);
    source_clear(&s->policy_timer);
    webkit_web_view_stop_loading(WEBKIT_WEB_VIEW(s->view));
    GError *error=g_error_new_literal(g_quark_from_static_string("ziggurat-webkit-request-policy"),code,reason);
    failure_set(s,error);g_error_free(error);
    notify(s,2,NULL,s->failure.code,&s->failure);
}
static void remote_start(ZwkState *s) {
    RemoteData *remote=s->remote;
    if(!live(s)||!remote||remote->failed||remote->ready||!remote->handshake||!remote->bootstrap_loaded)return;
    if(navigation_begin(s,NAV_REMOTE,remote->url,NULL)!=ZWK_OK || prepare_document(s)!=ZWK_OK){remote_fail(s,ZWK_POLICY_PREPARATION,"Document preparation failed");return;}
    remote->ready=TRUE;source_clear(&s->policy_timer);
    Navigation *op=s->navigation; navigation_ref(op);
    const uint64_t generation=s->generation;
    notify(s,0,NULL,0,NULL);
    if(navigation_current(s,op)&&s->generation==generation) {
        op->issued=TRUE; webkit_web_view_load_uri(WEBKIT_WEB_VIEW(s->view),op->uri);
    }
    navigation_release(op);
}
static gboolean remote_message(WebKitWebView *view,WebKitUserMessage *message_value,gpointer data) {
    if(strcmp(webkit_user_message_get_name(message_value),"ziggurat-request-policy-ready"))return FALSE;
    ZwkState *s=data;retain(s);
    if(live(s)&&s->remote&&!s->remote->failed){
        guint abi=0;guint64 id=0,page_id=0;gboolean valid=FALSE;
        GVariant *value=webkit_user_message_get_parameters(message_value);
        if(value&&g_variant_is_of_type(value,G_VARIANT_TYPE("(uttb)")))g_variant_get(value,"(uttb)",&abi,&id,&page_id,&valid);
        if(!valid||abi!=ZWK_POLICY_ABI||id!=s->remote->id||page_id!=webkit_web_view_get_page_id(view)||s->remote->handshake)
            remote_fail(s,ZWK_POLICY_MISMATCH,"Request policy handshake mismatch");
        else{s->remote->handshake=TRUE;remote_start(s);}
    }
    release(s);return TRUE;
}
static gboolean remote_timeout(gpointer data) {
    ZwkState *s=data;GSource *source=s->policy_timer;s->policy_timer=NULL;g_source_unref(source);
    remote_fail(s,ZWK_POLICY_TIMEOUT,"Request policy handshake timed out");return G_SOURCE_REMOVE;
}
static gboolean initialize(gpointer data) {
    ZwkState *s=data;
    GSource *source=s->initial; s->initial=NULL; g_source_unref(source);
    if(live(s) && !initializers_allow_navigation(s)){
        navigation_fail(s,ZWK_POLICY_PREPARATION,"Initializer registration unavailable");
    }else if(live(s)&&s->remote){
        s->remote->bootstrap=TRUE;
        if (navigation_begin(s,NAV_BOOTSTRAP,"about:blank",NULL)!=ZWK_OK) { remote_fail(s,ZWK_POLICY_PREPARATION,"Bootstrap preparation failed"); return G_SOURCE_REMOVE; }
        s->policy_timer=g_timeout_source_new(s->remote->timeout_ms);retain(s);
        g_source_set_callback(s->policy_timer,remote_timeout,s,release);g_source_attach(s->policy_timer,g_main_context_default());
        s->navigation->issued=TRUE;
        webkit_web_view_load_html(WEBKIT_WEB_VIEW(s->view),"",NULL);
    } else if (live(s)) {
        const int result=navigation_begin(s,NAV_INITIAL,s->local.budget?s->local.url:"about:blank",NULL);
        if (result!=ZWK_OK || prepare_document(s)!=ZWK_OK) navigation_fail(s,ZWK_POLICY_PREPARATION,"Initial document preparation failed");
        else {
            Navigation *op=s->navigation; navigation_ref(op);
            notify(s,0,NULL,0,NULL);
            if (navigation_current(s,op)) {
                op->issued=TRUE;
                if (s->local.budget) webkit_web_view_load_uri(WEBKIT_WEB_VIEW(s->view),op->uri);
                else webkit_web_view_load_html(WEBKIT_WEB_VIEW(s->view),s->html,NULL);
            }
            navigation_release(op);
        }
    }
    return G_SOURCE_REMOVE;
}
static int content_result(int result) {
    switch (result) {
        case ZLG_CONTENT_OK: return ZWK_OK;
        case ZLG_CONTENT_CLOSED: return ZWK_CLOSED;
        case ZLG_CONTENT_BUSY: return ZWK_FULL;
        case ZLG_CONTENT_INVALID: return ZWK_INVALID;
        case ZLG_CONTENT_OOM: return ZWK_OOM;
        default: return ZWK_NATIVE_FAILED;
    }
}
static int create(void *window,const ZwkOptions *options,uint32_t width,uint32_t height,gboolean session,ZwkNotify callback,ZwkPageNotify page_callback,ZwkScriptNotify script_callback,ZwkDeadline deadline,void *owner,ZwkState **out) {
    *out=NULL;
    if (!options || !options->html || options->max_pending==0 || options->max_pending>16 || options->max_result_bytes==0 ||
        options->max_result_bytes>1024*1024 || options->region>1 || strlen(options->html)>16*1024*1024 || (options->remote&&(options->local||*options->html)) || (!session&&!window) || (session&&options->region)) return ZWK_INVALID;
    ZwkState *s=g_try_new0(ZwkState,1);
    if (!s) return ZWK_OOM;
    s->thread=g_thread_self(); s->refs=1; g_atomic_int_inc(&live_states);
    s->session=session;
    if(options->remote){int result=remote_create(options->remote,&s->remote);if(result!=ZWK_OK){zwk_close(s);return result;}}
    if (options->local && !local_prepare(&s->local,options->local)) { zwk_close(s); return ZWK_OOM; }
    s->html=g_try_malloc(strlen(options->html)+1);
    if (!s->html) { zwk_close(s); return ZWK_OOM; }
    strcpy(s->html,options->html);
    s->owner=owner; s->notify=callback; s->page=page_callback; s->script=script_callback; s->deadline=deadline;
    s->limit=options->max_pending; s->result_limit=options->max_result_bytes; s->policy=options->policy_flags;
    if(options->initializers){
        int result=zwk_initializers_prepare(s,options->initializers,0,NULL);
        if(result!=ZWK_OK){zwk_close(s);return result;}
    }
    if (options->profile_context) {
        void *context=NULL;
        int result=zwk_profile_context_get(options->profile_context,&context);
        if (result!=ZWK_PROFILE_OK) {
            zwk_close(s);
            return result==ZWK_PROFILE_CLOSED?ZWK_CLOSED:ZWK_INVALID;
        }
        s->context=g_object_ref(context);
    } else s->context=webkit_web_context_new_ephemeral();
    if(s->remote){
        webkit_web_context_set_web_extensions_directory(s->context,s->remote->directory);
        ZwkRequestPolicy *policy_data=s->remote->requests;
        webkit_web_context_set_web_extensions_initialization_user_data(s->context,policy_data->storage);
    }
    if (s->local.budget) {
        retain(s); webkit_web_context_register_uri_scheme(s->context,s->local.scheme,local_resource,s,release);
        WebKitSecurityManager *security=webkit_web_context_get_security_manager(s->context);
        webkit_security_manager_register_uri_scheme_as_cors_enabled(security,s->local.scheme);
        if (options->local->secure) webkit_security_manager_register_uri_scheme_as_secure(security,s->local.scheme);
    }
    s->manager=webkit_user_content_manager_new();
    if (!webkit_user_content_manager_register_script_message_handler_in_world(s->manager,"ziggurat","ziggurat-private")) {
        zwk_close(s); return ZWK_NATIVE_FAILED;
    }
    static const char csp[]="default-src 'none'; script-src 'unsafe-inline' 'unsafe-eval'; style-src 'unsafe-inline'; img-src data: blob:; "
        "connect-src 'none'; frame-src 'none'; worker-src 'none'; object-src 'none'; base-uri 'none'; form-action 'none'";
    s->view=g_object_new(WEBKIT_TYPE_WEB_VIEW,"web-context",s->context,"user-content-manager",s->manager,
        "default-content-security-policy",s->remote?s->remote->csp:(s->local.budget?s->local.csp:csp),NULL);
    g_object_ref_sink(s->view); g_atomic_int_inc(&live_views);
    retain(s); g_object_weak_ref(G_OBJECT(s->view),view_finalized,s);
    WebKitSettings *settings=webkit_web_view_get_settings(WEBKIT_WEB_VIEW(s->view));
    webkit_settings_set_enable_developer_extras(settings,FALSE);
    webkit_settings_set_enable_fullscreen(settings,FALSE);
    webkit_settings_set_enable_webrtc(settings,FALSE);
    webkit_settings_set_enable_media_stream(settings,FALSE);
    /* These settings remain required on the supported 2.40 API baseline. */
    G_GNUC_BEGIN_IGNORE_DEPRECATIONS
    if (webkit_get_major_version()==2 && webkit_get_minor_version()<48)
        webkit_settings_set_enable_dns_prefetching(settings,FALSE);
    if (webkit_get_major_version()==2 && webkit_get_minor_version()<50)
        webkit_settings_set_enable_hyperlink_auditing(settings,FALSE);
    G_GNUC_END_IGNORE_DEPRECATIONS
    webkit_settings_set_allow_modal_dialogs(settings,FALSE);
    webkit_settings_set_javascript_can_access_clipboard(settings,FALSE);
    webkit_settings_set_enable_html5_database(settings,options->profile_context!=NULL);
    webkit_settings_set_enable_html5_local_storage(settings,options->profile_context!=NULL);
    webkit_settings_set_enable_page_cache(settings,FALSE);
    webkit_settings_set_allow_file_access_from_file_urls(settings,FALSE);
    webkit_settings_set_allow_universal_access_from_file_urls(settings,FALSE);
    if (options->user_agent) webkit_settings_set_user_agent(settings,options->user_agent);
    webkit_web_view_set_zoom_level(WEBKIT_WEB_VIEW(s->view),options->zoom);
    g_signal_connect(s->manager,"script-message-received::ziggurat",G_CALLBACK(message),s);
    g_signal_connect(s->context,"download-started",G_CALLBACK(downloaded),s);
    g_signal_connect(s->view,"decide-policy",G_CALLBACK(policy),s);
    if(s->remote)g_signal_connect(s->view,"user-message-received",G_CALLBACK(remote_message),s);
    g_signal_connect(s->view,"load-changed",G_CALLBACK(loaded),s);
    g_signal_connect(s->view,"load-failed",G_CALLBACK(load_failed),s);
    g_signal_connect(s->view,"web-process-terminated",G_CALLBACK(process_failed),s);
    g_signal_connect(s->view,"notify::title",G_CALLBACK(title_changed),s);
    if (s->local.budget || s->remote) {
        g_signal_connect(s->view,"notify::uri",G_CALLBACK(source_changed),s);
        g_signal_connect(s->view,"notify::is-loading",G_CALLBACK(loading_changed),s);
        s->history=g_object_ref(webkit_web_view_get_back_forward_list(WEBKIT_WEB_VIEW(s->view)));
        g_signal_connect(s->history,"changed",G_CALLBACK(history_changed),s);
    }
    g_signal_connect(s->view,"permission-request",G_CALLBACK(permission),s);
    g_signal_connect(s->view,"authenticate",G_CALLBACK(authentication),s);
    g_signal_connect(s->view,"script-dialog",G_CALLBACK(dialog),s);
    g_signal_connect(s->view,"run-file-chooser",G_CALLBACK(chooser),s);
    g_signal_connect(s->view,"print",G_CALLBACK(print_requested),s);
    g_signal_connect(s->view,"run-color-chooser",G_CALLBACK(color_chooser),s);
    g_signal_connect(s->view,"show-notification",G_CALLBACK(notification),s);
    g_signal_connect(s->view,"create",G_CALLBACK(popup),s);
    g_signal_connect(s->view,"context-menu",G_CALLBACK(context_menu),s);
    if (session) {
        int result=session_size(s,width,height,0,0);
        if (result!=ZWK_OK) { zwk_close(s); return result; }
        s->session_width=width; s->session_height=height;
    } else {
        int result=options->region?zlg_region_attach(window,s->view,&s->region):zlg_content_attach(window,s->view,&s->host);
        if (result!=ZLG_CONTENT_OK) { zwk_close(s); return content_result(result); }
    }
    if(options->initializers)zwk_initializers_activate(s);
    s->initial=g_idle_source_new(); retain(s);
    g_source_set_callback(s->initial,initialize,s,release);
    g_source_attach(s->initial,g_main_context_default());
    *out=s; return ZWK_OK;
}
int zwk_create(void *window,const ZwkOptions *options,ZwkNotify callback,ZwkPageNotify page_callback,ZwkScriptNotify script_callback,ZwkDeadline deadline,void *owner,ZwkState **out) {
    return create(window,options,0,0,FALSE,callback,page_callback,script_callback,deadline,owner,out);
}
int zwk_session_create(const ZwkOptions *options,uint32_t width,uint32_t height,ZwkNotify callback,ZwkPageNotify page_callback,ZwkScriptNotify script_callback,ZwkDeadline deadline,void *owner,ZwkState **out) {
    return create(NULL,options,width,height,TRUE,callback,page_callback,script_callback,deadline,owner,out);
}
void zwk_close(ZwkState *s) {
    if (s->closed) return;
    s->closed=TRUE; s->owner=NULL;
    find_state_close(s);
    initializers_cancel_all(s);
    capture_cancel_all(s);
    s->load_started=FALSE; s->loading_serial=0; s->revoked_load_serial=0; s->loading_failure=(ZwkFailure){0};
    navigation_clear(s);
    resources_cancel_all(s);
    source_clear(&s->initial); source_clear(&s->timer); source_clear(&s->policy_timer);
    for (Script *operation=s->scripts;operation;operation=operation->next) {
        operation->cancelled=TRUE; g_cancellable_cancel(operation->cancel);
    }
    if (s->manager) g_signal_handlers_disconnect_by_data(s->manager,s);
    if (s->context) g_signal_handlers_disconnect_by_data(s->context,s);
    if (s->view) g_signal_handlers_disconnect_by_data(s->view,s);
    if (s->history) g_signal_handlers_disconnect_by_data(s->history,s);
    g_clear_object(&s->history);
    ZlgContentHost *host=s->host; s->host=NULL;
    if (host) zlg_content_detach(host);
    ZlgRegionHost *region=s->region; s->region=NULL;
    if (region) zlg_region_detach(region);
    GtkWidget *view=s->view; s->view=NULL;
    if (view) { gtk_widget_destroy(view); g_object_unref(view); }
    g_clear_object(&s->manager); g_clear_object(&s->context);
    release(s);
}
static void evaluated(GObject *view,GAsyncResult *result,gpointer data) {
    Script *operation=data; ZwkState *s=operation->state;
    GError *error=NULL;
    JSCValue *value=webkit_web_view_evaluate_javascript_finish(WEBKIT_WEB_VIEW(view),result,&error);
    Script **link=&s->scripts;
    while (*link && *link!=operation) link=&(*link)->next;
    g_assert(*link==operation); *link=operation->next; --s->pending;
    if (live(s) && !operation->cancelled) {
        int status=0; char *json=NULL; uint16_t *utf16=NULL;
        if (error) { failure_set(s,error); status=1; }
        else if (!value || !jsc_value_is_array(value)) status=3;
        else {
            JSCValue *flag=jsc_value_object_get_property_at_index(value,0);
            status=jsc_value_to_int32(flag); g_object_unref(flag);
            if (!status) {
                JSCValue *body=jsc_value_object_get_property_at_index(value,1);
                if (jsc_value_is_string(body)) json=jsc_value_to_string(body);
                g_object_unref(body);
                if (!json) status=3;
                else if (strlen(json)>s->result_limit) status=2;
                else if (!(utf16=wide(json,s->result_limit))) status=3;
            }
        }
        if (live(s) && s->script) s->script(s->owner,operation->token,status,error?error->code:0,utf16,error?&s->failure:NULL);
        g_free(utf16); g_free(json);
    }
    if (value) g_object_unref(value);
    if (error) g_error_free(error);
    g_object_unref(operation->cancel); g_free(operation);
    g_atomic_int_add(&live_callbacks,-1); release(s);
}
int zwk_evaluate(ZwkState *s,const char *script,uint64_t token) {
    if (!live(s)) return ZWK_CLOSED;
    if (!document(s)) return ZWK_NOT_READY;
    if (s->pending>=s->limit) return ZWK_FULL;
    char *quoted=js_quote(script);
    if (!quoted) return ZWK_OOM;
    char *wrapped=try_format("(()=>{const value=(0,eval)(%s);let json=JSON.stringify(value);if(json===undefined)json='null';return json.length>%u?[2]:[0,json]})()",quoted,s->result_limit);
    g_free(quoted);
    if (!wrapped) return ZWK_OOM;
    Script *operation=g_try_new0(Script,1);
    if (!operation) { g_free(wrapped); return ZWK_OOM; }
    operation->state=s; operation->token=token; operation->cancel=g_cancellable_new();
    operation->next=s->scripts; s->scripts=operation; ++s->pending; retain(s); g_atomic_int_inc(&live_callbacks);
    webkit_web_view_evaluate_javascript(WEBKIT_WEB_VIEW(s->view),wrapped,-1,NULL,NULL,operation->cancel,evaluated,operation);
    g_free(wrapped); return ZWK_OK;
}
void zwk_evaluate_cancel(ZwkState *s,uint64_t token) {
    for (Script *operation=s->scripts;operation;operation=operation->next) if (operation->token==token) {
        operation->cancelled=TRUE; g_cancellable_cancel(operation->cancel); return;
    }
}
static void sent(GObject *view,GAsyncResult *result,gpointer data) {
    ZwkState *s=data; GError *error=NULL;
    JSCValue *value=webkit_web_view_evaluate_javascript_finish(WEBKIT_WEB_VIEW(view),result,&error);
    if (value) g_object_unref(value);
    if (error) g_error_free(error);
    --s->pending; g_atomic_int_add(&live_callbacks,-1); release(s);
}
int zwk_post(ZwkState *s,const char *text) {
    if (!live(s)) return ZWK_CLOSED;
    if (!document(s)) return ZWK_NOT_READY;
    if (!ipc_allowed(s)) return ZWK_IPC_DENIED;
    if (s->pending>=s->limit) return ZWK_FULL;
    char *quoted=js_quote(text); if (!quoted) return ZWK_OOM;
    char *script=try_format("window.postMessage({__zigguratHost:%s},'*')",quoted); g_free(quoted);
    if (!script) return ZWK_OOM;
    ++s->pending; retain(s); g_atomic_int_inc(&live_callbacks);
    webkit_web_view_evaluate_javascript(WEBKIT_WEB_VIEW(s->view),script,-1,NULL,NULL,NULL,sent,s);
    g_free(script); return ZWK_OK;
}
int zwk_zoom(ZwkState *s,double *value,int write) {
    if (!live(s)) return ZWK_CLOSED;
    if (write) webkit_web_view_set_zoom_level(WEBKIT_WEB_VIEW(s->view),*value);
    else *value=webkit_web_view_get_zoom_level(WEBKIT_WEB_VIEW(s->view));
    return ZWK_OK;
}
int zwk_user_agent(ZwkState *s,const char *set,char **get) {
    if (!live(s)) return ZWK_CLOSED;
    WebKitSettings *settings=webkit_web_view_get_settings(WEBKIT_WEB_VIEW(s->view));
    if (set) webkit_settings_set_user_agent(settings,*set?set:NULL);
    if (get) { const char *value=webkit_settings_get_user_agent(settings); *get=g_try_malloc(strlen(value)+1); if (!*get) return ZWK_OOM; strcpy(*get,value); }
    return ZWK_OK;
}
void zwk_string_free(char *value) { g_free(value); }
static gboolean deadline_ready(gpointer data) {
    ZwkState *s=data; GSource *source=s->timer; s->timer=NULL; g_source_unref(source);
    if (live(s) && s->deadline) s->deadline(s->owner);
    return G_SOURCE_REMOVE;
}
int zwk_deadline_arm(ZwkState *s,uint64_t nanoseconds) {
    if (!live(s)) return ZWK_CLOSED;
    if (nanoseconds>UINT64_C(600000000000)) return ZWK_INVALID;
    uint64_t milliseconds=(nanoseconds+999999)/1000000;
    source_clear(&s->timer);
    s->timer=g_timeout_source_new((guint)MAX(milliseconds,1)); retain(s);
    g_source_set_callback(s->timer,deadline_ready,s,release);
    g_source_attach(s->timer,g_main_context_default()); return ZWK_OK;
}
void zwk_deadline_cancel(ZwkState *s) { source_clear(&s->timer); }
static int navigation_submit(ZwkState *s,NavigationKind kind,const char *uri,WebKitBackForwardListItem *item) {
    if(!initializers_allow_navigation(s))return ZWK_NAVIGATION_PENDING;
    if (s->navigation || s->load_started || webkit_web_view_is_loading(WEBKIT_WEB_VIEW(s->view))) return ZWK_NAVIGATION_PENDING;
    int result=navigation_begin(s,kind,uri,item);
    if (result!=ZWK_OK) return result;
    Navigation *op=s->navigation; navigation_ref(op);
    if (kind!=NAV_HISTORY && kind!=NAV_FRAGMENT) result=prepare_document(s);
    if (result==ZWK_OK && navigation_current(s,op)) {
        op->issued=TRUE;
        if (kind==NAV_HISTORY) webkit_web_view_go_to_back_forward_list_item(WEBKIT_WEB_VIEW(s->view),op->item);
        else if (kind==NAV_REFRESH && (s->local.budget || s->remote)) webkit_web_view_reload(WEBKIT_WEB_VIEW(s->view));
        else if (kind==NAV_REFRESH && !s->local.budget && !s->remote) webkit_web_view_load_html(WEBKIT_WEB_VIEW(s->view),s->html,NULL);
        else webkit_web_view_load_uri(WEBKIT_WEB_VIEW(s->view),op->uri);
        if (!live(s)) result=ZWK_CLOSED;
        else if (op->cancelled) result=ZWK_NAVIGATION_CANCELLED;
    } else if (result==ZWK_OK) result=live(s)?ZWK_NAVIGATION_CANCELLED:ZWK_CLOSED;
    if (result!=ZWK_OK && s->navigation==op) navigation_clear(s);
    navigation_release(op); return result;
}
int zwk_refresh(ZwkState *s) {
    retain(s);
    const int result=!live(s)?ZWK_CLOSED:(s->navigation || s->load_started || webkit_web_view_is_loading(WEBKIT_WEB_VIEW(s->view)))?ZWK_NAVIGATION_PENDING:
        !document(s) || !s->current_uri?ZWK_NOT_READY:navigation_submit(s,NAV_REFRESH,s->current_uri,NULL);
    release(s); return result;
}
int zwk_navigate_remote(ZwkState *s,const char *uri) {
    retain(s); int result;
    if (!live(s)) result=ZWK_CLOSED;
    else if (!s->remote || !s->remote->ready || s->remote->failed) result=ZWK_NOT_READY;
    else if (!remote_navigate(s->remote,uri)) result=ZWK_IPC_DENIED;
    else {
        const NavigationKind kind=document(s) && s->current_uri && remote_fragment_change(s->remote,s->current_uri,uri)?NAV_FRAGMENT:NAV_REMOTE;
        result=navigation_submit(s,kind,uri,NULL);
    }
    release(s); return result;
}
int zwk_navigate_local(ZwkState *s,const char *path) {
    retain(s); int result;
    if (!live(s)) result=ZWK_CLOSED;
    else if (!s->local.budget || !local_route(path)) result=ZWK_INVALID;
    else {
        char uri[4400];
        const int length=g_snprintf(uri,sizeof(uri),"%s://%s%s",s->local.scheme,s->local.host,path);
        result=length<0 || (size_t)length>=sizeof(uri)?ZWK_INVALID:navigation_submit(s,NAV_LOCAL,uri,NULL);
    }
    release(s); return result;
}
int zwk_history(ZwkState *s,int forward) {
    retain(s); int result;
    if (!live(s)) result=ZWK_CLOSED;
    else if (!s->history || (!s->local.budget && !s->remote)) result=ZWK_NOT_READY;
    else if (s->navigation || s->load_started) result=ZWK_NAVIGATION_PENDING;
    else if (!document(s)) result=ZWK_NOT_READY;
    else if (webkit_web_view_is_loading(WEBKIT_WEB_VIEW(s->view))) result=ZWK_NAVIGATION_PENDING;
    else {
        WebKitBackForwardListItem *item=forward?webkit_back_forward_list_get_forward_item(s->history):webkit_back_forward_list_get_back_item(s->history);
        const char *uri=item?webkit_back_forward_list_item_get_uri(item):NULL;
        result=!item?ZWK_NO_HISTORY:!trusted_uri(s,uri)?ZWK_IPC_DENIED:navigation_submit(s,NAV_HISTORY,uri,item);
    }
    release(s); return result;
}
int zwk_stop(ZwkState *s) {
    retain(s);
    int result=ZWK_CLOSED;
    if (live(s)) {
        navigation_revoke(s);
        webkit_web_view_stop_loading(WEBKIT_WEB_VIEW(s->view)); result=ZWK_OK;
    }
    release(s); return result;
}
int zwk_focus(ZwkState *s) {
    retain(s);
    int result=ZWK_CLOSED;
    if (live(s)) result=s->region?content_result(zlg_region_focus(s->region)):s->host?content_result(zlg_content_focus(s->host)):ZWK_CLOSED;
    release(s); return result;
}
static int floor_scale(int value, int scale) {
    int quotient=value/scale, remainder=value%scale;
    return quotient-(remainder<0);
}
static int ceil_scale(int value, int scale) {
    int quotient=value/scale, remainder=value%scale;
    return quotient+(remainder>0);
}
int zwk_viewport(ZwkState *s, int32_t left, int32_t top, int32_t right, int32_t bottom, int visible) {
    retain(s);
    int result=ZWK_CLOSED;
    if (live(s) && s->region && s->view) {
        int scale=MAX(1,gtk_widget_get_scale_factor(s->view));
        int x=floor_scale(left,scale), y=floor_scale(top,scale);
        int64_t width=(int64_t)ceil_scale(right,scale)-x, height=(int64_t)ceil_scale(bottom,scale)-y;
        if (right<left || bottom<top || width>32768 || height>32768) result=ZWK_INVALID;
        else result=content_result(zlg_region_viewport(s->region,x,y,(int)width,(int)height,visible && right>left && bottom>top));
    }
    release(s); return result;
}
#include "webkit_session_impl.h"
int zwk_recovery_begin(ZwkState *s) {
    if (s->closed) return ZWK_CLOSED;
    if(s->initializers && s->initializers->pending)return ZWK_NAVIGATION_PENDING;
    if (s->recovering) return ZWK_FULL;
    s->recovering=TRUE; retain(s); return ZWK_OK;
}
void zwk_recovery_cancel(ZwkState *s) { s->recovering=FALSE; release(s); }
void zwk_recovery_dispatch(ZwkState *s) {
    s->recovering=FALSE;
    notify(s,9,NULL,0,NULL);
    release(s);
}
ZwkState *zwk_recovery_anchor(ZwkNotify callback,void *owner) {
    ZwkState *s=g_try_new0(ZwkState,1);
    if (!s) return NULL;
    s->thread=g_thread_self(); s->refs=1; s->owner=owner; s->notify=callback;
    g_atomic_int_inc(&live_states); return s;
}
