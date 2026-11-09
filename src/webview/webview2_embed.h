/* Web views in a window of native UI (attachRegion) on WebView2: each page
   is a composition controller whose visuals are in a DirectComposition
   target of the window that is not topmost, the window's web layer, under
   the target its frames show through (topmost). The frames are transparent
   where the content shows a page (holes), so that what the content paints
   after the page shows over it. The window keeps the mouse: a subclass
   sends it on to the page under the pointer, unless the content painted
   over the page there (a cover) or its corners cut it away, as visual
   hosting has the host do; the page takes the keyboard as it gets the
   focus, tells the cursor it wants, and gives the keyboard back as Tab
   leaves it past its last element (or Shift+Tab its first). Its UI
   Automation provider holds the page's tree, which the window's provider
   shows inside the node standing for the page. */
#include <commctrl.h>

#define EMBED_MAX_COVERS 16

/* IDCompositionDevice, IDCompositionTarget, IDCompositionVisual and
   IDCompositionRectangleClip declare C++ interfaces only: their vtable
   slots, from dcomp.h. The overloads take a slot each, the one taking an
   animation first. */
enum {
    EMBED_DEV_COMMIT=3, EMBED_DEV_CREATE_TARGET=6, EMBED_DEV_CREATE_VISUAL=7, EMBED_DEV_CREATE_RECT_CLIP=24,
    EMBED_TARGET_SET_ROOT=3,
    EMBED_VISUAL_SET_TRANSFORM=8, EMBED_VISUAL_SET_CLIP_OBJECT=13, EMBED_VISUAL_SET_CLIP=14,
    EMBED_VISUAL_ADD=16, EMBED_VISUAL_REMOVE=17,
    EMBED_CLIP_LEFT=4, EMBED_CLIP_TOP=6, EMBED_CLIP_RIGHT=8, EMBED_CLIP_BOTTOM=10, EMBED_CLIP_TOP_LEFT_X=12
};
static const GUID embed_iid_dcomp_device={0xc37ea93a,0xe7aa,0x450d,{0xb1,0x6f,0x97,0x46,0xcb,0x04,0x07,0xf3}};
static void **embed_vtbl(void *object){return *(void ***)object;}
typedef HRESULT (STDMETHODCALLTYPE *EmbedCall0)(void *);
typedef HRESULT (STDMETHODCALLTYPE *EmbedCallPtr)(void *,void *);
typedef HRESULT (STDMETHODCALLTYPE *EmbedCallFloat)(void *,float);
#define EMBED_RELEASE(p) do { if (p) { IUnknown_Release((IUnknown *)(p)); (p)=NULL; } } while (0)

typedef struct EmbedLayer EmbedLayer;
typedef struct Embed {
    State *state;
    EmbedLayer *layer;
    struct Embed *next; /* in the layer, in the order the pages were added */
    ICoreWebView2CompositionController *comp;
    IUnknown *clip_visual, *web_visual, *corners;
    IUnknown *automation;
    HCURSOR cursor;
    BOOL focused;
    /* Where the page shows, in the window's client pixels: the part its
       clips leave, its origin and how much the content's transforms scale
       it, the boxes the content paints over it, and its corners' radii in
       its own pixels from the top-left clockwise. */
    BOOL shown, placed;
    RECT clip;
    float at_x, at_y, scale_x, scale_y, width, height, radii[4];
    RECT covers[EMBED_MAX_COVERS];
    uint32_t cover_count;
    /* The wheel over the page scrolls the native UI around it. */
    BOOL wheel_to_container;
    EventRegistrationToken cursor_token, got_token, lost_token, move_token;
    BOOL has_cursor, has_got, has_lost, has_move;
} Embed;
struct EmbedLayer {
    HWND hwnd;
    IUnknown *dcomp, *target, *root;
    Embed *first;
    Embed *hover, *capture;
    BOOL tracking;
    EmbedLayer *next;
};
static EmbedLayer *embed_layers;

