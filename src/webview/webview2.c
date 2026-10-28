/* COM ownership and native request enforcement. Public configuration, View
   lifecycle and application state live in Zig. Late handlers fail closed. */
#define COBJMACROS
#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <WebView2.h>
#include <stdlib.h>
#include <wchar.h>
#include <stdint.h>
#include <shlwapi.h>
#include <stdio.h>
#define MAX_PAGE_URI_UNITS 16384
/* Prefix of the page-facts script's messages; see page_facts.zig. */
#define FACTS_MARKER L"\x01ziggurat-facts:"
#define FACTS_MARKER_UNITS 16
static BOOL bounded_uri(const WCHAR *uri) { return uri && wcsnlen(uri, MAX_PAGE_URI_UNITS + 1) <= MAX_PAGE_URI_UNITS; }
#include "remote_policy.h"
#include "initializers_types.h"
#include "windows_profile.h"

static LONG live_states, live_handlers, owned_controllers;
#include "schemes.h"
#include "actions_types.h"
void zwv_resource_counts(uint32_t *states, uint32_t *handlers, uint32_t *controllers) {
    *states = (uint32_t)InterlockedCompareExchange(&live_states, 0, 0);
    *handlers = (uint32_t)InterlockedCompareExchange(&live_handlers, 0, 0);
    *controllers = (uint32_t)InterlockedCompareExchange(&owned_controllers, 0, 0);
}

typedef void (*Notify)(void *, int, const WCHAR *, HRESULT);
typedef void (*ScriptNotify)(void *, uint64_t, HRESULT, const WCHAR *);
typedef struct ScriptHandler ScriptHandler;
typedef struct ToolOperation ToolOperation;
typedef struct DeferredResource DeferredResource;
typedef struct FileControl FileControl;
typedef void (*ToolNotify)(void *,uint64_t,uint32_t,HRESULT,const void *,uint32_t);
/* An HTTP sign-in: the request's URI and the server's challenge. zwv_auth_answer
   answers it during the call; not answered, it goes without credentials. */
typedef void (*AuthOffer)(void *,const WCHAR *,const WCHAR *,void *);
/* A certificate error: URI, COREWEBVIEW2_WEB_ERROR_STATUS and the PEM
   certificate. Nonzero allows it for the host until the browser ends. */
typedef int (*CertificateOffer)(void *,const WCHAR *,int32_t,const WCHAR *);
/* A page's context menu: what was clicked, the engine's top-level items
   (flags 1 enabled, 2 checked) and keep, one per item, which the app clears
   to leave one out. zwv_context_menu_append adds the app's items during the
   call. Nonzero shows no menu. */
typedef struct ContextItemInput { const WCHAR *name; const WCHAR *label; uint32_t kind; uint32_t flags; } ContextItemInput;
typedef struct ContextTargetInput { const WCHAR *link, *link_text, *image, *media, *selection, *frame; uint32_t editable; } ContextTargetInput;
typedef int (*ContextMenuOffer)(void *,const ContextTargetInput *,const ContextItemInput *,uint32_t,uint8_t *,void *);
typedef struct ViewSettings { double zoom; const WCHAR *user_agent; _Bool devtools; uint32_t tool_flags,tool_limit,max_cookies,max_cookie_bytes,max_capture_bytes; const SchemeInput *schemes;uint32_t scheme_count;_Bool local_ipc;const ActionInput *actions;const InitializerInput *initializers; ZwpwContext *owned_context; const WCHAR *facts; const WCHAR *browser_arguments; AuthOffer auth; CertificateOffer certificate_offer; uint32_t context_menu; ContextMenuOffer context_offer; uint32_t gestures; } ViewSettings;
typedef void (*Resource)(void *, const WCHAR *, const WCHAR *, const NativeHeader *, uint32_t, void *);
typedef struct PageEvent {
    int kind;
    uint64_t navigation_id;
    uint32_t flags;
    int32_t status;
    const WCHAR *value;
} PageEvent;
typedef int (*PageNotify)(void *, const PageEvent *);
typedef void (*SeedNotify)(void *, HRESULT);
typedef struct State State;
struct State {
    LONG refs;
    BOOL closed;
    HWND hwnd;
    BOOL has_viewport, viewport_visible;
    RECT viewport;
    ICoreWebView2Environment *environment;
    ZwpwContext *owned_context;
    ICoreWebView2_14 *tls_webview;
    EventRegistrationToken server_certificate_token;
    BOOL has_server_certificate;
    ICoreWebView2EnvironmentOptions *environment_options;
    ICoreWebView2Controller *controller;
    ICoreWebView2 *webview;
    ICoreWebView2_4 *webview4;
    ICoreWebView2_22 *webview22;
    ICoreWebView2_10 *webview10;
    ICoreWebView2_5 *webview5;
    RemotePolicy remote;
    ActionPolicy *actions;
    PermissionPending *permission_requests;
    DownloadPending *download_requests;
    ScriptHandler *scripts;
    uint32_t script_count, script_limit;
    ScriptNotify script_notify;
    InitializerState *initializers;
    double zoom;
    WCHAR *user_agent;
    BOOL devtools;
    ToolOperation *tools;
    uint32_t tool_count,tool_limit,tool_flags,max_cookies,max_cookie_bytes,max_capture_bytes;
    ToolNotify tool_notify;
    ICoreWebView2Find *find;
    uint64_t find_token;
    BOOL find_ready;
    EventRegistrationToken find_match_token,find_index_token;
    BOOL has_find_match,has_find_index;
    ICoreWebView2Profile4 *profile;
    ICoreWebView2PermissionSettingCollectionView *permissions;
    UINT32 permission_index, permission_count;
    UINT32 permission_limit;
    EventRegistrationToken message_token, navigation_token, frame_token, resource_token;
    EventRegistrationToken popup_token, permission_token, download_token, process_token;
    EventRegistrationToken completed_token, dom_token, source_token, title_token, history_token, content_token;
    EventRegistrationToken authentication_token, certificate_token;
    BOOL has_message, has_navigation, has_frame, has_resource;
    BOOL has_popup, has_permission, has_download, has_process;
    BOOL has_completed, has_dom, has_source, has_title, has_history, has_content;
    BOOL has_authentication, has_certificate;
    WCHAR *facts_script;
    BOOL facts_added;
    AuthOffer auth;
    CertificateOffer certificate_offer;
    /* 1 swipe between pages, 2 pinch zoom; both off unless asked. */
    uint32_t gestures;
    /* 0 no menu, 1 the engine's, 2 the app's offer changes it. */
    uint32_t context_menu;
    ContextMenuOffer context_offer;
    ICoreWebView2_11 *webview11;
    EventRegistrationToken context_token;
    BOOL has_context;
    /* WebView2's command ids of the app's items in the menu shown last. */
    INT32 context_native[32];
    uint32_t context_command[32], context_count;
    WCHAR *html;
    WCHAR *document_source;
    WCHAR *initial_url, *local_prefix;
    BOOL custom_site, local_ipc;
    WCHAR *expected_url;
    BOOL expected_refresh, expected_history, allow_local_navigation, navigating;
    uint64_t navigation_id;
    BOOL has_document, committed;
    BOOL observe_metadata;
    BOOL initial_navigation;
    BOOL recovering;
    unsigned policy;
    Notify notify;
    Resource resource;
    ICoreWebView2WebResourceResponse *denied_response;
    DeferredResource *resources;
    uint32_t resource_count;
    FileControl *file_controls[8];
    PageNotify page_notify;
    SeedNotify seed_notify;
    void *seed_context;
    void *context;
};
static void file_controls_close(State *);
static void state_cleanup(State *);
static void owned_initialization_failed(State *,HRESULT);
static void initializers_fail_before_submit(State *);
static void retain(State *s) { InterlockedIncrement(&s->refs); }
static void release(State *s) {
    if (InterlockedDecrement(&s->refs) == 0) {
        remote_deinit(&s->remote);
        initializers_free(s->initializers);
        action_policy_free(s->actions);
        if (s->environment_options) ICoreWebView2EnvironmentOptions_Release(s->environment_options);
        if (s->owned_context) zwpw_context_unref(s->owned_context);
        free(s->facts_script); free(s->html); free(s->document_source); free(s->initial_url); free(s->local_prefix); free(s->expected_url); free(s->user_agent); free(s);
        InterlockedDecrement(&live_states);
    }
}
static void notify(State *s, int kind, const WCHAR *value, HRESULT hr) {
    retain(s);
    if (!s->closed&&kind==2&&s->owned_context&&zwpw_context_is_pending(s->owned_context)) {
        zwpw_context_fail(s->owned_context,hr);release(s);return;
    }
    if (kind==2) initializers_fail_before_submit(s);
    /* A queued replacement owns the next state transition. Suppress late
       events from its old controller while resource callbacks keep serving the
       old immutable config until close. Cancellation restores ordinary events. */
    if (!s->closed && (!s->recovering || kind == 9)) s->notify(s->context, kind, value, hr);
    release(s);
}
static BOOL page_notify(State *s, int kind, uint64_t id, uint32_t flags, int32_t status, const WCHAR *value) {
    retain(s);
    PageEvent event = { kind, id, flags, status, value };
    BOOL accepted = FALSE;
    if (!s->closed && !s->recovering && s->page_notify) accepted = s->page_notify(s->context, &event) != 0;
    release(s);
    return accepted;
}
static BOOL local_source(State *s,const WCHAR *uri) {
    return bounded_uri(uri)&&s->local_prefix&&(s->custom_site?scheme_uri_matches(uri,s->local_prefix):wcsncmp(uri,s->local_prefix,wcslen(s->local_prefix))==0);
}

/* Each callback has its own COM refcount and retains State through async close. */
#define HANDLER(Name, Interface, Id) \
    typedef struct Name { Interface iface; LONG refs; State *state; } Name; \
    static HRESULT STDMETHODCALLTYPE Name##_query(Interface *p, REFIID iid, void **out) { \
        if (!out) return E_POINTER; *out = NULL; \
        if (!IsEqualIID(iid, &IID_IUnknown) && !IsEqualIID(iid, &Id)) return E_NOINTERFACE; \
        *out = p; InterlockedIncrement(&((Name *)p)->refs); return S_OK; \
    } \
    static ULONG STDMETHODCALLTYPE Name##_add(Interface *p) { return InterlockedIncrement(&((Name *)p)->refs); } \
    static ULONG STDMETHODCALLTYPE Name##_release(Interface *p) { \
        Name *h = (Name *)p; LONG refs = InterlockedDecrement(&h->refs); \
        if (!refs) { release(h->state); free(h); InterlockedDecrement(&live_handlers); } return refs; \
    }

HANDLER(EnvironmentHandler, ICoreWebView2CreateCoreWebView2EnvironmentCompletedHandler, IID_ICoreWebView2CreateCoreWebView2EnvironmentCompletedHandler)
HANDLER(ControllerHandler, ICoreWebView2CreateCoreWebView2ControllerCompletedHandler, IID_ICoreWebView2CreateCoreWebView2ControllerCompletedHandler)
HANDLER(MessageHandler, ICoreWebView2WebMessageReceivedEventHandler, IID_ICoreWebView2WebMessageReceivedEventHandler)
HANDLER(NavigationHandler, ICoreWebView2NavigationStartingEventHandler, IID_ICoreWebView2NavigationStartingEventHandler)
HANDLER(FrameHandler, ICoreWebView2NavigationStartingEventHandler, IID_ICoreWebView2NavigationStartingEventHandler)
HANDLER(ResourceHandler, ICoreWebView2WebResourceRequestedEventHandler, IID_ICoreWebView2WebResourceRequestedEventHandler)
HANDLER(PopupHandler, ICoreWebView2NewWindowRequestedEventHandler, IID_ICoreWebView2NewWindowRequestedEventHandler)
HANDLER(PermissionHandler, ICoreWebView2PermissionRequestedEventHandler, IID_ICoreWebView2PermissionRequestedEventHandler)
HANDLER(ContextMenuHandler, ICoreWebView2ContextMenuRequestedEventHandler, IID_ICoreWebView2ContextMenuRequestedEventHandler)
HANDLER(ContextItemHandler, ICoreWebView2CustomItemSelectedEventHandler, IID_ICoreWebView2CustomItemSelectedEventHandler)
HANDLER(DownloadHandler, ICoreWebView2DownloadStartingEventHandler, IID_ICoreWebView2DownloadStartingEventHandler)
HANDLER(ProcessHandler, ICoreWebView2ProcessFailedEventHandler, IID_ICoreWebView2ProcessFailedEventHandler)
HANDLER(PermissionsHandler, ICoreWebView2GetNonDefaultPermissionSettingsCompletedHandler, IID_ICoreWebView2GetNonDefaultPermissionSettingsCompletedHandler)
HANDLER(ResetPermissionHandler, ICoreWebView2SetPermissionStateCompletedHandler, IID_ICoreWebView2SetPermissionStateCompletedHandler)
HANDLER(SeedPermissionHandler, ICoreWebView2SetPermissionStateCompletedHandler, IID_ICoreWebView2SetPermissionStateCompletedHandler)
HANDLER(DevToolsCallHandler, ICoreWebView2CallDevToolsProtocolMethodCompletedHandler, IID_ICoreWebView2CallDevToolsProtocolMethodCompletedHandler)
HANDLER(CompletedHandler, ICoreWebView2NavigationCompletedEventHandler, IID_ICoreWebView2NavigationCompletedEventHandler)
HANDLER(DomHandler, ICoreWebView2DOMContentLoadedEventHandler, IID_ICoreWebView2DOMContentLoadedEventHandler)
HANDLER(SourceHandler, ICoreWebView2SourceChangedEventHandler, IID_ICoreWebView2SourceChangedEventHandler)
HANDLER(TitleHandler, ICoreWebView2DocumentTitleChangedEventHandler, IID_ICoreWebView2DocumentTitleChangedEventHandler)
HANDLER(HistoryHandler, ICoreWebView2HistoryChangedEventHandler, IID_ICoreWebView2HistoryChangedEventHandler)
HANDLER(ContentHandler, ICoreWebView2ContentLoadingEventHandler, IID_ICoreWebView2ContentLoadingEventHandler)
HANDLER(AuthenticationHandler, ICoreWebView2BasicAuthenticationRequestedEventHandler, IID_ICoreWebView2BasicAuthenticationRequestedEventHandler)
HANDLER(CertificateHandler, ICoreWebView2ClientCertificateRequestedEventHandler, IID_ICoreWebView2ClientCertificateRequestedEventHandler)
HANDLER(ServerCertificateHandler, ICoreWebView2ServerCertificateErrorDetectedEventHandler, IID_ICoreWebView2ServerCertificateErrorDetectedEventHandler)
HANDLER(FindMatchHandler, ICoreWebView2FindMatchCountChangedEventHandler, IID_ICoreWebView2FindMatchCountChangedEventHandler)
HANDLER(FindIndexHandler, ICoreWebView2FindActiveMatchIndexChangedEventHandler, IID_ICoreWebView2FindActiveMatchIndexChangedEventHandler)
HANDLER(FactsHandler, ICoreWebView2AddScriptToExecuteOnDocumentCreatedCompletedHandler, IID_ICoreWebView2AddScriptToExecuteOnDocumentCreatedCompletedHandler)

