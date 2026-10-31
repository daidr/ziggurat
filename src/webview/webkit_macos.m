/* The WKWebView backend: the WebKitGTK native contract of webkit_native.h on
 * macOS, for trusted HTML pages in ephemeral storage. Custom local sites,
 * remote pages, profiles, sessions, regions and the browser tools are refused
 * here and before they reach this file.
 *
 * Every function runs on the main thread. A page object is reference counted
 * by Core Foundation: zwk_create and zwk_recovery_anchor return one reference
 * that zwk_close or the recovery calls give back, and every pending engine
 * completion holds its own through its block. */
#import <AppKit/AppKit.h>
#import <WebKit/WebKit.h>
#include <objc/message.h>
#include <stdatomic.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include "webkit_native.h"
#include "webkit_content_rules.h"

void *zlm_window_content(void *window);

/* Engine calls without public API. Each is looked up before use. */
@interface WKWebView (ZigguratEngine)
- (void)_setPageMuted:(NSUInteger)state;
- (NSUInteger)_mediaMutedState;
- (BOOL)_isPlayingAudio;
- (NSString *)_userAgent;
@end
enum { MEDIA_AUDIO_MUTED=1 };

static atomic_uint live_states, live_callbacks, live_views, live_compiles;

static uint32_t domain_code(NSString *domain) {
    /* FNV-1a over the domain name: stable and never zero. */
    uint32_t hash=2166136261u;
    for (const char *c=domain.UTF8String?:"";*c;c++) { hash^=(unsigned char)*c; hash*=16777619u; }
    return hash?hash:1;
}

@interface ZwkWebView : WKWebView
@end
@implementation ZwkWebView
/* No engine context menu, as on Linux. */
- (void)willOpenMenu:(NSMenu *)menu withEvent:(NSEvent *)event { [menu removeAllItems]; [super willOpenMenu:menu withEvent:event]; }
@end

@interface ZwkPage : NSObject <WKNavigationDelegate, WKUIDelegate, WKScriptMessageHandler> {
@public
    void *owner;
    ZwkNotify notify_fn;
    ZwkPageNotify page_fn;
    ZwkScriptNotify script_fn;
    ZwkDeadline deadline_fn;
    BOOL closed, recovering, committed, failed, dom_ready, load_started, pending_navigation, authorized, observing, autoplay, muted, waiting_sandbox;
    uint64_t generation;
    uint32_t limit, result_limit, pending, posts, policy;
    ZwkFailure failure;
    NSString *html, *facts, *current_uri;
    ZwkWebView *view;
    WKUserContentController *controller;
    WKContentWorld *world;
    NSArray<WKContentRuleList *> *filters;
    WKNavigation *navigation;
    NSTimer *timer;
    NSMutableSet<NSNumber *> *cancelled;
}
@end

static BOOL live(ZwkPage *s) { return !s->closed && !s->recovering && s->owner; }
static ZwkPage *page_of(ZwkState *s) { return (__bridge ZwkPage *)(void *)s; }

void zwk_counts(uint32_t *states,uint32_t *callbacks,uint32_t *views) {
    *states=atomic_load(&live_states); *callbacks=atomic_load(&live_callbacks); *views=atomic_load(&live_views);
}
void zwk_last_failure(ZwkState *s,ZwkFailure *value) { *value=page_of(s)->failure; }

static void failure_set(ZwkPage *s,NSError *error) {
    if (error) s->failure=(ZwkFailure){domain_code(error.domain),(int32_t)error.code};
}
/* A NUL-terminated UTF-16 copy of text, or NULL past limit UTF-8 bytes. */
static uint16_t *wide(NSString *text,size_t limit) {
    if (!text || [text lengthOfBytesUsingEncoding:NSUTF8StringEncoding]>limit) return NULL;
    const NSUInteger length=text.length;
    uint16_t *value=malloc((length+1)*sizeof(uint16_t));
    if (!value) return NULL;
    [text getCharacters:(unichar *)value range:NSMakeRange(0,length)];
    value[length]=0;
    return value;
}
static void notify(ZwkPage *s,int kind,NSString *text,int32_t code,const ZwkFailure *failure) {
    if (!live(s) || !s->notify_fn) return;
    uint16_t *value=wide(text,65536);
    s->notify_fn(s->owner,kind,value,code,failure);
    free(value);
}
static BOOL page(ZwkPage *s,int kind,uint32_t flags,int32_t status,NSString *text) {
    if (!live(s) || !s->page_fn) return NO;
    uint16_t *value=wide(text,16384);
    ZwkPageEvent event={kind,s->generation,flags,status,value};
    const BOOL accepted=s->page_fn(s->owner,&event)!=0;
    free(value);
    return accepted && live(s);
}
static BOOL document(ZwkPage *s) {
    if (!live(s) || !s->committed || s->failed || !s->view) return NO;
    return [s->view.URL.absoluteString isEqualToString:@"about:blank"];
}

/* Pages of trusted HTML reach no network, as the content security policy
 * of the Linux backend keeps them: one rule list blocks every load but the
 * document's own. Lists apply to http, https and ws loads; data and blob
 * URLs stay usable. Compiled once per process, before the first load. */
static WKContentRuleList *sandbox;
static NSError *sandbox_error;
static BOOL sandbox_compiling;
static NSMutableArray<ZwkPage *> *sandbox_waiting;
static void initialize(ZwkPage *s);
static void sandbox_compile(void) {
    if (sandbox || sandbox_compiling) return;
    sandbox_compiling=YES; sandbox_error=nil;
    NSString *source=@"[{\"trigger\":{\"url-filter\":\".*\",\"resource-type\":[\"image\",\"style-sheet\",\"script\",\"font\",\"raw\",\"svg-document\",\"media\"]},\"action\":{\"type\":\"block\"}}]";
    NSURL *directory=[NSURL fileURLWithPath:[NSTemporaryDirectory() stringByAppendingPathComponent:@"ziggurat-webkit-sandbox"] isDirectory:YES];
    [[NSFileManager defaultManager] createDirectoryAtURL:directory withIntermediateDirectories:YES attributes:@{NSFilePosixPermissions:@0700} error:NULL];
    WKContentRuleListStore *store=[WKContentRuleListStore storeWithURL:directory];
    [store compileContentRuleListForIdentifier:@"ziggurat-html-sandbox-1" encodedContentRuleList:source completionHandler:^(WKContentRuleList *list,NSError *error) {
        sandbox_compiling=NO; sandbox=list; sandbox_error=list?nil:error;
        NSArray<ZwkPage *> *waiting=sandbox_waiting; sandbox_waiting=nil;
        for (ZwkPage *s in waiting) { s->waiting_sandbox=NO; initialize(s); }
    }];
}
static void rule_lists_apply(ZwkPage *s) {
    [s->controller removeAllContentRuleLists];
    if (sandbox) [s->controller addContentRuleList:sandbox];
    for (WKContentRuleList *list in s->filters) [s->controller addContentRuleList:list];
}