static LRESULT CALLBACK embed_subclass(HWND,UINT,WPARAM,LPARAM,UINT_PTR,DWORD_PTR);
static void embed_layer_free(EmbedLayer *l) {
    if (l->hwnd) RemoveWindowSubclass(l->hwnd,embed_subclass,1);
    EMBED_RELEASE(l->root);EMBED_RELEASE(l->target);EMBED_RELEASE(l->dcomp);
    for (EmbedLayer **at=&embed_layers;*at;at=&(*at)->next) if (*at==l) { *at=l->next;break; }
    free(l);
}
static HRESULT embed_layer_of(HWND hwnd,EmbedLayer **out) {
    *out=NULL;
    for (EmbedLayer *l=embed_layers;l;l=l->next) if (l->hwnd==hwnd) { *out=l;return S_OK; }
    typedef HRESULT (WINAPI *Create2)(IUnknown *,REFIID,void **);
    HMODULE module=GetModuleHandleW(L"dcomp.dll");
    if (!module) module=LoadLibraryExW(L"dcomp.dll",NULL,LOAD_LIBRARY_SEARCH_SYSTEM32);
    Create2 create=module?(Create2)(void *)GetProcAddress(module,"DCompositionCreateDevice2"):NULL;
    if (!create) return HRESULT_FROM_WIN32(ERROR_PROC_NOT_FOUND);
    EmbedLayer *l=calloc(1,sizeof(*l));
    if (!l) return E_OUTOFMEMORY;
    /* A device of its own, without a rendering device, which no GPU reset
       of the frames takes away. */
    HRESULT hr=create(NULL,&embed_iid_dcomp_device,(void **)&l->dcomp);
    if (SUCCEEDED(hr)) hr=((HRESULT (STDMETHODCALLTYPE *)(void *,HWND,BOOL,void **))embed_vtbl(l->dcomp)[EMBED_DEV_CREATE_TARGET])(l->dcomp,hwnd,FALSE,(void **)&l->target);
    if (SUCCEEDED(hr)) hr=((EmbedCallPtr)embed_vtbl(l->dcomp)[EMBED_DEV_CREATE_VISUAL])(l->dcomp,&l->root);
    if (SUCCEEDED(hr)) hr=((EmbedCallPtr)embed_vtbl(l->target)[EMBED_TARGET_SET_ROOT])(l->target,l->root);
    if (SUCCEEDED(hr)&&!SetWindowSubclass(hwnd,embed_subclass,1,(DWORD_PTR)l)) hr=HRESULT_FROM_WIN32(GetLastError());
    if (FAILED(hr)) { EMBED_RELEASE(l->root);EMBED_RELEASE(l->target);EMBED_RELEASE(l->dcomp);free(l);return hr; }
    l->hwnd=hwnd;l->next=embed_layers;embed_layers=l;
    *out=l;return S_OK;
}
static void embed_commit(EmbedLayer *l) { if (l&&l->dcomp) ((EmbedCall0)embed_vtbl(l->dcomp)[EMBED_DEV_COMMIT])(l->dcomp); }
static void embed_visual_transform(IUnknown *visual,float x,float y,float sx,float sy) {
    float m[6]={sx,0,0,sy,x,y}; /* D2D_MATRIX_3X2_F */
    ((EmbedCallPtr)embed_vtbl(visual)[EMBED_VISUAL_SET_TRANSFORM])(visual,m);
}
static void embed_visual_clip(IUnknown *visual,float w,float h) {
    float r[4]={0,0,w,h}; /* D2D_RECT_F */
    ((EmbedCallPtr)embed_vtbl(visual)[EMBED_VISUAL_SET_CLIP])(visual,r);
}
/* Cuts the page's visual to its box of width by height pixels inside its
   corners, or takes the cut away without radii. */
static void embed_corners(Embed *e) {
    BOOL round=e->radii[0]>0||e->radii[1]>0||e->radii[2]>0||e->radii[3]>0;
    if (!round) {
        if (e->corners) { ((EmbedCallPtr)embed_vtbl(e->web_visual)[EMBED_VISUAL_SET_CLIP_OBJECT])(e->web_visual,NULL);EMBED_RELEASE(e->corners); }
        return;
    }
    if (!e->corners) {
        if (FAILED(((EmbedCallPtr)embed_vtbl(e->layer->dcomp)[EMBED_DEV_CREATE_RECT_CLIP])(e->layer->dcomp,&e->corners))||!e->corners) { e->corners=NULL;return; }
        ((EmbedCallPtr)embed_vtbl(e->web_visual)[EMBED_VISUAL_SET_CLIP_OBJECT])(e->web_visual,e->corners);
    }
    void **v=embed_vtbl(e->corners);
    ((EmbedCallFloat)v[EMBED_CLIP_LEFT])(e->corners,0);
    ((EmbedCallFloat)v[EMBED_CLIP_TOP])(e->corners,0);
    ((EmbedCallFloat)v[EMBED_CLIP_RIGHT])(e->corners,e->width);
    ((EmbedCallFloat)v[EMBED_CLIP_BOTTOM])(e->corners,e->height);
    /* The setters go around by the bottom-left before the bottom-right. */
    const float order[4]={e->radii[0],e->radii[1],e->radii[3],e->radii[2]};
    for (int i=0;i<4;i++) {
        ((EmbedCallFloat)v[EMBED_CLIP_TOP_LEFT_X+4*i])(e->corners,order[i]);
        ((EmbedCallFloat)v[EMBED_CLIP_TOP_LEFT_X+4*i+2])(e->corners,order[i]);
    }
}