static HRESULT STDMETHODCALLTYPE environment_invoke(ICoreWebView2CreateCoreWebView2EnvironmentCompletedHandler *, HRESULT, ICoreWebView2Environment *);
static HRESULT STDMETHODCALLTYPE controller_invoke(ICoreWebView2CreateCoreWebView2ControllerCompletedHandler *, HRESULT, ICoreWebView2Controller *);
static HRESULT STDMETHODCALLTYPE message_invoke(ICoreWebView2WebMessageReceivedEventHandler *, ICoreWebView2 *, ICoreWebView2WebMessageReceivedEventArgs *);
static HRESULT STDMETHODCALLTYPE navigation_invoke(ICoreWebView2NavigationStartingEventHandler *, ICoreWebView2 *, ICoreWebView2NavigationStartingEventArgs *);
static HRESULT STDMETHODCALLTYPE frame_invoke(ICoreWebView2NavigationStartingEventHandler *, ICoreWebView2 *, ICoreWebView2NavigationStartingEventArgs *);
static HRESULT STDMETHODCALLTYPE resource_invoke(ICoreWebView2WebResourceRequestedEventHandler *, ICoreWebView2 *, ICoreWebView2WebResourceRequestedEventArgs *);
static HRESULT STDMETHODCALLTYPE popup_invoke(ICoreWebView2NewWindowRequestedEventHandler *, ICoreWebView2 *, ICoreWebView2NewWindowRequestedEventArgs *);
static HRESULT STDMETHODCALLTYPE context_menu_invoke(ICoreWebView2ContextMenuRequestedEventHandler *,ICoreWebView2 *,ICoreWebView2ContextMenuRequestedEventArgs *);
static HRESULT STDMETHODCALLTYPE context_item_invoke(ICoreWebView2CustomItemSelectedEventHandler *,ICoreWebView2ContextMenuItem *,IUnknown *);
static HRESULT STDMETHODCALLTYPE permission_invoke(ICoreWebView2PermissionRequestedEventHandler *, ICoreWebView2 *, ICoreWebView2PermissionRequestedEventArgs *);
static HRESULT STDMETHODCALLTYPE download_invoke(ICoreWebView2DownloadStartingEventHandler *, ICoreWebView2 *, ICoreWebView2DownloadStartingEventArgs *);
static HRESULT STDMETHODCALLTYPE process_invoke(ICoreWebView2ProcessFailedEventHandler *, ICoreWebView2 *, ICoreWebView2ProcessFailedEventArgs *);
static HRESULT STDMETHODCALLTYPE permissions_invoke(ICoreWebView2GetNonDefaultPermissionSettingsCompletedHandler *, HRESULT, ICoreWebView2PermissionSettingCollectionView *);
static HRESULT STDMETHODCALLTYPE reset_permission_invoke(ICoreWebView2SetPermissionStateCompletedHandler *, HRESULT);
static HRESULT STDMETHODCALLTYPE seed_permission_invoke(ICoreWebView2SetPermissionStateCompletedHandler *, HRESULT);
static HRESULT STDMETHODCALLTYPE devtools_call_invoke(ICoreWebView2CallDevToolsProtocolMethodCompletedHandler *,HRESULT,LPCWSTR);
static HRESULT STDMETHODCALLTYPE completed_invoke(ICoreWebView2NavigationCompletedEventHandler *, ICoreWebView2 *, ICoreWebView2NavigationCompletedEventArgs *);
static HRESULT STDMETHODCALLTYPE dom_invoke(ICoreWebView2DOMContentLoadedEventHandler *, ICoreWebView2 *, ICoreWebView2DOMContentLoadedEventArgs *);
static HRESULT STDMETHODCALLTYPE source_invoke(ICoreWebView2SourceChangedEventHandler *, ICoreWebView2 *, ICoreWebView2SourceChangedEventArgs *);
static HRESULT STDMETHODCALLTYPE title_invoke(ICoreWebView2DocumentTitleChangedEventHandler *, ICoreWebView2 *, IUnknown *);
static HRESULT STDMETHODCALLTYPE history_invoke(ICoreWebView2HistoryChangedEventHandler *, ICoreWebView2 *, IUnknown *);
static HRESULT STDMETHODCALLTYPE content_invoke(ICoreWebView2ContentLoadingEventHandler *, ICoreWebView2 *, ICoreWebView2ContentLoadingEventArgs *);
static HRESULT STDMETHODCALLTYPE authentication_invoke(ICoreWebView2BasicAuthenticationRequestedEventHandler *, ICoreWebView2 *, ICoreWebView2BasicAuthenticationRequestedEventArgs *);
static HRESULT STDMETHODCALLTYPE certificate_invoke(ICoreWebView2ClientCertificateRequestedEventHandler *, ICoreWebView2 *, ICoreWebView2ClientCertificateRequestedEventArgs *);
static HRESULT STDMETHODCALLTYPE server_certificate_invoke(ICoreWebView2ServerCertificateErrorDetectedEventHandler *,ICoreWebView2 *,ICoreWebView2ServerCertificateErrorDetectedEventArgs *);
static HRESULT STDMETHODCALLTYPE find_match_invoke(ICoreWebView2FindMatchCountChangedEventHandler *,ICoreWebView2Find *,IUnknown *);
static HRESULT STDMETHODCALLTYPE find_index_invoke(ICoreWebView2FindActiveMatchIndexChangedEventHandler *,ICoreWebView2Find *,IUnknown *);
static HRESULT STDMETHODCALLTYPE facts_invoke(ICoreWebView2AddScriptToExecuteOnDocumentCreatedCompletedHandler *,HRESULT,LPCWSTR);

#define VTABLE(Name, Interface, Invoke) \
    static Interface##Vtbl Name##_vtable = { Name##_query, Name##_add, Name##_release, Invoke }; \
    static Name *Name##_new(State *s) { \
        Name *h = calloc(1, sizeof(*h)); if (!h) return NULL; \
        h->iface.lpVtbl = &Name##_vtable; h->refs = 1; h->state = s; retain(s); InterlockedIncrement(&live_handlers); return h; \
    }
VTABLE(EnvironmentHandler, ICoreWebView2CreateCoreWebView2EnvironmentCompletedHandler, environment_invoke)
VTABLE(ControllerHandler, ICoreWebView2CreateCoreWebView2ControllerCompletedHandler, controller_invoke)
VTABLE(MessageHandler, ICoreWebView2WebMessageReceivedEventHandler, message_invoke)
VTABLE(NavigationHandler, ICoreWebView2NavigationStartingEventHandler, navigation_invoke)
VTABLE(FrameHandler, ICoreWebView2NavigationStartingEventHandler, frame_invoke)
VTABLE(ResourceHandler, ICoreWebView2WebResourceRequestedEventHandler, resource_invoke)
VTABLE(PopupHandler, ICoreWebView2NewWindowRequestedEventHandler, popup_invoke)
VTABLE(ContextMenuHandler, ICoreWebView2ContextMenuRequestedEventHandler, context_menu_invoke)
VTABLE(ContextItemHandler, ICoreWebView2CustomItemSelectedEventHandler, context_item_invoke)
VTABLE(PermissionHandler, ICoreWebView2PermissionRequestedEventHandler, permission_invoke)
VTABLE(DownloadHandler, ICoreWebView2DownloadStartingEventHandler, download_invoke)
VTABLE(ProcessHandler, ICoreWebView2ProcessFailedEventHandler, process_invoke)
VTABLE(PermissionsHandler, ICoreWebView2GetNonDefaultPermissionSettingsCompletedHandler, permissions_invoke)
VTABLE(ResetPermissionHandler, ICoreWebView2SetPermissionStateCompletedHandler, reset_permission_invoke)
VTABLE(SeedPermissionHandler, ICoreWebView2SetPermissionStateCompletedHandler, seed_permission_invoke)
VTABLE(DevToolsCallHandler, ICoreWebView2CallDevToolsProtocolMethodCompletedHandler, devtools_call_invoke)
VTABLE(CompletedHandler, ICoreWebView2NavigationCompletedEventHandler, completed_invoke)
VTABLE(DomHandler, ICoreWebView2DOMContentLoadedEventHandler, dom_invoke)
VTABLE(SourceHandler, ICoreWebView2SourceChangedEventHandler, source_invoke)
VTABLE(TitleHandler, ICoreWebView2DocumentTitleChangedEventHandler, title_invoke)
VTABLE(HistoryHandler, ICoreWebView2HistoryChangedEventHandler, history_invoke)
VTABLE(ContentHandler, ICoreWebView2ContentLoadingEventHandler, content_invoke)
VTABLE(AuthenticationHandler, ICoreWebView2BasicAuthenticationRequestedEventHandler, authentication_invoke)
VTABLE(CertificateHandler, ICoreWebView2ClientCertificateRequestedEventHandler, certificate_invoke)
VTABLE(ServerCertificateHandler, ICoreWebView2ServerCertificateErrorDetectedEventHandler, server_certificate_invoke)
VTABLE(FindMatchHandler, ICoreWebView2FindMatchCountChangedEventHandler, find_match_invoke)
VTABLE(FindIndexHandler, ICoreWebView2FindActiveMatchIndexChangedEventHandler, find_index_invoke)
VTABLE(FactsHandler, ICoreWebView2AddScriptToExecuteOnDocumentCreatedCompletedHandler, facts_invoke)
#include "evaluations.h"
#include "browser_tools.h"
#include "permissions_native.h"
#include "downloads_native.h"


static void next_permission(State *s);
static HRESULT start_document(State *s) {
    if (s->closed) return E_ABORT;
    if (s->owned_context) {
        int result=zwpw_context_activate(s->owned_context);
        if (result!=ZWPW_PROFILE_OK||s->closed) return E_ABORT;
    }
    s->initial_navigation = TRUE;
    HRESULT hr = s->initial_url ? ICoreWebView2_Navigate(s->webview, s->initial_url) : ICoreWebView2_NavigateToString(s->webview, s->html);
    if (SUCCEEDED(hr)) {
        free(s->html); s->html = NULL;
        notify(s, 0, NULL, S_OK);
    }
    return hr;
}
#include "initializers_native.h"
static HRESULT prepare_permissions(State *s) {
    if (s->closed||!s->webview) return E_ABORT;
    ICoreWebView2 *view=s->webview;ICoreWebView2_AddRef(view);
    ICoreWebView2_13 *view13=NULL;ICoreWebView2Profile *base=NULL;
    ICoreWebView2Profile4 *profile=NULL;
    HRESULT hr=s->closed?E_ABORT:ICoreWebView2_QueryInterface(view,&IID_ICoreWebView2_13,(void **)&view13);
    if (SUCCEEDED(hr)&&(!view13||s->closed)) hr=E_ABORT;
    if (SUCCEEDED(hr)) hr=ICoreWebView2_13_get_Profile(view13,&base);
    if (SUCCEEDED(hr)&&(!base||s->closed)) hr=E_ABORT;
    if (SUCCEEDED(hr)) hr=ICoreWebView2Profile_QueryInterface(base,&IID_ICoreWebView2Profile4,(void **)&profile);
    if (SUCCEEDED(hr)&&(!profile||s->closed)) hr=E_ABORT;
    if (base) ICoreWebView2Profile_Release(base);
    if (view13) ICoreWebView2_13_Release(view13);
    if (s->closed) hr=E_ABORT;
    if (SUCCEEDED(hr)) {
        ICoreWebView2Profile4_AddRef(profile);
        if (s->closed) { ICoreWebView2Profile4_Release(profile);hr=E_ABORT; }
        else {
            s->profile=profile;
            PermissionsHandler *handler=PermissionsHandler_new(s);
            if (!handler) hr=E_OUTOFMEMORY;
            else {
                hr=ICoreWebView2Profile4_GetNonDefaultPermissionSettings(profile,&handler->iface);
                PermissionsHandler_release(&handler->iface);
            }
        }
    }
    if (profile) ICoreWebView2Profile4_Release(profile);
    ICoreWebView2_Release(view);return hr;
}
static HRESULT STDMETHODCALLTYPE permissions_invoke(ICoreWebView2GetNonDefaultPermissionSettingsCompletedHandler *p,HRESULT hr,ICoreWebView2PermissionSettingCollectionView *collection) {
    State *s=((PermissionsHandler *)p)->state;retain(s);
    UINT32 count=0;
    if (!s->closed) {
        if (SUCCEEDED(hr)&&collection) hr=ICoreWebView2PermissionSettingCollectionView_get_Count(collection,&count);
        else if (SUCCEEDED(hr)) hr=E_POINTER;
        if (SUCCEEDED(hr)&&count>s->permission_limit) hr=HRESULT_FROM_WIN32(ERROR_BUFFER_OVERFLOW);
        if (SUCCEEDED(hr)&&!s->closed) {
            ICoreWebView2PermissionSettingCollectionView_AddRef(collection);
            if (s->closed) ICoreWebView2PermissionSettingCollectionView_Release(collection);
            else { s->permissions=collection;s->permission_count=count;next_permission(s); }
        } else if (FAILED(hr)&&!s->closed) owned_initialization_failed(s,hr);
    }
    release(s);return S_OK;
}
static void next_permission(State *s) {
    if (s->closed||!s->permissions) return;
    ICoreWebView2PermissionSettingCollectionView *collection=s->permissions;
    ICoreWebView2PermissionSettingCollectionView_AddRef(collection);
    ICoreWebView2Profile4 *profile=NULL;
    HRESULT hr=S_OK;
    while (!s->closed&&s->permission_index<s->permission_count) {
        ICoreWebView2PermissionSetting *setting=NULL;WCHAR *origin=NULL;
        COREWEBVIEW2_PERMISSION_STATE state=COREWEBVIEW2_PERMISSION_STATE_DEFAULT;
        COREWEBVIEW2_PERMISSION_KIND kind=COREWEBVIEW2_PERMISSION_KIND_UNKNOWN_PERMISSION;
        hr=ICoreWebView2PermissionSettingCollectionView_GetValueAtIndex(collection,s->permission_index++,&setting);
        if (SUCCEEDED(hr)&&!setting) hr=E_POINTER;
        if (SUCCEEDED(hr)&&!s->closed) hr=ICoreWebView2PermissionSetting_get_PermissionState(setting,&state);
        BOOL reset=SUCCEEDED(hr)&&!s->closed&&state==COREWEBVIEW2_PERMISSION_STATE_ALLOW;
        if (reset) {
            hr=ICoreWebView2PermissionSetting_get_PermissionKind(setting,&kind);
            if (SUCCEEDED(hr)&&!s->closed) hr=ICoreWebView2PermissionSetting_get_PermissionOrigin(setting,&origin);
            if (SUCCEEDED(hr)&&!s->closed) {
                profile=s->profile;ICoreWebView2Profile4_AddRef(profile);
                if (!s->closed) {
                    ResetPermissionHandler *handler=ResetPermissionHandler_new(s);
                    if (!handler) hr=E_OUTOFMEMORY;
                    else {
                        hr=ICoreWebView2Profile4_SetPermissionState(profile,kind,origin,COREWEBVIEW2_PERMISSION_STATE_DEFAULT,&handler->iface);
                        ResetPermissionHandler_release(&handler->iface);
                    }
                }
            }
        }
        CoTaskMemFree(origin);
        if (setting) ICoreWebView2PermissionSetting_Release(setting);
        if (reset||FAILED(hr)||s->closed) goto done;
    }
    if (!s->closed) {
        ICoreWebView2PermissionSettingCollectionView *owned=s->permissions;s->permissions=NULL;
        ICoreWebView2PermissionSettingCollectionView_Release(owned);
        if (!s->closed) hr=initializers_start(s);
    }
done:
    if (profile) ICoreWebView2Profile4_Release(profile);
    ICoreWebView2PermissionSettingCollectionView_Release(collection);
    if (FAILED(hr)&&!s->closed) owned_initialization_failed(s,hr);
}
static HRESULT STDMETHODCALLTYPE reset_permission_invoke(ICoreWebView2SetPermissionStateCompletedHandler *p, HRESULT hr) {
    State *s = ((ResetPermissionHandler *)p)->state; retain(s);
    if (!s->closed) {
        if (FAILED(hr)) owned_initialization_failed(s,hr);
        else next_permission(s);
    }
    release(s); return S_OK;
}
static HRESULT STDMETHODCALLTYPE seed_permission_invoke(ICoreWebView2SetPermissionStateCompletedHandler *p, HRESULT hr) {
    State *s = ((SeedPermissionHandler *)p)->state; retain(s);
    SeedNotify done = s->seed_notify; void *context = s->seed_context;
    s->seed_notify = NULL; s->seed_context = NULL;
    if (!s->closed && done) done(context, hr);
    release(s); return S_OK;
}
/* Native integration fault setup: exercise a real persisted grant before a
   fresh View's initialization policy. This is not a public Zig permission API. */
