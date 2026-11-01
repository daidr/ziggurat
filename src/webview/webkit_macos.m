/* The WKWebView backend: the WebKitGTK native contract of webkit_native.h on
 * macOS, for trusted HTML pages, custom-scheme local sites and remote pages
 * in ephemeral or persistent profile storage. A local site serves the page's HTML and resources
 * through a WKURLSchemeHandler. A remote page's grants hold by origin: the
 * navigation policy checks each navigation, and a content rule list of its
 * own blocks every load but those of granted origins. Sessions, regions and
 * cookie stores are refused here and before they reach this file.
 *
 * Every function runs on the main thread. A page object is reference counted
 * by Core Foundation: zwk_create and zwk_recovery_anchor return one reference
 * that zwk_close or the recovery calls give back, and every pending engine
 * completion holds its own through its block. */
#import <AppKit/AppKit.h>
#import <WebKit/WebKit.h>
#include <objc/message.h>
#include <objc/runtime.h>
#include <errno.h>
#include <fcntl.h>
#include <arpa/inet.h>
#include <ctype.h>
#include <stdatomic.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <strings.h>
#include <unistd.h>
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
@interface WKHTTPCookieStore (ZigguratEngine)
- (void)_flushCookiesToDiskWithCompletionHandler:(void (^)(void))done;
@end
@interface WKPreferences (ZigguratEngine)
- (void)_setUsesPageCache:(BOOL)value;
@end
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
@interface WKProcessPool (ZigguratEngine)
- (void)_registerURLSchemeAsSecure:(NSString *)scheme;
@end
#pragma clang diagnostic pop
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

/* One granted origin of a remote page, with the headers its navigations may
 * carry beyond the browser's own. */
typedef struct ZwkRemoteGrant {
    BOOL https;
    uint16_t port;
    uint32_t flags, methods, header_count;
    char host[256];
    char **names, **values;
} ZwkRemoteGrant;
/* The engine's own find, which WebKitGTK's find controller wraps too: one
 * search of a string reports its match count, or that it found none. */
@interface WKWebView (ZigguratFind)
- (void)_findString:(NSString *)string options:(NSUInteger)options maxCount:(NSUInteger)count;
- (void)_hideFindUI;
- (void)_setFindDelegate:(id)delegate;
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
    /* The navigation in progress: what it loads, and for history the item. */
    int nav_kind;
    BOOL nav_prepared;
    NSString *nav_uri;
    WKBackForwardListItem *nav_item;
    /* The local site, when the page has one: its strings and resource rows
     * live in local_storage. */
    BOOL local, local_ipc;
    char *local_storage;
    const char *local_scheme, *local_host, *local_start;
    ZwkLocalResource *local_resources;
    uint32_t local_count, local_limit;
    ZwkLocalBudget *local_budget;
    NSString *local_url, *local_csp;
    NSData *html_bytes;
    id local_handler;
    /* The site's grants beyond the default policy, when it has them. */
    BOOL policy_extended;
    uint32_t policy_methods, policy_header_count, policy_origin_count;
    char **policy_names, **policy_values, **policy_origins;
    /* The app's resource handler, and the requests it deferred. */
    ZwkResourceNotify resource_fn;
    uint32_t resource_limit;
    BOOL dynamic_document;
    NSMutableArray *deferred;
    /* The remote page, when the page is one: its grants and rule list. A
     * navigation the page starts itself is adopted when the engine names it. */
    BOOL remote, remote_loopback, remote_script_navigation, remote_redirects, waiting_remote, nav_adopt;
    uint32_t remote_count;
    ZwkRemoteGrant *remote_grants;
    NSString *remote_url, *remote_ipc, *remote_source, *remote_identifier;
    WKContentRuleList *remote_rules;
    /* The page's text search, once the app first searches it. */
    ZwkFindGate *find;
    /* The budget of captures, PDFs and clears, when the app allows them. */
    ZwkCaptureBudget *capture;
}
@end
static void resources_cancel_all(ZwkPage *s);
enum { NAV_INITIAL, NAV_REFRESH, NAV_LOCAL, NAV_HISTORY, NAV_REMOTE, NAV_FRAGMENT };
enum { REMOTE_NAVIGATE=1u, REMOTE_REQUESTS=2u, REMOTE_IPC=4u };
static BOOL managed_header(const char *name);
static BOOL header_name(const char *name);
static BOOL header_value(const char *value);
static int method_index(NSString *method);
static void remote_free(ZwkPage *s);
static void find_gate_close(ZwkFindGate *g);
static void capture_cancel_all(ZwkPage *s);
static void find_terminal(ZwkPage *s,BOOL found,NSUInteger count);

static BOOL live(ZwkPage *s) { return !s->closed && !s->recovering && s->owner; }
static ZwkPage *page_of(ZwkState *s) { return (__bridge ZwkPage *)(void *)s; }

/* Remote origins, as the Linux backend and the Zig validation name them:
 * http only on loopback hosts, and loopback only by the page's opt-in. */
static BOOL remote_loopback_host(const char *host) {
    const size_t length=strlen(host);
    if (!strcmp(host,"localhost") || (length>10 && !strcmp(host+length-10,".localhost"))) return YES;
    struct in_addr v4; struct in6_addr v6;
    if (inet_pton(AF_INET,host,&v4)==1) return (ntohl(v4.s_addr)>>24)==127;
    if (inet_pton(AF_INET6,host,&v6)==1) {
        static const uint8_t zero[12]={0};
        if (IN6_IS_ADDR_LOOPBACK(&v6)) return YES;
        const BOOL mapped=!memcmp(v6.s6_addr,zero,10) && v6.s6_addr[10]==255 && v6.s6_addr[11]==255;
        return (mapped || !memcmp(v6.s6_addr,zero,12)) && v6.s6_addr[12]==127;
    }
    return NO;
}
/* One http(s) URI's origin: scheme, lowercase host without brackets, port. */
static BOOL remote_parse(NSString *text,BOOL origin_only,BOOL loopback,ZwkRemoteGrant *out) {
    if (!text || [text lengthOfBytesUsingEncoding:NSUTF8StringEncoding]>16384) return NO;
    NSURLComponents *c=[NSURLComponents componentsWithString:text];
    if (!c || !c.scheme || !c.percentEncodedHost.length || c.percentEncodedUser || c.percentEncodedPassword) return NO;
    NSString *scheme=c.scheme.lowercaseString;
    const BOOL https=[scheme isEqualToString:@"https"];
    if (!https && ![scheme isEqualToString:@"http"]) return NO;
    NSString *host=c.percentEncodedHost.lowercaseString;
    if (host.length>2 && [host hasPrefix:@"["] && [host hasSuffix:@"]"]) host=[host substringWithRange:NSMakeRange(1,host.length-2)];
    const char *value=host.UTF8String;
    if (!value || !*value || strlen(value)>=sizeof(out->host) || strpbrk(value,"%/\\?#@[] ")) return NO;
    const long port=c.port?c.port.longValue:(https?443:80);
    if (port<1 || port>65535) return NO;
    if (origin_only && ((c.percentEncodedPath.length && ![c.percentEncodedPath isEqualToString:@"/"]) || c.percentEncodedQuery || c.percentEncodedFragment)) return NO;
    const BOOL local_host=remote_loopback_host(value);
    if ((local_host && !loopback) || (!https && !local_host)) return NO;
    memset(out,0,sizeof(*out));
    out->https=https; out->port=(uint16_t)port; memcpy(out->host,value,strlen(value)+1);
    return YES;
}
static const ZwkRemoteGrant *remote_grant(ZwkPage *s,NSString *uri) {
    ZwkRemoteGrant parsed;
    if (!s->remote || !remote_parse(uri,NO,s->remote_loopback,&parsed)) return NULL;
    for (uint32_t i=0;i<s->remote_count;++i) {
        const ZwkRemoteGrant *grant=&s->remote_grants[i];
        if (grant->https==parsed.https && grant->port==parsed.port && !strcmp(grant->host,parsed.host)) return grant;
    }
    return NULL;
}
/* A document of the page: an origin granted navigation and its GET. */
static BOOL remote_navigate(ZwkPage *s,NSString *uri) {
    const ZwkRemoteGrant *grant=remote_grant(s,uri);
    return grant && (grant->flags&(REMOTE_NAVIGATE|REMOTE_REQUESTS))==(REMOTE_NAVIGATE|REMOTE_REQUESTS) && (grant->methods&1u);
}
/* A navigation's own request, by its method and the headers it carries. */
static BOOL remote_request_allowed(ZwkPage *s,NSURLRequest *request) {
    const ZwkRemoteGrant *grant=remote_grant(s,request.URL.absoluteString);
    const int verb=method_index(request.HTTPMethod?:@"GET");
    if (!grant || verb<0 || !(grant->methods&(1u<<(unsigned)verb))) return NO;
    NSDictionary<NSString *,NSString *> *headers=request.allHTTPHeaderFields;
    if (headers.count>64) return NO;
    for (NSString *key in headers) {
        const char *name=key.UTF8String, *value=headers[key].UTF8String;
        if (!header_name(name) || !header_value(value)) return NO;
        if (managed_header(name)) continue;
        BOOL allowed=NO;
        for (uint32_t i=0;i<grant->header_count;++i) if (!strcasecmp(name,grant->names[i]) && (!grant->values[i] || !strcmp(value,grant->values[i]))) { allowed=YES; break; }
        if (!allowed) return NO;
    }
    return YES;
}
/* Escapes stay encoded: decoding a query could equate a delimiter with data. */
static BOOL remote_uri_equal(ZwkPage *s,NSString *a,NSString *b,BOOL ignore_fragment) {
    ZwkRemoteGrant x, y;
    if (!remote_parse(a,NO,s->remote_loopback,&x) || !remote_parse(b,NO,s->remote_loopback,&y) ||
        x.https!=y.https || x.port!=y.port || strcmp(x.host,y.host)) return NO;
    NSURLComponents *l=[NSURLComponents componentsWithString:a], *r=[NSURLComponents componentsWithString:b];
    NSString *lp=l.percentEncodedPath.length?l.percentEncodedPath:@"/", *rp=r.percentEncodedPath.length?r.percentEncodedPath:@"/";
    if (![lp isEqualToString:rp]) return NO;
    if (l.percentEncodedQuery!=r.percentEncodedQuery && ![l.percentEncodedQuery isEqualToString:r.percentEncodedQuery]) return NO;
    return ignore_fragment || l.percentEncodedFragment==r.percentEncodedFragment || [l.percentEncodedFragment isEqualToString:r.percentEncodedFragment];
}
/* The engine moves within the document to a URI with a fragment that
 * differs from the current one at most in its fragment. */
static BOOL remote_fragment_change(ZwkPage *s,NSString *from,NSString *to) {
    return [NSURLComponents componentsWithString:to].percentEncodedFragment!=nil && remote_uri_equal(s,from,to,YES);
}
static BOOL same_uri(ZwkPage *s,NSString *a,NSString *b) {
    if (!a || !b) return NO;
    return s->remote?remote_uri_equal(s,a,b,NO):[a isEqualToString:b];
}

void zwk_counts(uint32_t *states,uint32_t *callbacks,uint32_t *views) {
    *states=atomic_load(&live_states); *callbacks=atomic_load(&live_callbacks); *views=atomic_load(&live_views);
}
void zwk_last_failure(ZwkState *s,ZwkFailure *value) { *value=page_of(s)->failure; }
/* Test hook: whether the page swipes between pages and pinches. */
void zwk_test_gestures(ZwkState *s,int *swipe,int *pinch) {
    WKWebView *view=page_of(s)->view; *swipe=view.allowsBackForwardNavigationGestures?1:0; *pinch=view.allowsMagnification?1:0;
}

static void failure_set(ZwkPage *s,NSError *error) {
    if (error) s->failure=(ZwkFailure){domain_code(error.domain),(int32_t)error.code};
}
/* A NUL-terminated UTF-16 copy of text, or NULL past limit UTF-8 bytes. */
static uint16_t *utf16_copy(NSString *text,size_t limit) {
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
    uint16_t *value=utf16_copy(text,65536);
    s->notify_fn(s->owner,kind,value,code,failure);
    free(value);
}
static BOOL page(ZwkPage *s,int kind,uint32_t flags,int32_t status,NSString *text) {
    if (!live(s) || !s->page_fn) return NO;
    uint16_t *value=utf16_copy(text,16384);
    ZwkPageEvent event={kind,s->generation,flags,status,value};
    const BOOL accepted=s->page_fn(s->owner,&event)!=0;
    free(value);
    return accepted && live(s);
}
/* A path of the site: letters, digits and -_. between slashes, without
 * dot segments. */
static BOOL local_route(const char *path) {
    size_t length=0, segment=0;
    if (!path || path[0]!='/') return NO;
    for (;path[length];++length) {
        const unsigned char c=(unsigned char)path[length];
        if (length==4096 || (!isalnum(c) && !strchr("/-_.",c))) return NO;
        if (c=='/') {
            if ((segment==1 && path[length-1]=='.') || (segment==2 && path[length-1]=='.' && path[length-2]=='.')) return NO;
            segment=0;
        } else ++segment;
    }
    return !((segment==1 && path[length-1]=='.') || (segment==2 && path[length-1]=='.' && path[length-2]=='.'));
}
/* A URI of the site, scheme://host/path with an optional query and
 * fragment, and its path. Credentials, ports and escapes never make another
 * authority or route. */