/* Whether the page takes the pointer at x, y of the window's client area. */
static BOOL embed_at(const Embed *e,int x,int y) {
    if (!e->shown||!e->comp||e->state->closed) return FALSE;
    POINT p={x,y};
    if (!PtInRect(&e->clip,p)) return FALSE;
    for (uint32_t i=0;i<e->cover_count;i++) if (PtInRect(&e->covers[i],p)) return FALSE;
    float lx=(x-e->at_x)/e->scale_x, ly=(y-e->at_y)/e->scale_y;
    if (lx<0||ly<0||lx>=e->width||ly>=e->height) return FALSE;
    const float sides[4][2]={{0,0},{1,0},{1,1},{0,1}};
    for (int i=0;i<4;i++) {
        float r=e->radii[i];
        if (r<=0) continue;
        float cx=r+sides[i][0]*(e->width-2*r), cy=r+sides[i][1]*(e->height-2*r);
        float dx=lx-cx, dy=ly-cy;
        if ((sides[i][0]==0)!=(dx<0)||(sides[i][1]==0)!=(dy<0)) continue;
        if (dx*dx+dy*dy>r*r) return FALSE;
    }
    return TRUE;
}
/* The page that takes the pointer there: the one added last of those that
   do, as each is placed over those before it. */
static Embed *embed_hit(EmbedLayer *l,int x,int y) {
    Embed *found=NULL;
    for (Embed *e=l->first;e;e=e->next) if (embed_at(e,x,y)) found=e;
    return found;
}
static POINT embed_page_point(const Embed *e,int x,int y) {
    POINT p={(LONG)floorf((x-e->at_x)/e->scale_x+0.5f),(LONG)floorf((y-e->at_y)/e->scale_y+0.5f)};
    return p;
}
static void embed_leave(Embed *e) {
    if (e&&e->comp&&!e->state->closed) {
        POINT none={0,0};
        ICoreWebView2CompositionController_SendMouseInput(e->comp,COREWEBVIEW2_MOUSE_EVENT_KIND_LEAVE,COREWEBVIEW2_MOUSE_EVENT_VIRTUAL_KEYS_NONE,0,none);
    }
}
static void embed_focus(Embed *e) {
    if (e->focused||!e->state->controller||e->state->closed) return;
    ICoreWebView2Controller_MoveFocus(e->state->controller,COREWEBVIEW2_MOVE_FOCUS_REASON_PROGRAMMATIC);
}
static BOOL embed_button_down(UINT m) {
    return m==WM_LBUTTONDOWN||m==WM_LBUTTONDBLCLK||m==WM_RBUTTONDOWN||m==WM_RBUTTONDBLCLK||m==WM_MBUTTONDOWN||m==WM_MBUTTONDBLCLK||m==WM_XBUTTONDOWN||m==WM_XBUTTONDBLCLK;
}
static BOOL embed_button_up(UINT m) { return m==WM_LBUTTONUP||m==WM_RBUTTONUP||m==WM_MBUTTONUP||m==WM_XBUTTONUP; }
/* A pinch on a touchpad: a wheel by less than a notch with Ctrl held. */
static BOOL embed_pinching(UINT m,WPARAM wp) { return m==WM_MOUSEWHEEL&&((short)HIWORD(wp))%WHEEL_DELTA!=0&&(LOWORD(wp)&MK_CONTROL); }

/* Sends a mouse message of the window on to the page under the pointer,
   or the page that took the press, and reports whether the window's own
   handling is to be skipped: the content still hears the pointer move over
   the page and the buttons go down and up on it, which gives its node the
   focus, but not the wheel the page takes. */