HRESULT zwv_test_seed_permission(State *s, const WCHAR *origin, SeedNotify done, void *context) {
    if (s->closed || !s->profile) return E_ABORT;
    if (s->seed_notify) return E_PENDING;
    SeedPermissionHandler *handler = SeedPermissionHandler_new(s);
    if (!handler) return E_OUTOFMEMORY;
    s->seed_notify = done; s->seed_context = context;
    HRESULT hr = ICoreWebView2Profile4_SetPermissionState(s->profile, COREWEBVIEW2_PERMISSION_KIND_GEOLOCATION, origin, COREWEBVIEW2_PERMISSION_STATE_ALLOW, &handler->iface);
    SeedPermissionHandler_release(&handler->iface);
    if (FAILED(hr)) { s->seed_notify = NULL; s->seed_context = NULL; }
    return hr;
}

static HRESULT STDMETHODCALLTYPE devtools_call_invoke(ICoreWebView2CallDevToolsProtocolMethodCompletedHandler *p,HRESULT hr,LPCWSTR result) {
    (void)p; (void)hr; (void)result; return S_OK;
}
/* Native integration input: a right click of the page at x, y in CSS
   pixels, as the DevTools protocol sends a mouse's. Not a public Zig API. */
/* Moves the page's video out into picture in picture, the playing one or
   else the largest, or back, as a user's gesture: requestPictureInPicture()
   needs one, which ExecuteScript is not. */
HRESULT zwv_toggle_picture_in_picture(State *s) {
    if (s->closed || s->recovering || !s->webview) return E_ABORT;
    static const WCHAR params[]=L"{\"expression\":\"(()=>{if(document.pictureInPictureElement)return document.exitPictureInPicture();"
        L"const all=[...document.querySelectorAll('video')].filter(v=>!v.disablePictureInPicture);"
        L"const v=all.find(v=>!v.paused)||all.sort((a,b)=>b.clientWidth*b.clientHeight-a.clientWidth*a.clientHeight)[0];"
        L"if(v)return v.requestPictureInPicture()})()\",\"userGesture\":true,\"awaitPromise\":false}";
    DevToolsCallHandler *handler=DevToolsCallHandler_new(s);
    if (!handler) return E_OUTOFMEMORY;
    HRESULT hr=ICoreWebView2_CallDevToolsProtocolMethod(s->webview,L"Runtime.evaluate",params,&handler->iface);
    DevToolsCallHandler_release(&handler->iface);
    return hr;
}
/* Whether the page swipes between pages and pinches, as WebView2 says. */
HRESULT zwv_test_gestures(State *s, int32_t *swipe, int32_t *pinch) {
    if (s->closed || !s->webview) return E_ABORT;
    ICoreWebView2Settings *settings=NULL;ICoreWebView2Settings5 *settings5=NULL;ICoreWebView2Settings6 *settings6=NULL;
    BOOL value=FALSE;
    HRESULT hr=ICoreWebView2_get_Settings(s->webview,&settings);
    if (SUCCEEDED(hr)) hr=ICoreWebView2Settings_QueryInterface(settings,&IID_ICoreWebView2Settings5,(void **)&settings5);
    if (SUCCEEDED(hr)) hr=ICoreWebView2Settings5_get_IsPinchZoomEnabled(settings5,&value);
    if (SUCCEEDED(hr)) { *pinch=value?1:0; hr=ICoreWebView2Settings_QueryInterface(settings,&IID_ICoreWebView2Settings6,(void **)&settings6); }
    if (SUCCEEDED(hr)) hr=ICoreWebView2Settings6_get_IsSwipeNavigationEnabled(settings6,&value);
    if (SUCCEEDED(hr)) *swipe=value?1:0;
    if (settings6) ICoreWebView2Settings6_Release(settings6);
    if (settings5) ICoreWebView2Settings5_Release(settings5);
    if (settings) ICoreWebView2Settings_Release(settings);
    return hr;
}
HRESULT zwv_test_right_click(State *s, int32_t x, int32_t y) {
    if (s->closed || !s->webview) return E_ABORT;
    HRESULT hr=S_OK;
    for (int release=0;release<2&&SUCCEEDED(hr);release++) {
        WCHAR params[160];
        swprintf(params,160,L"{\"type\":\"%ls\",\"x\":%d,\"y\":%d,\"button\":\"right\",\"buttons\":%d,\"clickCount\":1}",release?L"mouseReleased":L"mousePressed",(int)x,(int)y,release?0:2);
        DevToolsCallHandler *handler=DevToolsCallHandler_new(s);
        if (!handler) return E_OUTOFMEMORY;
        hr=ICoreWebView2_CallDevToolsProtocolMethod(s->webview,L"Input.dispatchMouseEvent",params,&handler->iface);
        DevToolsCallHandler_release(&handler->iface);
    }
    return hr;
}

static void policy_notify(State *s, int kind, const WCHAR *uri, int detail) {
    if (s->policy & (1u << (kind - 3))) notify(s, kind, uri, detail);
}

static HRESULT viewport_apply(State *s,RECT bounds,BOOL visible) {
    if (s->closed) return HRESULT_FROM_WIN32(ERROR_INVALID_WINDOW_HANDLE);
    if (!s->controller) return S_OK;
    ICoreWebView2Controller *controller=s->controller;
    ICoreWebView2Controller_AddRef(controller);
    RECT previous={0}; BOOL previous_visible=FALSE;
    HRESULT hr=ICoreWebView2Controller_get_Bounds(controller,&previous);
    if (SUCCEEDED(hr)) hr=ICoreWebView2Controller_get_IsVisible(controller,&previous_visible);
    if (FAILED(hr) || s->closed) goto done;
    if (!EqualRect(&previous,&bounds)) hr=ICoreWebView2Controller_put_Bounds(controller,bounds);
    if (SUCCEEDED(hr) && !s->closed && visible!=previous_visible) hr=ICoreWebView2Controller_put_IsVisible(controller,visible);
    if (FAILED(hr) && !s->closed) {
        HRESULT rollback=ICoreWebView2Controller_put_Bounds(controller,previous);
        if (SUCCEEDED(rollback) && !s->closed) rollback=ICoreWebView2Controller_put_IsVisible(controller,previous_visible);
        if (FAILED(rollback)) {
            ICoreWebView2Controller_Close(controller);
            notify(s,2,NULL,hr);
        }
    }
done:
    if (SUCCEEDED(hr) && s->closed) hr=HRESULT_FROM_WIN32(ERROR_INVALID_WINDOW_HANDLE);
    ICoreWebView2Controller_Release(controller);
    return hr;
}
HRESULT zwv_viewport(State *s,int32_t left,int32_t top,int32_t right,int32_t bottom,_Bool visible) {
    if (!s || right<left || bottom<top || (int64_t)right-left>INT32_MAX || (int64_t)bottom-top>INT32_MAX) return E_INVALIDARG;
    retain(s);
    RECT bounds={left,top,right,bottom};
    HRESULT hr=viewport_apply(s,bounds,visible);
    if (SUCCEEDED(hr) && !s->closed) {
        s->has_viewport=TRUE; s->viewport=bounds; s->viewport_visible=visible;
    }
    release(s); return hr;
}
HRESULT zwv_parent_position(State *s) {
    if (!s || s->closed) return HRESULT_FROM_WIN32(ERROR_INVALID_WINDOW_HANDLE);
    retain(s);
    ICoreWebView2Controller *controller=s->controller;
    HRESULT hr=S_OK;
    if (controller) {
        ICoreWebView2Controller_AddRef(controller);
        hr=ICoreWebView2Controller_NotifyParentWindowPositionChanged(controller);
        if (SUCCEEDED(hr) && s->closed) hr=HRESULT_FROM_WIN32(ERROR_INVALID_WINDOW_HANDLE);
        ICoreWebView2Controller_Release(controller);
    }
    release(s); return hr;
}
/* The fixed controller parent moved or was reparented. Keep State alive across
   both outgoing COM calls, including a synchronous close from either call. */
HRESULT zwv_session_viewport(State *s,int32_t width,int32_t height,_Bool visible) {
    if (!s || s->closed) return HRESULT_FROM_WIN32(ERROR_INVALID_WINDOW_HANDLE);
    retain(s);
    HRESULT hr=zwv_viewport(s,0,0,width,height,visible);
    if (SUCCEEDED(hr)) hr=zwv_parent_position(s);
    release(s); return hr;
}
HRESULT zwv_resize(State *s) {
    retain(s);
    HRESULT hr=s->closed?HRESULT_FROM_WIN32(ERROR_INVALID_WINDOW_HANDLE):S_OK;
    if (!s->closed && s->controller) {
        RECT rect;
        if (s->has_viewport) hr=viewport_apply(s,s->viewport,s->viewport_visible);
        else if (GetClientRect(s->hwnd,&rect)) hr=viewport_apply(s,rect,TRUE);
        else hr=HRESULT_FROM_WIN32(GetLastError());
    }
    release(s);
    return hr;
}

static void owned_release(void *context) { release(context); }
static void owned_environment(void *context,HRESULT hr,ICoreWebView2Environment *environment) {
    State *s=context;retain(s);
    if (s->closed) { release(s);return; }
    if (FAILED(hr)||!environment) { owned_initialization_failed(s,FAILED(hr)?hr:E_FAIL);release(s);return; }
    ICoreWebView2Environment_AddRef(environment);
    if (s->closed||(s->owned_context&&!zwpw_context_is_pending(s->owned_context))) {
        ICoreWebView2Environment_Release(environment);release(s);return;
    }
    s->environment=environment;
    ControllerHandler *handler=ControllerHandler_new(s);
    if (!handler) hr=E_OUTOFMEMORY;
    else {
        hr=ICoreWebView2Environment_CreateCoreWebView2Controller(environment,s->hwnd,&handler->iface);
        ControllerHandler_release(&handler->iface);
    }
    if (FAILED(hr)&&!s->closed) owned_initialization_failed(s,hr);
    release(s);
}
static HRESULT STDMETHODCALLTYPE environment_invoke(ICoreWebView2CreateCoreWebView2EnvironmentCompletedHandler *p,HRESULT hr,ICoreWebView2Environment *environment) {
    owned_environment(((EnvironmentHandler *)p)->state,hr,environment);return S_OK;
}
static void owned_revoke(void *context,HRESULT reason) {
    State *s=context;retain(s);
    if (!s->closed) notify(s,2,NULL,reason);
    if (!s->closed) {
        /* Keep the View's linear State owner but actively release main COM.
           Later zwv_close consumes that reference once without another notify. */
        s->closed=2;state_cleanup(s);
    }
    release(s);
}
static void owned_initialization_failed(State *s,HRESULT hr) {
    if (!s->closed) notify(s,2,NULL,hr);
}
static HRESULT owned_controller_prepare(State *s) {
    ZwpwContext *context=s->owned_context;
    if (!context) return S_OK;
    ICoreWebView2 *view=s->webview;ICoreWebView2_AddRef(view);
    UINT32 pid=0;HANDLE process=NULL;ICoreWebView2_14 *tls=NULL;
    HRESULT hr=s->closed?E_ABORT:ICoreWebView2_get_BrowserProcessId(view,&pid);
    if (SUCCEEDED(hr)&&(!pid||s->closed||!zwpw_context_is_pending(context))) hr=E_ABORT;
    if (SUCCEEDED(hr)) {
        process=OpenProcess(SYNCHRONIZE,FALSE,pid);
        if (!process) hr=HRESULT_FROM_WIN32(GetLastError());
    }
    if (SUCCEEDED(hr)&&(s->closed||!zwpw_context_is_pending(context))) hr=E_ABORT;
    if (SUCCEEDED(hr)) {
        int result=zwpw_context_publish_process(context,&process);
        if (result!=ZWPW_PROFILE_OK) hr=result==ZWPW_PROFILE_FULL?HRESULT_FROM_WIN32(ERROR_NOT_ENOUGH_QUOTA):E_ABORT;
    }
    if (process) CloseHandle(process);
    if (SUCCEEDED(hr)&&(s->closed||!zwpw_context_is_pending(context))) hr=E_ABORT;
    if (SUCCEEDED(hr)) hr=ICoreWebView2_QueryInterface(view,&IID_ICoreWebView2_14,(void **)&tls);
    if (SUCCEEDED(hr)&&(!tls||s->closed||!zwpw_context_is_pending(context))) hr=E_ABORT;
    if (SUCCEEDED(hr)) {
        ServerCertificateHandler *handler=ServerCertificateHandler_new(s);
        if (!handler) hr=E_OUTOFMEMORY;
        else {
            EventRegistrationToken token;
            hr=ICoreWebView2_14_add_ServerCertificateErrorDetected(tls,&handler->iface,&token);
            ServerCertificateHandler_release(&handler->iface);
            if (SUCCEEDED(hr)) {
                if (!s->closed&&zwpw_context_is_pending(context)) {
                    s->tls_webview=tls;tls=NULL;s->server_certificate_token=token;s->has_server_certificate=TRUE;
                } else { ICoreWebView2_14_remove_ServerCertificateErrorDetected(tls,token);hr=E_ABORT; }
            }
        }
    }
    if (tls) ICoreWebView2_14_Release(tls);
    ICoreWebView2_Release(view);
    if (s->closed||!zwpw_context_is_pending(context)) return E_ABORT;
    return hr;
}
/* An owned profile's own loopback certificate is allowed while its session
   is active; any other goes to the app's handler, else fails. */