static char *js_quote(const char *text) {
    size_t length=strlen(text), bytes=3;
    if (length>1024*1024) return NULL;
    for (size_t i=0;i<length;i++) bytes+=(text[i]=='"' || text[i]=='\\')?2:((unsigned char)text[i]<32?6:1);
    char *output=malloc(bytes);
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

static void navigation_clear(ZwkPage *s) {
    s->pending_navigation=NO; s->authorized=NO; s->navigation=nil; s->load_started=NO;
}
/* Withdraws the current navigation. A started load keeps its identity until
 * the engine ends it, as a failed load that grants nothing. */
static void navigation_revoke(ZwkPage *s) {
    s->pending_navigation=NO; s->authorized=NO;
    if (s->load_started) { s->committed=NO; s->failed=YES; }
    else s->navigation=nil;
}
static void navigation_fail(ZwkPage *s,int code,NSString *reason) {
    if (!live(s)) return;
    const uint64_t generation=s->generation;
    failure_set(s,[NSError errorWithDomain:@"ziggurat-webkit-navigation" code:code userInfo:@{NSLocalizedDescriptionKey:reason}]);
    const ZwkFailure failure=s->failure;
    s->committed=NO; s->failed=YES; navigation_revoke(s);
    if (live(s) && s->generation==generation) (void)page(s,6,0,0,nil);
    if (live(s) && s->generation==generation) [s->view stopLoading];
    if (live(s) && s->generation==generation) notify(s,2,nil,code,&failure);
}
/* Installs the next document's private and public scripts and takes the
 * next generation, after the private invalidation of the current one. */
static int prepare_document(ZwkPage *s) {
    if (!live(s)) return ZWK_CLOSED;
    if (s->generation==UINT64_MAX) return ZWK_FULL;
    NSString *private_script=[NSString stringWithFormat:
        @"(()=>{const send=x=>webkit.messageHandlers.ziggurat.postMessage('%llu|'+x);"
        "const valid=x=>{if(typeof x!=='string'||x.length>65536)return false;let bytes=0;"
        "for(const c of x){const p=c.codePointAt(0);if(!p)return false;bytes+=p<128?1:p<2048?2:p<65536?3:4;"
        "if(bytes>65536)return false}return true};"
        "addEventListener('message',e=>{if(e.isTrusted&&e.source===window&&window===top&&location.href==='about:blank'&&"
        "e.data&&valid(e.data.__ziggurat))send('M'+e.data.__ziggurat)});"
        "addEventListener('DOMContentLoaded',()=>send('D'),{once:true});%@})()",
        (unsigned long long)(s->generation+1),s->facts?:@""];
    static NSString *const public_script=
        @"(()=>{const listeners=new Map;const transport=Object.freeze({"
        "postMessage(value){if(typeof value!=='string'||value.length>65536||value.includes('\\0'))throw TypeError('InvalidMessage');"
        "window.postMessage({__ziggurat:value},'*')},"
        "addEventListener(type,fn){if(type!=='message'||typeof fn!=='function'||listeners.has(fn))return;"
        "const wrap=e=>{if(e.source===window&&e.data&&typeof e.data.__zigguratHost==='string')fn({data:e.data.__zigguratHost})};"
        "listeners.set(fn,wrap);window.addEventListener('message',wrap)},"
        "removeEventListener(type,fn){if(type==='message'&&listeners.has(fn)){window.removeEventListener('message',listeners.get(fn));listeners.delete(fn)}}});"
        "if(!window.chrome)window.chrome={};Object.defineProperty(window.chrome,'webview',{value:transport})})()";
    const uint64_t generation=s->generation;
    s->committed=NO;
    /* Private invalidation never manufactures a public start or page. */
    if (generation && !page(s,6,0,0,nil)) return live(s)?ZWK_NAVIGATION_CANCELLED:ZWK_CLOSED;
    if (!s->pending_navigation || s->generation!=generation) return live(s)?ZWK_NAVIGATION_CANCELLED:ZWK_CLOSED;
    ++s->generation; s->failed=NO; s->dom_ready=NO;
    [s->controller removeAllUserScripts];
    [s->controller addUserScript:[[WKUserScript alloc] initWithSource:private_script injectionTime:WKUserScriptInjectionTimeAtDocumentStart forMainFrameOnly:YES inContentWorld:s->world]];
    [s->controller addUserScript:[[WKUserScript alloc] initWithSource:public_script injectionTime:WKUserScriptInjectionTimeAtDocumentStart forMainFrameOnly:YES inContentWorld:WKContentWorld.pageWorld]];
    return ZWK_OK;
}
/* Starts a navigation to the page's HTML: prepares the next document, then
 * issues the load. ready first tells the owner the page exists. */
static int navigation_submit(ZwkPage *s,BOOL ready) {
    if (s->pending_navigation || s->load_started || s->view.loading) return ZWK_NAVIGATION_PENDING;
    s->pending_navigation=YES; s->authorized=NO; s->navigation=nil;
    int result=prepare_document(s);
    if (result!=ZWK_OK) { if (live(s)) navigation_clear(s); return result; }
    const uint64_t generation=s->generation;
    if (ready) notify(s,0,nil,0,NULL);
    if (!live(s)) return ZWK_CLOSED;
    if (!s->pending_navigation || s->generation!=generation) return ZWK_NAVIGATION_CANCELLED;
    s->navigation=[s->view loadHTMLString:s->html baseURL:nil];
    return ZWK_OK;
}
static void initialize(ZwkPage *s) {
    if (!live(s)) return;
    if (!sandbox) {
        if (sandbox_error) {
            failure_set(s,sandbox_error);
            const ZwkFailure failure=s->failure;
            s->failed=YES; notify(s,2,nil,failure.code,&failure);
            return;
        }
        if (!sandbox_waiting) sandbox_waiting=[NSMutableArray array];
        s->waiting_sandbox=YES; [sandbox_waiting addObject:s];
        sandbox_compile();
        return;
    }
    rule_lists_apply(s);
    if (navigation_submit(s,YES)!=ZWK_OK && live(s)) navigation_fail(s,ZWK_POLICY_PREPARATION,@"Initial document preparation failed");
}

static BOOL user_gesture(WKNavigationAction *action) {
    SEL selector=NSSelectorFromString(@"_isUserInitiated");
    if ([action respondsToSelector:selector]) return ((BOOL (*)(id,SEL))objc_msgSend)(action,selector);
    return action.navigationType==WKNavigationTypeLinkActivated || action.navigationType==WKNavigationTypeFormSubmitted;
}

static void *title_context=&title_context;
static void *audio_context=&audio_context;

@implementation ZwkPage
- (instancetype)init {
    if ((self=[super init])) { cancelled=[NSMutableSet set]; atomic_fetch_add(&live_states,1); }
    return self;
}
- (void)dealloc { atomic_fetch_sub(&live_states,1); }

- (void)webView:(WKWebView *)webView decidePolicyForNavigationAction:(WKNavigationAction *)action decisionHandler:(void (^)(WKNavigationActionPolicy))decision {
    ZwkPage *keep __attribute__((objc_precise_lifetime))=self; (void)keep; (void)webView;
    NSString *uri=action.request.URL.absoluteString;
    if (!action.targetFrame) { decision(WKNavigationActionPolicyAllow); return; } /* createWebView decides */
    if (!action.targetFrame.mainFrame) {
        /* Frames of the document itself; no frame reaches another source. */
        decision([uri isEqualToString:@"about:blank"] || [uri isEqualToString:@"about:srcdoc"]?WKNavigationActionPolicyAllow:WKNavigationActionPolicyCancel);
        return;
    }
    BOOL allowed=NO;
    if (live(self) && pending_navigation && !authorized && action.navigationType==WKNavigationTypeOther && [uri isEqualToString:@"about:blank"]) allowed=YES;
    if (allowed) { authorized=YES; decision(WKNavigationActionPolicyAllow); return; }
    decision(WKNavigationActionPolicyCancel);
    if (live(self) && (policy&1u)) notify(self,3,uri,user_gesture(action)?1:0,NULL);
}
- (void)webView:(WKWebView *)webView decidePolicyForNavigationResponse:(WKNavigationResponse *)response decisionHandler:(void (^)(WKNavigationResponsePolicy))decision {
    (void)webView;
    decision(live(self) && response.canShowMIMEType?WKNavigationResponsePolicyAllow:WKNavigationResponsePolicyCancel);
}
- (void)webView:(WKWebView *)webView didStartProvisionalNavigation:(WKNavigation *)value {
    ZwkPage *keep __attribute__((objc_precise_lifetime))=self; (void)keep;
    if (!live(self) || !value || value!=navigation) return;
    if (!pending_navigation || !authorized) { navigation_fail(self,ZWK_POLICY_PREPARATION,@"Full document started without prepared authorization"); return; }
    const uint64_t current=generation;
    load_started=YES; committed=NO; failed=NO; dom_ready=NO;
    if (!page(self,0,0,0,webView.URL.absoluteString?:@"about:blank") && live(self) && generation==current) {
        navigation_revoke(self);
        [webView stopLoading];
    }
}
- (void)webView:(WKWebView *)webView didCommitNavigation:(WKNavigation *)value {
    ZwkPage *keep __attribute__((objc_precise_lifetime))=self; (void)keep;
    if (!live(self) || !value || value!=navigation || !pending_navigation) return;
    NSString *uri=webView.URL.absoluteString;
    if (!load_started || ![uri isEqualToString:@"about:blank"]) { navigation_fail(self,ZWK_POLICY_PREPARATION,@"Committed document has no valid current URI snapshot"); return; }
    current_uri=uri;
    const uint64_t current=generation;
    committed=YES;
    if (!page(self,3,1,0,uri) && live(self) && generation==current) committed=NO;
    if (live(self) && generation==current && committed && dom_ready) (void)page(self,2,0,0,nil);
}
- (void)finish:(WKNavigation *)value error:(NSError *)error {
    ZwkPage *keep __attribute__((objc_precise_lifetime))=self; (void)keep;
    if (!live(self) || !value || value!=navigation) return;
    const BOOL started=load_started;
    int32_t status=0;
    if (error) { failure_set(self,error); status=failure.code; failed=YES; committed=NO; }
    const BOOL success=document(self);
    navigation_clear(self);
    if (started) (void)page(self,1,success?1:0,status,nil);
}
- (void)webView:(WKWebView *)webView didFinishNavigation:(WKNavigation *)value { (void)webView; [self finish:value error:nil]; }
- (void)webView:(WKWebView *)webView didFailNavigation:(WKNavigation *)value withError:(NSError *)error { (void)webView; [self finish:value error:error]; }
- (void)webView:(WKWebView *)webView didFailProvisionalNavigation:(WKNavigation *)value withError:(NSError *)error { (void)webView; [self finish:value error:error]; }
- (void)webViewWebContentProcessDidTerminate:(WKWebView *)webView {
    ZwkPage *keep __attribute__((objc_precise_lifetime))=self; (void)keep; (void)webView;
    failed=YES; committed=NO;
    navigation_clear(self);
    notify(self,8,nil,0,NULL);
}
- (void)webView:(WKWebView *)webView didReceiveAuthenticationChallenge:(NSURLAuthenticationChallenge *)challenge completionHandler:(void (^)(NSURLSessionAuthChallengeDisposition,NSURLCredential *))completion {
    (void)webView;
    completion([challenge.protectionSpace.authenticationMethod isEqualToString:NSURLAuthenticationMethodServerTrust]?NSURLSessionAuthChallengePerformDefaultHandling:NSURLSessionAuthChallengeCancelAuthenticationChallenge,nil);
}

- (WKWebView *)webView:(WKWebView *)webView createWebViewWithConfiguration:(WKWebViewConfiguration *)configuration forNavigationAction:(WKNavigationAction *)action windowFeatures:(WKWindowFeatures *)features {
    ZwkPage *keep __attribute__((objc_precise_lifetime))=self; (void)keep; (void)webView; (void)configuration; (void)features;
    NSString *uri=action.request.URL.absoluteString;
    if (live(self) && uri && (policy&2u)) notify(self,4,uri,user_gesture(action)?1:0,NULL);
    return nil;
}
- (void)webView:(WKWebView *)webView runJavaScriptAlertPanelWithMessage:(NSString *)message initiatedByFrame:(WKFrameInfo *)frame completionHandler:(void (^)(void))completion {
    (void)webView; (void)message; (void)frame; completion();
}
- (void)webView:(WKWebView *)webView runJavaScriptConfirmPanelWithMessage:(NSString *)message initiatedByFrame:(WKFrameInfo *)frame completionHandler:(void (^)(BOOL))completion {
    (void)webView; (void)message; (void)frame; completion(NO);
}
- (void)webView:(WKWebView *)webView runJavaScriptTextInputPanelWithPrompt:(NSString *)prompt defaultText:(NSString *)text initiatedByFrame:(WKFrameInfo *)frame completionHandler:(void (^)(NSString *))completion {
    (void)webView; (void)prompt; (void)text; (void)frame; completion(nil);
}
- (void)webView:(WKWebView *)webView runOpenPanelWithParameters:(WKOpenPanelParameters *)parameters initiatedByFrame:(WKFrameInfo *)frame completionHandler:(void (^)(NSArray<NSURL *> *))completion {
    (void)webView; (void)parameters; (void)frame; completion(nil);
}
- (void)webView:(WKWebView *)webView requestMediaCapturePermissionForOrigin:(WKSecurityOrigin *)origin initiatedByFrame:(WKFrameInfo *)frame type:(WKMediaCaptureType)type decisionHandler:(void (^)(WKPermissionDecision))decision API_AVAILABLE(macos(12.0)) {
    (void)webView; (void)origin; (void)frame; (void)type; decision(WKPermissionDecisionDeny);
}

- (void)userContentController:(WKUserContentController *)controller_value didReceiveScriptMessage:(WKScriptMessage *)message {
    ZwkPage *keep __attribute__((objc_precise_lifetime))=self; (void)keep; (void)controller_value;
    if (!live(self) || !message.frameInfo.mainFrame || ![message.body isKindOfClass:[NSString class]]) return;
    NSString *text=message.body;
    NSString *prefix=[NSString stringWithFormat:@"%llu|",(unsigned long long)generation];
    if (![text hasPrefix:prefix] || text.length==prefix.length || [text lengthOfBytesUsingEncoding:NSUTF8StringEncoding]>65584 || [text rangeOfCharacterFromSet:[NSCharacterSet characterSetWithRange:NSMakeRange(0,1)]].location!=NSNotFound) return;
    NSString *body=[text substringFromIndex:prefix.length];
    const unichar kind=[body characterAtIndex:0];
    NSString *rest=[body substringFromIndex:1];
    const NSUInteger bytes=[rest lengthOfBytesUsingEncoding:NSUTF8StringEncoding];
    if (kind=='F' && facts && bytes<=256) {
        if (committed && !failed) (void)page(self,10,0,0,rest);
    } else if (kind=='D' && !rest.length) {
        dom_ready=YES;
        if (document(self)) (void)page(self,2,0,0,nil);
    } else if (kind=='M' && bytes<=65536 && document(self) && notify_fn) {
        uint16_t *value=wide(rest,65536);
        if (value) { notify_fn(owner,1,value,0,NULL); free(value); }
    }
}

- (void)observeValueForKeyPath:(NSString *)path ofObject:(id)object change:(NSDictionary *)change context:(void *)context {
    ZwkPage *keep __attribute__((objc_precise_lifetime))=self; (void)keep; (void)path; (void)change;
    if (context==title_context) {
        if (document(self)) (void)page(self,4,0,0,view.title?:@"");
    } else if (context==audio_context) {
        /* Audibility belongs to the view, not a document: it is told between
           documents too, under the current generation. */
        if (live(self)) (void)page(self,7,[object _isPlayingAudio]?1u:0u,0,nil);
    } else [super observeValueForKeyPath:path ofObject:object change:change context:context];
}
@end

static BOOL engine_has(WKWebView *view,SEL selector) { return [view respondsToSelector:selector]; }
static void set_muted(ZwkPage *s,BOOL value) {
    s->muted=value;
    if (!engine_has(s->view,@selector(_setPageMuted:))) return;
    NSUInteger state=engine_has(s->view,@selector(_mediaMutedState))?[s->view _mediaMutedState]:0;
    [s->view _setPageMuted:value?(state|MEDIA_AUDIO_MUTED):(state&~(NSUInteger)MEDIA_AUDIO_MUTED)];
}

int zwk_create(void *window,const ZwkOptions *options,ZwkNotify callback,ZwkPageNotify page_callback,ZwkScriptNotify script_callback,ZwkDeadline deadline,void *owner,ZwkState **out) {
    *out=NULL;
    if (!options || !options->html || !window || options->max_pending==0 || options->max_pending>16 || options->max_result_bytes==0 ||
        options->max_result_bytes>1024*1024 || strlen(options->html)>16*1024*1024) return ZWK_INVALID;
    if (options->local || options->remote || options->region || options->profile_context || options->initializers) return ZWK_INVALID;
    @autoreleasepool {
        NSView *host=(__bridge NSView *)zlm_window_content(window);
        if (!host) return ZWK_CLOSED;
        NSString *html=[NSString stringWithUTF8String:options->html];
        if (!html) return ZWK_INVALID;
        ZwkPage *s=[[ZwkPage alloc] init];
        if (!s) return ZWK_OOM;
        s->html=html;
        if (options->facts && !(s->facts=[NSString stringWithUTF8String:options->facts])) return ZWK_INVALID;
        s->autoplay=options->autoplay!=0;
        s->owner=owner; s->notify_fn=callback; s->page_fn=page_callback; s->script_fn=script_callback; s->deadline_fn=deadline;
        s->limit=options->max_pending; s->result_limit=options->max_result_bytes; s->policy=options->policy_flags;
        NSMutableArray<WKContentRuleList *> *filters=[NSMutableArray arrayWithCapacity:options->content_filter_count];
        for (uint32_t i=0;i<options->content_filter_count;i++) [filters addObject:(__bridge WKContentRuleList *)options->content_filters[i]];
        s->filters=filters;
        WKWebViewConfiguration *configuration=[[WKWebViewConfiguration alloc] init];
        configuration.websiteDataStore=[WKWebsiteDataStore nonPersistentDataStore];
        /* By default sound plays only after a gesture, as on Linux. */
        configuration.mediaTypesRequiringUserActionForPlayback=s->autoplay?WKAudiovisualMediaTypeNone:WKAudiovisualMediaTypeAudio;
        configuration.preferences.javaScriptCanOpenWindowsAutomatically=NO;
        if (@available(macOS 12.3,*)) configuration.preferences.elementFullscreenEnabled=NO;
        s->controller=configuration.userContentController;
        s->world=[WKContentWorld worldWithName:@"ziggurat-private"];
        [s->controller addScriptMessageHandler:s contentWorld:s->world name:@"ziggurat"];
        ZwkWebView *view=[[ZwkWebView alloc] initWithFrame:host.bounds configuration:configuration];
        if (!view) { [s->controller removeAllScriptMessageHandlers]; return ZWK_NATIVE_FAILED; }
        s->view=view; atomic_fetch_add(&live_views,1);
        view.autoresizingMask=NSViewWidthSizable|NSViewHeightSizable;
        view.navigationDelegate=s; view.UIDelegate=s;
        view.allowsBackForwardNavigationGestures=NO;
        view.allowsMagnification=NO;
        if (options->user_agent) view.customUserAgent=[NSString stringWithUTF8String:options->user_agent];
        view.pageZoom=options->zoom;
        if (@available(macOS 13.3,*)) view.inspectable=options->developer_tools!=0;
        if (options->audio_muted) set_muted(s,YES);
        [view addObserver:s forKeyPath:@"title" options:0 context:title_context];
        if (engine_has(view,@selector(_isPlayingAudio))) [view addObserver:s forKeyPath:@"_isPlayingAudio" options:0 context:audio_context];
        s->observing=YES;
        [host addSubview:view];
        dispatch_async(dispatch_get_main_queue(),^{ initialize(s); });
        *out=(__bridge_retained void *)s;
    }
    return ZWK_OK;
}
int zwk_session_create(const ZwkOptions *options,uint32_t width,uint32_t height,ZwkNotify callback,ZwkPageNotify page_callback,ZwkScriptNotify script_callback,ZwkDeadline deadline,void *owner,ZwkState **out) {
    (void)options; (void)width; (void)height; (void)callback; (void)page_callback; (void)script_callback; (void)deadline; (void)owner;
    *out=NULL; return ZWK_INVALID;
}
int zwk_session_mount(ZwkState *s,void *window,int32_t left,int32_t top,int32_t right,int32_t bottom,int visible,uint64_t epoch) {
    (void)s; (void)window; (void)left; (void)top; (void)right; (void)bottom; (void)visible; (void)epoch; return ZWK_INVALID;
}
int zwk_session_park(ZwkState *s,uint64_t epoch) { (void)s; (void)epoch; return ZWK_INVALID; }
int zwk_session_size(ZwkState *s,uint32_t *width,uint32_t *height) { (void)s; *width=0; *height=0; return ZWK_INVALID; }
void zwk_session_parent_destroying(ZwkState *s,uint64_t epoch) { (void)s; (void)epoch; }

void zwk_close(ZwkState *state) {
    ZwkPage *s=page_of(state);
    if (s->closed) return;
    @autoreleasepool {
        s->closed=YES; s->owner=NULL;
        [s->timer invalidate]; s->timer=nil;
        navigation_clear(s);
        if (s->waiting_sandbox) { [sandbox_waiting removeObject:s]; s->waiting_sandbox=NO; }
        ZwkWebView *view=s->view; s->view=nil;
        if (view) {
            if (s->observing) {
                [view removeObserver:s forKeyPath:@"title" context:title_context];
                if (engine_has(view,@selector(_isPlayingAudio))) [view removeObserver:s forKeyPath:@"_isPlayingAudio" context:audio_context];
                s->observing=NO;
            }
            view.navigationDelegate=nil; view.UIDelegate=nil;
            [s->controller removeAllScriptMessageHandlers];
            [view stopLoading];
            [view removeFromSuperview];
            atomic_fetch_sub(&live_views,1);
        }
        s->controller=nil;
        CFRelease(state);
    }
}

int zwk_evaluate(ZwkState *state,const char *source,uint64_t token) {
    ZwkPage *s=page_of(state);
    if (!live(s)) return ZWK_CLOSED;
    if (!document(s)) return ZWK_NOT_READY;
    if (s->pending>=s->limit) return ZWK_FULL;
    char *quoted=js_quote(source);
    if (!quoted) return ZWK_OOM;
    @autoreleasepool {
        NSString *literal=[NSString stringWithUTF8String:quoted];
        free(quoted);
        NSString *wrapped=literal?[NSString stringWithFormat:@"(()=>{const value=(0,eval)(%@);let json=JSON.stringify(value);if(json===undefined)json='null';return json.length>%u?[2]:[0,json]})()",literal,s->result_limit]:nil;
        if (!wrapped) return ZWK_INVALID;
        ++s->pending; atomic_fetch_add(&live_callbacks,1);
        [s->view evaluateJavaScript:wrapped inFrame:nil inContentWorld:WKContentWorld.pageWorld completionHandler:^(id value,NSError *error) {
            --s->pending;
            NSNumber *key=@(token);
            const BOOL withdrawn=[s->cancelled containsObject:key];
            [s->cancelled removeObject:key];
            if (live(s) && !withdrawn && s->script_fn) {
                int status=0; uint16_t *utf16=NULL;
                if (error) { failure_set(s,error); status=1; }
                else if (![value isKindOfClass:[NSArray class]] || ![[value firstObject] isKindOfClass:[NSNumber class]]) status=3;
                else {
                    status=[[value firstObject] intValue];
                    if (!status) {
                        id body=[value count]>1?value[1]:nil;
                        if (![body isKindOfClass:[NSString class]]) status=3;
                        else if ([body lengthOfBytesUsingEncoding:NSUTF8StringEncoding]>s->result_limit) status=2;
                        else if (!(utf16=wide(body,s->result_limit))) status=3;
                    }
                }
                s->script_fn(s->owner,token,status,error?(int32_t)error.code:0,utf16,error?&s->failure:NULL);
                free(utf16);
            }
            atomic_fetch_sub(&live_callbacks,1);
        }];
    }
    return ZWK_OK;
}
void zwk_evaluate_cancel(ZwkState *state,uint64_t token) { [page_of(state)->cancelled addObject:@(token)]; }

/* Posts are messages, not script evaluations, and do not share their limit.
 * The bound only stops a page that never runs from queueing without end. */
enum { POST_LIMIT=1024 };
int zwk_post(ZwkState *state,const char *text) {
    ZwkPage *s=page_of(state);
    if (!live(s)) return ZWK_CLOSED;
    if (!document(s)) return ZWK_NOT_READY;
    if (s->posts>=POST_LIMIT) return ZWK_FULL;
    char *quoted=js_quote(text);
    if (!quoted) return ZWK_OOM;
    @autoreleasepool {
        NSString *literal=[NSString stringWithUTF8String:quoted];
        free(quoted);
        NSString *source=literal?[NSString stringWithFormat:@"window.postMessage({__zigguratHost:%@},'*')",literal]:nil;
        if (!source) return ZWK_INVALID;
        ++s->posts; atomic_fetch_add(&live_callbacks,1);
        [s->view evaluateJavaScript:source inFrame:nil inContentWorld:WKContentWorld.pageWorld completionHandler:^(id value,NSError *error) {
            (void)value; (void)error;
            --s->posts; atomic_fetch_sub(&live_callbacks,1);
        }];
    }
    return ZWK_OK;
}
int zwk_zoom(ZwkState *state,double *value,int write) {
    ZwkPage *s=page_of(state);
    if (!live(s)) return ZWK_CLOSED;
    if (write) s->view.pageZoom=*value;
    else *value=s->view.pageZoom;
    return ZWK_OK;
}
int zwk_audio(ZwkState *state,int op,int *value) {
    ZwkPage *s=page_of(state);
    if (!live(s)) return ZWK_CLOSED;
    switch (op) {
    case 0:
        *value=engine_has(s->view,@selector(_mediaMutedState))?(([s->view _mediaMutedState]&MEDIA_AUDIO_MUTED)?1:0):(s->muted?1:0);
        return ZWK_OK;
    case 1:
        if (!engine_has(s->view,@selector(_setPageMuted:))) return ZWK_NATIVE_FAILED;
        set_muted(s,*value!=0); return ZWK_OK;
    case 2:
        *value=engine_has(s->view,@selector(_isPlayingAudio)) && [s->view _isPlayingAudio]?1:0;
        return ZWK_OK;
    }
    return ZWK_INVALID;
}
int zwk_content_filters(ZwkState *state,void *const *filters,uint32_t count) {
    ZwkPage *s=page_of(state);
    if (!live(s)) return ZWK_CLOSED;
    if (count && !filters) return ZWK_INVALID;
    NSMutableArray<WKContentRuleList *> *lists=[NSMutableArray arrayWithCapacity:count];
    for (uint32_t i=0;i<count;i++) [lists addObject:(__bridge WKContentRuleList *)filters[i]];
    s->filters=lists;
    if (!s->waiting_sandbox) rule_lists_apply(s);
    return ZWK_OK;
}
int zwk_user_agent(ZwkState *state,const char *set,char **get) {
    ZwkPage *s=page_of(state);
    if (!live(s)) return ZWK_CLOSED;
    @autoreleasepool {
        if (set) s->view.customUserAgent=*set?[NSString stringWithUTF8String:set]:nil;
        if (get) {
            NSString *value=s->view.customUserAgent;
            if (!value.length && engine_has(s->view,@selector(_userAgent))) value=[s->view _userAgent];
            *get=strdup(value.UTF8String?:"");
            if (!*get) return ZWK_OOM;
        }
    }
    return ZWK_OK;
}
int zwk_devtools(ZwkState *state,int op,int *enabled,int *visible) {
    ZwkPage *s=page_of(state);
    if (!live(s)) return ZWK_CLOSED;
    if (op<0 || op>3) return ZWK_INVALID;
    if (@available(macOS 13.3,*)) {
        if (op==1) s->view.inspectable=YES;
        if (op==2) s->view.inspectable=NO;
        /* The Web Inspector attaches from Safari's Develop menu. */
        if (op==3) return s->view.inspectable?ZWK_NATIVE_FAILED:ZWK_DEVTOOLS_DISABLED;
        if (enabled) *enabled=s->view.inspectable?1:0;
        if (visible) *visible=0;
        return ZWK_OK;
    }
    if (op!=0) return ZWK_NATIVE_FAILED;
    if (enabled) *enabled=0;
    if (visible) *visible=0;
    return ZWK_OK;
}
void zwk_devtools_counts(uint32_t *shown) { *shown=0; }
void zwk_string_free(char *value) { free(value); }
int zwk_deadline_arm(ZwkState *state,uint64_t nanoseconds) {
    ZwkPage *s=page_of(state);
    if (!live(s)) return ZWK_CLOSED;
    if (nanoseconds>UINT64_C(600000000000)) return ZWK_INVALID;
    const uint64_t milliseconds=(nanoseconds+999999)/1000000;
    [s->timer invalidate];
    s->timer=[NSTimer timerWithTimeInterval:(double)(milliseconds?milliseconds:1)/1000.0 repeats:NO block:^(NSTimer *timer) {
        if (s->timer!=timer) return;
        s->timer=nil;
        if (live(s) && s->deadline_fn) s->deadline_fn(s->owner);
    }];
    [[NSRunLoop mainRunLoop] addTimer:s->timer forMode:NSRunLoopCommonModes];
    return ZWK_OK;
}
void zwk_deadline_cancel(ZwkState *state) { ZwkPage *s=page_of(state); [s->timer invalidate]; s->timer=nil; }
int zwk_refresh(ZwkState *state) {
    ZwkPage *s=page_of(state);
    ZwkPage *keep __attribute__((objc_precise_lifetime))=s; (void)keep;
    if (!live(s)) return ZWK_CLOSED;
    if (s->pending_navigation || s->load_started || s->view.loading) return ZWK_NAVIGATION_PENDING;
    if (!document(s)) return ZWK_NOT_READY;
    return navigation_submit(s,NO);
}
int zwk_navigate_remote(ZwkState *state,const char *uri) { (void)uri; return live(page_of(state))?ZWK_NOT_READY:ZWK_CLOSED; }
int zwk_navigate_local(ZwkState *state,const char *path) { (void)path; return live(page_of(state))?ZWK_INVALID:ZWK_CLOSED; }
int zwk_history(ZwkState *state,int forward) { (void)forward; return live(page_of(state))?ZWK_NOT_READY:ZWK_CLOSED; }
int zwk_stop(ZwkState *state) {
    ZwkPage *s=page_of(state);
    if (!live(s)) return ZWK_CLOSED;
    navigation_revoke(s);
    [s->view stopLoading];
    return ZWK_OK;
}
int zwk_focus(ZwkState *state) {
    ZwkPage *s=page_of(state);
    if (!live(s) || !s->view.window) return ZWK_CLOSED;
    return [s->view.window makeFirstResponder:s->view]?ZWK_OK:ZWK_NATIVE_FAILED;
}
int zwk_viewport(ZwkState *state,int32_t left,int32_t top,int32_t right,int32_t bottom,int visible) {
    (void)state; (void)left; (void)top; (void)right; (void)bottom; (void)visible; return ZWK_CLOSED;
}

int zwk_recovery_begin(ZwkState *state) {
    ZwkPage *s=page_of(state);
    if (s->closed) return ZWK_CLOSED;
    if (s->recovering) return ZWK_FULL;
    s->recovering=YES; CFRetain(state); return ZWK_OK;
}
void zwk_recovery_cancel(ZwkState *state) { page_of(state)->recovering=NO; CFRelease(state); }
void zwk_recovery_dispatch(ZwkState *state) {
    ZwkPage *s=page_of(state);
    s->recovering=NO;
    notify(s,9,nil,0,NULL);
    CFRelease(state);
}
ZwkState *zwk_recovery_anchor(ZwkNotify callback,void *owner) {
    ZwkPage *s=[[ZwkPage alloc] init];
    if (!s) return NULL;
    s->owner=owner; s->notify_fn=callback;
    return (__bridge_retained void *)s;
}

/* Compiled content rule lists, kept by a WKContentRuleListStore at the
 * caller's directory. A compile holds itself through its engine calls; a
 * cancelled one finishes them without calling its owner. */
@interface ZwkCompile : NSObject {
@public
    ZwkContentDone done;
    void *context;
    NSString *list_id, *identifier;
}
@end
@implementation ZwkCompile
@end
#define HASH_DIGITS 16
static BOOL stale(NSString *list_id,NSString *current,NSString *name) {
    if ([name isEqualToString:current] || ![name hasPrefix:[list_id stringByAppendingString:@"-"]]) return NO;
    NSString *hash=[name substringFromIndex:list_id.length+1];
    if (hash.length!=HASH_DIGITS) return NO;
    for (NSUInteger i=0;i<hash.length;i++) {
        const unichar c=[hash characterAtIndex:i];
        if (!((c>='0'&&c<='9')||(c>='a'&&c<='f'))) return NO;
    }
    return YES;
}
static void compile_finish(ZwkCompile *op,WKContentRuleList *list,NSError *error) {
    ZwkContentDone done=op->done; op->done=NULL;
    if (done) {
        const BOOL invalid=error && [error.domain isEqualToString:WKErrorDomain] && error.code==WKErrorContentRuleListStoreCompileFailed;
        done(op->context,list?(__bridge_retained void *)list:NULL,invalid?1:0,error?domain_code(error.domain):0,error?(int32_t)error.code:0);
    }
    atomic_fetch_sub(&live_compiles,1);
}
int zwk_content_compile(const char *directory,const char *name_id,const char *identifier,const char *rules,size_t length,ZwkContentDone done,void *context,ZwkContentCompile **out) {
    *out=NULL;
    if (!directory || !name_id || !identifier || !rules || !done || directory[0]!='/') return ZWK_CONTENT_INVALID;
    @autoreleasepool {
        NSString *path=[NSString stringWithUTF8String:directory];
        NSString *source=[[NSString alloc] initWithBytes:rules length:length encoding:NSUTF8StringEncoding];
        if (!path || !source) return ZWK_CONTENT_INVALID;
        if (![[NSFileManager defaultManager] createDirectoryAtPath:path withIntermediateDirectories:YES attributes:@{NSFilePosixPermissions:@0700} error:NULL]) return ZWK_CONTENT_STORAGE;
        ZwkCompile *op=[[ZwkCompile alloc] init];
        if (!op) return ZWK_CONTENT_OOM;
        op->done=done; op->context=context;
        op->list_id=[NSString stringWithUTF8String:name_id]; op->identifier=[NSString stringWithUTF8String:identifier];
        if (!op->list_id || !op->identifier) return ZWK_CONTENT_INVALID;
        WKContentRuleListStore *store=[WKContentRuleListStore storeWithURL:[NSURL fileURLWithPath:path isDirectory:YES]];
        if (!store) return ZWK_CONTENT_STORAGE;
        atomic_fetch_add(&live_compiles,1);
        [store lookUpContentRuleListForIdentifier:op->identifier completionHandler:^(WKContentRuleList *found,NSError *missing) {
            (void)missing;
            if (found || !op->done) { compile_finish(op,found,nil); return; }
            [store compileContentRuleListForIdentifier:op->identifier encodedContentRuleList:source completionHandler:^(WKContentRuleList *list,NSError *error) {
                if (list) {
                    /* Removes the lists the store keeps for id but this one. */
                    NSString *list_id=op->list_id, *current=op->identifier;
                    [store getAvailableContentRuleListIdentifiers:^(NSArray<NSString *> *names) {
                        for (NSString *name in names) if (stale(list_id,current,name)) [store removeContentRuleListForIdentifier:name completionHandler:^(NSError *removed) { (void)removed; }];
                    }];
                }
                compile_finish(op,list,list?nil:error);
            }];
        }];
        *out=(__bridge ZwkContentCompile *)op;
    }
    return ZWK_CONTENT_OK;
}
void zwk_content_cancel(ZwkContentCompile *value) {
    if (!value) return;
    ZwkCompile *op=(__bridge ZwkCompile *)value;
    op->done=NULL; op->context=NULL;
}
void zwk_content_filter_unref(void *filter) { if (filter) CFRelease(filter); }
const char *zwk_content_filter_identifier(void *filter) { return ((__bridge WKContentRuleList *)filter).identifier.UTF8String; }
uint32_t zwk_content_compile_count(void) { return atomic_load(&live_compiles); }

/* Contracts this backend does not implement yet. Each refuses or reports
 * nothing; the Zig side refuses the options that would reach them. */
void zwk_initializer_counts(uint32_t *budgets,uint32_t *owners,uint32_t *handlers,uint64_t *bytes) { *budgets=0; *owners=0; *handlers=0; *bytes=0; }
int zwk_initializers_prepare(ZwkState *s,const ZwkInitializerInput *input,uint64_t token,ZwkInitializerNotify callback) { (void)s; (void)input; (void)token; (void)callback; return ZWK_INVALID; }
void zwk_initializers_activate(ZwkState *s) { (void)s; }
void zwk_initializers_abandon(ZwkState *s) { (void)s; }
void zwk_initializers_cancel(ZwkState *s,uint64_t token) { (void)s; (void)token; }
_Bool zwk_initializers_try_cancel(ZwkState *s,uint64_t token) { (void)s; (void)token; return 0; }
_Bool zwk_initializers_blocked(ZwkState *s) { (void)s; return 0; }
void *zwk_initializer_budget_create(size_t limit,int32_t *status) { (void)limit; *status=0; return NULL; }
size_t zwk_initializer_budget_limit(void *budget) { (void)budget; return 0; }
void zwk_initializer_budget_retain(void *budget) { (void)budget; }
void zwk_initializer_budget_unref(void *budget) { (void)budget; }
_Bool zwk_initializer_budget_reserve(void *budget,size_t bytes) { (void)budget; (void)bytes; return 0; }
void zwk_initializer_budget_release(void *budget,size_t bytes) { (void)budget; (void)bytes; }

ZwkFindBudget *zwk_find_budget_new(uint32_t limit) { (void)limit; return NULL; }
int zwk_find_budget_limit(ZwkFindBudget *budget,uint32_t limit) { (void)budget; (void)limit; return ZWK_INVALID; }
void zwk_find_budget_close(ZwkFindBudget *budget) { (void)budget; }
void zwk_find_budget_release(ZwkFindBudget *budget) { (void)budget; }
int zwk_find_prepare(ZwkState *s,ZwkFindBudget *budget,ZwkFindNotify callback,const char *text,size_t length,uint32_t flags,ZwkFindCommand **out) {
    (void)s; (void)budget; (void)callback; (void)text; (void)length; (void)flags; *out=NULL; return ZWK_INVALID;
}
int zwk_find_commit(ZwkFindCommand *command,uint64_t token) { (void)command; (void)token; return ZWK_INVALID; }
void zwk_find_abort(ZwkFindCommand *command) { (void)command; }
int zwk_find_action(ZwkState *s,int action,ZwkFindSnapshot *snapshot) { (void)s; (void)action; (void)snapshot; return ZWK_INVALID; }
void zwk_find_cancel(ZwkState *s,uint64_t token) { (void)s; (void)token; }
void zwk_find_counts(uint32_t *a,uint32_t *b,uint32_t *c,size_t *d,size_t *e) { *a=0; *b=0; *c=0; *d=0; *e=0; }

ZwkCaptureBudget *zwk_capture_budget_new(uint32_t pending,uint32_t bytes,ZwkCaptureNotify callback) { (void)pending; (void)bytes; (void)callback; return NULL; }
int zwk_capture_budget_limit(ZwkCaptureBudget *budget,uint32_t pending,uint32_t bytes) { (void)budget; (void)pending; (void)bytes; return ZWK_CAPTURE_INVALID; }
void zwk_capture_budget_close(ZwkCaptureBudget *budget) { (void)budget; }
void zwk_capture_budget_release(ZwkCaptureBudget *budget) { (void)budget; }
int zwk_capture_enable(ZwkState *s,ZwkCaptureBudget *budget) { (void)s; (void)budget; return ZWK_CAPTURE_INVALID; }
int zwk_capture_start(ZwkState *s,uint64_t token) { (void)s; (void)token; return ZWK_CAPTURE_INVALID; }
int zwk_clear_start(ZwkState *s,uint64_t token) { (void)s; (void)token; return ZWK_CAPTURE_INVALID; }
int zwk_pdf_start(ZwkState *s,uint64_t token,const char *path,const ZwkPdfRequest *request) { (void)s; (void)token; (void)path; (void)request; return ZWK_CAPTURE_INVALID; }
void zwk_capture_cancel(ZwkState *s,uint64_t token) { (void)s; (void)token; }
void zwk_capture_counts(uint32_t *a,uint32_t *b,size_t *c,size_t *d) { *a=0; *b=0; *c=0; *d=0; }

int zwk_resources_enable(ZwkState *s,ZwkResourceNotify callback,int dynamic,uint32_t limit) { (void)s; (void)callback; (void)dynamic; (void)limit; return ZWK_INVALID; }
int zwk_resource_respond(void *request,uint32_t status,const uint8_t *mime,size_t mime_length,const uint8_t *body,size_t length,const ZwkResponseHeader *headers,uint32_t count) {
    (void)request; (void)status; (void)mime; (void)mime_length; (void)body; (void)length; (void)headers; (void)count; return ZWK_INVALID;
}
int zwk_resource_defer(void *request,uint64_t token) { (void)request; (void)token; return ZWK_INVALID; }
int zwk_resource_respond_deferred(ZwkState *s,uint64_t token,uint32_t status,const uint8_t *mime,size_t mime_length,const uint8_t *body,size_t length,const ZwkResponseHeader *headers,uint32_t count) {
    (void)s; (void)token; (void)status; (void)mime; (void)mime_length; (void)body; (void)length; (void)headers; (void)count; return ZWK_INVALID;
}
void zwk_resource_cancel(ZwkState *s,uint64_t token) { (void)s; (void)token; }
void zwk_resource_cancel_all(ZwkState *s) { (void)s; }
uint32_t zwk_resources_pending(void) { return 0; }
int zwk_resource_respond_file(void *request,ZwkFile *file,uint64_t length,ZwkFileBudget *budget,uint32_t status,const uint8_t *mime,size_t mime_length,const ZwkResponseHeader *headers,uint32_t count,int ticket,ZwkFileControl **out) {
    (void)request; (void)file; (void)length; (void)budget; (void)status; (void)mime; (void)mime_length; (void)headers; (void)count; (void)ticket; *out=NULL; return ZWK_INVALID;
}
int zwk_resource_respond_file_deferred(ZwkState *s,uint64_t token,ZwkFile *file,uint64_t length,ZwkFileBudget *budget,uint32_t status,const uint8_t *mime,size_t mime_length,const ZwkResponseHeader *headers,uint32_t count,int ticket,ZwkFileControl **out) {
    (void)s; (void)token; (void)file; (void)length; (void)budget; (void)status; (void)mime; (void)mime_length; (void)headers; (void)count; (void)ticket; *out=NULL; return ZWK_INVALID;
}
ZwkFileBudget *zwk_file_budget_create(uint32_t limit) { (void)limit; return NULL; }
void zwk_file_budget_limit(ZwkFileBudget *budget,uint32_t limit) { (void)budget; (void)limit; }
void zwk_file_budget_release(ZwkFileBudget *budget) { (void)budget; }
void zwk_file_counts(uint32_t *a,uint32_t *b,uint32_t *c,uint32_t *d) { *a=0; *b=0; *c=0; *d=0; }

ZwkLocalBudget *zwk_local_budget_new(uint32_t max_live,uint32_t max_bytes) { (void)max_live; (void)max_bytes; return NULL; }
void zwk_local_budget_limit(ZwkLocalBudget *budget,uint32_t max_live,uint32_t max_bytes) { (void)budget; (void)max_live; (void)max_bytes; }
void zwk_local_budget_release(ZwkLocalBudget *budget) { (void)budget; }
void zwk_local_counts(uint32_t *budgets,uint32_t *streams,uint32_t *bytes) { *budgets=0; *streams=0; *bytes=0; }