static BOOL embed_mouse(EmbedLayer *l,UINT m,WPARAM wp,LPARAM lp) {
    POINT pt={GET_X_LPARAM(lp),GET_Y_LPARAM(lp)};
    BOOL wheel=m==WM_MOUSEWHEEL||m==WM_MOUSEHWHEEL;
    if (wheel) ScreenToClient(l->hwnd,&pt);
    BOOL held=(LOWORD(wp)&(MK_LBUTTON|MK_RBUTTON|MK_MBUTTON|MK_XBUTTON1|MK_XBUTTON2))!=0;
    Embed *e=l->capture;
    if (!e&&(!held||embed_button_down(m))) e=embed_hit(l,pt.x,pt.y);
    if (e!=l->hover) { embed_leave(l->hover);l->hover=e; }
    if (!e) return FALSE;
    if (wheel&&e->wheel_to_container&&!embed_pinching(m,wp)) return FALSE;
    if (m==WM_MOUSEMOVE&&!l->tracking) {
        TRACKMOUSEEVENT track={sizeof(track),TME_LEAVE,l->hwnd,0};
        l->tracking=TrackMouseEvent(&track);
    }
    UINT32 data=0;
    if (wheel) data=(UINT32)(INT32)(short)HIWORD(wp);
    else if (m==WM_XBUTTONDOWN||m==WM_XBUTTONUP||m==WM_XBUTTONDBLCLK) data=HIWORD(wp);
    if (embed_button_down(m)) {
        if (!l->capture) { l->capture=e;SetCapture(l->hwnd); }
    }
    POINT local=embed_page_point(e,pt.x,pt.y);
    ICoreWebView2CompositionController_SendMouseInput(e->comp,(COREWEBVIEW2_MOUSE_EVENT_KIND)m,(COREWEBVIEW2_MOUSE_EVENT_VIRTUAL_KEYS)LOWORD(wp),data,local);
    if (embed_button_up(m)&&!held) {
        l->capture=NULL;
        if (GetCapture()==l->hwnd) ReleaseCapture();
    }
    return wheel;
}
/* Sets the cursor of the page under the pointer, and reports whether there
   is one: WM_SETCURSOR comes before the move that tells. */
static BOOL embed_set_cursor(EmbedLayer *l) {
    Embed *e=l->capture;
    if (!e) {
        POINT pt;
        if (!GetCursorPos(&pt)||!ScreenToClient(l->hwnd,&pt)) return FALSE;
        e=embed_hit(l,pt.x,pt.y);
    }
    if (!e||!e->cursor) return FALSE;
    SetCursor(e->cursor);
    return TRUE;
}
static LRESULT CALLBACK embed_subclass(HWND hwnd,UINT m,WPARAM wp,LPARAM lp,UINT_PTR id,DWORD_PTR data) {
    (void)id;
    EmbedLayer *l=(EmbedLayer *)data;
    if ((m>=WM_MOUSEFIRST&&m<=WM_MOUSELAST)) {
        BOOL down=embed_button_down(m);
        Embed *before=l->capture;
        /* A release goes to the page that took the press before the
           content's handling lets go of the capture, which would forget
           that page. */
        if (embed_button_up(m)) {
            embed_mouse(l,m,wp,lp);
            return DefSubclassProc(hwnd,m,wp,lp);
        }
        LRESULT result=0;
        /* The content's handling first: a press there may take the focus
           to the window, which the page then takes. */
        if (!(m==WM_MOUSEWHEEL||m==WM_MOUSEHWHEEL)) result=DefSubclassProc(hwnd,m,wp,lp);
        if (embed_mouse(l,m,wp,lp)) return 0;
        if (down&&l->capture&&l->capture!=before) embed_focus(l->capture);
        if (m==WM_MOUSEWHEEL||m==WM_MOUSEHWHEEL) return DefSubclassProc(hwnd,m,wp,lp);
        return result;
    }
    switch (m) {
    case WM_MOUSELEAVE:
        l->tracking=FALSE;
        if (l->hover&&!l->capture) { embed_leave(l->hover);l->hover=NULL; }
        break;
    case WM_CAPTURECHANGED:
        /* Another window took the capture: the press is over. */
        if ((HWND)lp!=hwnd&&l->capture) { embed_leave(l->capture);l->capture=NULL; }
        break;
    case WM_SETCURSOR:
        if ((HWND)wp==hwnd&&LOWORD(lp)==HTCLIENT&&embed_set_cursor(l)) return TRUE;
        break;
    case WM_NCDESTROY:
        RemoveWindowSubclass(hwnd,embed_subclass,1);
        l->hwnd=NULL;
        break;
    }
    return DefSubclassProc(hwnd,m,wp,lp);
}