static HRESULT STDMETHODCALLTYPE server_certificate_invoke(ICoreWebView2ServerCertificateErrorDetectedEventHandler *iface,ICoreWebView2 *sender,ICoreWebView2ServerCertificateErrorDetectedEventArgs *args) {
    (void)sender;State *s=((ServerCertificateHandler *)iface)->state;retain(s);
    HRESULT hr=ICoreWebView2ServerCertificateErrorDetectedEventArgs_put_Action(args,COREWEBVIEW2_SERVER_CERTIFICATE_ERROR_ACTION_CANCEL);
    BOOL action_failed=FAILED(hr),allow=FALSE;
    WCHAR *uri=NULL,*pem=NULL;ICoreWebView2Certificate *certificate=NULL;
    ZwpwContext *context=s->owned_context;
    if (SUCCEEDED(hr)&&!s->closed&&((context&&zwpw_context_is_active(context))||s->certificate_offer)) hr=ICoreWebView2ServerCertificateErrorDetectedEventArgs_get_RequestUri(args,&uri);
    else if (SUCCEEDED(hr)) hr=E_ABORT;
    if (SUCCEEDED(hr)&&!uri) hr=E_POINTER;
    if (SUCCEEDED(hr)) hr=ICoreWebView2ServerCertificateErrorDetectedEventArgs_get_ServerCertificate(args,&certificate);
    if (SUCCEEDED(hr)&&(!certificate||s->closed)) hr=E_ABORT;
    if (SUCCEEDED(hr)) hr=ICoreWebView2Certificate_ToPemEncoding(certificate,&pem);
    if (SUCCEEDED(hr)&&!pem) hr=E_POINTER;
    if (SUCCEEDED(hr)&&context&&!s->closed&&zwpw_context_is_active(context)) {
        NetOrigin origin;
        /* Seal never changes an already active session authority; cache hits
           may omit this callback. Navigation/request rights remain separate. */
        allow=SUCCEEDED(net_origin(uri,FALSE,TRUE,&origin))&&origin.https&&!wcscmp(origin.host,L"127.0.0.1")&&zwpw_context_certificate_matches(context,pem);
    }
    if (SUCCEEDED(hr)&&!allow&&!s->closed&&s->certificate_offer) {
        COREWEBVIEW2_WEB_ERROR_STATUS status=COREWEBVIEW2_WEB_ERROR_STATUS_UNKNOWN;
        (void)ICoreWebView2ServerCertificateErrorDetectedEventArgs_get_ErrorStatus(args,&status);
        allow=s->certificate_offer(s->context,uri,(int32_t)status,pem)!=0&&!s->closed;
    }
    if (allow) {
        hr=ICoreWebView2ServerCertificateErrorDetectedEventArgs_put_Action(args,COREWEBVIEW2_SERVER_CERTIFICATE_ERROR_ACTION_ALWAYS_ALLOW);
        action_failed=FAILED(hr);
    }
    CoTaskMemFree(uri);CoTaskMemFree(pem);
    if (certificate) ICoreWebView2Certificate_Release(certificate);
    if (action_failed&&!s->closed&&context) owned_revoke(s,hr);
    release(s);return S_OK;
}

static HRESULT STDMETHODCALLTYPE controller_invoke(ICoreWebView2CreateCoreWebView2ControllerCompletedHandler *p,HRESULT hr,ICoreWebView2Controller *controller) {
    State *s=((ControllerHandler *)p)->state;retain(s);
    ICoreWebView2 *view=NULL;
    ICoreWebView2_4 *view4=NULL;ICoreWebView2_22 *view22=NULL;
    ICoreWebView2_10 *view10=NULL;ICoreWebView2_5 *view5=NULL;ICoreWebView2_14 *view14=NULL;ICoreWebView2_11 *view11=NULL;
    ICoreWebView2Settings *settings=NULL;ICoreWebView2Settings2 *settings2=NULL;ICoreWebView2Settings5 *settings5=NULL;ICoreWebView2Settings6 *settings6=NULL;
    BOOL controller_pin=FALSE;
    if (s->closed) { if (controller) ICoreWebView2Controller_Close(controller);goto done; }
    if (FAILED(hr)||!controller) { owned_initialization_failed(s,FAILED(hr)?hr:E_FAIL);goto done; }
    ICoreWebView2Controller_AddRef(controller);controller_pin=TRUE;
    if (s->closed) goto done;
    ICoreWebView2Controller_AddRef(controller);
    if (s->closed) { ICoreWebView2Controller_Release(controller);goto done; }
    s->controller=controller;InterlockedIncrement(&owned_controllers);
    hr=ICoreWebView2Controller_get_CoreWebView2(controller,&view);
    if (FAILED(hr)||!view) { if (SUCCEEDED(hr)) hr=E_POINTER;goto failed; }
    if (s->closed) goto done;
    ICoreWebView2_AddRef(view);
    if (s->closed) { ICoreWebView2_Release(view);goto done; }
    s->webview=view;
    hr=owned_controller_prepare(s);if (FAILED(hr)||s->closed) goto failed;
    /* SDK output is never written straight into State across a foreign call.
       Each temporary interface remains pinned through reentrant close. */
#define QUERY_INTERFACE(Type,Id,Local,Field) do {     hr=ICoreWebView2_QueryInterface(view,&Id,(void **)&Local);     if (FAILED(hr)||!Local) { if (SUCCEEDED(hr)) hr=E_POINTER;goto failed; }     if (s->closed) goto done;     Type##_AddRef(Local);     if (s->closed) { Type##_Release(Local);goto done; }     s->Field=Local; } while (0)
#define REGISTER_HANDLER(Type,Interface,Sender,Add,Remove,Token,Flag) do {     Type *handler=Type##_new(s);     if (!handler) { hr=E_OUTOFMEMORY;goto failed; }     EventRegistrationToken token;     hr=Interface##_##Add(Sender,&handler->iface,&token);     Type##_release(&handler->iface);     if (FAILED(hr)) goto failed;     if (s->closed) { Interface##_##Remove(Sender,token);goto done; }     s->Token=token;s->Flag=TRUE; } while (0)
    REGISTER_HANDLER(NavigationHandler,ICoreWebView2,view,add_NavigationStarting,remove_NavigationStarting,navigation_token,has_navigation);
    REGISTER_HANDLER(MessageHandler,ICoreWebView2,view,add_WebMessageReceived,remove_WebMessageReceived,message_token,has_message);
    if (s->remote.enabled) {
        QUERY_INTERFACE(ICoreWebView2_10,IID_ICoreWebView2_10,view10,webview10);
        QUERY_INTERFACE(ICoreWebView2_5,IID_ICoreWebView2_5,view5,webview5);
        REGISTER_HANDLER(AuthenticationHandler,ICoreWebView2_10,view10,add_BasicAuthenticationRequested,remove_BasicAuthenticationRequested,authentication_token,has_authentication);
        REGISTER_HANDLER(CertificateHandler,ICoreWebView2_5,view5,add_ClientCertificateRequested,remove_ClientCertificateRequested,certificate_token,has_certificate);
        if (s->certificate_offer&&!s->tls_webview) {
            QUERY_INTERFACE(ICoreWebView2_14,IID_ICoreWebView2_14,view14,tls_webview);
            REGISTER_HANDLER(ServerCertificateHandler,ICoreWebView2_14,view14,add_ServerCertificateErrorDetected,remove_ServerCertificateErrorDetected,server_certificate_token,has_server_certificate);
        }
    }
    QUERY_INTERFACE(ICoreWebView2_4,IID_ICoreWebView2_4,view4,webview4);
    QUERY_INTERFACE(ICoreWebView2_22,IID_ICoreWebView2_22,view22,webview22);
    ICoreWebView2Environment *environment=s->environment;
    ICoreWebView2Environment_AddRef(environment);
    if (!s->closed) {
        ICoreWebView2WebResourceResponse *response=NULL;
        hr=ICoreWebView2Environment_CreateWebResourceResponse(environment,NULL,403,L"Forbidden",L"Content-Length: 0\r\nCache-Control: no-store\r\n",&response);
        if (s->closed||FAILED(hr)) { if (response) ICoreWebView2WebResourceResponse_Release(response); }
        else if (!response) hr=E_POINTER;
        else s->denied_response=response;
    }
    ICoreWebView2Environment_Release(environment);
    if (FAILED(hr)||s->closed) goto failed;
    REGISTER_HANDLER(FrameHandler,ICoreWebView2,view,add_FrameNavigationStarting,remove_FrameNavigationStarting,frame_token,has_frame);
    REGISTER_HANDLER(ResourceHandler,ICoreWebView2,view,add_WebResourceRequested,remove_WebResourceRequested,resource_token,has_resource);
    REGISTER_HANDLER(PopupHandler,ICoreWebView2,view,add_NewWindowRequested,remove_NewWindowRequested,popup_token,has_popup);
    REGISTER_HANDLER(PermissionHandler,ICoreWebView2,view,add_PermissionRequested,remove_PermissionRequested,permission_token,has_permission);
    REGISTER_HANDLER(ProcessHandler,ICoreWebView2,view,add_ProcessFailed,remove_ProcessFailed,process_token,has_process);
    REGISTER_HANDLER(CompletedHandler,ICoreWebView2,view,add_NavigationCompleted,remove_NavigationCompleted,completed_token,has_completed);
    REGISTER_HANDLER(SourceHandler,ICoreWebView2,view,add_SourceChanged,remove_SourceChanged,source_token,has_source);
    if (s->observe_metadata) {
        REGISTER_HANDLER(TitleHandler,ICoreWebView2,view,add_DocumentTitleChanged,remove_DocumentTitleChanged,title_token,has_title);
        REGISTER_HANDLER(DomHandler,ICoreWebView2_22,view22,add_DOMContentLoaded,remove_DOMContentLoaded,dom_token,has_dom);
    }
    REGISTER_HANDLER(HistoryHandler,ICoreWebView2,view,add_HistoryChanged,remove_HistoryChanged,history_token,has_history);
    REGISTER_HANDLER(ContentHandler,ICoreWebView2,view,add_ContentLoading,remove_ContentLoading,content_token,has_content);
    REGISTER_HANDLER(DownloadHandler,ICoreWebView2_4,view4,add_DownloadStarting,remove_DownloadStarting,download_token,has_download);
    if (s->context_menu==2&&s->context_offer) {
        QUERY_INTERFACE(ICoreWebView2_11,IID_ICoreWebView2_11,view11,webview11);
        REGISTER_HANDLER(ContextMenuHandler,ICoreWebView2_11,view11,add_ContextMenuRequested,remove_ContextMenuRequested,context_token,has_context);
    }
#undef REGISTER_HANDLER
#undef QUERY_INTERFACE
    hr=ICoreWebView2_22_AddWebResourceRequestedFilterWithRequestSourceKinds(view22,L"*",COREWEBVIEW2_WEB_RESOURCE_CONTEXT_ALL,COREWEBVIEW2_WEB_RESOURCE_REQUEST_SOURCE_KINDS_ALL);
    if (FAILED(hr)||s->closed) goto failed;
    hr=ICoreWebView2_get_Settings(view,&settings);
    if (FAILED(hr)||!settings) { if (SUCCEEDED(hr)) hr=E_POINTER;goto failed; }
#define SETTING(Name,Value) do {     if (s->closed) goto done;     hr=ICoreWebView2Settings_##Name(settings,Value);     if (FAILED(hr)||s->closed) goto failed; } while (0)
    SETTING(put_AreHostObjectsAllowed,FALSE);
    SETTING(put_AreDefaultScriptDialogsEnabled,FALSE);
    SETTING(put_AreDefaultContextMenusEnabled,s->context_menu!=0);
    SETTING(put_AreDevToolsEnabled,s->devtools);
#undef SETTING
    if (s->user_agent) {
        hr=ICoreWebView2Settings_QueryInterface(settings,&IID_ICoreWebView2Settings2,(void **)&settings2);
        if (FAILED(hr)||!settings2) { if (SUCCEEDED(hr)) hr=E_POINTER;goto failed; }
        if (s->closed) goto done;
        /* The argument's State-owned bytes are not freed until this SDK call
           has taken its input. No caller application callback is invoked here. */
        hr=ICoreWebView2Settings2_put_UserAgent(settings2,s->user_agent);
        if (FAILED(hr)||s->closed) goto failed;
    }
    /* WebView2 swipes and pinches by default; a page does only when asked. */
    hr=ICoreWebView2Settings_QueryInterface(settings,&IID_ICoreWebView2Settings5,(void **)&settings5);
    if (FAILED(hr)||!settings5) { if (SUCCEEDED(hr)) hr=E_POINTER;goto failed; }
    hr=ICoreWebView2Settings5_put_IsPinchZoomEnabled(settings5,(s->gestures&2u)!=0);
    if (FAILED(hr)||s->closed) goto failed;
    hr=ICoreWebView2Settings_QueryInterface(settings,&IID_ICoreWebView2Settings6,(void **)&settings6);
    if (FAILED(hr)||!settings6) { if (SUCCEEDED(hr)) hr=E_POINTER;goto failed; }
    hr=ICoreWebView2Settings6_put_IsSwipeNavigationEnabled(settings6,(s->gestures&1u)!=0);
    if (FAILED(hr)||s->closed) goto failed;
    hr=ICoreWebView2Controller_put_ZoomFactor(controller,s->zoom);
    if (FAILED(hr)||s->closed) goto failed;
    RECT bounds;
    if (s->has_viewport) bounds=s->viewport;
    else if (!GetClientRect(s->hwnd,&bounds)) { hr=HRESULT_FROM_WIN32(GetLastError());goto failed; }
    if (s->closed) goto done;
    hr=viewport_apply(s,bounds,s->has_viewport?s->viewport_visible:TRUE);
    if (FAILED(hr)||s->closed) goto failed;
    hr=prepare_permissions(s);
    if (FAILED(hr)) goto failed;
    goto done;
failed:
    if (!s->closed) owned_initialization_failed(s,hr);
done:
    if (settings2) ICoreWebView2Settings2_Release(settings2);
    if (settings5) ICoreWebView2Settings5_Release(settings5);
    if (settings6) ICoreWebView2Settings6_Release(settings6);
    if (settings) ICoreWebView2Settings_Release(settings);
    if (view5) ICoreWebView2_5_Release(view5);
    if (view10) ICoreWebView2_10_Release(view10);
    if (view14) ICoreWebView2_14_Release(view14);
    if (view11) ICoreWebView2_11_Release(view11);
    if (view22) ICoreWebView2_22_Release(view22);
    if (view4) ICoreWebView2_4_Release(view4);
    if (view) ICoreWebView2_Release(view);
    if (controller_pin) ICoreWebView2Controller_Release(controller);
    release(s);return S_OK;
}

static HRESULT STDMETHODCALLTYPE message_invoke(ICoreWebView2WebMessageReceivedEventHandler *p, ICoreWebView2 *sender, ICoreWebView2WebMessageReceivedEventArgs *args) {
    (void)sender;
    State *s = ((MessageHandler *)p)->state;
    retain(s);
    if (!s->closed && s->committed) {
        WCHAR *source = NULL, *text = NULL, *current = NULL;
        HRESULT hr = ICoreWebView2WebMessageReceivedEventArgs_get_Source(args, &source);
        if (SUCCEEDED(hr)) hr = ICoreWebView2_get_Source(sender, &current);
        /* The View's own page-facts script tells it from documents of any
           origin. A page that posts the marker itself only tells its own facts. */
        if (s->facts_script && SUCCEEDED(hr) && bounded_uri(source) && bounded_uri(current) && wcscmp(source, current) == 0 &&
            SUCCEEDED(ICoreWebView2WebMessageReceivedEventArgs_TryGetWebMessageAsString(args, &text)) && text &&
            wcsncmp(text, FACTS_MARKER, FACTS_MARKER_UNITS) == 0) {
            if (wcsnlen(text, 257) <= 256) page_notify(s, 10, s->navigation_id, 0, 0, text + FACTS_MARKER_UNITS);
            CoTaskMemFree(source); CoTaskMemFree(current); CoTaskMemFree(text);
            release(s);
            return S_OK;
        }
        CoTaskMemFree(text); text = NULL;
        /* This base event is top-level only. No frame message handlers are added.
           Require the trusted document and the currently committed source. */
        if (SUCCEEDED(hr) && bounded_uri(source) && bounded_uri(current) && wcscmp(source, current) == 0 && s->document_source &&
            (wcscmp(source, s->document_source) == 0 || (!s->initial_url && wcscmp(source, L"about:blank") == 0)) &&
            (!s->remote.enabled || (remote_grants(&s->remote,source)&REMOTE_IPC)) && (!s->custom_site || s->local_ipc)) {
            hr = ICoreWebView2WebMessageReceivedEventArgs_TryGetWebMessageAsString(args, &text);
            if (SUCCEEDED(hr) && text) {
                size_t len = wcsnlen(text, 65537);
                if (len <= 65536) {
                    int bytes = WideCharToMultiByte(CP_UTF8, WC_ERR_INVALID_CHARS, text, (int)len, NULL, 0, NULL, NULL);
                    if (bytes <= 65536 && (bytes > 0 || len == 0)) notify(s, 1, text, S_OK);
                }
            }
        }
        CoTaskMemFree(source); CoTaskMemFree(current); CoTaskMemFree(text);
    }
    release(s);
    return S_OK;
}