static BOOL local_uri(ZwkPage *s,const char *text,char path[4097]) {
    if (!s->local || !text || strnlen(text,16385)>16384) return NO;
    for (const char *p=text;*p;++p) if ((unsigned char)*p<=32 || (unsigned char)*p>=127 || *p=='\\') return NO;
    const char *authority=strstr(text,"://");
    if (!authority) return NO;
    const size_t scheme_length=(size_t)(authority-text);
    if (scheme_length!=strlen(s->local_scheme) || strncasecmp(text,s->local_scheme,scheme_length)) return NO;
    authority+=3;
    const size_t authority_length=strcspn(authority,"/?#");
    for (size_t i=0;i<authority_length;++i) if (authority[i]=='@' || authority[i]==':' || authority[i]=='%') return NO;
    if (authority_length!=strlen(s->local_host) || strncasecmp(authority,s->local_host,authority_length)) return NO;
    const char *raw=authority+authority_length;
    const size_t path_length=strcspn(raw,"?#");
    if (!path_length || path_length>4096) return NO;
    memcpy(path,raw,path_length); path[path_length]=0;
    return local_route(path);
}
static BOOL trusted_uri(ZwkPage *s,NSString *uri) {
    char path[4097];
    if (!uri) return NO;
    if (s->remote) return remote_navigate(s,uri);
    return s->local?local_uri(s,uri.UTF8String,path):[uri isEqualToString:@"about:blank"];
}
static BOOL document(ZwkPage *s) {
    if (!live(s) || !s->committed || s->failed || !s->view) return NO;
    if (s->pending_navigation && !s->nav_prepared) return NO;
    return trusted_uri(s,s->view.URL.absoluteString);
}
static BOOL ipc_allowed(ZwkPage *s) {
    if (s->remote) { const ZwkRemoteGrant *grant=remote_grant(s,s->view.URL.absoluteString); return grant && (grant->flags&REMOTE_IPC); }
    return !s->local || s->local_ipc;
}
static void history_notify(ZwkPage *s) {
    if (!live(s) || !s->committed || (!s->local && !s->remote)) return;
    (void)page(s,5,(s->view.canGoBack?1u:0u)|(s->view.canGoForward?2u:0u),0,nil);
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
static WKContentRuleListStore *rule_store(void) {
    NSURL *directory=[NSURL fileURLWithPath:[NSTemporaryDirectory() stringByAppendingPathComponent:@"ziggurat-webkit-sandbox"] isDirectory:YES];
    [[NSFileManager defaultManager] createDirectoryAtURL:directory withIntermediateDirectories:YES attributes:@{NSFilePosixPermissions:@0700} error:NULL];
    return [WKContentRuleListStore storeWithURL:directory];
}
static void sandbox_compile(void) {
    if (sandbox || sandbox_compiling) return;
    sandbox_compiling=YES; sandbox_error=nil;
    NSString *source=@"[{\"trigger\":{\"url-filter\":\".*\",\"resource-type\":[\"image\",\"style-sheet\",\"script\",\"font\",\"raw\",\"svg-document\",\"media\"]},\"action\":{\"type\":\"block\"}}]";
    WKContentRuleListStore *store=rule_store();
    [store compileContentRuleListForIdentifier:@"ziggurat-html-sandbox-1" encodedContentRuleList:source completionHandler:^(WKContentRuleList *list,NSError *error) {
        sandbox_compiling=NO; sandbox=list; sandbox_error=list?nil:error;
        NSArray<ZwkPage *> *waiting=sandbox_waiting; sandbox_waiting=nil;
        for (ZwkPage *s in waiting) { s->waiting_sandbox=NO; initialize(s); }
    }];
}
static void rule_lists_apply(ZwkPage *s) {
    [s->controller removeAllContentRuleLists];
    /* A local site's own content security policy keeps it to its loads; a
     * remote page's list keeps it to its granted origins. */
    if (s->remote) { if (s->remote_rules) [s->controller addContentRuleList:s->remote_rules]; }
    else if (sandbox && !s->local) [s->controller addContentRuleList:sandbox];
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

static void navigation_forget(ZwkPage *s) {
    s->pending_navigation=NO; s->authorized=NO; s->nav_prepared=NO; s->nav_adopt=NO; s->nav_uri=nil; s->nav_item=nil;
}
static void navigation_clear(ZwkPage *s) {
    navigation_forget(s); s->navigation=nil; s->load_started=NO;
}
/* Withdraws the current navigation. A started load keeps its identity until
 * the engine ends it, as a failed load that grants nothing. */
static void navigation_revoke(ZwkPage *s) {
    navigation_forget(s);
    if (s->load_started) { s->committed=NO; s->failed=YES; }
    else s->navigation=nil;
}
static void navigation_fail(ZwkPage *s,int code,NSString *reason) {
    if (!live(s)) return;
    const uint64_t generation=s->generation;
    failure_set(s,[NSError errorWithDomain:@"ziggurat-webkit-navigation" code:code userInfo:@{NSLocalizedDescriptionKey:reason}]);
    const ZwkFailure failure=s->failure;
    s->committed=NO; s->failed=YES; navigation_revoke(s);
    if (live(s) && s->generation==generation) resources_cancel_all(s);
    if (live(s) && s->generation==generation) (void)page(s,6,0,0,nil);
    if (live(s) && s->generation==generation) [s->view stopLoading];
    if (live(s) && s->generation==generation) notify(s,2,nil,code,&failure);
}
/* Installs the next document's private and public scripts and takes the
 * next generation, after the private invalidation of the current one. */
static int prepare_document(ZwkPage *s) {
    if (!live(s)) return ZWK_CLOSED;
    if (s->generation==UINT64_MAX) return ZWK_FULL;
    NSString *source_check=s->remote?@"trusted.has(location.origin)":s->local?[NSString stringWithFormat:@"location.protocol==='%s:'&&location.hostname==='%s'&&location.port===''",s->local_scheme,s->local_host]:
        @"location.href==='about:blank'";
    NSString *preamble=s->remote?[NSString stringWithFormat:@"const trusted=new Set(%@.map(x=>new URL(x).origin));",s->remote_ipc]:@"";
    NSString *private_script=[NSString stringWithFormat:
        @"(()=>{%@const send=x=>webkit.messageHandlers.ziggurat.postMessage('%llu|'+x);"
        "const valid=x=>{if(typeof x!=='string'||x.length>65536)return false;let bytes=0;"
        "for(const c of x){const p=c.codePointAt(0);if(!p)return false;bytes+=p<128?1:p<2048?2:p<65536?3:4;"
        "if(bytes>65536)return false}return true};"
        "addEventListener('message',e=>{if(e.isTrusted&&e.source===window&&window===top&&%@&&"
        "e.data&&valid(e.data.__ziggurat))send('M'+e.data.__ziggurat)});"
        "addEventListener('DOMContentLoaded',()=>send('D'),{once:true});%@})()",
        preamble,(unsigned long long)(s->generation+1),source_check,s->facts?:@""];
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
    resources_cancel_all(s);
    if (!s->pending_navigation || s->generation!=generation) return live(s)?ZWK_NAVIGATION_CANCELLED:ZWK_CLOSED;
    ++s->generation; s->failed=NO; s->dom_ready=NO;
    [s->controller removeAllUserScripts];
    [s->controller addUserScript:[[WKUserScript alloc] initWithSource:private_script injectionTime:WKUserScriptInjectionTimeAtDocumentStart forMainFrameOnly:YES inContentWorld:s->world]];
    [s->controller addUserScript:[[WKUserScript alloc] initWithSource:public_script injectionTime:WKUserScriptInjectionTimeAtDocumentStart forMainFrameOnly:YES inContentWorld:WKContentWorld.pageWorld]];
    return ZWK_OK;
}
/* Starts a navigation: prepares the next document, then issues the load.
 * A history navigation prepares when the engine asks for its policy, as a
 * same-document one keeps its document. ready first tells the owner the page
 * exists. */
static int navigation_submit(ZwkPage *s,int kind,NSString *uri,WKBackForwardListItem *item,BOOL ready) {
    if (s->pending_navigation || s->load_started || s->view.loading) return ZWK_NAVIGATION_PENDING;
    if (!uri || [uri lengthOfBytesUsingEncoding:NSUTF8StringEncoding]>16384) return ZWK_INVALID;
    s->pending_navigation=YES; s->authorized=NO; s->navigation=nil;
    s->nav_kind=kind; s->nav_uri=uri; s->nav_item=item; s->nav_prepared=NO;
    if (kind!=NAV_HISTORY && kind!=NAV_FRAGMENT) {
        const int result=prepare_document(s);
        if (result!=ZWK_OK) { if (live(s)) navigation_clear(s); return result; }
        s->nav_prepared=YES;
    }
    const uint64_t generation=s->generation;
    if (ready) notify(s,0,nil,0,NULL);
    if (!live(s)) return ZWK_CLOSED;
    if (!s->pending_navigation || s->generation!=generation) return ZWK_NAVIGATION_CANCELLED;
    WKNavigation *value;
    if (kind==NAV_HISTORY) value=[s->view goToBackForwardListItem:item];
    else if (!s->local && !s->remote) value=[s->view loadHTMLString:s->html baseURL:nil];
    else if (kind==NAV_REFRESH) value=[s->view reload];
    else value=[s->view loadRequest:[NSURLRequest requestWithURL:[NSURL URLWithString:uri]]];
    if (!live(s)) return ZWK_CLOSED;
    if (!s->pending_navigation || s->generation!=generation) return ZWK_NAVIGATION_CANCELLED;
    if (!value && kind!=NAV_HISTORY && kind!=NAV_FRAGMENT) { navigation_clear(s); return ZWK_NATIVE_FAILED; }
    s->navigation=value;
    return ZWK_OK;
}
static void remote_compile(ZwkPage *s);
static void initialize(ZwkPage *s) {
    if (!live(s)) return;
    if (s->remote) {
        if (!s->remote_rules) { if (!s->waiting_remote) remote_compile(s); return; }
    } else if (!sandbox && !s->local) {
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
    if (navigation_submit(s,s->remote?NAV_REMOTE:NAV_INITIAL,s->remote?s->remote_url:s->local?s->local_url:@"about:blank",nil,YES)!=ZWK_OK && live(s))
        navigation_fail(s,ZWK_POLICY_PREPARATION,@"Initial document preparation failed");
}

static BOOL user_gesture(WKNavigationAction *action) {
    SEL selector=NSSelectorFromString(@"_isUserInitiated");
    if ([action respondsToSelector:selector]) return ((BOOL (*)(id,SEL))objc_msgSend)(action,selector);
    return action.navigationType==WKNavigationTypeLinkActivated || action.navigationType==WKNavigationTypeFormSubmitted;
}

static void *title_context=&title_context;
static void *audio_context=&audio_context;
static void *history_context=&history_context;

@implementation ZwkPage
- (instancetype)init {
    if ((self=[super init])) { cancelled=[NSMutableSet set]; atomic_fetch_add(&live_states,1); }
    return self;
}
- (void)dealloc {
    for (uint32_t i=0;i<policy_header_count;++i) { free(policy_names[i]); free(policy_values[i]); }
    for (uint32_t i=0;i<policy_origin_count;++i) free(policy_origins[i]);
    free(policy_names); free(policy_values); free(policy_origins);
    free(local_storage);
    if (local_budget) zwk_local_budget_release(local_budget);
    remote_free(self);
    if (capture) zwk_capture_budget_release(capture);
    atomic_fetch_sub(&live_states,1);
}

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
    if (live(self) && pending_navigation && !authorized) {
        if (!local && !remote) allowed=action.navigationType==WKNavigationTypeOther && [uri isEqualToString:@"about:blank"];
        else {
            allowed=trusted_uri(self,uri) && same_uri(self,uri,nav_uri);
            if (allowed && nav_kind==NAV_HISTORY) allowed=action.navigationType==WKNavigationTypeBackForward;
            if (allowed && remote) allowed=remote_request_allowed(self,action.request);
            if (allowed && !nav_prepared && nav_kind!=NAV_FRAGMENT) {
                const int result=prepare_document(self);
                allowed=result==ZWK_OK && live(self) && pending_navigation;
                if (allowed) nav_prepared=YES;
                else if (live(self) && pending_navigation) navigation_fail(self,ZWK_POLICY_PREPARATION,@"Navigation document preparation failed");
            }
        }
    } else if (live(self) && remote && remote_navigate(self,uri) && remote_request_allowed(self,action.request)) {
        if (pending_navigation) {
            /* A server redirect of the load in progress. */
            if (authorized && load_started && nav_prepared && remote_redirects) { nav_uri=uri; decision(WKNavigationActionPolicyAllow); return; }
        } else if (remote_script_navigation && action.navigationType!=WKNavigationTypeFormSubmitted && action.navigationType!=WKNavigationTypeFormResubmitted) {
            /* The page's own navigation: forms stay refused, as Linux's
             * form-action 'none' refuses them. */
            const int kind=committed && current_uri && remote_fragment_change(self,current_uri,uri)?NAV_FRAGMENT:NAV_REMOTE;
            pending_navigation=YES; authorized=NO; navigation=nil; load_started=NO;
            nav_kind=kind; nav_uri=uri; nav_item=nil; nav_prepared=NO; nav_adopt=YES;
            if (kind==NAV_FRAGMENT) allowed=YES;
            else {
                const int result=prepare_document(self);
                allowed=result==ZWK_OK && live(self) && pending_navigation;
                if (allowed) nav_prepared=YES;
                else if (live(self) && pending_navigation) navigation_fail(self,ZWK_POLICY_PREPARATION,@"Script navigation preparation failed");
            }
        }
    }
    if (allowed) { authorized=YES; decision(WKNavigationActionPolicyAllow); return; }
    decision(WKNavigationActionPolicyCancel);
    if (live(self) && (policy&1u)) notify(self,3,uri,user_gesture(action)?1:0,NULL);
}
- (void)webView:(WKWebView *)webView decidePolicyForNavigationResponse:(WKNavigationResponse *)response decisionHandler:(void (^)(WKNavigationResponsePolicy))decision {
    (void)webView;
    decision(live(self) && response.canShowMIMEType?WKNavigationResponsePolicyAllow:WKNavigationResponsePolicyCancel);
}
/* Whether a navigation the engine names is the one in progress. The page's
 * own navigation is known by the first one named after its policy. */
- (BOOL)current:(WKNavigation *)value {
    if (!value) return NO;
    if (value==navigation) return YES;
    if (!nav_adopt || navigation || !pending_navigation || !authorized) return NO;
    navigation=value; nav_adopt=NO;
    return YES;
}
- (void)webView:(WKWebView *)webView didStartProvisionalNavigation:(WKNavigation *)value {
    ZwkPage *keep __attribute__((objc_precise_lifetime))=self; (void)keep;
    if (!live(self) || ![self current:value]) return;
    if (!pending_navigation || !authorized || !nav_prepared) { navigation_fail(self,ZWK_POLICY_PREPARATION,@"Full document started without prepared authorization"); return; }
    const uint64_t current=generation;
    load_started=YES; committed=NO; failed=NO; dom_ready=NO;
    if (!page(self,0,0,0,webView.URL.absoluteString?:nav_uri) && live(self) && generation==current) {
        navigation_revoke(self);
        [webView stopLoading];
    }
}
- (void)webView:(WKWebView *)webView didReceiveServerRedirectForProvisionalNavigation:(WKNavigation *)value {
    ZwkPage *keep __attribute__((objc_precise_lifetime))=self; (void)keep;
    if (!live(self) || ![self current:value] || !pending_navigation) return;
    NSString *uri=webView.URL.absoluteString;
    if (!remote || !remote_redirects || !remote_navigate(self,uri)) navigation_fail(self,ZWK_POLICY_PREPARATION,@"Redirect denied");
    else nav_uri=uri;
}
- (void)webView:(WKWebView *)webView didCommitNavigation:(WKNavigation *)value {
    ZwkPage *keep __attribute__((objc_precise_lifetime))=self; (void)keep;
    if (!live(self) || ![self current:value] || !pending_navigation) return;
    NSString *uri=webView.URL.absoluteString;
    if (!load_started || !trusted_uri(self,uri) || (nav_kind==NAV_HISTORY && webView.backForwardList.currentItem!=nav_item)) {
        navigation_fail(self,ZWK_POLICY_PREPARATION,@"Committed document has no valid current URI snapshot"); return;
    }
    current_uri=uri;
    const uint64_t current=generation;
    committed=YES;
    if (!page(self,3,1,0,uri) && live(self) && generation==current) committed=NO;
    if (live(self) && generation==current && committed && dom_ready) (void)page(self,2,0,0,nil);
}
- (void)finish:(WKNavigation *)value error:(NSError *)error {
    ZwkPage *keep __attribute__((objc_precise_lifetime))=self; (void)keep;
    if (!live(self) || ![self current:value]) return;
    const BOOL started=load_started;
    int32_t status=0;
    if (error) { failure_set(self,error); status=failure.code; failed=YES; committed=NO; resources_cancel_all(self); }
    const BOOL success=document(self);
    const uint64_t current=generation;
    navigation_clear(self);
    if (started) (void)page(self,1,success?1:0,status,nil);
    if (started && live(self) && generation==current) history_notify(self);
}
/* pushState, replaceState, fragments and history within one document. Only
 * the page's own history navigation or a URI of the site is accepted. The
 * engine names a same-document history step with a navigation of its own,
 * not the one goToBackForwardListItem returned: the item tells it. */
- (void)_webView:(WKWebView *)webView navigation:(WKNavigation *)value didSameDocumentNavigation:(NSInteger)type {
    ZwkPage *keep __attribute__((objc_precise_lifetime))=self; (void)keep; (void)type; (void)value;
    if (!live(self)) return;
    NSString *uri=webView.URL.absoluteString;
    if (pending_navigation && !load_started && ((nav_kind==NAV_HISTORY && !authorized) || nav_kind==NAV_FRAGMENT)) {
        if (!trusted_uri(self,uri) || !same_uri(self,uri,nav_uri) || (nav_kind==NAV_HISTORY && webView.backForwardList.currentItem!=nav_item)) {
            navigation_fail(self,ZWK_POLICY_PREPARATION,@"Unexpected same-document navigation sequence");
            return;
        }
        current_uri=uri;
        navigation_clear(self);
        (void)page(self,3,1,0,uri);
        if (live(self) && !pending_navigation) history_notify(self);
        return;
    }
    if (!committed || pending_navigation || [uri isEqualToString:current_uri]) return;
    if (!trusted_uri(self,uri)) { navigation_fail(self,ZWK_POLICY_PREPARATION,@"Same-document URI snapshot failed"); return; }
    current_uri=uri;
    (void)page(self,3,1,0,uri);
}
- (void)webView:(WKWebView *)webView didFinishNavigation:(WKNavigation *)value { (void)webView; [self finish:value error:nil]; }
- (void)webView:(WKWebView *)webView didFailNavigation:(WKNavigation *)value withError:(NSError *)error { (void)webView; [self finish:value error:error]; }
- (void)webView:(WKWebView *)webView didFailProvisionalNavigation:(WKNavigation *)value withError:(NSError *)error { (void)webView; [self finish:value error:error]; }
/* _WKFindDelegate: the answer to the search in progress. */
- (void)_webView:(WKWebView *)webView didFindMatches:(NSUInteger)matches forString:(NSString *)string withMatchIndex:(NSInteger)index {
    ZwkPage *keep __attribute__((objc_precise_lifetime))=self; (void)keep; (void)webView; (void)string; (void)index;
    find_terminal(self,YES,matches);
}
- (void)_webView:(WKWebView *)webView didFailToFindString:(NSString *)string {
    ZwkPage *keep __attribute__((objc_precise_lifetime))=self; (void)keep; (void)webView; (void)string;
    find_terminal(self,NO,0);
}
- (void)webViewWebContentProcessDidTerminate:(WKWebView *)webView {
    ZwkPage *keep __attribute__((objc_precise_lifetime))=self; (void)keep; (void)webView;
    failed=YES; committed=NO;
    navigation_clear(self);
    resources_cancel_all(self);
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
    } else if (kind=='M' && bytes<=65536 && document(self) && notify_fn && ipc_allowed(self)) {
        uint16_t *value=utf16_copy(rest,65536);
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
    } else if (context==history_context) {
        if (!pending_navigation) history_notify(self);
    } else [super observeValueForKeyPath:path ofObject:object change:change context:context];
}
@end

/* Budgets bound the response bodies a site has in flight. A body here is
 * handed to the engine whole, so it holds its reservation only while it is
 * delivered. */
struct ZwkLocalBudget { atomic_int refs, live, bytes, max_live, max_bytes; };
static atomic_int local_budgets, local_streams, local_bytes;
static BOOL local_reserve(atomic_int *value,int amount,int limit) {
    int previous=atomic_load(value);
    for (;;) {
        if (previous>limit || amount>limit-previous) return NO;
        if (atomic_compare_exchange_weak(value,&previous,previous+amount)) return YES;
    }
}
ZwkLocalBudget *zwk_local_budget_new(uint32_t max_live,uint32_t max_bytes) {
    if (!max_live || max_live>8 || !max_bytes || max_bytes>32*1024*1024) return NULL;
    ZwkLocalBudget *budget=calloc(1,sizeof(*budget));
    if (!budget) return NULL;
    atomic_init(&budget->refs,1); atomic_init(&budget->max_live,(int)max_live); atomic_init(&budget->max_bytes,(int)max_bytes);
    atomic_fetch_add(&local_budgets,1);
    return budget;
}
void zwk_local_budget_limit(ZwkLocalBudget *budget,uint32_t max_live,uint32_t max_bytes) {
    if (!max_live || max_live>8 || !max_bytes || max_bytes>32*1024*1024) abort();
    atomic_store(&budget->max_live,(int)max_live); atomic_store(&budget->max_bytes,(int)max_bytes);
}
void zwk_local_budget_release(ZwkLocalBudget *budget) {
    if (atomic_fetch_sub(&budget->refs,1)!=1) return;
    if (atomic_load(&budget->live) || atomic_load(&budget->bytes)) abort();
    free(budget); atomic_fetch_sub(&local_budgets,1);
}
void zwk_local_counts(uint32_t *budgets,uint32_t *streams,uint32_t *bytes) {
    *budgets=(uint32_t)atomic_load(&local_budgets); *streams=(uint32_t)atomic_load(&local_streams); *bytes=(uint32_t)atomic_load(&local_bytes);
}
static BOOL local_body_reserve(ZwkLocalBudget *budget,int length) {
    if (!local_reserve(&local_streams,1,32)) return NO;
    if (!local_reserve(&budget->live,1,atomic_load(&budget->max_live))) { atomic_fetch_sub(&local_streams,1); return NO; }
    if (!local_reserve(&budget->bytes,length,atomic_load(&budget->max_bytes))) {
        atomic_fetch_sub(&budget->live,1); atomic_fetch_sub(&local_streams,1); return NO;
    }
    atomic_fetch_add(&local_bytes,length);
    return YES;
}
static void local_body_release(ZwkLocalBudget *budget,int length) {
    atomic_fetch_sub(&budget->bytes,length); atomic_fetch_sub(&budget->live,1);
    atomic_fetch_sub(&local_bytes,length); atomic_fetch_sub(&local_streams,1);
}

/* Headers the engine sets itself. The default policy takes no other, and
 * no Origin: a site's own reads are GET and HEAD without one. */
static BOOL managed_header(const char *name) {
    if (!strncasecmp(name,"sec-",4)) return YES;
    static const char *const names[]={"accept","accept-encoding","accept-language","user-agent","origin","referer","cookie","host","connection","content-length","cache-control","pragma","dnt","priority","upgrade-insecure-requests","if-match","if-none-match","if-modified-since","if-unmodified-since","if-range","access-control-request-method","access-control-request-headers"};
    for (size_t i=0;i<sizeof(names)/sizeof(*names);++i) if (!strcasecmp(name,names[i])) return YES;
    return NO;
}
static BOOL header_name(const char *name) {
    if (!name || !*name) return NO;
    for (const char *p=name;*p;++p) if (!isalnum((unsigned char)*p) && !strchr("!#$%&'*+-.^_`|~",*p)) return NO;
    return YES;
}
static BOOL header_value(const char *value) {
    if (!value) return NO;
    for (const char *p=value;*p;++p) if (((unsigned char)*p<32 && *p!='\t') || (unsigned char)*p==127) return NO;
    return YES;
}
static int method_index(NSString *method) {
    static NSString *const methods[]={@"GET",@"HEAD",@"POST",@"PUT",@"PATCH",@"DELETE",@"OPTIONS"};
    for (int i=0;i<7;i++) if ([method isEqualToString:methods[i]]) return i;
    return -1;
}
/* The site's policy for one request: its method, its headers and its Origin,
 * as the Linux backend checks them. */
static BOOL local_request_allowed(ZwkPage *s,int verb,NSDictionary<NSString *,NSString *> *headers) {
    if (verb<0 || headers.count>64) return NO;
    size_t bytes=0; BOOL saw_origin=NO;
    if (s->policy_extended && !(s->policy_methods&(1u<<(unsigned)verb))) return NO;
    for (NSString *key in headers) {
        const char *name=key.UTF8String, *value=headers[key].UTF8String;
        if (!header_name(name) || !header_value(value) || (bytes+=strlen(name)+strlen(value))>16384) return NO;
        if (!strcasecmp(name,"origin")) {
            if (!s->policy_extended) return NO;
            BOOL allowed=NO;
            for (uint32_t i=0;i<s->policy_origin_count;++i) if (!strcmp(value,s->policy_origins[i])) { allowed=YES; break; }
            if (!allowed) return NO;
            saw_origin=YES;
        }
        if (managed_header(name)) continue;
        if (!s->policy_extended) return NO;
        BOOL allowed=NO;
        for (uint32_t i=0;i<s->policy_header_count;++i) if (!strcasecmp(name,s->policy_names[i]) && (!s->policy_values[i] || !strcmp(value,s->policy_values[i]))) { allowed=YES; break; }
        if (!allowed) return NO;
    }
    return verb<2 || (s->policy_extended && saw_origin);
}

@interface ZwkLocalHandler : NSObject <WKURLSchemeHandler> {
@public
    __weak ZwkPage *site_page;
}
@end
@interface ZwkDeferred : NSObject {
@public
    id<WKURLSchemeTask> task;
    uint64_t token, generation;
    BOOL head;
}
@end
@implementation ZwkDeferred
@end
static atomic_int live_resource_requests;
uint32_t zwk_resources_pending(void) { return (uint32_t)atomic_load(&live_resource_requests); }
static NSError *local_denied(void) {
    return [NSError errorWithDomain:@"ziggurat-local-resource" code:1 userInfo:@{NSLocalizedDescriptionKey:@"Local resource denied or full"}];
}
static BOOL response_text(char *out,const uint8_t *input,size_t length,size_t limit,BOOL name) {
    if (length>limit || (length && !input) || (name && !length)) return NO;
    for (size_t i=0;i<length;++i) if (input[i]<32 || input[i]>126) return NO;
    if (length) memcpy(out,input,length);
    out[length]=0;
    return !name || header_name(out);
}
static BOOL response_reserved(const char *name) {
    static const char *const reserved[]={"content-type","content-length","transfer-encoding","connection","keep-alive","te","trailer","upgrade","proxy-authenticate","proxy-authorization"};
    for (size_t i=0;i<sizeof(reserved)/sizeof(*reserved);++i) if (!strcasecmp(name,reserved[i])) return YES;
    return NO;
}
/* One response of the site, with its security headers. The body holds its
 * budget while it is handed to the engine. */
static int local_respond(ZwkPage *s,id<WKURLSchemeTask> task,BOOL head,uint32_t status,const uint8_t *mime,size_t mime_length,
    const uint8_t *body,size_t length,const ZwkResponseHeader *rows,uint32_t count) {
    char mime_text[128];
    if (status<200 || status>599 || !mime_length || !response_text(mime_text,mime,mime_length,127,NO) || count>16 || (count && !rows) ||
        (length && !body) || length>s->local_limit || ((status==204 || status==205 || status==304) && length)) return ZWK_INVALID;
    NSMutableDictionary<NSString *,NSString *> *headers=[NSMutableDictionary dictionaryWithCapacity:count+5];
    size_t bytes=0;
    for (uint32_t i=0;i<count;++i) {
        char name[65], value[2049];
        if (!response_text(name,rows[i].name,rows[i].name_length,64,YES) || !response_text(value,rows[i].value,rows[i].value_length,2048,NO) || response_reserved(name)) return ZWK_INVALID;
        bytes+=rows[i].name_length+rows[i].value_length+4;
        if (bytes>8192) return ZWK_INVALID;
        NSString *key=[NSString stringWithUTF8String:name];
        for (NSString *earlier in headers) if ([earlier caseInsensitiveCompare:key]==NSOrderedSame) return ZWK_INVALID;
        headers[key]=[NSString stringWithUTF8String:value];
    }
    headers[@"Content-Type"]=[NSString stringWithUTF8String:mime_text];
    headers[@"Content-Length"]=[NSString stringWithFormat:@"%zu",length];
    headers[@"Content-Security-Policy"]=s->local_csp;
    headers[@"Cache-Control"]=@"no-store";
    headers[@"X-Content-Type-Options"]=@"nosniff";
    const int reserved=head?0:(int)length;
    if (!local_body_reserve(s->local_budget,reserved)) return ZWK_FULL;
    NSHTTPURLResponse *response=[[NSHTTPURLResponse alloc] initWithURL:task.request.URL statusCode:(NSInteger)status HTTPVersion:@"HTTP/1.1" headerFields:headers];
    if (!response) { local_body_release(s->local_budget,reserved); return ZWK_OOM; }
    [task didReceiveResponse:response];
    if (reserved) [task didReceiveData:[NSData dataWithBytes:body length:length]];
    [task didFinish];
    local_body_release(s->local_budget,reserved);
    return ZWK_OK;
}

/* A request in the app's handler: valid only during the callback, under
 * the generation that asked. */
typedef struct ResourceCall { void *page; id<WKURLSchemeTask> __unsafe_unretained task; uint64_t generation; BOOL head, responded; } ResourceCall;
int zwk_resources_enable(ZwkState *state,ZwkResourceNotify callback,int dynamic,uint32_t limit) {
    ZwkPage *s=page_of(state);
    if (!live(s)) return ZWK_CLOSED;
    if (!s->local || s->resource_fn || !callback || !limit || limit>8) return ZWK_INVALID;
    s->resource_fn=callback; s->resource_limit=limit; s->dynamic_document=dynamic!=0;
    s->deferred=[NSMutableArray arrayWithCapacity:limit];
    return ZWK_OK;
}
static ZwkDeferred *resource_take(ZwkPage *s,uint64_t token) {
    /* A fast enumeration variable holds no reference: keep one before the
     * array lets go of the slot. */
    ZwkDeferred *found=nil;
    for (ZwkDeferred *slot in s->deferred) if (slot->token==token) { found=slot; break; }
    if (found) {
        [s->deferred removeObjectIdenticalTo:found];
        atomic_fetch_sub(&live_resource_requests,1);
    }
    return found;
}
void zwk_resource_cancel(ZwkState *state,uint64_t token) {
    ZwkPage *s=page_of(state);
    @autoreleasepool {
        ZwkDeferred *slot=resource_take(s,token);
        if (slot) [slot->task didFailWithError:local_denied()];
    }
}
static void resources_cancel_all(ZwkPage *s) {
    while (s->deferred.count) {
        ZwkDeferred *slot=s->deferred.lastObject;
        [s->deferred removeLastObject];
        atomic_fetch_sub(&live_resource_requests,1);
        [slot->task didFailWithError:local_denied()];
    }
}
void zwk_resource_cancel_all(ZwkState *state) { @autoreleasepool { resources_cancel_all(page_of(state)); } }
int zwk_resource_respond(void *opaque,uint32_t status,const uint8_t *mime,size_t mime_length,const uint8_t *body,size_t length,const ZwkResponseHeader *headers,uint32_t count) {
    ResourceCall *call=opaque; ZwkPage *s=(__bridge ZwkPage *)call->page;
    if (!live(s) || call->generation!=s->generation) return ZWK_CLOSED;
    if (call->responded) return ZWK_INVALID;
    @autoreleasepool {
        const int result=local_respond(s,call->task,call->head,status,mime,mime_length,body,length,headers,count);
        if (result==ZWK_OK) call->responded=YES;
        return result;
    }
}
int zwk_resource_defer(void *opaque,uint64_t token) {
    ResourceCall *call=opaque; ZwkPage *s=(__bridge ZwkPage *)call->page;
    if (!live(s) || call->generation!=s->generation) return ZWK_CLOSED;
    if (!s->resource_fn || call->responded || !token) return ZWK_INVALID;
    for (ZwkDeferred *slot in s->deferred) if (slot->token==token) return ZWK_INVALID;
    if (s->deferred.count>=s->resource_limit) return ZWK_FULL;
    ZwkDeferred *slot=[[ZwkDeferred alloc] init];
    slot->task=call->task; slot->token=token; slot->generation=call->generation; slot->head=call->head;
    [s->deferred addObject:slot];
    atomic_fetch_add(&live_resource_requests,1);
    call->responded=YES;
    return ZWK_OK;
}
int zwk_resource_respond_deferred(ZwkState *state,uint64_t token,uint32_t status,const uint8_t *mime,size_t mime_length,const uint8_t *body,size_t length,const ZwkResponseHeader *headers,uint32_t count) {
    ZwkPage *s=page_of(state);
    @autoreleasepool {
        ZwkDeferred *slot=resource_take(s,token);
        if (!slot) return ZWK_CLOSED;
        int result=ZWK_CLOSED;
        if (live(s) && slot->generation==s->generation) result=local_respond(s,slot->task,slot->head,status,mime,mime_length,body,length,headers,count);
        if (result!=ZWK_OK) [slot->task didFailWithError:local_denied()];
        return result;
    }
}
/* File streams are of the Linux backend; macOS sites answer with bytes. */
int zwk_resource_respond_file(void *request,ZwkFile *file,uint64_t length,ZwkFileBudget *budget,uint32_t status,const uint8_t *mime,size_t mime_length,const ZwkResponseHeader *headers,uint32_t count,int ticket,ZwkFileControl **out) {
    (void)request; (void)file; (void)length; (void)budget; (void)status; (void)mime; (void)mime_length; (void)headers; (void)count; (void)ticket; *out=NULL; return ZWK_INVALID;
}
int zwk_resource_respond_file_deferred(ZwkState *s,uint64_t token,ZwkFile *file,uint64_t length,ZwkFileBudget *budget,uint32_t status,const uint8_t *mime,size_t mime_length,const ZwkResponseHeader *headers,uint32_t count,int ticket,ZwkFileControl **out) {
    (void)s; (void)token; (void)file; (void)length; (void)budget; (void)status; (void)mime; (void)mime_length; (void)headers; (void)count; (void)ticket; *out=NULL; return ZWK_INVALID;
}
/* Hands one request to the app's handler. What it neither answers nor
 * defers fails as a refused load. */
static BOOL resource_notify(ZwkPage *s,id<WKURLSchemeTask> task,NSString *method) {
    if (!s->resource_fn) return NO;
    NSDictionary<NSString *,NSString *> *fields=task.request.allHTTPHeaderFields?:@{};
    ZwkResourceHeader headers[64]; uint32_t count=0;
    for (NSString *key in fields) {
        if (count==64) { [task didFailWithError:local_denied()]; return YES; }
        headers[count++]=(ZwkResourceHeader){key.UTF8String,fields[key].UTF8String};
    }
    ResourceCall call={(__bridge void *)s,task,s->generation,[method isEqualToString:@"HEAD"],NO};
    s->resource_fn(s->owner,task.request.URL.absoluteString.UTF8String,method.UTF8String,headers,count,&call);
    if (!call.responded) [task didFailWithError:local_denied()];
    return YES;
}
/* The site's reply to one request: the page's HTML at the start path, a
 * resource, the app's handler, or 404. Whatever the policy refuses fails as
 * a network error. */
static BOOL local_serve(ZwkPage *s,WKWebView *webView,id<WKURLSchemeTask> task) {
    if (!live(s) || s->failed || webView!=s->view) return NO;
    NSURLRequest *request=task.request;
    char path[4097];
    if (!local_uri(s,request.URL.absoluteString.UTF8String,path)) return NO;
    NSString *method=request.HTTPMethod?:@"GET";
    const int verb=method_index(method);
    /* WKWebView sends no Origin with a page's own requests to its scheme, so
     * writes, which the policy grants only with an allowed Origin, are
     * refused here. */
    if (!local_request_allowed(s,verb,request.allHTTPHeaderFields?:@{})) return NO;
    const BOOL read=verb<2, head=verb==1;
    const uint8_t *body=(const uint8_t *)"Not found"; size_t length=9; const char *mime="text/plain; charset=utf-8"; uint32_t status=404;
    if (read && !strcmp(path,s->local_start)) {
        if (s->dynamic_document) return resource_notify(s,task,method);
        body=s->html_bytes.bytes; length=s->html_bytes.length; mime="text/html; charset=utf-8"; status=200;
    } else if (read) {
        uint32_t low=0, high=s->local_count;
        while (low<high) {
            const uint32_t middle=low+(high-low)/2;
            const ZwkLocalResource *resource=&s->local_resources[middle];
            const int order=strcmp(path,resource->path);
            if (order<0) high=middle;
            else if (order>0) low=middle+1;
            else { body=resource->bytes; length=resource->length; mime=resource->mime; status=200; break; }
        }
    }
    if (status==404 && resource_notify(s,task,method)) return YES;
    return local_respond(s,task,head,status,(const uint8_t *)mime,strlen(mime),body,length,NULL,0)==ZWK_OK;
}
@implementation ZwkLocalHandler
- (void)webView:(WKWebView *)webView startURLSchemeTask:(id<WKURLSchemeTask>)task {
    @autoreleasepool {
        ZwkPage *s=site_page;
        if (!s || !local_serve(s,webView,task)) [task didFailWithError:local_denied()];
    }
}
/* A stopped request takes no answer: its deferral is dropped. */
- (void)webView:(WKWebView *)webView stopURLSchemeTask:(id<WKURLSchemeTask>)task {
    (void)webView;
    ZwkPage *s=site_page;
    if (!s) return;
    ZwkDeferred *found=nil;
    for (ZwkDeferred *slot in s->deferred) if (slot->task==task) { found=slot; break; }
    if (!found) return;
    [s->deferred removeObjectIdenticalTo:found];
    atomic_fetch_sub(&live_resource_requests,1);
}
@end

static void policy_free(ZwkPage *s) {
    for (uint32_t i=0;i<s->policy_header_count;++i) { free(s->policy_names[i]); free(s->policy_values[i]); }
    for (uint32_t i=0;i<s->policy_origin_count;++i) free(s->policy_origins[i]);
    free(s->policy_names); free(s->policy_values); free(s->policy_origins);
    s->policy_names=s->policy_values=s->policy_origins=NULL; s->policy_header_count=s->policy_origin_count=0; s->policy_extended=NO;
}
static void local_free(ZwkPage *s) {
    policy_free(s);
    free(s->local_storage); s->local_storage=NULL; s->local_resources=NULL; s->local_count=0;
    if (s->local_budget) zwk_local_budget_release(s->local_budget);
    s->local_budget=NULL;
}
static char *local_copy(char **cursor,const char *text,size_t length) {
    char *result=*cursor; memcpy(result,text,length); result[length]=0; *cursor+=length+1; return result;
}
/* Copies the site: its names, start path and sorted resource rows. The
 * bodies stay the owner's, as on Linux. */
static int local_prepare(ZwkPage *s,const ZwkLocalOptions *options) {
    if (!options->budget || options->count>4096 || (options->count && !options->resources) || !options->max_response_bytes ||
        options->max_response_bytes>16*1024*1024) return ZWK_INVALID;
    if (options->policy) {
        /* The View checked and made canonical every grant. */
        const ZwkLocalPolicy *policy=options->policy;
        if (!policy->methods || (policy->methods&~127u) || policy->header_count>16 || policy->origin_count>8 ||
            (policy->header_count && !policy->headers) || (policy->origin_count && !policy->origins)) return ZWK_INVALID;
        s->policy_extended=YES; s->policy_methods=policy->methods;
        s->policy_names=calloc(policy->header_count+1,sizeof(char *)); s->policy_values=calloc(policy->header_count+1,sizeof(char *));
        s->policy_origins=calloc(policy->origin_count+1,sizeof(char *));
        if (!s->policy_names || !s->policy_values || !s->policy_origins) return ZWK_OOM;
        for (uint32_t i=0;i<policy->header_count;++i) {
            const ZwkLocalHeaderGrant *row=&policy->headers[i];
            if (!header_name(row->name) || (row->value && !header_value(row->value))) return ZWK_INVALID;
            ++s->policy_header_count;
            if (!(s->policy_names[i]=strdup(row->name)) || (row->value && !(s->policy_values[i]=strdup(row->value)))) return ZWK_OOM;
        }
        for (uint32_t i=0;i<policy->origin_count;++i) {
            if (!policy->origins[i] || strnlen(policy->origins[i],1025)>1024) return ZWK_INVALID;
            ++s->policy_origin_count;
            if (!(s->policy_origins[i]=strdup(policy->origins[i]))) return ZWK_OOM;
        }
    }
    const size_t scheme_length=options->scheme?strnlen(options->scheme,33):0, host_length=options->host?strnlen(options->host,254):0;
    const size_t start_length=options->start_path?strnlen(options->start_path,4097):0;
    if (!scheme_length || scheme_length>32 || !host_length || host_length>253 || start_length>4096 || !local_route(options->start_path)) return ZWK_INVALID;
    if (!isalpha((unsigned char)options->scheme[0])) return ZWK_INVALID;
    for (size_t i=0;i<scheme_length;++i) {
        const unsigned char c=(unsigned char)options->scheme[i];
        if ((!isalnum(c) && !strchr("+-.",c)) || isupper(c)) return ZWK_INVALID;
    }
    for (size_t i=0;i<host_length;++i) {
        const unsigned char c=(unsigned char)options->host[i];
        if ((!isalnum(c) && c!='-' && c!='.') || isupper(c)) return ZWK_INVALID;
    }
    NSString *scheme=[NSString stringWithUTF8String:options->scheme];
    if (!scheme || [WKWebView handlesURLScheme:scheme]) return ZWK_INVALID;
    size_t length=(size_t)options->count*sizeof(ZwkLocalResource)+scheme_length+host_length+start_length+3;
    for (uint32_t i=0;i<options->count;++i) {
        const ZwkLocalResource *r=&options->resources[i];
        if (!r->path || !r->mime || !r->path_length || r->path_length>4096 || !r->mime_length || r->mime_length>127 || r->length>options->max_response_bytes || (r->length && !r->bytes)) return ZWK_INVALID;
        length+=r->path_length+r->mime_length+2;
    }
    s->local_storage=malloc(length);
    if (!s->local_storage) return ZWK_OOM;
    s->local_resources=(ZwkLocalResource *)(void *)s->local_storage;
    char *cursor=(char *)(s->local_resources+options->count);
    s->local_scheme=local_copy(&cursor,options->scheme,scheme_length);
    s->local_host=local_copy(&cursor,options->host,host_length);
    s->local_start=local_copy(&cursor,options->start_path,start_length);
    s->local_count=options->count; s->local_limit=options->max_response_bytes;
    for (uint32_t i=0;i<options->count;++i) {
        ZwkLocalResource *row=&s->local_resources[i];
        *row=options->resources[i];
        row->path=local_copy(&cursor,options->resources[i].path,row->path_length);
        row->mime=local_copy(&cursor,options->resources[i].mime,row->mime_length);
        if (!local_route(row->path) || strlen(row->path)!=row->path_length || strlen(row->mime)!=row->mime_length || !strcmp(row->path,s->local_start) ||
            (i && strcmp(s->local_resources[i-1].path,row->path)>=0)) return ZWK_INVALID;
        for (size_t j=0;j<row->mime_length;++j) if ((unsigned char)row->mime[j]<32 || (unsigned char)row->mime[j]>126) return ZWK_INVALID;
    }
    s->local_url=[NSString stringWithFormat:@"%s://%s%s",s->local_scheme,s->local_host,s->local_start];
    s->local_csp=[NSString stringWithFormat:@"default-src 'none'; script-src %1$s://%2$s 'unsafe-inline' 'unsafe-eval'; style-src %1$s://%2$s 'unsafe-inline'; img-src %1$s://%2$s data: blob:; connect-src %1$s://%2$s; frame-src 'none'; worker-src 'none'; object-src 'none'; base-uri 'none'; form-action 'none'",s->local_scheme,s->local_host];
    s->local_ipc=options->ipc!=0;
    s->local_budget=options->budget;
    atomic_fetch_add(&options->budget->refs,1);
    s->local=YES;
    return ZWK_OK;
}

static void remote_free(ZwkPage *s) {
    for (uint32_t i=0;i<s->remote_count;++i) {
        ZwkRemoteGrant *grant=&s->remote_grants[i];
        for (uint32_t j=0;j<grant->header_count;++j) { free(grant->names[j]); free(grant->values[j]); }
        free(grant->names); free(grant->values);
    }
    free(s->remote_grants); s->remote_grants=NULL; s->remote_count=0;
}
static NSString *remote_origin_text(const ZwkRemoteGrant *grant,NSString *scheme) {
    NSString *host=strchr(grant->host,':')?[NSString stringWithFormat:@"[%s]",grant->host]:[NSString stringWithUTF8String:grant->host];
    if (grant->port==(grant->https?443:80)) return [NSString stringWithFormat:@"%@://%@",scheme,host];
    return [NSString stringWithFormat:@"%@://%@:%u",scheme,host,(unsigned)grant->port];
}
/* A content rule list pattern for every URL of one origin. */
static NSString *remote_pattern(NSString *origin) {
    NSMutableString *pattern=[NSMutableString stringWithString:@"^"];
    for (NSUInteger i=0;i<origin.length;++i) {
        const unichar c=[origin characterAtIndex:i];
        if (strchr(".[]?+*()\\$^{}|",(int)c) && c) [pattern appendString:@"\\"];
        [pattern appendFormat:@"%C",c];
    }
    [pattern appendString:@"/"];
    return pattern;
}
/* Copies the grants and writes the page's rule list: every load is blocked
 * but those of origins granted requests. Their documents, images, scripts,
 * styles, fonts and media load by GET, so need its grant; a script's own
 * requests and sockets reach them by origin alone, as WKWebView never shows
 * the app their method or headers. No grant may carry a Bearer credential. */
static int remote_prepare(ZwkPage *s,const ZwkRemoteOptions *input) {
    if (!input->url || !input->origins || !input->count || input->count>32) return ZWK_INVALID;
    s->remote_loopback=input->loopback!=0; s->remote_script_navigation=input->script_navigation!=0; s->remote_redirects=input->redirects!=0;
    s->remote_url=[NSString stringWithUTF8String:input->url];
    ZwkRemoteGrant initial;
    if (!s->remote_url || !remote_parse(s->remote_url,NO,s->remote_loopback,&initial)) return ZWK_INVALID;
    if (!(s->remote_grants=calloc(input->count,sizeof(ZwkRemoteGrant)))) return ZWK_OOM;
    NSDictionary *block=@{@"type":@"block"}, *ignore=@{@"type":@"ignore-previous-rules"};
    NSMutableArray *rules=[NSMutableArray arrayWithObject:@{@"trigger":@{@"url-filter":@".*"},@"action":block}];
    for (NSString *scheme in @[@"^blob:",@"^about:"]) [rules addObject:@{@"trigger":@{@"url-filter":scheme},@"action":ignore}];
    NSMutableArray *ipc=[NSMutableArray array];
    BOOL allowed=NO;
    for (uint32_t i=0;i<input->count;++i) {
        const ZwkRemoteOrigin *source=&input->origins[i];
        ZwkRemoteGrant *grant=&s->remote_grants[i];
        NSString *origin=source->origin?[NSString stringWithUTF8String:source->origin]:nil;
        if ((source->flags&~7u) || (source->methods&~127u) || ((source->flags&REMOTE_REQUESTS) && !source->methods) || source->bearer ||
            source->header_count>16 || (source->header_count && !source->headers) || !remote_parse(origin,YES,s->remote_loopback,grant)) return ZWK_INVALID;
        s->remote_count=i+1;
        grant->flags=source->flags; grant->methods=source->methods;
        for (uint32_t j=0;j<i;++j) {
            const ZwkRemoteGrant *other=&s->remote_grants[j];
            if (other->https==grant->https && other->port==grant->port && !strcmp(other->host,grant->host)) return ZWK_INVALID;
        }
        if (source->header_count) {
            grant->names=calloc(source->header_count,sizeof(char *)); grant->values=calloc(source->header_count,sizeof(char *));
            if (!grant->names || !grant->values) return ZWK_OOM;
            size_t bytes=0;
            for (uint32_t j=0;j<source->header_count;++j) {
                const ZwkRemoteHeader *header=&source->headers[j];
                if (!header->name || !header_name(header->name) || managed_header(header->name) || (header->value && !header_value(header->value)) ||
                    (bytes+=strlen(header->name)+(header->value?strlen(header->value):0))>8192) return ZWK_INVALID;
                for (uint32_t k=0;k<j;++k) if (!strcasecmp(header->name,grant->names[k])) return ZWK_INVALID;
                grant->names[j]=strdup(header->name); grant->values[j]=header->value?strdup(header->value):NULL;
                grant->header_count=j+1;
                if (!grant->names[j] || (header->value && !grant->values[j])) return ZWK_OOM;
            }
        }
        if ((grant->flags&3u)==3u && (grant->methods&1u) && grant->https==initial.https && grant->port==initial.port && !strcmp(grant->host,initial.host)) allowed=YES;
        if (grant->flags&REMOTE_IPC) [ipc addObject:remote_origin_text(grant,grant->https?@"https":@"http")];
        if (grant->flags&REMOTE_REQUESTS) {
            [rules addObject:@{@"trigger":@{@"url-filter":remote_pattern(remote_origin_text(grant,grant->https?@"wss":@"ws"))},@"action":ignore}];
            NSString *pattern=remote_pattern(remote_origin_text(grant,grant->https?@"https":@"http"));
            [rules addObject:(grant->methods&1u)?@{@"trigger":@{@"url-filter":pattern},@"action":ignore}:
                @{@"trigger":@{@"url-filter":pattern,@"resource-type":@[@"raw"]},@"action":ignore}];
        }
    }
    if (!allowed) return ZWK_INVALID;
    NSData *rule_data=[NSJSONSerialization dataWithJSONObject:rules options:0 error:NULL];
    NSData *ipc_data=[NSJSONSerialization dataWithJSONObject:ipc options:0 error:NULL];
    if (!rule_data || !ipc_data) return ZWK_OOM;
    s->remote_source=[[NSString alloc] initWithData:rule_data encoding:NSUTF8StringEncoding];
    s->remote_ipc=[[NSString alloc] initWithData:ipc_data encoding:NSUTF8StringEncoding];
    if (!s->remote_source || !s->remote_ipc) return ZWK_OOM;
    static uint64_t serial;
    s->remote_identifier=[NSString stringWithFormat:@"ziggurat-remote-%d-%llu",(int)getpid(),(unsigned long long)++serial];
    s->remote=YES;
    return ZWK_OK;
}
/* Compiles the page's rule list before its first load. Each page has a list
 * of its own, removed from the store when the page closes. */
static void remote_compile(ZwkPage *s) {
    s->waiting_remote=YES;
    __weak ZwkPage *weak=s;
    NSString *identifier=s->remote_identifier;
    WKContentRuleListStore *store=rule_store();
    [store compileContentRuleListForIdentifier:identifier encodedContentRuleList:s->remote_source completionHandler:^(WKContentRuleList *list,NSError *error) {
        ZwkPage *page=weak;
        if (!page || !page->waiting_remote) {
            if (list) [store removeContentRuleListForIdentifier:identifier completionHandler:^(NSError *removed) { (void)removed; }];
            return;
        }
        page->waiting_remote=NO; page->remote_source=nil;
        if (!list) {
            if (!live(page)) return;
            failure_set(page,error?:[NSError errorWithDomain:@"ziggurat-webkit-navigation" code:ZWK_POLICY_PREPARATION userInfo:nil]);
            const ZwkFailure failure=page->failure;
            page->failed=YES; notify(page,2,nil,failure.code,&failure);
            return;
        }
        page->remote_rules=list;
        initialize(page);
    }];
}
static BOOL engine_has(WKWebView *view,SEL selector) { return [view respondsToSelector:selector]; }
static void set_muted(ZwkPage *s,BOOL value) {
    s->muted=value;
    if (!engine_has(s->view,@selector(_setPageMuted:))) return;
    NSUInteger state=engine_has(s->view,@selector(_mediaMutedState))?[s->view _mediaMutedState]:0;
    [s->view _setPageMuted:value?(state|MEDIA_AUDIO_MUTED):(state&~(NSUInteger)MEDIA_AUDIO_MUTED)];
}

/* Persistent profiles. A profile's WKWebsiteDataStore keeps its data under
 * the prepared directories through the engine's data store configuration;
 * every View of the profile shares the one store. The store carries a keeper
 * whose release gives back the profile reference that holds the storage
 * lock, so the lock outlives the last engine reference, as a GObject's
 * finalizer keeps it on Linux. The engine stores cookies inside the data
 * directory in its own format; the prepared cookie file stays unused. */
#define ZWK_PROFILE_PATH 4096u
#define ZWK_PROFILE_CONTEXTS 64u
#define ZWK_PROFILE_LEASES 256u
#define ZWK_PROFILE_BYTES (1024u*1024u)
struct ZwkProfile {
    void *store; /* A retained WKWebsiteDataStore. */
    char *data,*cache,*cookies;
    size_t owned_bytes,peak_bytes,limit,allocation_bytes;
    uint32_t contexts,capacity,leases,lease_capacity;
    atomic_int refs;
    int lock_fd;
    int accepting,owner_closed;
};
struct ZwkProfileContext {
    ZwkProfile *profile;
    void *store;
    int owner_closed,admitted;
};
static atomic_uint live_profiles,live_profile_contexts;
static atomic_size_t live_profile_bytes;
static int profile_owner(ZwkProfile *p) {
    if (!p) return ZWK_PROFILE_INVALID;
    return [NSThread isMainThread]?ZWK_PROFILE_OK:ZWK_PROFILE_WRONG_THREAD;
}
static int profile_path_size(const char *path,size_t *size) {
    if (!path || path[0]!='/') return ZWK_PROFILE_INVALID;
    const size_t n=strnlen(path,ZWK_PROFILE_PATH);
    if (!n || n==ZWK_PROFILE_PATH) return ZWK_PROFILE_INVALID;
    NSString *text=[[NSString alloc] initWithBytes:path length:n encoding:NSUTF8StringEncoding];
    if (!text) return ZWK_PROFILE_INVALID;
    *size=n+1;
    return ZWK_PROFILE_OK;
}
int zwk_profile_measure(const char *data,const char *cache,const char *cookies,size_t *bytes) {
    if (!bytes) return ZWK_PROFILE_INVALID;
    *bytes=0;
    size_t a,b,c;
    if (profile_path_size(data,&a) || profile_path_size(cache,&b) || profile_path_size(cookies,&c)) return ZWK_PROFILE_INVALID;
    *bytes=sizeof(ZwkProfile)+a+b+c;
    return ZWK_PROFILE_OK;
}
/* The loopback certificate exception is GLib's; the engine here takes none. */
int zwk_profile_measure_tls(const char *data,const char *cache,const char *cookies,const ZwkProfileTls *tls,size_t *bytes) {
    const int result=zwk_profile_measure(data,cache,cookies,bytes);
    if (result) return result;
    if (bytes) *bytes=0;
    return tls?ZWK_PROFILE_TLS_UNAVAILABLE:ZWK_PROFILE_INVALID;
}
int zwk_profile_create_tls(int borrowed_lock,const char *data,const char *cache,const char *cookies,const ZwkProfileOptions *options,const ZwkProfileTls *tls,
                          ZwkProfile **out,int *system_errno,ZwkProfileGlibFailure *failure) {
    (void)borrowed_lock; (void)data; (void)cache; (void)cookies; (void)options;
    if (system_errno) *system_errno=0;
    if (failure) *failure=(ZwkProfileGlibFailure){0,0};
    if (out) *out=NULL;
    return tls?ZWK_PROFILE_TLS_UNAVAILABLE:ZWK_PROFILE_INVALID;
}
static void profile_unref(ZwkProfile *p) {
    if (atomic_fetch_sub(&p->refs,1)!=1) return;
    /* Final native-only release: no engine object, App or Zig state. */
    const int fd=p->lock_fd;
    const size_t bytes=p->allocation_bytes;
    p->lock_fd=-1;
    if (fd>=0) close(fd);
    free(p);
    atomic_fetch_sub(&live_profile_bytes,bytes);
    atomic_fetch_sub(&live_profiles,1);
}
@interface ZwkProfileKeeper : NSObject { @public ZwkProfile *profile; }
@end
@implementation ZwkProfileKeeper
- (void)dealloc { if (profile) profile_unref(profile); }
@end
static char profile_keeper_key;
static void profile_set(id target,const char *name,NSURL *url) {
    SEL selector=sel_registerName(name);
    if ([target respondsToSelector:selector]) ((void (*)(id,SEL,id))objc_msgSend)(target,selector,url);
}
static WKWebsiteDataStore *profile_store(ZwkProfile *p) {
    Class type=NSClassFromString(@"_WKWebsiteDataStoreConfiguration");
    SEL make=sel_registerName("_initWithConfiguration:");
    if (!type || ![WKWebsiteDataStore instancesRespondToSelector:make]) return nil;
    id configuration=[[type alloc] init];
    /* The directories the engine has no setter for stay unset; the four it
     * keeps a page's own data in are required. */
    static const char *const required[]={"_setWebStorageDirectory:","_setIndexedDBDatabaseDirectory:","_setCookieStorageFile:","setNetworkCacheDirectory:"};
    for (size_t i=0;i<sizeof(required)/sizeof(*required);i++) if (![configuration respondsToSelector:sel_registerName(required[i])]) return nil;
    NSString *data=[NSString stringWithUTF8String:p->data];
    NSString *cache=[NSString stringWithUTF8String:p->cache];
    if (!data || !cache) return nil;
    NSURL *(^under)(NSString *,NSString *)=^NSURL *(NSString *base,NSString *child) {
        return [NSURL fileURLWithPath:[base stringByAppendingPathComponent:child] isDirectory:YES];
    };
    static const struct { const char *setter,*child; } in_data[]={
        {"_setWebStorageDirectory:","LocalStorage"},{"_setIndexedDBDatabaseDirectory:","IndexedDB"},
        {"_setWebSQLDatabaseDirectory:","WebSQL"},{"_setResourceLoadStatisticsDirectory:","ResourceLoadStatistics"},
        {"_setCacheStorageDirectory:","CacheStorage"},{"_setServiceWorkerRegistrationDirectory:","ServiceWorkers"},
        {"setDeviceIdHashSaltsStorageDirectory:","DeviceIdHashSalts"},{"setMediaKeysStorageDirectory:","MediaKeys"},
        {"setHSTSStorageDirectory:","HSTS"},{"setHstsStorageDirectory:","HSTS"},{"setAlternativeServicesDirectory:","AlternativeServices"},
        {"setGeneralStorageDirectory:","Storage"},{"setApplicationCacheDirectory:","ApplicationCache"},
    };
    for (size_t i=0;i<sizeof(in_data)/sizeof(*in_data);i++)
        profile_set(configuration,in_data[i].setter,under(data,[NSString stringWithUTF8String:in_data[i].child]));
    profile_set(configuration,"setNetworkCacheDirectory:",under(cache,@"NetworkCache"));
    profile_set(configuration,"_setCookieStorageFile:",[NSURL fileURLWithPath:[data stringByAppendingPathComponent:@"Cookies.binarycookies"] isDirectory:NO]);
    WKWebsiteDataStore *store=((id (*)(id,SEL,id))objc_msgSend)([WKWebsiteDataStore alloc],make,configuration);
    return store;
}
int zwk_profile_create(int borrowed_lock,const char *data,const char *cache,const char *cookies,const ZwkProfileOptions *options,ZwkProfile **out,int *system_errno) {
    if (system_errno) *system_errno=0;
    if (!out) return ZWK_PROFILE_INVALID;
    *out=NULL;
    if (![NSThread isMainThread]) return ZWK_PROFILE_WRONG_THREAD;
    size_t bytes;
    if (!options || !options->contexts || options->contexts>ZWK_PROFILE_CONTEXTS ||
        !options->leases || options->leases>ZWK_PROFILE_LEASES ||
        !options->bytes || options->bytes>ZWK_PROFILE_BYTES ||
        zwk_profile_measure(data,cache,cookies,&bytes)) return ZWK_PROFILE_INVALID;
    if (bytes>options->bytes) return ZWK_PROFILE_CAPACITY;
    const int lock_fd=fcntl(borrowed_lock,F_DUPFD_CLOEXEC,0);
    if (lock_fd<0) {
        if (system_errno) *system_errno=errno;
        return ZWK_PROFILE_SYSTEM;
    }
    ZwkProfile *p=malloc(bytes);
    if (!p) { close(lock_fd); return ZWK_PROFILE_OOM; }
    memset(p,0,sizeof(*p));
    atomic_init(&p->refs,1); p->lock_fd=lock_fd;
    p->allocation_bytes=p->owned_bytes=p->peak_bytes=bytes;
    p->capacity=options->contexts; p->lease_capacity=options->leases;
    p->limit=options->bytes; p->accepting=1;
    char *at=(char *)(p+1);
    size_t n=strlen(data)+1; p->data=at; memcpy(at,data,n); at+=n;
    n=strlen(cache)+1; p->cache=at; memcpy(at,cache,n); at+=n;
    n=strlen(cookies)+1; p->cookies=at; memcpy(at,cookies,n);
    atomic_fetch_add(&live_profiles,1);
    atomic_fetch_add(&live_profile_bytes,bytes);
    @autoreleasepool {
        WKWebsiteDataStore *store=profile_store(p);
        ZwkProfileKeeper *keeper=store?[[ZwkProfileKeeper alloc] init]:nil;
        if (!keeper) { p->owner_closed=1; profile_unref(p); return ZWK_PROFILE_NATIVE_FAILED; }
        atomic_fetch_add(&p->refs,1);
        keeper->profile=p;
        objc_setAssociatedObject(store,&profile_keeper_key,keeper,OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        p->store=(void *)CFBridgingRetain(store);
    }
    *out=p;
    return ZWK_PROFILE_OK;
}
int zwk_profile_seal(ZwkProfile *p) {
    const int result=profile_owner(p); if (result) return result;
    p->accepting=0;
    return ZWK_PROFILE_OK;
}
int zwk_profile_stats(ZwkProfile *p,ZwkProfileStats *stats) {
    const int result=profile_owner(p); if (result) return result;
    if (!stats) return ZWK_PROFILE_INVALID;
    *stats=(ZwkProfileStats){p->owned_bytes,p->peak_bytes,p->contexts,p->capacity,p->accepting,p->leases,p->lease_capacity};
    return ZWK_PROFILE_OK;
}
int zwk_profile_close(ZwkProfile *p) {
    const int result=profile_owner(p); if (result) return result;
    if (p->owner_closed) return ZWK_PROFILE_CLOSED;
    p->accepting=0; p->owner_closed=1;
    void *retained=p->store; p->store=NULL;
    if (retained) @autoreleasepool {
        /* The engine writes its cookies to disk now; the store, and with it
         * the storage lock, lasts until it has. */
        WKWebsiteDataStore *store=CFBridgingRelease(retained);
        WKHTTPCookieStore *cookies=store.httpCookieStore;
        if ([cookies respondsToSelector:@selector(_flushCookiesToDiskWithCompletionHandler:)])
            [cookies _flushCookiesToDiskWithCompletionHandler:^{ (void)store; }];
    }
    profile_unref(p);
    return ZWK_PROFILE_OK;
}
int zwk_profile_lease_check(ZwkProfile *p) {
    const int result=profile_owner(p); if (result) return result;
    return p->accepting && !p->owner_closed?ZWK_PROFILE_OK:ZWK_PROFILE_CLOSED;
}
int zwk_profile_lease_retain(ZwkProfile *p) {
    const int result=zwk_profile_lease_check(p); if (result) return result;
    if (p->leases==p->lease_capacity) return ZWK_PROFILE_FULL;
    ++p->leases; atomic_fetch_add(&p->refs,1);
    return ZWK_PROFILE_OK;
}
int zwk_profile_lease_release(ZwkProfile *p) {
    const int result=profile_owner(p); if (result) return result;
    if (!p->leases) return ZWK_PROFILE_INVALID;
    --p->leases; profile_unref(p);
    return ZWK_PROFILE_OK;
}
/* A retained WKWebsiteDataStore, given back with CFRelease. */
int zwk_profile_manager_ref(ZwkProfile *p,void **out) {
    if (!out) return ZWK_PROFILE_INVALID;
    *out=NULL;
    const int result=zwk_profile_lease_check(p); if (result) return result;
    *out=(void *)CFRetain(p->store);
    return ZWK_PROFILE_OK;
}
int zwk_profile_context_create(ZwkProfile *p,ZwkProfileContext **out) {
    if (!out) return ZWK_PROFILE_INVALID;
    *out=NULL;
    const int result=profile_owner(p); if (result) return result;
    if (!p->accepting || p->owner_closed) return ZWK_PROFILE_CLOSED;
    if (p->contexts==p->capacity) return ZWK_PROFILE_FULL;
    if (sizeof(ZwkProfileContext)>p->limit-p->owned_bytes) return ZWK_PROFILE_CAPACITY;
    ZwkProfileContext *c=malloc(sizeof(*c));
    if (!c) return ZWK_PROFILE_OOM;
    *c=(ZwkProfileContext){p,(void *)CFRetain(p->store),0,0};
    atomic_fetch_add(&p->refs,1); ++p->contexts; p->owned_bytes+=sizeof(*c);
    if (p->peak_bytes<p->owned_bytes) p->peak_bytes=p->owned_bytes;
    atomic_fetch_add(&live_profile_contexts,1);
    atomic_fetch_add(&live_profile_bytes,sizeof(*c));
    *out=c;
    return ZWK_PROFILE_OK;
}
/* The profile's WKWebsiteDataStore, borrowed. */
int zwk_profile_context_get(ZwkProfileContext *c,void **out) {
    if (!out || !c) return ZWK_PROFILE_INVALID;
    *out=NULL;
    const int result=profile_owner(c->profile); if (result) return result;
    if (c->owner_closed || (!c->profile->accepting && !c->admitted)) return ZWK_PROFILE_CLOSED;
    *out=c->store;
    return ZWK_PROFILE_OK;
}
int zwk_profile_context_admit(ZwkProfileContext *c) {
    if (!c) return ZWK_PROFILE_INVALID;
    const int result=profile_owner(c->profile); if (result) return result;
    if (c->owner_closed || !c->profile->accepting) return ZWK_PROFILE_CLOSED;
    if (c->admitted) return ZWK_PROFILE_INVALID;
    c->admitted=1;
    return ZWK_PROFILE_OK;
}
int zwk_profile_context_close(ZwkProfileContext *c) {
    if (!c) return ZWK_PROFILE_INVALID;
    const int result=profile_owner(c->profile); if (result) return result;
    if (c->owner_closed) return ZWK_PROFILE_CLOSED;
    ZwkProfile *p=c->profile;
    void *store=c->store;
    c->owner_closed=1; c->store=NULL;
    --p->contexts; p->owned_bytes-=sizeof(*c);
    free(c);
    atomic_fetch_sub(&live_profile_bytes,sizeof(ZwkProfileContext));
    atomic_fetch_sub(&live_profile_contexts,1);
    if (store) CFRelease(store);
    profile_unref(p);
    return ZWK_PROFILE_OK;
}
void zwk_profile_counts(uint32_t *profiles,uint32_t *contexts,size_t *bytes) {
    if (profiles) *profiles=atomic_load(&live_profiles);
    if (contexts) *contexts=atomic_load(&live_profile_contexts);
    if (bytes) *bytes=atomic_load(&live_profile_bytes);
}

int zwk_create(void *window,const ZwkOptions *options,ZwkNotify callback,ZwkPageNotify page_callback,ZwkScriptNotify script_callback,ZwkDeadline deadline,void *owner,ZwkState **out) {
    *out=NULL;
    if (!options || !options->html || !window || options->max_pending==0 || options->max_pending>16 || options->max_result_bytes==0 ||
        options->max_result_bytes>1024*1024 || strlen(options->html)>16*1024*1024) return ZWK_INVALID;
    if ((options->remote && (options->local || *options->html)) || options->region || options->initializers) return ZWK_INVALID;
    void *profile_store_ref=NULL;
    if (options->profile_context && zwk_profile_context_get(options->profile_context,&profile_store_ref)) return ZWK_CLOSED;
    @autoreleasepool {
        NSView *host=(__bridge NSView *)zlm_window_content(window);
        if (!host) return ZWK_CLOSED;
        NSString *html=[NSString stringWithUTF8String:options->html];
        if (!html) return ZWK_INVALID;
        ZwkPage *s=[[ZwkPage alloc] init];
        if (!s) return ZWK_OOM;
        s->html=html;
        s->html_bytes=[NSData dataWithBytes:options->html length:strlen(options->html)];
        if (options->local) {
            const int result=local_prepare(s,options->local);
            if (result!=ZWK_OK) { local_free(s); return result; }
        }
        if (options->remote) {
            const int result=remote_prepare(s,options->remote);
            if (result!=ZWK_OK) { remote_free(s); return result; }
        }
        if (options->facts && !(s->facts=[NSString stringWithUTF8String:options->facts])) return ZWK_INVALID;
        s->autoplay=options->autoplay!=0;
        s->owner=owner; s->notify_fn=callback; s->page_fn=page_callback; s->script_fn=script_callback; s->deadline_fn=deadline;
        s->limit=options->max_pending; s->result_limit=options->max_result_bytes; s->policy=options->policy_flags;
        NSMutableArray<WKContentRuleList *> *filters=[NSMutableArray arrayWithCapacity:options->content_filter_count];
        for (uint32_t i=0;i<options->content_filter_count;i++) [filters addObject:(__bridge WKContentRuleList *)options->content_filters[i]];
        s->filters=filters;
        WKWebViewConfiguration *configuration=[[WKWebViewConfiguration alloc] init];
        configuration.websiteDataStore=profile_store_ref?(__bridge WKWebsiteDataStore *)profile_store_ref:[WKWebsiteDataStore nonPersistentDataStore];
        /* By default sound plays only after a gesture, as on Linux. */
        configuration.mediaTypesRequiringUserActionForPlayback=s->autoplay?WKAudiovisualMediaTypeNone:WKAudiovisualMediaTypeAudio;
        configuration.preferences.javaScriptCanOpenWindowsAutomatically=NO;
        if (@available(macOS 12.3,*)) configuration.preferences.elementFullscreenEnabled=NO;
        /* History loads documents anew, with new generations, as on Linux:
         * a cached page would come back with its old scripts. */
        if ([configuration.preferences respondsToSelector:@selector(_setUsesPageCache:)]) [configuration.preferences _setUsesPageCache:NO];
        s->controller=configuration.userContentController;
        s->world=[WKContentWorld worldWithName:@"ziggurat-private"];
        if (s->local) {
            ZwkLocalHandler *handler=[[ZwkLocalHandler alloc] init];
            handler->site_page=s; s->local_handler=handler;
            [configuration setURLSchemeHandler:handler forURLScheme:[NSString stringWithUTF8String:s->local_scheme]];
            /* Secure as the registration asks, through the engine's own
             * registry, which the process pool still carries. */
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
            WKProcessPool *pool=configuration.processPool;
            if (options->local->secure && [pool respondsToSelector:@selector(_registerURLSchemeAsSecure:)])
                [pool _registerURLSchemeAsSecure:[NSString stringWithUTF8String:s->local_scheme]];
#pragma clang diagnostic pop
        }
        [s->controller addScriptMessageHandler:s contentWorld:s->world name:@"ziggurat"];
        ZwkWebView *view=[[ZwkWebView alloc] initWithFrame:host.bounds configuration:configuration];
        if (!view) { [s->controller removeAllScriptMessageHandlers]; local_free(s); remote_free(s); return ZWK_NATIVE_FAILED; }
        s->view=view; atomic_fetch_add(&live_views,1);
        view.autoresizingMask=NSViewWidthSizable|NSViewHeightSizable;
        view.navigationDelegate=s; view.UIDelegate=s;
        /* 1 swipes between pages, 2 pinches; both off unless asked. */
        view.allowsBackForwardNavigationGestures=(options->gestures&1u)!=0;
        view.allowsMagnification=(options->gestures&2u)!=0;
        if (options->user_agent) view.customUserAgent=[NSString stringWithUTF8String:options->user_agent];
        view.pageZoom=options->zoom;
        if (@available(macOS 13.3,*)) view.inspectable=options->developer_tools!=0;
        if (options->audio_muted) set_muted(s,YES);
        [view addObserver:s forKeyPath:@"title" options:0 context:title_context];
        if (engine_has(view,@selector(_isPlayingAudio))) [view addObserver:s forKeyPath:@"_isPlayingAudio" options:0 context:audio_context];
        if (s->local || s->remote) {
            [view addObserver:s forKeyPath:@"canGoBack" options:0 context:history_context];
            [view addObserver:s forKeyPath:@"canGoForward" options:0 context:history_context];
        }
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
        resources_cancel_all(s);
        s->closed=YES; s->owner=NULL;
        [s->timer invalidate]; s->timer=nil;
        navigation_clear(s);
        if (s->waiting_sandbox) { [sandbox_waiting removeObject:s]; s->waiting_sandbox=NO; }
        if (s->remote_identifier) {
            /* A compile still running removes its list when it ends. */
            if (!s->waiting_remote) [rule_store() removeContentRuleListForIdentifier:s->remote_identifier completionHandler:^(NSError *removed) { (void)removed; }];
            s->waiting_remote=NO; s->remote_identifier=nil;
        }
        if (s->find) find_gate_close(s->find);
        capture_cancel_all(s);
        ZwkWebView *view=s->view; s->view=nil;
        if (view) {
            if ([view respondsToSelector:@selector(_setFindDelegate:)]) [view _setFindDelegate:nil];
            if (s->observing) {
                [view removeObserver:s forKeyPath:@"title" context:title_context];
                if (engine_has(view,@selector(_isPlayingAudio))) [view removeObserver:s forKeyPath:@"_isPlayingAudio" context:audio_context];
                if (s->local || s->remote) {
                    [view removeObserver:s forKeyPath:@"canGoBack" context:history_context];
                    [view removeObserver:s forKeyPath:@"canGoForward" context:history_context];
                }
                s->observing=NO;
            }
            view.navigationDelegate=nil; view.UIDelegate=nil;
            [s->controller removeAllScriptMessageHandlers];
            [view stopLoading];
            [view removeFromSuperview];
            atomic_fetch_sub(&live_views,1);
        }
        s->controller=nil;
        if (s->local_handler) ((ZwkLocalHandler *)s->local_handler)->site_page=nil;
        local_free(s);
        remote_free(s);
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
                        else if (!(utf16=utf16_copy(body,s->result_limit))) status=3;
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
    if (!ipc_allowed(s)) return ZWK_IPC_DENIED;
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
    if (!document(s) || !s->current_uri) return ZWK_NOT_READY;
    @autoreleasepool { return navigation_submit(s,NAV_REFRESH,s->local || s->remote?s->current_uri:@"about:blank",nil,NO); }
}
int zwk_navigate_remote(ZwkState *state,const char *text) {
    ZwkPage *s=page_of(state);
    ZwkPage *keep __attribute__((objc_precise_lifetime))=s; (void)keep;
    if (!live(s)) return ZWK_CLOSED;
    if (!s->remote || !s->remote_rules) return ZWK_NOT_READY;
    @autoreleasepool {
        NSString *uri=text?[NSString stringWithUTF8String:text]:nil;
        if (!uri) return ZWK_INVALID;
        if (!remote_navigate(s,uri)) return ZWK_IPC_DENIED;
        const int kind=document(s) && s->current_uri && remote_fragment_change(s,s->current_uri,uri)?NAV_FRAGMENT:NAV_REMOTE;
        return navigation_submit(s,kind,uri,nil,NO);
    }
}
int zwk_navigate_local(ZwkState *state,const char *path) {
    ZwkPage *s=page_of(state);
    ZwkPage *keep __attribute__((objc_precise_lifetime))=s; (void)keep;
    if (!live(s)) return ZWK_CLOSED;
    if (!s->local || !local_route(path)) return ZWK_INVALID;
    @autoreleasepool {
        return navigation_submit(s,NAV_LOCAL,[NSString stringWithFormat:@"%s://%s%s",s->local_scheme,s->local_host,path],nil,NO);
    }
}
int zwk_history(ZwkState *state,int forward) {
    ZwkPage *s=page_of(state);
    ZwkPage *keep __attribute__((objc_precise_lifetime))=s; (void)keep;
    if (!live(s)) return ZWK_CLOSED;
    if (!s->local && !s->remote) return ZWK_NOT_READY;
    if (s->pending_navigation || s->load_started) return ZWK_NAVIGATION_PENDING;
    if (!document(s)) return ZWK_NOT_READY;
    if (s->view.loading) return ZWK_NAVIGATION_PENDING;
    @autoreleasepool {
        WKBackForwardListItem *item=forward?s->view.backForwardList.forwardItem:s->view.backForwardList.backItem;
        if (!item) return ZWK_NO_HISTORY;
        NSString *uri=item.URL.absoluteString;
        if (!trusted_uri(s,uri)) return ZWK_IPC_DENIED;
        return navigation_submit(s,NAV_HISTORY,uri,item,NO);
    }
}
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

/* Text search, as the Linux backend's find controller keeps it: a budget the
 * View owns bounds the pages searching and their commands; each page has one
 * gate, which holds the search in progress and the command the engine has
 * not answered yet. Every record is counted, for the leak checks. */
enum { FIND_LIMIT=8u, FIND_TERM_BYTES=4096u };
enum { FIND_START, FIND_NEXT, FIND_PREVIOUS };
/* _WKFindOptions */
enum { FIND_CASE_INSENSITIVE=1u<<0, FIND_BACKWARDS=1u<<3, FIND_WRAP_AROUND=1u<<4, FIND_INDICATOR=1u<<6, FIND_HIGHLIGHT=1u<<7 };
struct ZwkFindBudget {
    ZwkFindGate *gates;
    unsigned refs, limit, gate_count, command_count;
    size_t bytes;
    BOOL closed;
};
struct ZwkFindGate {
    ZwkFindGate *next;
    ZwkFindBudget *budget;
    void *page; /* Borrowed while the page holds this gate. */
    ZwkFindNotify notify;
    ZwkFindCommand *pending;
    ZwkFindSnapshot snapshot;
    uint64_t token;
    unsigned refs;
    BOOL closed, finish_requested;
    char *term;
    uint32_t flags;
};
struct ZwkFindCommand {
    ZwkFindGate *gate;
    void *page; /* A Core Foundation reference of its own. */
    ZwkFindBudget *budget;
    uint64_t token;
    size_t bytes;
    uint32_t flags;
    unsigned refs, kind;
    BOOL cancelled;
    /* A start owns its UTF-8 term directly after this record. */
};
static atomic_uint find_budgets, find_gates, find_commands;
static atomic_size_t find_bytes, find_peak;
static void find_account(ZwkFindBudget *b,size_t bytes) {
    b->bytes+=bytes;
    const size_t current=atomic_fetch_add(&find_bytes,bytes)+bytes;
    size_t peak=atomic_load(&find_peak);
    while (peak<current && !atomic_compare_exchange_weak(&find_peak,&peak,current)) { }
}
static void find_credit(ZwkFindBudget *b,size_t bytes) { b->bytes-=bytes; atomic_fetch_sub(&find_bytes,bytes); }
static void find_budget_ref(ZwkFindBudget *b) { ++b->refs; }
void zwk_find_budget_release(ZwkFindBudget *b) {
    if (--b->refs) return;
    free(b);
    atomic_fetch_sub(&find_budgets,1); atomic_fetch_sub(&find_bytes,sizeof(*b));
}
ZwkFindBudget *zwk_find_budget_new(uint32_t limit) {
    if (!limit || limit>FIND_LIMIT) return NULL;
    ZwkFindBudget *b=calloc(1,sizeof(*b));
    if (!b) return NULL;
    b->refs=1; b->limit=limit;
    atomic_fetch_add(&find_budgets,1); find_account(b,sizeof(*b));
    return b;
}
int zwk_find_budget_limit(ZwkFindBudget *b,uint32_t limit) {
    if (!b || !limit || limit>FIND_LIMIT) return ZWK_INVALID;
    if (b->closed) return ZWK_CLOSED;
    b->limit=limit; return ZWK_OK;
}
static void find_gate_ref(ZwkFindGate *g) { ++g->refs; }
static void find_gate_unref(ZwkFindGate *g) {
    if (--g->refs) return;
    ZwkFindBudget *b=g->budget;
    for (ZwkFindGate **link=&b->gates;*link;link=&(*link)->next) if (*link==g) { *link=g->next; break; }
    free(g->term); free(g);
    --b->gate_count; find_credit(b,sizeof(*g));
    atomic_fetch_sub(&find_gates,1);
    zwk_find_budget_release(b);
}
static void find_command_unref(ZwkFindCommand *command) {
    if (--command->refs) return;
    ZwkFindBudget *b=command->budget; ZwkFindGate *g=command->gate; void *page=command->page;
    const size_t bytes=command->bytes;
    free(command);
    --b->command_count; find_credit(b,bytes);
    atomic_fetch_sub(&find_commands,1);
    find_gate_unref(g); CFRelease(page); zwk_find_budget_release(b);
}
static void find_gate_close(ZwkFindGate *g) {
    if (g->closed) return;
    find_gate_ref(g);
    g->closed=YES; g->notify=NULL;
    ZwkPage *s=(__bridge ZwkPage *)g->page; g->page=NULL;
    const BOOL owned=s && s->find==g;
    if (owned) s->find=NULL;
    const BOOL stop=g->token && !g->finish_requested;
    g->token=0; g->finish_requested=YES;
    ZwkFindCommand *command=g->pending; g->pending=NULL;
    if (command) { command->cancelled=YES; find_command_unref(command); }
    if (stop && s && s->view && [s->view respondsToSelector:@selector(_hideFindUI)]) [s->view _hideFindUI];
    if (owned) find_gate_unref(g);
    find_gate_unref(g);
}
/* The engine's answer to the command in progress. */
static void find_terminal(ZwkPage *s,BOOL found,NSUInteger count) {
    ZwkFindGate *g=s->find;
    if (!g || g->closed || !g->pending) return;
    find_gate_ref(g);
    ZwkFindCommand *command=g->pending; g->pending=NULL;
    ZwkFindSnapshot snapshot={0,0,0}; int status=0;
    if (command->kind==FIND_START) {
        if (found && count>INT32_MAX) status=1;
        else { snapshot.known=1; snapshot.matches=found?(int32_t)count:0; }
    }
    g->snapshot=snapshot;
    if (!command->cancelled && !g->budget->closed && live(s) && g->page==(__bridge void *)s && g->token==command->token && g->notify)
        g->notify(s->owner,command->token,command->kind==FIND_START?0:1,status,&snapshot);
    find_command_unref(command); find_gate_unref(g);
}
static int find_document_status(ZwkPage *s,ZwkFindGate *g) {
    if (!live(s) || !s->view || (g && (g->closed || g->budget->closed || s->find!=g))) return ZWK_CLOSED;
    return document(s)?ZWK_OK:ZWK_NOT_READY;
}
void zwk_find_budget_close(ZwkFindBudget *b) {
    find_budget_ref(b); b->closed=YES;
    ZwkFindGate *gates[FIND_LIMIT]; unsigned count=0;
    for (ZwkFindGate *g=b->gates;g && count<FIND_LIMIT;g=g->next) { find_gate_ref(g); gates[count++]=g; }
    for (unsigned i=0;i<count;++i) { find_gate_close(gates[i]); find_gate_unref(gates[i]); }
    zwk_find_budget_release(b);
}
static int find_gate_get(ZwkPage *s,ZwkFindBudget *b,ZwkFindNotify notify,ZwkFindGate **out) {
    if (s->find) {
        ZwkFindGate *g=s->find;
        if (g->budget!=b || g->notify!=notify) return ZWK_INVALID;
        if (g->closed) return ZWK_CLOSED;
        find_gate_ref(g); *out=g; return ZWK_OK;
    }
    if (![s->view respondsToSelector:@selector(_findString:options:maxCount:)] || ![s->view respondsToSelector:@selector(_setFindDelegate:)]) return ZWK_NATIVE_FAILED;
    if (b->gate_count>=b->limit) return ZWK_FULL;
    ZwkFindGate *g=calloc(1,sizeof(*g));
    if (!g) return ZWK_OOM;
    ++b->gate_count; find_budget_ref(b);
    g->budget=b; g->refs=2; /* The page's, and the caller's. */
    g->next=b->gates; b->gates=g;
    atomic_fetch_add(&find_gates,1); find_account(b,sizeof(*g));
    g->page=(__bridge void *)s; g->notify=notify; s->find=g;
    [s->view _setFindDelegate:s];
    *out=g; return ZWK_OK;
}
static int find_command_new(ZwkPage *s,ZwkFindGate *g,const char *term,size_t length,uint32_t flags,unsigned kind,ZwkFindCommand **out) {
    ZwkFindBudget *b=g->budget;
    if (g->closed || b->closed || !live(s) || s->find!=g) return ZWK_CLOSED;
    if (g->pending || b->command_count>=b->limit) return ZWK_FULL;
    const size_t bytes=sizeof(ZwkFindCommand)+(kind==FIND_START?length+1:0);
    ZwkFindCommand *command=calloc(1,bytes);
    if (!command) return ZWK_OOM;
    ++b->command_count; find_budget_ref(b); find_gate_ref(g);
    command->gate=g; command->page=(void *)CFBridgingRetain(s); command->budget=b; command->refs=1; command->bytes=bytes; command->flags=flags; command->kind=kind;
    if (kind==FIND_START) memcpy(command+1,term,length);
    atomic_fetch_add(&find_commands,1); find_account(b,bytes);
    *out=command; return ZWK_OK;
}
static BOOL find_utf8(const char *text,size_t length) {
    NSString *value=[[NSString alloc] initWithBytes:text length:length encoding:NSUTF8StringEncoding];
    return value!=nil;
}
int zwk_find_prepare(ZwkState *state,ZwkFindBudget *b,ZwkFindNotify notify,const char *term,size_t length,uint32_t flags,ZwkFindCommand **out) {
    if (!state || !b || !out || !notify) return ZWK_INVALID;
    *out=NULL;
    ZwkPage *s=page_of(state);
    ZwkPage *keep __attribute__((objc_precise_lifetime))=s; (void)keep;
    if (!live(s) || b->closed) return ZWK_CLOSED;
    if (!term || !length || length>FIND_TERM_BYTES || memchr(term,0,length) || !find_utf8(term,length) || (flags&~7u) || (flags&2u) || !(flags&4u)) return ZWK_INVALID;
    int status=find_document_status(s,NULL);
    ZwkFindGate *g=NULL;
    if (status==ZWK_OK) status=find_gate_get(s,b,notify,&g);
    if (status==ZWK_OK) { status=find_command_new(s,g,term,length,flags,FIND_START,out); find_gate_unref(g); }
    return status;
}
void zwk_find_abort(ZwkFindCommand *command) { find_command_unref(command); }
int zwk_find_commit(ZwkFindCommand *command,uint64_t token) {
    ZwkFindGate *g=command->gate;
    ZwkPage *s=(__bridge ZwkPage *)command->page;
    int status=ZWK_OK;
    if (!token) status=ZWK_INVALID;
    else if (g->closed || command->budget->closed || !live(s) || s->find!=g) status=ZWK_CLOSED;
    else status=find_document_status(s,g);
    if (status==ZWK_OK && g->pending) status=ZWK_FULL;
    if (status==ZWK_OK && command->kind!=FIND_START && g->token!=token) status=ZWK_NOT_READY;
    if (status==ZWK_OK && command->kind==FIND_START) {
        char *term=strdup((const char *)(command+1));
        if (!term) status=ZWK_OOM;
        else { free(g->term); g->term=term; g->flags=command->flags; }
    }
    if (status!=ZWK_OK) { find_command_unref(command); return status; }
    command->token=token; g->pending=command; g->snapshot=(ZwkFindSnapshot){0,0,0};
    if (command->kind==FIND_START) { g->token=token; g->finish_requested=NO; }
    @autoreleasepool {
        NSUInteger options=FIND_WRAP_AROUND|FIND_INDICATOR|FIND_HIGHLIGHT;
        if (!(g->flags&1u)) options|=FIND_CASE_INSENSITIVE;
        if (command->kind==FIND_PREVIOUS) options|=FIND_BACKWARDS;
        NSString *text=[NSString stringWithUTF8String:g->term];
        [s->view _findString:text options:options maxCount:INT32_MAX];
    }
    return ZWK_OK;
}
int zwk_find_action(ZwkState *state,int action,ZwkFindSnapshot *out) {
    if (!state || action<0 || action>2) return ZWK_INVALID;
    ZwkPage *s=page_of(state);
    ZwkPage *keep __attribute__((objc_precise_lifetime))=s; (void)keep;
    if (!live(s)) return ZWK_CLOSED;
    ZwkFindGate *g=s->find;
    if (!g || g->closed || !g->token) return ZWK_NOT_READY;
    find_gate_ref(g);
    const uint64_t token=g->token;
    int status=find_document_status(s,g);
    if (status==ZWK_OK && g->token!=token) status=ZWK_NOT_READY;
    if (status==ZWK_OK && action==0) {
        if (!out) status=ZWK_INVALID; else *out=g->snapshot;
    } else if (status==ZWK_OK) {
        ZwkFindCommand *command=NULL;
        status=find_command_new(s,g,NULL,0,0,action==1?FIND_NEXT:FIND_PREVIOUS,&command);
        if (status==ZWK_OK) status=zwk_find_commit(command,token);
    }
    find_gate_unref(g);
    return status;
}
void zwk_find_cancel(ZwkState *state,uint64_t token) {
    ZwkPage *s=page_of(state);
    ZwkFindGate *g=s->find;
    if (!g || g->closed || g->token!=token || !token) return;
    g->token=0; g->snapshot=(ZwkFindSnapshot){0,0,0};
    if (g->pending && g->pending->token==token) g->pending->cancelled=YES;
    const BOOL stop=!g->finish_requested; g->finish_requested=YES;
    if (stop && s->view && [s->view respondsToSelector:@selector(_hideFindUI)]) [s->view _hideFindUI];
}
void zwk_find_counts(uint32_t *budgets,uint32_t *gates,uint32_t *commands,size_t *bytes,size_t *peak) {
    if (budgets) *budgets=atomic_load(&find_budgets);
    if (gates) *gates=atomic_load(&find_gates);
    if (commands) *commands=atomic_load(&find_commands);
    if (bytes) *bytes=atomic_load(&find_bytes);
    if (peak) *peak=atomic_load(&find_peak);
}

/* Captures, PDFs and clears, as the Linux backend keeps them: a budget the
 * View owns bounds the operations in flight and each capture's PNG bytes. The
 * engine cannot stop one it started: a cancelled operation ends unreported. */
enum { CAPTURE_PENDING=8u, CAPTURE_BYTES=16u*1024u*1024u };
typedef struct CaptureOp CaptureOp;
struct ZwkCaptureBudget {
    CaptureOp *ops;
    ZwkCaptureNotify notify;
    size_t bytes;
    unsigned refs, pending, limit, capacity;
    BOOL closed;
};
struct CaptureOp {
    CaptureOp *next;
    void *page; /* A Core Foundation reference of its own. */
    ZwkCaptureBudget *budget;
    uint64_t token;
    BOOL cancelled, print;
};
static atomic_uint capture_budgets, capture_operations;
static atomic_size_t capture_bytes, capture_peak;
static void capture_account(size_t amount) {
    const size_t current=atomic_fetch_add(&capture_bytes,amount)+amount;
    size_t peak=atomic_load(&capture_peak);
    while (peak<current && !atomic_compare_exchange_weak(&capture_peak,&peak,current)) { }
}
void zwk_capture_budget_release(ZwkCaptureBudget *b) {
    if (--b->refs) return;
    atomic_fetch_sub(&capture_budgets,1); atomic_fetch_sub(&capture_bytes,sizeof(*b));
    free(b);
}
ZwkCaptureBudget *zwk_capture_budget_new(uint32_t pending,uint32_t bytes,ZwkCaptureNotify notify) {
    if (!pending || pending>CAPTURE_PENDING || !bytes || bytes>CAPTURE_BYTES || !notify) return NULL;
    ZwkCaptureBudget *b=calloc(1,sizeof(*b));
    if (!b) return NULL;
    b->refs=1; b->limit=pending; b->capacity=bytes; b->notify=notify; b->bytes=sizeof(*b);
    atomic_fetch_add(&capture_budgets,1); capture_account(sizeof(*b));
    return b;
}
int zwk_capture_budget_limit(ZwkCaptureBudget *b,uint32_t pending,uint32_t bytes) {
    if (!b || !pending || pending>CAPTURE_PENDING || !bytes || bytes>CAPTURE_BYTES) return ZWK_INVALID;
    if (b->closed) return ZWK_CLOSED;
    b->limit=pending; b->capacity=bytes; return ZWK_OK;
}
static void capture_cancel_budget(ZwkCaptureBudget *b,ZwkPage *page,uint64_t token) {
    for (CaptureOp *op=b->ops;op;op=op->next)
        if ((!page || op->page==(__bridge void *)page) && (!token || op->token==token)) op->cancelled=YES;
}
void zwk_capture_budget_close(ZwkCaptureBudget *b) { b->closed=YES; capture_cancel_budget(b,nil,0); }
int zwk_capture_enable(ZwkState *state,ZwkCaptureBudget *b) {
    if (!state || !b) return ZWK_INVALID;
    ZwkPage *s=page_of(state);
    if (!live(s) || b->closed) return ZWK_CLOSED;
    if (s->capture) return ZWK_INVALID;
    ++b->refs; s->capture=b; return ZWK_OK;
}
static void capture_cancel_all(ZwkPage *s) { if (s->capture) capture_cancel_budget(s->capture,s,0); }
void zwk_capture_cancel(ZwkState *state,uint64_t token) {
    ZwkPage *s=page_of(state);
    if (s->capture) capture_cancel_budget(s->capture,s,token);
}
/* Takes a slot of the page's budget, or says why there is none. */
static int capture_begin(ZwkPage *s,uint64_t token,BOOL needs_document,BOOL print,CaptureOp **out) {
    if (!token) return ZWK_INVALID;
    if (!live(s)) return ZWK_CLOSED;
    ZwkCaptureBudget *b=s->capture;
    if (!b || b->closed) return ZWK_CLOSED;
    if (needs_document && !document(s)) return ZWK_NOT_READY;
    if (b->pending>=b->limit || atomic_load(&capture_operations)>=CAPTURE_PENDING) return ZWK_FULL;
    for (CaptureOp *at=b->ops;at;at=at->next) {
        if (at->token==token) return ZWK_INVALID;
        if (print && at->print && at->page==(__bridge void *)s) return ZWK_FULL;
    }
    CaptureOp *op=calloc(1,sizeof(*op));
    if (!op) return ZWK_OOM;
    op->page=(void *)CFBridgingRetain(s); op->budget=b; op->token=token; op->print=print;
    ++b->refs; op->next=b->ops; b->ops=op; ++b->pending; b->bytes+=sizeof(*op);
    atomic_fetch_add(&capture_operations,1); capture_account(sizeof(*op));
    *out=op; return ZWK_OK;
}
/* Ends an operation: reports it unless it was cancelled, then frees it. */
static void capture_end(CaptureOp *op,int status,const unsigned char *data,size_t length,NSError *error) {
    ZwkPage *s=CFBridgingRelease(op->page);
    ZwkCaptureBudget *b=op->budget;
    for (CaptureOp **link=&b->ops;*link;link=&(*link)->next) if (*link==op) { *link=op->next; break; }
    --b->pending; b->bytes-=sizeof(*op);
    atomic_fetch_sub(&capture_operations,1); atomic_fetch_sub(&capture_bytes,sizeof(*op));
    const uint64_t token=op->token; const BOOL cancelled=op->cancelled;
    free(op);
    if (!cancelled && !b->closed && live(s) && s->capture==b && b->notify) {
        const ZwkFailure failure=error?(ZwkFailure){domain_code(error.domain),(int32_t)error.code}:(ZwkFailure){0,0};
        static const unsigned char empty=0;
        b->notify(s->owner,token,status,data?data:&empty,length,error?&failure:NULL);
    }
    zwk_capture_budget_release(b);
}
/* The visible part of the page, as a PNG. */
int zwk_capture_start(ZwkState *state,uint64_t token) {
    ZwkPage *s=page_of(state);
    ZwkPage *keep __attribute__((objc_precise_lifetime))=s; (void)keep;
    CaptureOp *op=NULL;
    const int status=capture_begin(s,token,YES,NO,&op);
    if (status!=ZWK_OK) return status;
    const size_t capacity=s->capture->capacity;
    @autoreleasepool {
        [s->view takeSnapshotWithConfiguration:nil completionHandler:^(NSImage *image,NSError *error) {
            if (op->cancelled || op->budget->closed) { capture_end(op,ZWK_CAPTURE_OK,NULL,0,nil); return; }
            if (error || !image) { capture_end(op,error?ZWK_CAPTURE_NATIVE:ZWK_CAPTURE_INVALID,NULL,0,error); return; }
            NSData *png=nil;
            @autoreleasepool {
                CGImageRef cg=[image CGImageForProposedRect:NULL context:nil hints:nil];
                NSBitmapImageRep *bitmap=cg?[[NSBitmapImageRep alloc] initWithCGImage:cg]:nil;
                png=[bitmap representationUsingType:NSBitmapImageFileTypePNG properties:@{}];
            }
            if (!png.length) capture_end(op,ZWK_CAPTURE_INVALID,NULL,0,nil);
            else if (png.length>capacity) capture_end(op,ZWK_CAPTURE_LIMIT,NULL,0,nil);
            else capture_end(op,ZWK_CAPTURE_OK,png.bytes,png.length,nil);
        }];
    }
    return ZWK_OK;
}
/* Clears every data type of the page's own data store, for all time. */
int zwk_clear_start(ZwkState *state,uint64_t token) {
    ZwkPage *s=page_of(state);
    ZwkPage *keep __attribute__((objc_precise_lifetime))=s; (void)keep;
    CaptureOp *op=NULL;
    const int status=capture_begin(s,token,NO,NO,&op);
    if (status!=ZWK_OK) return status;
    @autoreleasepool {
        WKWebsiteDataStore *store=s->view.configuration.websiteDataStore;
        [store removeDataOfTypes:[WKWebsiteDataStore allWebsiteDataTypes] modifiedSince:[NSDate distantPast] completionHandler:^{
            capture_end(op,ZWK_CAPTURE_OK,NULL,0,nil);
        }];
    }
    return ZWK_OK;
}
/* Receives the end of a PDF's print operation. */
@interface ZwkPrintDone : NSObject {
@public
    CaptureOp *op;
    NSURL *file;
    BOOL backgrounds, set_backgrounds;
    WKPreferences *preferences;
}
- (void)printOperationDidRun:(NSPrintOperation *)operation success:(BOOL)success contextInfo:(void *)context;
- (void)finish:(BOOL)success;
@end
@implementation ZwkPrintDone
- (void)printOperationDidRun:(NSPrintOperation *)operation success:(BOOL)success contextInfo:(void *)context {
    (void)operation; (void)context;
    /* AppKit may run a save job, and call this, on its own thread. */
    if (![NSThread isMainThread]) {
        dispatch_async(dispatch_get_main_queue(),^{ [self finish:success]; });
        return;
    }
    [self finish:success];
}
- (void)finish:(BOOL)success {
    if (set_backgrounds) { if (@available(macOS 13.3,*)) preferences.shouldPrintBackgrounds=backgrounds; }
    NSError *error=success && [file checkResourceIsReachableAndReturnError:NULL]?nil:
        [NSError errorWithDomain:@"ziggurat-webkit-print" code:success?2:1 userInfo:nil];
    CaptureOp *value=op; op=NULL;
    capture_end(value,error?ZWK_CAPTURE_NATIVE:ZWK_CAPTURE_OK,NULL,0,error);
    CFRelease((__bridge CFTypeRef)self);
}
@end
/* Prints the document to a PDF file through AppKit's print system, which
 * paginates as the Linux backend's file printer does. One PDF runs at a time
 * per page, since it changes the page's backgrounds setting. */
int zwk_pdf_start(ZwkState *state,uint64_t token,const char *path,const ZwkPdfRequest *request) {
    ZwkPage *s=page_of(state);
    ZwkPage *keep __attribute__((objc_precise_lifetime))=s; (void)keep;
    if (!token || !path || path[0]!='/' || !request || !request->first_page || (request->last_page && request->last_page<request->first_page)) return ZWK_INVALID;
    for (int i=0;i<6;++i) if (!(request->page[i]>=0) || request->page[i]>1000) return ZWK_INVALID;
    if (!(request->page[0]>0) || !(request->page[1]>0)) return ZWK_INVALID;
    if (live(s) && !s->view.window) return ZWK_NATIVE_FAILED;
    CaptureOp *op=NULL;
    const int status=capture_begin(s,token,YES,YES,&op);
    if (status!=ZWK_OK) return status;
    @autoreleasepool {
        NSURL *file=[NSURL fileURLWithPath:[NSString stringWithUTF8String:path]];
        [[NSFileManager defaultManager] removeItemAtURL:file error:NULL];
        NSPrintInfo *info=[[NSPrintInfo alloc] initWithDictionary:@{
            NSPrintJobDisposition:NSPrintSaveJob,
            NSPrintJobSavingURL:file,
        }];
        /* The paper as given; landscape turns it, as GTK's page setup does. */
        info.paperSize=NSMakeSize(request->page[0]*72,request->page[1]*72);
        info.orientation=(request->flags&1u)?NSPaperOrientationLandscape:NSPaperOrientationPortrait;
        info.topMargin=request->page[2]*72; info.rightMargin=request->page[3]*72;
        info.bottomMargin=request->page[4]*72; info.leftMargin=request->page[5]*72;
        info.horizontalPagination=NSPrintingPaginationModeFit;
        info.verticalPagination=NSPrintingPaginationModeAutomatic;
        info.horizontallyCentered=NO; info.verticallyCentered=NO;
        if (request->first_page>1 || request->last_page) {
            info.dictionary[NSPrintAllPages]=@NO;
            info.dictionary[NSPrintFirstPage]=@(request->first_page);
            info.dictionary[NSPrintLastPage]=@(request->last_page?request->last_page:INT32_MAX/2);
        }
        ZwkPrintDone *done=[[ZwkPrintDone alloc] init];
        done->op=op; done->file=file;
        if (@available(macOS 13.3,*)) {
            done->preferences=s->view.configuration.preferences;
            done->backgrounds=done->preferences.shouldPrintBackgrounds; done->set_backgrounds=YES;
            done->preferences.shouldPrintBackgrounds=(request->flags&2u)!=0;
        }
        NSPrintOperation *operation=[s->view printOperationWithPrintInfo:info];
        operation.showsPrintPanel=NO; operation.showsProgressPanel=NO;
        /* WKWebView prints a view of no size blank. */
        operation.view.frame=s->view.bounds;
        CFBridgingRetain(done);
        [operation runOperationModalForWindow:s->view.window delegate:done didRunSelector:@selector(printOperationDidRun:success:contextInfo:) contextInfo:NULL];
    }
    return ZWK_OK;
}
void zwk_capture_counts(uint32_t *budgets,uint32_t *operations,size_t *bytes,size_t *peak) {
    if (budgets) *budgets=atomic_load(&capture_budgets);
    if (operations) *operations=atomic_load(&capture_operations);
    if (bytes) *bytes=atomic_load(&capture_bytes);
    if (peak) *peak=atomic_load(&capture_peak);
}

ZwkFileBudget *zwk_file_budget_create(uint32_t limit) { (void)limit; return NULL; }
void zwk_file_budget_limit(ZwkFileBudget *budget,uint32_t limit) { (void)budget; (void)limit; }
void zwk_file_budget_release(ZwkFileBudget *budget) { (void)budget; }
void zwk_file_counts(uint32_t *a,uint32_t *b,uint32_t *c,uint32_t *d) { *a=0; *b=0; *c=0; *d=0; }