HANDLER(CompositionHandler, ICoreWebView2CreateCoreWebView2CompositionControllerCompletedHandler, IID_ICoreWebView2CreateCoreWebView2CompositionControllerCompletedHandler)
HANDLER(CursorHandler, ICoreWebView2CursorChangedEventHandler, IID_ICoreWebView2CursorChangedEventHandler)
HANDLER(GotFocusHandler, ICoreWebView2FocusChangedEventHandler, IID_ICoreWebView2FocusChangedEventHandler)
HANDLER(LostFocusHandler, ICoreWebView2FocusChangedEventHandler, IID_ICoreWebView2FocusChangedEventHandler)
HANDLER(MoveFocusHandler, ICoreWebView2MoveFocusRequestedEventHandler, IID_ICoreWebView2MoveFocusRequestedEventHandler)
static HRESULT controller_ready(State *s,HRESULT hr,ICoreWebView2Controller *controller);
static HRESULT STDMETHODCALLTYPE composition_invoke(ICoreWebView2CreateCoreWebView2CompositionControllerCompletedHandler *p,HRESULT hr,ICoreWebView2CompositionController *comp) {
    State *s=((CompositionHandler *)p)->state;retain(s);
    ICoreWebView2Controller *controller=NULL;
    if (SUCCEEDED(hr)&&!comp) hr=E_POINTER;
    if (SUCCEEDED(hr)) {
        hr=ICoreWebView2CompositionController_QueryInterface(comp,&IID_ICoreWebView2Controller,(void **)&controller);
        if (SUCCEEDED(hr)&&!controller) hr=E_POINTER;
    }
    if (SUCCEEDED(hr)&&(s->closed||!s->embed)) {
        /* Closed while WebView2 made it: the page goes at once. */
        ICoreWebView2Controller_Close(controller);ICoreWebView2Controller_Release(controller);
        release(s);return S_OK;
    }
    if (SUCCEEDED(hr)) { ICoreWebView2CompositionController_AddRef(comp);s->embed->comp=comp; }
    controller_ready(s,hr,controller);
    if (controller) ICoreWebView2Controller_Release(controller);
    release(s);return S_OK;
}
static HRESULT STDMETHODCALLTYPE cursor_invoke(ICoreWebView2CursorChangedEventHandler *p,ICoreWebView2CompositionController *sender,IUnknown *args) {
    (void)args;State *s=((CursorHandler *)p)->state;
    Embed *e=s->embed;
    if (s->closed||!e||!sender) return S_OK;
    HCURSOR cursor=NULL;
    if (SUCCEEDED(ICoreWebView2CompositionController_get_Cursor(sender,&cursor))) e->cursor=cursor;
    if (e->layer&&(e->layer->hover==e||e->layer->capture==e)&&cursor) SetCursor(cursor);
    return S_OK;
}
static HRESULT STDMETHODCALLTYPE got_focus_invoke(ICoreWebView2FocusChangedEventHandler *p,ICoreWebView2Controller *sender,IUnknown *args) {
    (void)sender;(void)args;State *s=((GotFocusHandler *)p)->state;
    if (!s->closed&&s->embed) s->embed->focused=TRUE;
    return S_OK;
}
static HRESULT STDMETHODCALLTYPE lost_focus_invoke(ICoreWebView2FocusChangedEventHandler *p,ICoreWebView2Controller *sender,IUnknown *args) {
    (void)sender;(void)args;State *s=((LostFocusHandler *)p)->state;
    if (!s->closed&&s->embed) s->embed->focused=FALSE;
    return S_OK;
}
/* Tab past the page's last element (Shift+Tab past its first) gives the
   window the keyboard back, not the next window WebView2 would find, and
   tells the content, which moves its focus on from the page. */
static HRESULT STDMETHODCALLTYPE move_focus_invoke(ICoreWebView2MoveFocusRequestedEventHandler *p,ICoreWebView2Controller *sender,ICoreWebView2MoveFocusRequestedEventArgs *args) {
    (void)sender;State *s=((MoveFocusHandler *)p)->state;retain(s);
    COREWEBVIEW2_MOVE_FOCUS_REASON reason=COREWEBVIEW2_MOVE_FOCUS_REASON_PROGRAMMATIC;
    if (!s->closed&&args&&SUCCEEDED(ICoreWebView2MoveFocusRequestedEventArgs_get_Reason(args,&reason))&&reason!=COREWEBVIEW2_MOVE_FOCUS_REASON_PROGRAMMATIC) {
        ICoreWebView2MoveFocusRequestedEventArgs_put_Handled(args,TRUE);
        if (s->embed) s->embed->focused=FALSE;
        if (s->hwnd) SetFocus(s->hwnd);
        if (!s->closed) notify(s,reason==COREWEBVIEW2_MOVE_FOCUS_REASON_PREVIOUS?21:20,NULL,S_OK);
    }
    release(s);return S_OK;
}
VTABLE(CompositionHandler, ICoreWebView2CreateCoreWebView2CompositionControllerCompletedHandler, composition_invoke)
VTABLE(CursorHandler, ICoreWebView2CursorChangedEventHandler, cursor_invoke)
VTABLE(GotFocusHandler, ICoreWebView2FocusChangedEventHandler, got_focus_invoke)
VTABLE(LostFocusHandler, ICoreWebView2FocusChangedEventHandler, lost_focus_invoke)
VTABLE(MoveFocusHandler, ICoreWebView2MoveFocusRequestedEventHandler, move_focus_invoke)