static HRESULT STDMETHODCALLTYPE navigation_invoke(ICoreWebView2NavigationStartingEventHandler *p, ICoreWebView2 *sender, ICoreWebView2NavigationStartingEventArgs *args) {
    (void)sender;
    State *s = ((NavigationHandler *)p)->state;
    retain(s);
    WCHAR *uri = NULL;
    HRESULT hr = ICoreWebView2NavigationStartingEventArgs_get_Uri(args, &uri);
    BOOL user_initiated = TRUE, redirected = TRUE;
    ICoreWebView2NavigationStartingEventArgs_get_IsUserInitiated(args, &user_initiated);
    ICoreWebView2NavigationStartingEventArgs_get_IsRedirected(args, &redirected);
    uint64_t id = 0;
    if (SUCCEEDED(hr)) hr = ICoreWebView2NavigationStartingEventArgs_get_NavigationId(args, &id);
    COREWEBVIEW2_NAVIGATION_KIND kind = COREWEBVIEW2_NAVIGATION_KIND_NEW_DOCUMENT;
    ICoreWebView2NavigationStartingEventArgs3 *extended = NULL;
    HRESULT kind_hr = ICoreWebView2NavigationStartingEventArgs_QueryInterface(args, &IID_ICoreWebView2NavigationStartingEventArgs3, (void **)&extended);
    if (SUCCEEDED(kind_hr) && extended) {
        kind_hr = ICoreWebView2NavigationStartingEventArgs3_get_NavigationKind(extended, &kind);
        ICoreWebView2NavigationStartingEventArgs3_Release(extended);
    } else if (SUCCEEDED(kind_hr)) kind_hr = E_NOINTERFACE;
    BOOL local = local_source(s,uri);
    BOOL initial = s->initial_navigation && !redirected && uri &&
        (s->initial_url ? (s->remote.enabled?remote_url_equal(uri,s->initial_url,FALSE):wcscmp(uri, s->initial_url) == 0) : (!user_initiated &&
        (wcscmp(uri, L"about:blank") == 0 || wcsncmp(uri, L"data:text/html;", 15) == 0)));
    BOOL explicit_url = !redirected && SUCCEEDED(kind_hr) && kind == COREWEBVIEW2_NAVIGATION_KIND_NEW_DOCUMENT && uri && s->expected_url && (s->remote.enabled?remote_url_equal(uri,s->expected_url,FALSE):wcscmp(uri, s->expected_url) == 0);
    BOOL history = !redirected && SUCCEEDED(kind_hr) && kind == COREWEBVIEW2_NAVIGATION_KIND_BACK_OR_FORWARD && s->expected_history;
    BOOL refresh = !redirected && SUCCEEDED(kind_hr) && kind == COREWEBVIEW2_NAVIGATION_KIND_RELOAD && s->expected_refresh && uri && s->document_source &&
        ((s->remote.enabled?remote_url_equal(uri,s->document_source,FALSE):wcscmp(uri, s->document_source) == 0) || (!s->initial_url &&
        (wcscmp(uri, L"about:blank") == 0 || wcsncmp(uri, L"data:text/html;", 15) == 0)));
    BOOL bounded = bounded_uri(uri);
    BOOL html = !s->initial_url && (initial || refresh);
    BOOL remote_allowed=FALSE;
    if (s->remote.enabled && (remote_grants(&s->remote,uri)&REMOTE_NAVIGATE)) {
        remote_allowed=redirected?(s->remote.allow_redirects && s->has_document && s->navigating && s->navigation_id==id):
            (initial || explicit_url || history || refresh || s->remote.allow_script_navigation);
    }
    if (!s->closed && !s->recovering && initializers_allow_navigation(s) && SUCCEEDED(hr) && uri && (bounded || html) &&
        (s->remote.enabled?remote_allowed:((!s->custom_site||local) && (initial || explicit_url || refresh || (local && (s->allow_local_navigation || history)))))) {
        /* NavigateToString may report the whole document as a data URI, while
           its actual message Source is about:blank. Never duplicate that body. */
        WCHAR *source = _wcsdup(html ? L"about:blank" : uri);
        if (!source) {
            ICoreWebView2NavigationStartingEventArgs_put_Cancel(args, TRUE);
            notify(s, 2, NULL, E_OUTOFMEMORY);
        } else {
            BOOL same_navigation = s->has_document && s->navigation_id == id;
            free(s->document_source); s->document_source = source;
            free(s->expected_url); s->expected_url = NULL;
            s->expected_refresh = FALSE; s->expected_history = FALSE;
            s->initial_navigation = FALSE; s->has_document = TRUE;
            s->navigation_id = id; s->navigating = TRUE;
            if (!same_navigation) { s->committed = FALSE;file_controls_close(s); }
            if (!page_notify(s, 0, id, same_navigation ? 1 : 0, 0, uri))
                ICoreWebView2NavigationStartingEventArgs_put_Cancel(args, TRUE);
        }
    } else {
        ICoreWebView2NavigationStartingEventArgs_put_Cancel(args, TRUE);
        if (!s->closed && uri) policy_notify(s, 3, uri, user_initiated ? 1 : 0);
    }
    CoTaskMemFree(uri);
    release(s);
    return S_OK;
}

static BOOL trusted_source(State *s, const WCHAR *uri) {
    if (s->remote.enabled) return (remote_grants(&s->remote,uri)&REMOTE_NAVIGATE)!=0;
    return bounded_uri(uri) && (s->local_prefix ? local_source(s,uri) : wcscmp(uri, L"about:blank") == 0);
}
static HRESULT STDMETHODCALLTYPE content_invoke(ICoreWebView2ContentLoadingEventHandler *p, ICoreWebView2 *sender, ICoreWebView2ContentLoadingEventArgs *args) {
    (void)sender;
    State *s = ((ContentHandler *)p)->state; retain(s);
    uint64_t id = 0;
    if (!s->closed && s->has_document && SUCCEEDED(ICoreWebView2ContentLoadingEventArgs_get_NavigationId(args, &id)) && id == s->navigation_id)
        s->committed = TRUE;
    release(s); return S_OK;
}
static HRESULT STDMETHODCALLTYPE completed_invoke(ICoreWebView2NavigationCompletedEventHandler *p, ICoreWebView2 *sender, ICoreWebView2NavigationCompletedEventArgs *args) {
    State *s = ((CompletedHandler *)p)->state; retain(s);
    uint64_t id = 0; BOOL success = FALSE;
    COREWEBVIEW2_WEB_ERROR_STATUS status = COREWEBVIEW2_WEB_ERROR_STATUS_UNKNOWN;
    HRESULT hr = ICoreWebView2NavigationCompletedEventArgs_get_NavigationId(args, &id);
    if (!s->closed && !s->recovering && s->has_document && SUCCEEDED(hr) && id == s->navigation_id) {
        ICoreWebView2NavigationCompletedEventArgs_get_IsSuccess(args, &success);
        ICoreWebView2NavigationCompletedEventArgs_get_WebErrorStatus(args, &status);
        if (!success) file_controls_close(s);
        s->navigating = FALSE;
        WCHAR *current = NULL, *title = NULL;
        BOOL back = FALSE, forward = FALSE;
        if (SUCCEEDED(ICoreWebView2_get_Source(sender, &current)) && trusted_source(s, current)) {
            WCHAR *copy = _wcsdup(current);
            if (copy) { free(s->document_source); s->document_source = copy; }
        }
        if (s->observe_metadata) ICoreWebView2_get_DocumentTitle(sender, &title);
        HRESULT history_hr = ICoreWebView2_get_CanGoBack(sender, &back);
        if (SUCCEEDED(history_hr)) history_hr = ICoreWebView2_get_CanGoForward(sender, &forward);
        /* Refresh need not raise SourceChanged/DocumentTitleChanged: publish a
           load-completion snapshot as well. Capture before any application call. */
        if (trusted_source(s, current)) page_notify(s, 3, id, 1, 0, current);
        if (!s->closed && !s->recovering && id == s->navigation_id && title) page_notify(s, 4, id, 0, 0, title);
        if (!s->closed && !s->recovering && id == s->navigation_id && SUCCEEDED(history_hr))
            page_notify(s, 5, id, (back ? 1 : 0) | (forward ? 2 : 0), 0, NULL);
        if (!s->closed && !s->recovering && id == s->navigation_id)
            page_notify(s, 1, id, (success ? 1u : 0u) | (!success && status == COREWEBVIEW2_WEB_ERROR_STATUS_OPERATION_CANCELED ? 2u : 0u), (int32_t)status, NULL);
        CoTaskMemFree(current); CoTaskMemFree(title);
    }
    release(s); return S_OK;
}
static HRESULT STDMETHODCALLTYPE dom_invoke(ICoreWebView2DOMContentLoadedEventHandler *p, ICoreWebView2 *sender, ICoreWebView2DOMContentLoadedEventArgs *args) {
    (void)sender;
    State *s = ((DomHandler *)p)->state; retain(s);
    uint64_t id = 0;
    if (!s->closed && s->has_document && SUCCEEDED(ICoreWebView2DOMContentLoadedEventArgs_get_NavigationId(args, &id)) && id == s->navigation_id)
        page_notify(s, 2, id, 0, 0, NULL);
    release(s); return S_OK;
}
static HRESULT STDMETHODCALLTYPE source_invoke(ICoreWebView2SourceChangedEventHandler *p, ICoreWebView2 *sender, ICoreWebView2SourceChangedEventArgs *args) {
    (void)args;
    State *s = ((SourceHandler *)p)->state; retain(s);
    WCHAR *uri = NULL;
    if (!s->closed && !s->recovering && s->has_document && SUCCEEDED(ICoreWebView2_get_Source(sender, &uri))) {
        BOOL trusted = trusted_source(s, uri);
        WCHAR *copy = trusted ? _wcsdup(uri) : NULL;
        free(s->document_source); s->document_source = copy;
        if (!trusted || !copy) { s->committed = FALSE;file_controls_close(s); }
        if (trusted && !copy) notify(s, 2, NULL, E_OUTOFMEMORY);
        else page_notify(s, 3, s->navigation_id, trusted ? 1 : 0, 0, uri);
    }
    CoTaskMemFree(uri); release(s); return S_OK;
}
static HRESULT STDMETHODCALLTYPE title_invoke(ICoreWebView2DocumentTitleChangedEventHandler *p, ICoreWebView2 *sender, IUnknown *args) {
    (void)args;
    State *s = ((TitleHandler *)p)->state; retain(s);
    WCHAR *title = NULL;
    if (!s->closed && !s->recovering && s->has_document && SUCCEEDED(ICoreWebView2_get_DocumentTitle(sender, &title)))
        page_notify(s, 4, s->navigation_id, 0, 0, title);
    CoTaskMemFree(title); release(s); return S_OK;
}
static HRESULT STDMETHODCALLTYPE history_invoke(ICoreWebView2HistoryChangedEventHandler *p, ICoreWebView2 *sender, IUnknown *args) {
    (void)args;
    State *s = ((HistoryHandler *)p)->state; retain(s);
    BOOL back = FALSE, forward = FALSE;
    if (!s->closed && !s->recovering && s->has_document && SUCCEEDED(ICoreWebView2_get_CanGoBack(sender, &back)) && SUCCEEDED(ICoreWebView2_get_CanGoForward(sender, &forward)))
        page_notify(s, 5, s->navigation_id, (back ? 1 : 0) | (forward ? 2 : 0), 0, NULL);
    release(s); return S_OK;
}

