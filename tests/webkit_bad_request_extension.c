#include <webkit2/webkit-web-extension.h>
/* Test-only incompatible adapter: the host must reject its acknowledgement
   before issuing any application request. No production test switch exists. */
static void created(WebKitWebExtension *extension,WebKitWebPage *page,gpointer data){
    (void)extension;(void)data;
    webkit_web_page_send_message_to_view(page,webkit_user_message_new("ziggurat-request-policy-ready",g_variant_new("(uttb)",999u,(guint64)1,webkit_web_page_get_id(page),TRUE)),NULL,NULL,NULL);
}
G_MODULE_EXPORT void webkit_web_extension_initialize_with_user_data(WebKitWebExtension *extension,const GVariant *data){
    (void)data;g_signal_connect(extension,"page-created",G_CALLBACK(created),NULL);
}