/* Asks WebView2 for the page's composition controller in the window's web
   layer, which makes the layer on the first page of the window. */
static HRESULT embed_create(State *s,ICoreWebView2Environment *environment) {
    Embed *e=calloc(1,sizeof(*e));
    if (!e) return E_OUTOFMEMORY;
    e->state=s;e->scale_x=e->scale_y=1;
    HRESULT hr=embed_layer_of(s->hwnd,&e->layer);
    if (SUCCEEDED(hr)) hr=((EmbedCallPtr)embed_vtbl(e->layer->dcomp)[EMBED_DEV_CREATE_VISUAL])(e->layer->dcomp,&e->clip_visual);
    if (SUCCEEDED(hr)) hr=((EmbedCallPtr)embed_vtbl(e->layer->dcomp)[EMBED_DEV_CREATE_VISUAL])(e->layer->dcomp,&e->web_visual);
    if (SUCCEEDED(hr)) hr=((HRESULT (STDMETHODCALLTYPE *)(void *,void *,BOOL,void *))embed_vtbl(e->clip_visual)[EMBED_VISUAL_ADD])(e->clip_visual,e->web_visual,TRUE,NULL);
    /* Over the pages added before it. */
    if (SUCCEEDED(hr)) {
        Embed *last=NULL;
        for (Embed *at=e->layer->first;at;at=at->next) last=at;
        hr=((HRESULT (STDMETHODCALLTYPE *)(void *,void *,BOOL,void *))embed_vtbl(e->layer->root)[EMBED_VISUAL_ADD])(e->layer->root,e->clip_visual,TRUE,last?last->clip_visual:NULL);
        if (SUCCEEDED(hr)) { if (last) last->next=e; else e->layer->first=e; }
    }
    if (FAILED(hr)) {
        EMBED_RELEASE(e->web_visual);EMBED_RELEASE(e->clip_visual);
        if (e->layer&&!e->layer->first) embed_layer_free(e->layer);
        free(e);return hr;
    }
    embed_visual_clip(e->clip_visual,0,0);
    embed_commit(e->layer);
    s->embed=e;
    ICoreWebView2Environment3 *environment3=NULL;
    hr=ICoreWebView2Environment_QueryInterface(environment,&IID_ICoreWebView2Environment3,(void **)&environment3);
    if (SUCCEEDED(hr)&&!environment3) hr=E_NOINTERFACE;
    if (FAILED(hr)) return hr;
    CompositionHandler *handler=CompositionHandler_new(s);
    if (!handler) hr=E_OUTOFMEMORY;
    else {
        hr=ICoreWebView2Environment3_CreateCoreWebView2CompositionController(environment3,s->hwnd,&handler->iface);
        CompositionHandler_release(&handler->iface);
    }
    ICoreWebView2Environment3_Release(environment3);
    return hr;
}
/* Connects the controller of a page with an Embed to its visual and to the
   window, before the page's other handlers. */
static HRESULT embed_ready(State *s) {
    Embed *e=s->embed;
    if (!e||!e->comp) return S_OK;
    ICoreWebView2Controller *controller=s->controller;
    HRESULT hr=ICoreWebView2CompositionController_put_RootVisualTarget(e->comp,e->web_visual);
    if (FAILED(hr)||s->closed) return hr;
#define EMBED_REGISTER(Type,Interface,Sender,Add,Token,Flag) do { \
        Type *handler=Type##_new(s); if (!handler) return E_OUTOFMEMORY; \
        hr=Interface##_##Add(Sender,&handler->iface,&e->Token); Type##_release(&handler->iface); \
        if (FAILED(hr)) return hr; e->Flag=TRUE; if (s->closed) return S_OK; } while (0)
    EMBED_REGISTER(CursorHandler,ICoreWebView2CompositionController,e->comp,add_CursorChanged,cursor_token,has_cursor);
    EMBED_REGISTER(GotFocusHandler,ICoreWebView2Controller,controller,add_GotFocus,got_token,has_got);
    EMBED_REGISTER(LostFocusHandler,ICoreWebView2Controller,controller,add_LostFocus,lost_token,has_lost);
    EMBED_REGISTER(MoveFocusHandler,ICoreWebView2Controller,controller,add_MoveFocusRequested,move_token,has_move);