static HRESULT STDMETHODCALLTYPE frame_invoke(ICoreWebView2NavigationStartingEventHandler *p, ICoreWebView2 *sender, ICoreWebView2NavigationStartingEventArgs *args) {
    (void)sender;
    State *s = ((FrameHandler *)p)->state; retain(s);
    ICoreWebView2NavigationStartingEventArgs_put_Cancel(args, TRUE);
    WCHAR *uri = NULL;
    ICoreWebView2NavigationStartingEventArgs_get_Uri(args, &uri);
    if (!s->closed && uri) policy_notify(s, 7, uri, 0);
    CoTaskMemFree(uri); release(s); return S_OK;
}
static HRESULT STDMETHODCALLTYPE popup_invoke(ICoreWebView2NewWindowRequestedEventHandler *p, ICoreWebView2 *sender, ICoreWebView2NewWindowRequestedEventArgs *args) {
    (void)sender;
    State *s = ((PopupHandler *)p)->state; retain(s);
    ICoreWebView2NewWindowRequestedEventArgs_put_Handled(args, TRUE);
    WCHAR *uri = NULL;
    ICoreWebView2NewWindowRequestedEventArgs_get_Uri(args, &uri);
    BOOL user = FALSE;
    ICoreWebView2NewWindowRequestedEventArgs_get_IsUserInitiated(args, &user);
    if (!s->closed && uri) policy_notify(s, 4, uri, user ? 1 : 0);
    CoTaskMemFree(uri); release(s); return S_OK;
}
static HRESULT STDMETHODCALLTYPE permission_invoke(ICoreWebView2PermissionRequestedEventHandler *p, ICoreWebView2 *sender, ICoreWebView2PermissionRequestedEventArgs *args) {
    (void)sender;
    State *s = ((PermissionHandler *)p)->state; retain(s);
    HRESULT safe=ICoreWebView2PermissionRequestedEventArgs_put_State(args, COREWEBVIEW2_PERMISSION_STATE_DENY);
    ICoreWebView2PermissionRequestedEventArgs3 *extended = NULL;
    if (SUCCEEDED(ICoreWebView2PermissionRequestedEventArgs_QueryInterface(args, &IID_ICoreWebView2PermissionRequestedEventArgs3, (void **)&extended))) {
        HRESULT no_save=ICoreWebView2PermissionRequestedEventArgs3_put_SavesInProfile(extended, FALSE);
        HRESULT handled=ICoreWebView2PermissionRequestedEventArgs3_put_Handled(extended, TRUE);
        if (SUCCEEDED(safe)) safe=FAILED(no_save)?no_save:handled;
    }
    WCHAR *uri = NULL; COREWEBVIEW2_PERMISSION_KIND kind = COREWEBVIEW2_PERMISSION_KIND_UNKNOWN_PERMISSION;
    HRESULT hr=ICoreWebView2PermissionRequestedEventArgs_get_Uri(args, &uri);
    if (SUCCEEDED(hr)) hr=ICoreWebView2PermissionRequestedEventArgs_get_PermissionKind(args, &kind);
    BOOL user=FALSE;
    if (SUCCEEDED(hr)) hr=ICoreWebView2PermissionRequestedEventArgs_get_IsUserInitiated(args,&user);
    const WCHAR *origin=SUCCEEDED(hr)?permission_offer_origin(s,uri,(uint32_t)kind,user):NULL;
    if (!s->closed&&!s->recovering&&extended&&SUCCEEDED(safe)&&SUCCEEDED(hr)&&origin) {
        PermissionCall call={s,extended,s->navigation_id,FALSE};
        s->actions->permission_offer(s->context,origin,(uint32_t)kind,user!=FALSE,&call);
    } else if (!s->closed && uri) policy_notify(s, 6, uri, (int)kind);
    if (extended) ICoreWebView2PermissionRequestedEventArgs3_Release(extended);
    CoTaskMemFree(uri); release(s); return S_OK;
}
static HRESULT STDMETHODCALLTYPE download_invoke(ICoreWebView2DownloadStartingEventHandler *p, ICoreWebView2 *sender, ICoreWebView2DownloadStartingEventArgs *args) {
    (void)sender;
    State *s = ((DownloadHandler *)p)->state; retain(s);
    HRESULT hr=ICoreWebView2DownloadStartingEventArgs_put_Cancel(args, TRUE);
    HRESULT handled=ICoreWebView2DownloadStartingEventArgs_put_Handled(args, TRUE);
    if (SUCCEEDED(hr)) hr=handled;
    ICoreWebView2DownloadOperation *operation=NULL;WCHAR *uri=NULL,*mime=NULL,*path=NULL;
    INT64 total=-1;
    if (SUCCEEDED(hr)) hr=ICoreWebView2DownloadStartingEventArgs_get_DownloadOperation(args,&operation);
    if (SUCCEEDED(hr)&&!operation) hr=E_POINTER;
    if (SUCCEEDED(hr)) hr=ICoreWebView2DownloadOperation_get_Uri(operation,&uri);
    if (SUCCEEDED(hr)) hr=ICoreWebView2DownloadOperation_get_TotalBytesToReceive(operation,&total);
    if (SUCCEEDED(hr)) hr=ICoreWebView2DownloadOperation_get_MimeType(operation,&mime);
    if (SUCCEEDED(hr)) hr=ICoreWebView2DownloadStartingEventArgs_get_ResultFilePath(args,&path);
    if (SUCCEEDED(hr)&&path&&wcsnlen(path,32768)>32767) hr=E_INVALIDARG;
    const WCHAR *name=path?path:L"";
    if (SUCCEEDED(hr)&&path) for (const WCHAR *p=path;*p;p++) if (*p==L'/'||*p==L'\\') name=p+1;
    if (!s->closed&&!s->recovering&&SUCCEEDED(hr)&&mime&&wcsnlen(mime,128)<=127&&wcsnlen(name,256)<=255&&download_origin_allowed(s,uri,total)) {
        DownloadCall call={s,args,operation,FALSE};s->actions->download_offer(s->context,uri,mime,name,total,&call);
    } else if (!s->closed&&uri) policy_notify(s,5,uri,0);
    if (operation) ICoreWebView2DownloadOperation_Release(operation);
    CoTaskMemFree(uri);CoTaskMemFree(mime);CoTaskMemFree(path);release(s);return S_OK;
}
static HRESULT STDMETHODCALLTYPE process_invoke(ICoreWebView2ProcessFailedEventHandler *p, ICoreWebView2 *sender, ICoreWebView2ProcessFailedEventArgs *args) {
    (void)sender;
    State *s = ((ProcessHandler *)p)->state; retain(s);
    COREWEBVIEW2_PROCESS_FAILED_KIND kind = COREWEBVIEW2_PROCESS_FAILED_KIND_BROWSER_PROCESS_EXITED;
    if (SUCCEEDED(ICoreWebView2ProcessFailedEventArgs_get_ProcessFailedKind(args, &kind)) && !s->closed) { file_controls_close(s);notify(s, 8, NULL, (HRESULT)kind); }
    release(s); return S_OK;
}
/* The app's offer changes WebView2's menu in place, which WebView2 then
   shows: its own items keep doing what they do. */
typedef struct ContextCall { State *state; ICoreWebView2ContextMenuItemCollection *items; ICoreWebView2Environment9 *environment; } ContextCall;
HRESULT zwv_context_menu_append(void *call_pointer,const WCHAR *label,uint32_t command,uint32_t kind,uint32_t flags) {
    ContextCall *call=call_pointer;
    if (!call||!call->environment||(kind!=3&&!label)) return E_INVALIDARG;
    State *s=call->state;
    if (kind!=3&&s->context_count==32) return HRESULT_FROM_WIN32(ERROR_NOT_ENOUGH_QUOTA);
    const COREWEBVIEW2_CONTEXT_MENU_ITEM_KIND native=kind==1?COREWEBVIEW2_CONTEXT_MENU_ITEM_KIND_CHECK_BOX:kind==3?COREWEBVIEW2_CONTEXT_MENU_ITEM_KIND_SEPARATOR:COREWEBVIEW2_CONTEXT_MENU_ITEM_KIND_COMMAND;
    ICoreWebView2ContextMenuItem *item=NULL;
    HRESULT hr=ICoreWebView2Environment9_CreateContextMenuItem(call->environment,kind==3?L"":label,NULL,native,&item);
    if (SUCCEEDED(hr)&&!item) hr=E_POINTER;
    if (SUCCEEDED(hr)&&kind!=3) hr=ICoreWebView2ContextMenuItem_put_IsEnabled(item,(flags&1)!=0);
    if (SUCCEEDED(hr)&&kind==1) hr=ICoreWebView2ContextMenuItem_put_IsChecked(item,(flags&2)!=0);
    INT32 id=0;
    if (SUCCEEDED(hr)&&kind!=3) hr=ICoreWebView2ContextMenuItem_get_CommandId(item,&id);
    if (SUCCEEDED(hr)&&kind!=3) {
        ContextItemHandler *handler=ContextItemHandler_new(s);
        EventRegistrationToken token;
        if (!handler) hr=E_OUTOFMEMORY;
        else { hr=ICoreWebView2ContextMenuItem_add_CustomItemSelected(item,&handler->iface,&token); ContextItemHandler_release(&handler->iface); }
    }
    UINT32 count=0;
    if (SUCCEEDED(hr)) hr=ICoreWebView2ContextMenuItemCollection_get_Count(call->items,&count);
    if (SUCCEEDED(hr)) hr=ICoreWebView2ContextMenuItemCollection_InsertValueAtIndex(call->items,count,item);
    if (SUCCEEDED(hr)&&kind!=3) { s->context_native[s->context_count]=id; s->context_command[s->context_count]=command; s->context_count++; }
    if (item) ICoreWebView2ContextMenuItem_Release(item);
    return hr;
}
static WCHAR *context_target_text(ICoreWebView2ContextMenuTarget *target,HRESULT (STDMETHODCALLTYPE *has)(ICoreWebView2ContextMenuTarget *,BOOL *),HRESULT (STDMETHODCALLTYPE *get)(ICoreWebView2ContextMenuTarget *,LPWSTR *)) {
    BOOL present=FALSE; LPWSTR value=NULL;
    if (has&&(FAILED(has(target,&present))||!present)) return NULL;
    if (FAILED(get(target,&value))) return NULL;
    if (value&&!*value) { CoTaskMemFree(value); return NULL; }
    return value;
}
static BOOL context_item_separator(ICoreWebView2ContextMenuItemCollection *items,UINT32 index,BOOL *separator) {
    ICoreWebView2ContextMenuItem *item=NULL;
    COREWEBVIEW2_CONTEXT_MENU_ITEM_KIND kind=COREWEBVIEW2_CONTEXT_MENU_ITEM_KIND_COMMAND;
    if (FAILED(ICoreWebView2ContextMenuItemCollection_GetValueAtIndex(items,index,&item))||!item) return FALSE;
    (void)ICoreWebView2ContextMenuItem_get_Kind(item,&kind);
    ICoreWebView2ContextMenuItem_Release(item);
    *separator=kind==COREWEBVIEW2_CONTEXT_MENU_ITEM_KIND_SEPARATOR;
    return TRUE;
}
/* Separators first, last or after another go with the items around them. */
static void context_menu_tidy(ICoreWebView2ContextMenuItemCollection *items) {
    UINT32 count=0;
    BOOL previous=TRUE,separator=FALSE;
    if (FAILED(ICoreWebView2ContextMenuItemCollection_get_Count(items,&count))) return;
    for (UINT32 i=0;i<count;) {
        if (!context_item_separator(items,i,&separator)) return;
        if (separator&&previous) {
            if (FAILED(ICoreWebView2ContextMenuItemCollection_RemoveValueAtIndex(items,i))) return;
            count--; continue;
        }
        previous=separator; i++;
    }
    while (count>0&&context_item_separator(items,count-1,&separator)&&separator) {
        if (FAILED(ICoreWebView2ContextMenuItemCollection_RemoveValueAtIndex(items,count-1))) return;
        count--;
    }
}
static HRESULT STDMETHODCALLTYPE context_menu_invoke(ICoreWebView2ContextMenuRequestedEventHandler *p,ICoreWebView2 *sender,ICoreWebView2ContextMenuRequestedEventArgs *args) {
    (void)sender; State *s=((ContextMenuHandler *)p)->state; retain(s);
    ICoreWebView2ContextMenuItemCollection *items=NULL; ICoreWebView2ContextMenuTarget *target=NULL; ICoreWebView2Environment9 *environment=NULL;
    ContextItemInput inputs[64]; LPWSTR names[64],labels[64]; uint8_t keep[64]; UINT32 count=0,listed=0;
    ContextTargetInput in={0}; LPWSTR frame=NULL,source=NULL,selection=NULL,link=NULL,link_text=NULL;
    BOOL prevented=FALSE;
    HRESULT hr=s->closed||!s->context_offer?E_ABORT:ICoreWebView2ContextMenuRequestedEventArgs_get_MenuItems(args,&items);
    if (SUCCEEDED(hr)&&!items) hr=E_POINTER;
    if (SUCCEEDED(hr)) hr=ICoreWebView2ContextMenuRequestedEventArgs_get_ContextMenuTarget(args,&target);
    if (SUCCEEDED(hr)&&!target) hr=E_POINTER;
    if (SUCCEEDED(hr)) hr=ICoreWebView2Environment_QueryInterface(s->environment,&IID_ICoreWebView2Environment9,(void **)&environment);
    if (SUCCEEDED(hr)) hr=ICoreWebView2ContextMenuItemCollection_get_Count(items,&count);
    for (UINT32 i=0;SUCCEEDED(hr)&&i<count&&i<64;i++) {
        ICoreWebView2ContextMenuItem *item=NULL;
        COREWEBVIEW2_CONTEXT_MENU_ITEM_KIND kind=COREWEBVIEW2_CONTEXT_MENU_ITEM_KIND_COMMAND; BOOL enabled=FALSE,checked=FALSE;
        names[i]=labels[i]=NULL;
        if (FAILED(ICoreWebView2ContextMenuItemCollection_GetValueAtIndex(items,i,&item))||!item) break;
        (void)ICoreWebView2ContextMenuItem_get_Name(item,&names[i]);
        (void)ICoreWebView2ContextMenuItem_get_Label(item,&labels[i]);
        (void)ICoreWebView2ContextMenuItem_get_Kind(item,&kind);
        (void)ICoreWebView2ContextMenuItem_get_IsEnabled(item,&enabled);
        (void)ICoreWebView2ContextMenuItem_get_IsChecked(item,&checked);
        ICoreWebView2ContextMenuItem_Release(item);
        inputs[i]=(ContextItemInput){names[i]?names[i]:L"",labels[i]?labels[i]:L"",kind==COREWEBVIEW2_CONTEXT_MENU_ITEM_KIND_CHECK_BOX?1u:kind==COREWEBVIEW2_CONTEXT_MENU_ITEM_KIND_RADIO?2u:kind==COREWEBVIEW2_CONTEXT_MENU_ITEM_KIND_SEPARATOR?3u:kind==COREWEBVIEW2_CONTEXT_MENU_ITEM_KIND_SUBMENU?4u:0u,(enabled?1u:0u)|(checked?2u:0u)};
        keep[i]=1; listed=i+1;
    }
    if (SUCCEEDED(hr)&&!s->closed) {
        COREWEBVIEW2_CONTEXT_MENU_TARGET_KIND kind=COREWEBVIEW2_CONTEXT_MENU_TARGET_KIND_PAGE;
        BOOL editable=FALSE,main=TRUE;
        (void)ICoreWebView2ContextMenuTarget_get_Kind(target,&kind);
        (void)ICoreWebView2ContextMenuTarget_get_IsEditable(target,&editable);
        (void)ICoreWebView2ContextMenuTarget_get_IsRequestedForMainFrame(target,&main);
        link=context_target_text(target,target->lpVtbl->get_HasLinkUri,target->lpVtbl->get_LinkUri);
        link_text=context_target_text(target,target->lpVtbl->get_HasLinkText,target->lpVtbl->get_LinkText);
        source=context_target_text(target,target->lpVtbl->get_HasSourceUri,target->lpVtbl->get_SourceUri);
        selection=context_target_text(target,target->lpVtbl->get_HasSelection,target->lpVtbl->get_SelectionText);
        if (!main) frame=context_target_text(target,NULL,target->lpVtbl->get_FrameUri);
        in.link=link; in.link_text=link_text; in.selection=selection; in.frame=frame; in.editable=editable?1u:0u;
        if (kind==COREWEBVIEW2_CONTEXT_MENU_TARGET_KIND_IMAGE) in.image=source;
        else if (kind==COREWEBVIEW2_CONTEXT_MENU_TARGET_KIND_AUDIO||kind==COREWEBVIEW2_CONTEXT_MENU_TARGET_KIND_VIDEO) in.media=source;
        s->context_count=0;
        ContextCall call={s,items,environment};
        prevented=s->context_offer(s->context,&in,inputs,listed,keep,&call)!=0;
        if (!s->closed&&!prevented) {
            for (UINT32 i=listed;i>0;i--) if (!keep[i-1]) (void)ICoreWebView2ContextMenuItemCollection_RemoveValueAtIndex(items,i-1);
            context_menu_tidy(items);
            UINT32 left=0;
            /* A menu the app emptied shows nothing. */
            if (SUCCEEDED(ICoreWebView2ContextMenuItemCollection_get_Count(items,&left))&&!left) prevented=TRUE;
        }
    }
    if (prevented||s->closed) (void)ICoreWebView2ContextMenuRequestedEventArgs_put_Handled(args,TRUE);
    for (UINT32 i=0;i<listed;i++) { CoTaskMemFree(names[i]); CoTaskMemFree(labels[i]); }
    CoTaskMemFree(frame); CoTaskMemFree(source); CoTaskMemFree(selection); CoTaskMemFree(link); CoTaskMemFree(link_text);
    if (environment) ICoreWebView2Environment9_Release(environment);
    if (target) ICoreWebView2ContextMenuTarget_Release(target);
    if (items) ICoreWebView2ContextMenuItemCollection_Release(items);
    release(s); return S_OK;
}
static HRESULT STDMETHODCALLTYPE context_item_invoke(ICoreWebView2CustomItemSelectedEventHandler *p,ICoreWebView2ContextMenuItem *sender,IUnknown *args) {
    (void)args; State *s=((ContextItemHandler *)p)->state; retain(s);
    INT32 id=0;
    if (!s->closed&&sender&&SUCCEEDED(ICoreWebView2ContextMenuItem_get_CommandId(sender,&id)))
        for (uint32_t i=0;i<s->context_count;i++) if (s->context_native[i]==id) { (void)page_notify(s,11,0,0,(int32_t)s->context_command[i],NULL); break; }
    release(s); return S_OK;
}
typedef struct AuthCall { ICoreWebView2BasicAuthenticationRequestedEventArgs *args; BOOL answered; } AuthCall;
HRESULT zwv_auth_answer(void *call_pointer,const WCHAR *user,const WCHAR *password) {
    AuthCall *call=call_pointer;
    if (!call||call->answered||!user||!password) return E_INVALIDARG;
    ICoreWebView2BasicAuthenticationResponse *response=NULL;
    HRESULT hr=ICoreWebView2BasicAuthenticationRequestedEventArgs_get_Response(call->args,&response);
    if (SUCCEEDED(hr)&&!response) hr=E_POINTER;
    if (SUCCEEDED(hr)) hr=ICoreWebView2BasicAuthenticationResponse_put_UserName(response,user);
    if (SUCCEEDED(hr)) hr=ICoreWebView2BasicAuthenticationResponse_put_Password(response,password);
    if (response) ICoreWebView2BasicAuthenticationResponse_Release(response);
    if (SUCCEEDED(hr)) call->answered=TRUE;
    return hr;
}
/* Every sign-in is answered: WebView2's own dialog never shows. Without the
   app's credentials the request goes without, to the server's refusal. */
