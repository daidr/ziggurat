#include <webkit2/webkit-web-extension.h>
#if !WEBKIT_CHECK_VERSION(2,40,0)
#error "Ziggurat requires WebKitGTK API 4.1 version 2.40 or newer"
#endif
#include "webkit_request_policy.h"

typedef struct PagePolicy {
    ZwkRequestPolicy *policy;
    guint64 allowed,denied,redirected;
} PagePolicy;
static void page_policy_free(gpointer value,GClosure *closure) {
    (void)closure; PagePolicy *page=value;
    zwk_request_policy_unref(page->policy); g_free(page);
}
static void count_one(guint64 *count) { if (*count<G_MAXUINT64) ++*count; }
static gboolean deny_request(WebKitWebPage *page,WebKitURIRequest *request,WebKitURIResponse *redirect,gpointer data) {
    (void)page; (void)request; (void)redirect; (void)data; return TRUE;
}
static gboolean before_request(WebKitWebPage *page,WebKitURIRequest *request,WebKitURIResponse *redirect,gpointer data) {
    (void)page; PagePolicy *state=data;
    ZwkRequestDecision decision=zwk_request_policy_prepare(state->policy,webkit_uri_request_get_uri(request),
        webkit_uri_request_get_http_method(request),webkit_uri_request_get_http_headers(request));
    if (redirect) count_one(&state->redirected);
    count_one(decision==ZWK_REQUEST_ALLOW?&state->allowed:&state->denied);
    return decision!=ZWK_REQUEST_ALLOW;
}
static gboolean host_message(WebKitWebPage *page,WebKitUserMessage *message,gpointer data) {
    (void)page; PagePolicy *state=data;
    if (strcmp(webkit_user_message_get_name(message),"ziggurat-request-policy-stats")) return FALSE;
    webkit_user_message_send_reply(message,webkit_user_message_new("ziggurat-request-policy-stats",
        g_variant_new("(ttt)",state->allowed,state->denied,state->redirected)));
    return TRUE;
}
static void page_created(WebKitWebExtension *extension,WebKitWebPage *page,gpointer data) {
    (void)extension; ZwkRequestPolicy *policy=data;
    PagePolicy *state=g_try_new0(PagePolicy,1);
    if (state) {
        state->policy=zwk_request_policy_ref(policy);
        g_signal_connect_data(page,"send-request",G_CALLBACK(before_request),state,page_policy_free,0);
        g_signal_connect(page,"user-message-received",G_CALLBACK(host_message),state);
    } else {
        /* No policy or storage must never turn into default network access. */
        g_signal_connect(page,"send-request",G_CALLBACK(deny_request),NULL);
    }
    webkit_web_page_send_message_to_view(page,webkit_user_message_new("ziggurat-request-policy-ready",
        g_variant_new("(uttb)",ZWK_POLICY_ABI,policy?policy->id:0,webkit_web_page_get_id(page),state && policy)),NULL,NULL,NULL);
}
static void extension_policy_free(gpointer value,GClosure *closure) { (void)closure; zwk_request_policy_unref(value); }
G_MODULE_EXPORT void webkit_web_extension_initialize_with_user_data(WebKitWebExtension *extension,const GVariant *data) {
    ZwkRequestPolicy *policy=zwk_request_policy_new((GVariant *)data);
    g_signal_connect_data(extension,"page-created",G_CALLBACK(page_created),policy,extension_policy_free,0);
}