#undef EMBED_REGISTER
    HCURSOR cursor=NULL;
    if (SUCCEEDED(ICoreWebView2CompositionController_get_Cursor(e->comp,&cursor))) e->cursor=cursor;
    ICoreWebView2CompositionController2 *comp2=NULL;
    if (SUCCEEDED(ICoreWebView2CompositionController_QueryInterface(e->comp,&IID_ICoreWebView2CompositionController2,(void **)&comp2))&&comp2) {
        IUnknown *provider=NULL;
        if (SUCCEEDED(ICoreWebView2CompositionController2_get_AutomationProvider(comp2,&provider))&&provider&&!s->closed) e->automation=provider;
        else if (provider) IUnknown_Release(provider);
        ICoreWebView2CompositionController2_Release(comp2);
    }
    return S_OK;
}
/* Takes the page out of its window's web layer, and the layer away with
   its last page. */
static void embed_close(State *s) {
    Embed *e=s->embed;
    if (!e) return;
    s->embed=NULL;
    EmbedLayer *l=e->layer;
    if (e->comp) {
        if (e->has_cursor) ICoreWebView2CompositionController_remove_CursorChanged(e->comp,e->cursor_token);
        ICoreWebView2CompositionController_put_RootVisualTarget(e->comp,NULL);
    }
    if (s->controller) {
        if (e->has_got) ICoreWebView2Controller_remove_GotFocus(s->controller,e->got_token);
        if (e->has_lost) ICoreWebView2Controller_remove_LostFocus(s->controller,e->lost_token);
        if (e->has_move) ICoreWebView2Controller_remove_MoveFocusRequested(s->controller,e->move_token);
    }
    if (e->focused&&s->hwnd&&IsWindow(s->hwnd)) SetFocus(s->hwnd);
    if (l) {
        if (l->hover==e) l->hover=NULL;
        if (l->capture==e) { l->capture=NULL;if (l->hwnd&&GetCapture()==l->hwnd) ReleaseCapture(); }
        for (Embed **at=&l->first;*at;at=&(*at)->next) if (*at==e) { *at=e->next;break; }
        if (l->root&&e->clip_visual) ((EmbedCallPtr)embed_vtbl(l->root)[EMBED_VISUAL_REMOVE])(l->root,e->clip_visual);
        embed_commit(l);
    }
    EMBED_RELEASE(e->automation);
    EMBED_RELEASE(e->comp);
    EMBED_RELEASE(e->corners);EMBED_RELEASE(e->web_visual);EMBED_RELEASE(e->clip_visual);
    if (l&&!l->first) embed_layer_free(l);
    free(e);
}

/* Places a page with an Embed: its clip, its frame and the size it lays out
   at, in the window's client pixels, its corners' radii in its own pixels
   from the top-left clockwise, and the boxes the content paints over it. */
static HRESULT embed_apply(State *s);
HRESULT zwv_embed_place(State *s,const float *clip,const float *frame,const float *layout,const float *radii,const float *covers,uint32_t cover_count,_Bool visible,_Bool wheel_to_container) {
    if (!s||s->closed) return HRESULT_FROM_WIN32(ERROR_INVALID_WINDOW_HANDLE);
    Embed *e=s->embed;
    if (!e) return E_NOT_VALID_STATE;
    if (cover_count>EMBED_MAX_COVERS) cover_count=EMBED_MAX_COVERS;
    float cx=floorf(clip[0]+0.5f), cy=floorf(clip[1]+0.5f);
    float cw=floorf(clip[0]+clip[2]+0.5f)-cx, ch=floorf(clip[1]+clip[3]+0.5f)-cy;
    if (cw<0) cw=0;
    if (ch<0) ch=0;
    float width=layout[0]>=1?layout[0]:1, height=layout[1]>=1?layout[1]:1;
    e->clip.left=(LONG)cx;e->clip.top=(LONG)cy;e->clip.right=(LONG)(cx+cw);e->clip.bottom=(LONG)(cy+ch);
    e->at_x=frame[0];e->at_y=frame[1];
    e->scale_x=frame[2]>0?frame[2]/width:1;e->scale_y=frame[3]>0?frame[3]/height:1;
    e->width=width;e->height=height;
    for (int i=0;i<4;i++) e->radii[i]=radii[i]>0?radii[i]:0;
    for (uint32_t i=0;i<cover_count;i++) {
        const float *b=covers+4*i;
        e->covers[i].left=(LONG)floorf(b[0]+0.5f);e->covers[i].top=(LONG)floorf(b[1]+0.5f);
        e->covers[i].right=(LONG)floorf(b[0]+b[2]+0.5f);e->covers[i].bottom=(LONG)floorf(b[1]+b[3]+0.5f);
    }
    e->cover_count=cover_count;
    e->shown=visible&&cw>0&&ch>0;
    e->wheel_to_container=wheel_to_container;
    embed_visual_clip(e->clip_visual,e->shown?cw:0,e->shown?ch:0);
    embed_visual_transform(e->clip_visual,cx,cy,1,1);
    /* The page draws from its visual's origin, scaled to its frame. */
    embed_visual_transform(e->web_visual,e->at_x-cx,e->at_y-cy,e->scale_x,e->scale_y);
    embed_corners(e);
    embed_commit(e->layer);
    e->placed=TRUE;
    if (!e->shown) {
        if (e->layer&&e->layer->hover==e) { embed_leave(e);e->layer->hover=NULL; }
        /* A hidden page keeps no keyboard: it goes back to the window. */
        if (e->focused&&s->hwnd) SetFocus(s->hwnd);
    }
    return embed_apply(s);
}
/* Gives the controller the page's placement: its bounds, which place what
   WebView2 shows in windows of its own, and whether it shows. Before the
   first placement the page stays hidden. */