static HRESULT STDMETHODCALLTYPE authentication_invoke(ICoreWebView2BasicAuthenticationRequestedEventHandler *p, ICoreWebView2 *sender, ICoreWebView2BasicAuthenticationRequestedEventArgs *args) {
    (void)sender; State *s=((AuthenticationHandler *)p)->state; retain(s);
    AuthCall call={args,FALSE};
    if (!s->closed&&s->auth) {
        WCHAR *uri=NULL,*challenge=NULL;
        if (SUCCEEDED(ICoreWebView2BasicAuthenticationRequestedEventArgs_get_Uri(args,&uri))&&uri&&
            SUCCEEDED(ICoreWebView2BasicAuthenticationRequestedEventArgs_get_Challenge(args,&challenge))&&challenge&&!s->closed)
            s->auth(s->context,uri,challenge,&call);
        CoTaskMemFree(uri);CoTaskMemFree(challenge);
    }
    if (!call.answered) ICoreWebView2BasicAuthenticationRequestedEventArgs_put_Cancel(args,TRUE);
    release(s); return S_OK;
}
static HRESULT STDMETHODCALLTYPE certificate_invoke(ICoreWebView2ClientCertificateRequestedEventHandler *p, ICoreWebView2 *sender, ICoreWebView2ClientCertificateRequestedEventArgs *args) {
    (void)p; (void)sender;
    ICoreWebView2ClientCertificateRequestedEventArgs_put_Cancel(args,TRUE);
    ICoreWebView2ClientCertificateRequestedEventArgs_put_Handled(args,TRUE); return S_OK;
}

typedef struct ResourceCall { State *state; ICoreWebView2WebResourceRequestedEventArgs *args; BOOL responded, head; } ResourceCall;
typedef struct ResponseHeader { const char *name; uint32_t name_len; const char *value; uint32_t value_len; } ResponseHeader;
static BOOL response_header_reserved(const char *name,size_t length) {
    static const char *names[]={"content-type","content-length","transfer-encoding","connection","keep-alive","te","trailer","upgrade","proxy-authenticate","proxy-authorization"};
    for (size_t i=0;i<sizeof(names)/sizeof(names[0]);i++) if (header_ascii_equal(name,length,names[i],strlen(names[i]))) return TRUE;
    return FALSE;
}
static HRESULT response_headers(unsigned status,const char *mime,size_t mime_len,uint64_t body_len,const ResponseHeader *extra,uint32_t extra_count,WCHAR *headers) {
    if (status < 200 || status > 599 || !mime || !mime_len || mime_len > 127 || extra_count>16 || (extra_count&&!extra) || ((status==204||status==205||status==304)&&body_len)) return E_INVALIDARG;
    WCHAR type[128];
    for (size_t i = 0; i < mime_len; i++) {
        if ((unsigned char)mime[i] < 32 || (unsigned char)mime[i] > 126) return E_INVALIDARG;
        type[i] = (WCHAR)mime[i];
    }
    type[mime_len] = 0;
    BOOL nosniff=FALSE,cache=FALSE; size_t extra_bytes=0;
    for (uint32_t i=0;i<extra_count;i++) {
        const ResponseHeader *header=&extra[i];
        if (!header->name||!header->name_len||header->name_len>64||header->value_len>2048||(header->value_len&&!header->value)||response_header_reserved(header->name,header->name_len)) return E_INVALIDARG;
        for (uint32_t j=0;j<header->name_len;j++) if ((unsigned char)header->name[j]>126||!header_token_char((unsigned char)header->name[j])) return E_INVALIDARG;
        for (uint32_t j=0;j<header->value_len;j++) if ((unsigned char)header->value[j]<32||(unsigned char)header->value[j]>126) return E_INVALIDARG;
        for (uint32_t j=0;j<i;j++) if (header_ascii_equal(extra[j].name,extra[j].name_len,header->name,header->name_len)) return E_INVALIDARG;
        if ((extra_bytes+=header->name_len+header->value_len+4)>8192) return E_INVALIDARG;
        if (header_ascii_equal(header->name,header->name_len,"x-content-type-options",22)) nosniff=TRUE;
        if (header_ascii_equal(header->name,header->name_len,"cache-control",13)) cache=TRUE;
    }
    int used=_snwprintf(headers,8704,L"Content-Type: %ls\r\n",type);
    if (!nosniff) used+=_snwprintf(headers+used,8704-used,L"X-Content-Type-Options: nosniff\r\n");
    if (!cache) used+=_snwprintf(headers+used,8704-used,L"Cache-Control: no-store\r\n");
    if (status!=204&&status!=304) used+=_snwprintf(headers+used,8704-used,L"Content-Length: %llu\r\n",(unsigned long long)body_len);
    for (uint32_t i=0;i<extra_count;i++) {
        const ResponseHeader *header=&extra[i];
        for (uint32_t j=0;j<header->name_len;j++) headers[used++]=(unsigned char)header->name[j];
        headers[used++]=L':';headers[used++]=L' ';
        for (uint32_t j=0;j<header->value_len;j++) headers[used++]=(unsigned char)header->value[j];
        headers[used++]=L'\r';headers[used++]=L'\n';
    }
    headers[used]=0;
    return S_OK;
}
HRESULT zwv_respond(ResourceCall *call, unsigned status, const char *mime, size_t mime_len, const unsigned char *body, size_t body_len,const ResponseHeader *extra,uint32_t extra_count) {
    if (!call || call->responded || call->state->closed) return E_ABORT;
    if (body_len > 16u*1024u*1024u || (body_len && !body)) return E_INVALIDARG;
    WCHAR headers[8704];HRESULT hr=response_headers(status,mime,mime_len,body_len,extra,extra_count,headers);
    if(FAILED(hr))return hr;
    IStream *stream = NULL;
    if (call->head || body_len == 0) hr = CreateStreamOnHGlobal(NULL, TRUE, &stream);
    else { stream = SHCreateMemStream(body, (UINT)body_len); hr = stream ? S_OK : E_OUTOFMEMORY; }
    if (FAILED(hr)) return hr;
    ICoreWebView2WebResourceResponse *response = NULL;
    hr = ICoreWebView2Environment_CreateWebResourceResponse(call->state->environment, stream, (int)status,
        status == 200 ? L"OK" : status == 404 ? L"Not Found" : status == 403 ? L"Forbidden" : L"Response", headers, &response);
    IStream_Release(stream);
    if (SUCCEEDED(hr)) {
        hr = ICoreWebView2WebResourceRequestedEventArgs_put_Response(call->args, response);
        ICoreWebView2WebResourceResponse_Release(response);
        if (SUCCEEDED(hr)) call->responded = TRUE;
    }
    return hr;
}
#include "resource_deferrals.h"
#include "file_stream.h"
static HRESULT STDMETHODCALLTYPE resource_invoke(ICoreWebView2WebResourceRequestedEventHandler *p, ICoreWebView2 *sender, ICoreWebView2WebResourceRequestedEventArgs *args) {
    (void)sender;
    State *s = ((ResourceHandler *)p)->state; retain(s);
    ICoreWebView2WebResourceRequest *request = NULL; WCHAR *uri = NULL, *method = NULL;
    ResourceCall call = { s, args, FALSE, FALSE };
    NativeHeader headers[REQUEST_HEADER_LIMIT];uint32_t header_count=0;
    if (SUCCEEDED(ICoreWebView2WebResourceRequestedEventArgs_get_Request(args, &request)) && request) {
        ICoreWebView2WebResourceRequest_get_Uri(request, &uri);
        ICoreWebView2WebResourceRequest_get_Method(request, &method);
        call.head = method && wcscmp(method, L"HEAD") == 0;
        int parsed=request_method(method);
        ICoreWebView2HttpRequestHeaders *sending_headers=NULL;
        HRESULT headers_hr=S_OK;
        if(s->remote.credentials){
            headers_hr=ICoreWebView2WebResourceRequest_get_Headers(request,&sending_headers);
            if(SUCCEEDED(headers_hr))headers_hr=sending_headers?ICoreWebView2HttpRequestHeaders_RemoveHeader(sending_headers,L"Authorization"):E_POINTER;
        }
        if(SUCCEEDED(headers_hr))headers_hr=parsed<0?E_INVALIDARG:headers_collect(request,headers,&header_count);
        const WCHAR *authorization=NULL;
        if (!s->closed && s->remote.enabled && SUCCEEDED(headers_hr) && remote_request_check(&s->remote,uri,parsed,headers,header_count,&authorization)) {
            COREWEBVIEW2_WEB_RESOURCE_CONTEXT resource_context=COREWEBVIEW2_WEB_RESOURCE_CONTEXT_ALL;
            HRESULT context_hr=ICoreWebView2WebResourceRequestedEventArgs_get_ResourceContext(args,&resource_context);
            BOOL document_allowed=SUCCEEDED(context_hr) && (resource_context!=COREWEBVIEW2_WEB_RESOURCE_CONTEXT_DOCUMENT ||
                (initializers_allow_navigation(s) && s->navigating && remote_url_equal(uri,s->document_source,TRUE)));
            if(document_allowed&&authorization)document_allowed=sending_headers&&SUCCEEDED(ICoreWebView2HttpRequestHeaders_SetHeader(sending_headers,L"Authorization",authorization));
            if (!s->closed && document_allowed) {
                if(sending_headers)ICoreWebView2HttpRequestHeaders_Release(sending_headers);
                ICoreWebView2WebResourceRequest_Release(request);
                headers_free(headers,header_count);
                CoTaskMemFree(uri); CoTaskMemFree(method); release(s); return S_OK;
            }
        }
        if(sending_headers)ICoreWebView2HttpRequestHeaders_Release(sending_headers);
        if (!s->closed && s->resource && local_source(s,uri) && SUCCEEDED(headers_hr) &&
            (!s->custom_site||scheme_request_origin_allowed(s->environment_options,s->local_prefix,parsed,headers,header_count))) {
            s->resource(s->context, uri, method, headers,header_count,&call);
        }
        ICoreWebView2WebResourceRequest_Release(request);
    }
    if (!call.responded && !s->closed) {
        HRESULT hr = s->denied_response?ICoreWebView2WebResourceRequestedEventArgs_put_Response(args,s->denied_response):E_UNEXPECTED;
        if (FAILED(hr)) notify(s, 2, NULL, hr);
    }
    headers_free(headers,header_count); CoTaskMemFree(uri); CoTaskMemFree(method); release(s); return S_OK;
}

typedef HRESULT (STDAPICALLTYPE *CreateEnvironment)(PCWSTR, PCWSTR, ICoreWebView2EnvironmentOptions *, ICoreWebView2CreateCoreWebView2EnvironmentCompletedHandler *);
static HMODULE loader; /* Process-lifetime module; async callbacks can outlive a window. */
static HRESULT load_loader(void) {
    if (loader) return S_OK;
    WCHAR *path = calloc(32768, sizeof(WCHAR));
    if (!path) return E_OUTOFMEMORY;
    DWORD length = GetModuleFileNameW(NULL, path, 32768);
    WCHAR *slash = wcsrchr(path, L'\\');
    if (!length || length >= 32768 || !slash || (slash - path) + 20 >= 32768) { free(path); return E_FAIL; }
    wcscpy(slash + 1, L"WebView2Loader.dll");
    loader = LoadLibraryExW(path, NULL, LOAD_LIBRARY_SEARCH_DLL_LOAD_DIR | LOAD_LIBRARY_SEARCH_SYSTEM32);
    DWORD error = GetLastError();
    free(path);
    return loader ? S_OK : HRESULT_FROM_WIN32(error);
}

State *zwv_create(HWND hwnd, const WCHAR *html, const WCHAR *profile, const WCHAR *initial_url, const WCHAR *local_prefix, const RemoteInput *remote, const ViewSettings *settings,
    unsigned policy, unsigned permission_limit, unsigned script_limit, _Bool allow_local_navigation, _Bool observe_metadata, Notify callback, PageNotify page_callback, ScriptNotify script_callback, ToolNotify tool_callback, Resource resource, void *context, HRESULT *out) {
    ZwpwContext *owned=settings?settings->owned_context:NULL;
    if (owned) zwpw_context_ref(owned);
    *out = load_loader();
    if (FAILED(*out)) { if (owned) zwpw_context_unref(owned);return NULL; }
    CreateEnvironment create = (CreateEnvironment)GetProcAddress(loader, "CreateCoreWebView2EnvironmentWithOptions");
    if (!create) { *out = HRESULT_FROM_WIN32(ERROR_PROC_NOT_FOUND);if (owned) zwpw_context_unref(owned);return NULL; }
    State *s = calloc(1, sizeof(*s));
    if (!s) { *out = E_OUTOFMEMORY;if (owned) zwpw_context_unref(owned);return NULL; }
    s->owned_context=owned;
    InterlockedIncrement(&live_states);
    s->refs = 1; s->hwnd = hwnd; s->notify = callback; s->resource = resource; s->context = context; s->policy = policy; s->permission_limit = permission_limit;
    s->script_limit=script_limit; s->script_notify=script_callback;
    if (!script_limit || script_limit>16) { release(s); *out=E_INVALIDARG; return NULL; }
    s->zoom=settings?settings->zoom:1.0; s->devtools=settings && settings->devtools;
    s->tool_notify=tool_callback;
    s->tool_flags=settings?settings->tool_flags:0; s->tool_limit=settings?settings->tool_limit:8;
    s->max_cookies=settings?settings->max_cookies:128; s->max_cookie_bytes=settings?settings->max_cookie_bytes:65536;
    s->max_capture_bytes=settings?settings->max_capture_bytes:4194304;
    if (!s->tool_limit || s->tool_limit>8 || !s->max_cookies || s->max_cookies>128 || !s->max_cookie_bytes || s->max_cookie_bytes>262144 || !s->max_capture_bytes || s->max_capture_bytes>16777216) { release(s); *out=E_INVALIDARG; return NULL; }
    if (s->zoom!=s->zoom || s->zoom<0.25 || s->zoom>5.0) { release(s); *out=E_INVALIDARG; return NULL; }
    if (settings && settings->user_agent) { s->user_agent=_wcsdup(settings->user_agent); if (!s->user_agent) { release(s); *out=E_OUTOFMEMORY; return NULL; } }
    if (settings) { s->auth=settings->auth; s->certificate_offer=settings->certificate_offer; s->context_menu=settings->context_menu; s->context_offer=settings->context_offer; s->gestures=settings->gestures; }
    if (settings && settings->facts) { s->facts_script=_wcsdup(settings->facts); if (!s->facts_script) { release(s); *out=E_OUTOFMEMORY; return NULL; } }
    *out=remote_init(&s->remote,remote);
    if (FAILED(*out)) { release(s); return NULL; }
    *out=action_policy_new(settings?settings->actions:NULL,&s->actions);
    if (FAILED(*out)) { release(s);return NULL; }
    s->page_notify = page_callback; s->allow_local_navigation = allow_local_navigation;
    s->observe_metadata = observe_metadata;
    s->html = initial_url ? NULL : _wcsdup(html);
    if (initial_url) s->initial_url = _wcsdup(initial_url);
    if (local_prefix) s->local_prefix = _wcsdup(local_prefix);
    if ((!initial_url && !s->html) || (initial_url && !s->initial_url) || (local_prefix && !s->local_prefix)) { release(s); *out = E_OUTOFMEMORY; return NULL; }
    if (owned) {
        if (settings->scheme_count||settings->browser_arguments||!profile||*profile) { release(s);*out=E_INVALIDARG;return NULL; }
    } else {
        *out=scheme_options_new(settings?settings->schemes:NULL,settings?settings->scheme_count:0,settings?settings->browser_arguments:NULL,&s->environment_options);
        if (FAILED(*out)) { release(s);return NULL; }
    }
    s->custom_site=local_prefix&&wcsncmp(local_prefix,L"https://",8)!=0;
    s->local_ipc=!s->custom_site||(settings&&settings->local_ipc);
    if (s->custom_site) {
        BOOL registered=FALSE;
        for (uint32_t i=0;settings&&i<settings->scheme_count;i++) {
            size_t length=wcslen(settings->schemes[i].name);
            if (wcsncmp(local_prefix,settings->schemes[i].name,length)==0&&local_prefix[length]==L':') registered=TRUE;
        }
        if (!registered || !scheme_uri_matches(local_prefix,local_prefix)) { release(s);*out=E_INVALIDARG;return NULL; }
    }
    if (settings && settings->initializers) {
        *out=zwv_initializers_prepare(s,settings->initializers,0,NULL);
        if (FAILED(*out)) { release(s);return NULL; }
    }
    if (owned) {
        ZwpwContextStart start={s,owned_environment,owned_revoke,owned_release};
        retain(s);
        int result=zwpw_context_begin(owned,create,&start);
        if (result!=ZWPW_PROFILE_OK) {
            release(s);*out=result==ZWPW_PROFILE_FULL?HRESULT_FROM_WIN32(ERROR_NOT_ENOUGH_QUOTA):E_ABORT;
            initializers_close(s);release(s);return NULL;
        }
        *out=S_OK;
    } else {
        EnvironmentHandler *h = EnvironmentHandler_new(s);
        if (!h) { initializers_close(s);release(s); *out = E_OUTOFMEMORY; return NULL; }
        *out = create(NULL, profile, s->environment_options, &h->iface);
        EnvironmentHandler_release(&h->iface);
    }
    if (FAILED(*out)) { s->closed = TRUE; s->context = NULL; s->notify = NULL; s->resource = NULL; initializers_close(s);release(s); return NULL; }
    return s;
}

HRESULT zwv_post(State *s, const WCHAR *message) {
    if (s->closed || !s->webview) return E_ABORT;
    if (s->custom_site && (!s->local_ipc || !s->committed || !local_source(s,s->document_source))) return E_ACCESSDENIED;
    if (s->remote.enabled && (!s->committed || !s->document_source || !(remote_grants(&s->remote,s->document_source)&REMOTE_IPC))) return E_ACCESSDENIED;
    return ICoreWebView2_PostWebMessageAsString(s->webview, message);
}
/* The browser process the app's web views share. */
HRESULT zwv_process_id(State *s,uint32_t *pid) {
    *pid=0;
    if (s->closed || s->recovering || !s->webview) return E_ABORT;
    UINT32 value=0;
    HRESULT hr=ICoreWebView2_get_BrowserProcessId(s->webview,&value);
    if (SUCCEEDED(hr)) *pid=value;
    return hr;
}
HRESULT zwv_zoom(State *s,double *value,_Bool set) {
    if (s->closed || s->recovering || !s->controller) return E_ABORT;
    if (set) {
        if (*value!=*value || *value<0.25 || *value>5.0) return E_INVALIDARG;
        return ICoreWebView2Controller_put_ZoomFactor(s->controller,*value);
    }
    return ICoreWebView2Controller_get_ZoomFactor(s->controller,value);
}
HRESULT zwv_user_agent(State *s,const WCHAR *value,WCHAR **out) {
    if (s->closed || s->recovering || !s->webview) return E_ABORT;
    ICoreWebView2Settings *settings=NULL;
    ICoreWebView2Settings2 *settings2=NULL;
    HRESULT hr=ICoreWebView2_get_Settings(s->webview,&settings);
    if (SUCCEEDED(hr)) hr=ICoreWebView2Settings_QueryInterface(settings,&IID_ICoreWebView2Settings2,(void **)&settings2);
    if (settings) ICoreWebView2Settings_Release(settings);
    if (SUCCEEDED(hr)) {
        hr=out?ICoreWebView2Settings2_get_UserAgent(settings2,out):ICoreWebView2Settings2_put_UserAgent(settings2,value);
        ICoreWebView2Settings2_Release(settings2);
    }
    return hr;
}
void zwv_string_free(WCHAR *value) { CoTaskMemFree(value); }
/* The URI of the page's own document that last loaded, for a session
   state; NULL before one did. */
HRESULT zwv_document_source(State *s,WCHAR **out) {
    *out=NULL;
    if (s->closed || s->recovering || !s->webview) return E_ABORT;
    if (!s->document_source) return S_FALSE;
    const size_t bytes=(wcslen(s->document_source)+1)*sizeof(WCHAR);
    if (!(*out=CoTaskMemAlloc(bytes))) return E_OUTOFMEMORY;
    memcpy(*out,s->document_source,bytes);
    return S_OK;
}
HRESULT zwv_devtools(State *s,_Bool *enabled,_Bool set,_Bool open) {
    if (s->closed || s->recovering || !s->webview) return E_ABORT;
    ICoreWebView2Settings *settings=NULL;
    HRESULT hr=ICoreWebView2_get_Settings(s->webview,&settings);
    BOOL value=*enabled;
    if (SUCCEEDED(hr)) {
        hr=set?ICoreWebView2Settings_put_AreDevToolsEnabled(settings,value):ICoreWebView2Settings_get_AreDevToolsEnabled(settings,&value);
        ICoreWebView2Settings_Release(settings);
    }
    if (SUCCEEDED(hr)) {
        *enabled=value!=FALSE;
        if (open) hr=value?ICoreWebView2_OpenDevToolsWindow(s->webview):E_ACCESSDENIED;
    }
    return hr;
}
HRESULT zwv_navigate_remote(State *s,const WCHAR *url) {
    if (s->closed || s->recovering || !s->webview) return E_ABORT;
    if (!initializers_allow_navigation(s)) return E_PENDING;
    if (!(remote_grants(&s->remote,url)&REMOTE_NAVIGATE)) return E_ACCESSDENIED;
    if (s->expected_url || s->expected_refresh || s->expected_history) return E_PENDING;
    s->expected_url=_wcsdup(url); if (!s->expected_url) return E_OUTOFMEMORY;
    HRESULT hr=ICoreWebView2_Navigate(s->webview,url);
    if (FAILED(hr)) { free(s->expected_url); s->expected_url=NULL; }
    return hr;
}

HRESULT zwv_navigate_local(State *s, const WCHAR *path) {
    if (s->closed || s->recovering || !s->webview) return E_ABORT;
    if (!initializers_allow_navigation(s)) return E_PENDING;
    if (!s->local_prefix || !path || path[0] != L'/') return E_INVALIDARG;
    size_t prefix_len = wcslen(s->local_prefix), path_len = wcsnlen(path, 4097);
    if (path_len > 4096) return E_INVALIDARG;
    if (s->expected_url || s->expected_refresh || s->expected_history) return E_PENDING;
    WCHAR *url = calloc(prefix_len + path_len + 1, sizeof(WCHAR));
    if (!url) return E_OUTOFMEMORY;
    memcpy(url, s->local_prefix, (prefix_len - 1) * sizeof(WCHAR));
    memcpy(url + prefix_len - 1, path, (path_len + 1) * sizeof(WCHAR));
    s->expected_url = url;
    HRESULT hr = ICoreWebView2_Navigate(s->webview, url);
    if (FAILED(hr)) { free(s->expected_url); s->expected_url = NULL; }
    return hr;
}
HRESULT zwv_page_action(State *s, int action) {
    if (s->closed || s->recovering || !s->webview) return E_ABORT;
    if (action == 3) {
        HRESULT hr = ICoreWebView2_Stop(s->webview);
        if (SUCCEEDED(hr)) {
            free(s->expected_url); s->expected_url = NULL;
            s->expected_refresh = FALSE; s->expected_history = FALSE;
        }
        return hr;
    }
    if (!initializers_allow_navigation(s)) return E_PENDING;
    if (s->expected_url || s->expected_refresh || s->expected_history) return E_PENDING;
    HRESULT hr;
    if (action == 0 || action == 1) {
        if (!s->local_prefix && !s->remote.enabled) return E_INVALIDARG;
        s->expected_history = TRUE;
        hr = action == 0 ? ICoreWebView2_GoBack(s->webview) : ICoreWebView2_GoForward(s->webview);
    } else if (action == 2) {
        s->expected_refresh = TRUE;
        hr = ICoreWebView2_Reload(s->webview);
    } else return E_INVALIDARG;
    if (FAILED(hr)) { s->expected_refresh = FALSE; s->expected_history = FALSE; }
    return hr;
}

HRESULT zwv_recovery_begin(State *s) {
    if (s->closed) return E_ABORT;
    if (s->initializers && s->initializers->pending) return E_PENDING;
    if (s->recovering) return E_PENDING;
    s->recovering = TRUE; retain(s); return S_OK;
}
/* A failed synchronous recreation has no native controller to retain. A fresh
   empty anchor guards queued recovery without reviving any closed callback state. */
State *zwv_recovery_anchor(Notify callback, void *context) {
    State *s = calloc(1, sizeof(*s));
    if (!s) return NULL;
    InterlockedIncrement(&live_states);
    s->refs = 1; s->notify = callback; s->context = context;
    return s;
}
void zwv_recovery_cancel(State *s) { s->recovering = FALSE; release(s); }
void zwv_recovery_dispatch(State *s) {
    s->recovering = FALSE;
    notify(s, 9, NULL, S_OK);
    release(s);
}
HRESULT zwv_browser_process_id(State *s, unsigned *pid) {
    if (s->closed || !s->webview) return E_ABORT;
    return ICoreWebView2_get_BrowserProcessId(s->webview, pid);
}

void zwv_close(State *s) {
    if (s->closed) {
        if (s->closed==2) { s->closed=TRUE;release(s); }
        return;
    }
    s->closed=TRUE;state_cleanup(s);release(s);
}
static void state_cleanup(State *s) {
    s->context = NULL;
    s->notify = NULL;
    s->resource = NULL;
    s->page_notify = NULL;
    s->script_notify = NULL;
    s->tool_notify=NULL;
    if (s->owned_context) zwpw_context_detach(s->owned_context);
    initializers_close(s);
    if (s->actions) s->actions->permission_offer=NULL;
    permission_requests_close(s);
    if (s->actions) { s->actions->download_offer=NULL;s->actions->download_notify=NULL; }
    download_requests_close(s);
    file_controls_close(s);
    resource_deferrals_close(s);
    if (s->denied_response) { ICoreWebView2WebResourceResponse_Release(s->denied_response);s->denied_response=NULL; }
    browser_tools_close(s);
    s->seed_notify = NULL; s->seed_context = NULL;
    free(s->html); s->html = NULL;
    if (s->tls_webview) {
        ICoreWebView2_14 *tls=s->tls_webview;s->tls_webview=NULL;
        if (s->has_server_certificate) ICoreWebView2_14_remove_ServerCertificateErrorDetected(tls,s->server_certificate_token);
        s->has_server_certificate=FALSE;ICoreWebView2_14_Release(tls);
    }
    if (s->webview) {
        if (s->has_message) ICoreWebView2_remove_WebMessageReceived(s->webview, s->message_token);
        if (s->has_navigation) ICoreWebView2_remove_NavigationStarting(s->webview, s->navigation_token);
        if (s->has_frame) ICoreWebView2_remove_FrameNavigationStarting(s->webview, s->frame_token);
        if (s->has_resource) ICoreWebView2_remove_WebResourceRequested(s->webview, s->resource_token);
        if (s->has_popup) ICoreWebView2_remove_NewWindowRequested(s->webview, s->popup_token);
        if (s->has_permission) ICoreWebView2_remove_PermissionRequested(s->webview, s->permission_token);
        if (s->has_process) ICoreWebView2_remove_ProcessFailed(s->webview, s->process_token);
        if (s->has_download) ICoreWebView2_4_remove_DownloadStarting(s->webview4, s->download_token);
        if (s->has_completed) ICoreWebView2_remove_NavigationCompleted(s->webview, s->completed_token);
        if (s->has_source) ICoreWebView2_remove_SourceChanged(s->webview, s->source_token);
        if (s->has_title) ICoreWebView2_remove_DocumentTitleChanged(s->webview, s->title_token);
        if (s->has_history) ICoreWebView2_remove_HistoryChanged(s->webview, s->history_token);
        if (s->has_content) ICoreWebView2_remove_ContentLoading(s->webview, s->content_token);
        if (s->has_authentication) ICoreWebView2_10_remove_BasicAuthenticationRequested(s->webview10,s->authentication_token);
        if (s->has_certificate) ICoreWebView2_5_remove_ClientCertificateRequested(s->webview5,s->certificate_token);
        if (s->webview10) { ICoreWebView2_10_Release(s->webview10); s->webview10=NULL; }
        if (s->has_context) ICoreWebView2_11_remove_ContextMenuRequested(s->webview11,s->context_token);
        s->has_context=FALSE;
        if (s->webview11) { ICoreWebView2_11_Release(s->webview11); s->webview11=NULL; }
        if (s->webview5) { ICoreWebView2_5_Release(s->webview5); s->webview5=NULL; }
        if (s->has_dom) ICoreWebView2_22_remove_DOMContentLoaded(s->webview22, s->dom_token);
        if (s->webview22) { ICoreWebView2_22_Release(s->webview22); s->webview22 = NULL; }
        if (s->webview4) { ICoreWebView2_4_Release(s->webview4); s->webview4 = NULL; }
        ICoreWebView2_Release(s->webview); s->webview = NULL;
    }
    free(s->document_source); s->document_source = NULL;
    free(s->initial_url); s->initial_url = NULL;
    free(s->local_prefix); s->local_prefix = NULL;
    free(s->user_agent); s->user_agent=NULL;
    if (s->permissions) { ICoreWebView2PermissionSettingCollectionView_Release(s->permissions); s->permissions = NULL; }
    if (s->profile) { ICoreWebView2Profile4_Release(s->profile); s->profile = NULL; }
    if (s->controller) {
        ICoreWebView2Controller_Close(s->controller);
        ICoreWebView2Controller_Release(s->controller); s->controller = NULL;
        InterlockedDecrement(&owned_controllers);
    }
    if (s->environment) { ICoreWebView2Environment_Release(s->environment); s->environment = NULL; }
}