static HRESULT embed_apply(State *s) {
    Embed *e=s->embed;
    ICoreWebView2Controller *controller=s->controller;
    if (!e||!controller) return S_OK;
    float width=e->width, height=e->height;
    BOOL show=e->placed&&e->shown;
    ICoreWebView2Controller_AddRef(controller);
    HRESULT hr=S_OK;
    if (show) {
        /* Its bounds, in the window's pixels, place what WebView2 shows in
           windows of its own, as a select's options. */
        RECT bounds={(LONG)floorf(e->at_x+0.5f),(LONG)floorf(e->at_y+0.5f),(LONG)floorf(e->at_x+0.5f)+(LONG)width,(LONG)floorf(e->at_y+0.5f)+(LONG)height};
        RECT previous={0};
        if (SUCCEEDED(ICoreWebView2Controller_get_Bounds(controller,&previous))&&!EqualRect(&previous,&bounds)) hr=ICoreWebView2Controller_put_Bounds(controller,bounds);
    }
    BOOL was=FALSE;
    if (SUCCEEDED(hr)&&!s->closed&&SUCCEEDED(ICoreWebView2Controller_get_IsVisible(controller,&was))&&was!=show) hr=ICoreWebView2Controller_put_IsVisible(controller,show);
    if (SUCCEEDED(hr)&&s->closed) hr=HRESULT_FROM_WIN32(ERROR_INVALID_WINDOW_HANDLE);
    ICoreWebView2Controller_Release(controller);
    return hr;
}
/* Gives the page the keyboard at its first element, or its last going
   back. */
HRESULT zwv_embed_tab_into(State *s,_Bool back) {
    if (!s||s->closed) return HRESULT_FROM_WIN32(ERROR_INVALID_WINDOW_HANDLE);
    if (!s->embed||!s->controller) return E_NOT_VALID_STATE;
    if (!s->embed->shown) return S_OK;
    return ICoreWebView2Controller_MoveFocus(s->controller,back?COREWEBVIEW2_MOVE_FOCUS_REASON_PREVIOUS:COREWEBVIEW2_MOVE_FOCUS_REASON_NEXT);
}
int zwv_embed_focused(State *s) { return s&&!s->closed&&s->embed&&s->embed->focused; }
/* WebView2's UI Automation provider of the page, which the page keeps, or
   NULL. */
void *zwv_embed_automation(State *s) { return s&&!s->closed&&s->embed?s->embed->automation:NULL; }
int zwv_embed_composed(State *s) { return s&&s->embed&&s->embed->comp; }
/* Test hook: the controller's bounds, in the window's client pixels, and
   whether it shows. */
HRESULT zwv_embed_test_bounds(State *s,int32_t *out,int *visible) {
    if (!s||s->closed||!s->controller) return E_NOT_VALID_STATE;
    RECT r={0}; BOOL shown=FALSE;
    HRESULT hr=ICoreWebView2Controller_get_Bounds(s->controller,&r);
    if (SUCCEEDED(hr)) hr=ICoreWebView2Controller_get_IsVisible(s->controller,&shown);
    out[0]=r.left;out[1]=r.top;out[2]=r.right;out[3]=r.bottom;*visible=shown!=0;
    return hr;
}
