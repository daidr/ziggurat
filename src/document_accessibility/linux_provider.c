#include "linux_internal.h"
#include <limits.h>
#include <math.h>
#include <string.h>

static void text_interface(AtkTextIface *);
static void component_interface(AtkComponentIface *);
G_DEFINE_TYPE_WITH_CODE(ZdaNative,zda_linux_provider,ATK_TYPE_OBJECT,
    G_IMPLEMENT_INTERFACE(ATK_TYPE_TEXT,text_interface)
    G_IMPLEMENT_INTERFACE(ATK_TYPE_COMPONENT,component_interface))

static gboolean readable(ZdaNative *state) {
    return zda_linux_owner(state) && !state->closed && state->ready && state->text;
}
static gboolean visible(ZdaNative *state) {
    return readable(state) && !state->composing && state->geometry &&
        state->geometry->version==state->text->version && state->geometry->scale==state->scale &&
        (state->position_flags&ZLG_ACCESSIBILITY_EXTENT);
}
static void provider_dispose(GObject *object) {
    ZdaNative *state=(ZdaNative *)object;
    /* Explicit g_object_run_dispose may precede Bridge.close. It revokes native
     * ingress but does not consume the Bridge's initial owning GObject ref. */
    zda_linux_mark(state);
    ZlgAccessibilityBinding *binding=state->binding; state->binding=NULL;
    if (binding) { zlg_accessibility_withdraw(binding); zlg_accessibility_release(binding); }
    if (state->account) { zda_account_close(state->account); zda_linux_drop_current(state); }
    G_OBJECT_CLASS(zda_linux_provider_parent_class)->dispose(object);
}
static void provider_finalize(GObject *object) {
    ZdaNative *state=(ZdaNative *)object;
    ZdaAccount *account=state->account;
    G_OBJECT_CLASS(zda_linux_provider_parent_class)->finalize(object);
    if (account) { zda_linux_object_release(account,sizeof(ZdaNative)); zda_account_release(account); }
}
static AtkStateSet *provider_states(AtkObject *object) {
    ZdaNative *state=(ZdaNative *)object;
    if (!zda_linux_owner(state)) return NULL;
    AtkStateSet *set=ATK_OBJECT_CLASS(zda_linux_provider_parent_class)->ref_state_set(object);
    if (state->closed) atk_state_set_add_state(set,ATK_STATE_DEFUNCT);
    else {
        atk_state_set_add_state(set,ATK_STATE_READ_ONLY);
        atk_state_set_add_state(set,ATK_STATE_MULTI_LINE);
        if (!state->ready) atk_state_set_add_state(set,ATK_STATE_STALE);
        if (state->enabled) { atk_state_set_add_state(set,ATK_STATE_ENABLED); atk_state_set_add_state(set,ATK_STATE_SENSITIVE); }
        /* Extent alone is also available while hidden. The first port only
         * claims showing when the cached X11 origin proves a mapped area;
         * extent-only platforms conservatively omit these two states. */
        if (visible(state) && (state->position_flags &
                (ZLG_ACCESSIBILITY_WINDOW_ORIGIN|ZLG_ACCESSIBILITY_SCREEN_ORIGIN))) {
            atk_state_set_add_state(set,ATK_STATE_VISIBLE);
            atk_state_set_add_state(set,ATK_STATE_SHOWING);
        }
    }
    return set;
}
static void zda_linux_provider_class_init(ZdaNativeClass *klass) {
    G_OBJECT_CLASS(klass)->dispose=provider_dispose;
    G_OBJECT_CLASS(klass)->finalize=provider_finalize;
    ATK_OBJECT_CLASS(klass)->ref_state_set=provider_states;
}
static void zda_linux_provider_init(ZdaNative *state) { state->owner=g_thread_self(); }

int zda_linux_create(const ZdaSource *sources, uint32_t count, uint64_t bytes,
    uint32_t ranges, uint32_t outputs, ZdaError *error, ZdaNative **out) {
    if (error) { error->domain=0; error->code=0; }
    if (!out) return ZDA_INVALID;
    *out=NULL;
    if (!sources || count!=1 || !outputs || outputs>UINT32_C(67108864) ||
        sources->read_only!=1 || sources->selectable || sources->focusable || sources->scrollable ||
        sources->name_length>=128 || (sources->name_length && !sources->name)) return ZDA_INVALID;
    char name[128*3+1]; size_t used=0;
    for (uint32_t at=0;at<sources->name_length;) {
        uint32_t ch=sources->name[at++];
        if (!ch) return ZDA_INVALID;
        if (ch>=0xd800 && ch<=0xdbff) {
            if (at==sources->name_length || sources->name[at]<0xdc00 || sources->name[at]>0xdfff) return ZDA_INVALID;
            ch=0x10000+((ch-0xd800)<<10)+(sources->name[at++]-0xdc00);
        } else if (ch>=0xdc00 && ch<=0xdfff) return ZDA_INVALID;
        used+=(size_t)g_unichar_to_utf8(ch,name+used);
    }
    name[used]=0;
    ZdaAccount *account=NULL;
    int result=zda_account_create(bytes,ranges,&account);
    if (result) return result;
    result=zda_linux_object_reserve(account,sizeof(ZdaNative));
    if (result) { zda_account_release(account); return result; }
    /* This is SDK GObject allocation, not our fallible block allocator. No
     * Window pointer crosses it. The initial ref owns the account on return. */
    ZdaNative *state=g_object_new(zda_linux_provider_get_type(),NULL);
    if (!state) { zda_linux_object_release(account,sizeof(ZdaNative)); zda_account_release(account); return ZDA_OOM; }
    state->account=account; state->output_units=outputs;
    atk_object_set_role(ATK_OBJECT(state),ATK_ROLE_DOCUMENT_TEXT);
    atk_object_set_name(ATK_OBJECT(state),name);
    if (state->closed) { g_object_unref(state); return ZDA_CLOSED; }
    *out=state; return ZDA_OK;
}
static int host_result(int code) {
    switch (code) {
        case ZLG_ACCESSIBILITY_OK: return ZDA_OK;
        case ZLG_ACCESSIBILITY_CLOSED: return ZDA_CLOSED;
        case ZLG_ACCESSIBILITY_BUSY: return ZDA_LINUX_BUSY;
        case ZLG_ACCESSIBILITY_OOM: return ZDA_OOM;
        case ZLG_ACCESSIBILITY_UNSUPPORTED: return ZDA_LINUX_UNSUPPORTED;
        default: return ZDA_INVALID;
    }
}
int zda_linux_prepare(ZdaNative *state, void *native) {
    int result=zda_linux_live(state);
    if (result) return result;
    if (state->binding) return ZDA_LINUX_BUSY;
    ZlgAccessibilityBinding *binding=NULL;
    result=host_result(zlg_accessibility_prepare(native,state,zda_linux_mark,&binding));
    if (result) return result;
    state->binding=binding;
    return ZDA_OK;
}
int zda_linux_mount(ZdaNative *state) {
    int result=zda_linux_live(state);
    if (result) return result;
    if (!state->binding) return ZDA_INVALID;
    zda_linux_retain(state);
    result=host_result(zlg_accessibility_mount(state->binding));
    if (!result && state->closed) result=ZDA_CLOSED;
    zda_linux_release(state); return result;
}
int32_t zda_native_disconnect(ZdaNative *state) {
    if (!zda_linux_owner(state)) return ZDA_INVALID;
    zda_linux_retain(state);
    zda_native_begin_close(state);
    ZlgAccessibilityBinding *binding=state->binding; state->binding=NULL;
    if (binding) { zlg_accessibility_withdraw(binding); zlg_accessibility_release(binding); }
    zda_linux_drop_current(state);
    atk_object_notify_state_change(ATK_OBJECT(state),ATK_STATE_DEFUNCT,TRUE);
    zda_linux_release(state); /* Bridge initial ownership. */
    zda_linux_release(state); /* Invocation pin. */
    return ZDA_OK;
}
void *zda_native_provider(ZdaNative *state, uint32_t source) {
    if (!zda_linux_owner(state) || state->closed || (source!=0 && source!=UINT32_MAX)) return NULL;
    return g_object_ref(state);
}
void zda_linux_notify_text(ZdaNative *state, uint32_t removed, const char *old_text, uint32_t inserted, const char *new_text) {
    if (removed) g_signal_emit_by_name(state,"text-remove::system",0,(gint)removed,old_text);
    if (!state->closed && inserted) g_signal_emit_by_name(state,"text-insert::system",0,(gint)inserted,new_text);
}
void zda_linux_notify_geometry(ZdaNative *state) {
    if (!state->closed) g_signal_emit_by_name(state,"visible-data-changed");
}

static gchar *text_get(AtkText *object, gint start, gint end) {
    ZdaNative *state=(ZdaNative *)object;
    if (!readable(state) || start<0 || end< -1) return NULL;
    uint32_t count=state->text->scalar_count-1;
    if (end==-1) end=(gint)count;
    if (start>end || (uint32_t)end>count) return NULL;
    int error;
    return zda_linux_utf8(state->text,state->text->scalars[start],state->text->scalars[end],NULL,&error);
}
static gint text_count(AtkText *object) { ZdaNative *state=(ZdaNative *)object; return readable(state)?(gint)(state->text->scalar_count-1):-1; }
static gunichar text_character(AtkText *object, gint offset) {
    ZdaNative *state=(ZdaNative *)object;
    if (!readable(state) || offset<0 || (uint32_t)offset>=state->text->scalar_count-1) return 0;
    uint32_t at=state->text->scalars[offset], ch=state->text->text[at++];
    if (ch>=0xd800 && ch<=0xdbff) ch=0x10000+((ch-0xd800)<<10)+(state->text->text[at]-0xdc00);
    return ch;
}
static gchar *text_string(AtkText *object, gint offset, AtkTextGranularity unit, gint *start, gint *end) {
    *start=-1; *end=-1;
    if (unit!=ATK_TEXT_GRANULARITY_CHAR || offset<0 || offset>=text_count(object)) return NULL;
    gchar *text=text_get(object,offset,offset+1);
    if (text) { *start=offset; *end=offset+1; }
    return text;
}
static gchar *text_unsupported_boundary(AtkText *object, gint offset, AtkTextBoundary unit, gint *start, gint *end) {
    (void)object; (void)offset; (void)unit; *start=-1; *end=-1; return NULL;
}
static gint text_caret(AtkText *object) {
    ZdaNative *state=(ZdaNative *)object;
    return readable(state)?zda_linux_scalar(state->text,state->caret):-1;
}
static gint text_selection_count(AtkText *object) { (void)object; return 0; }
static gchar *text_selection(AtkText *object, gint index, gint *start, gint *end) {
    (void)object; (void)index; *start=-1; *end=-1; return NULL;
}
static gboolean text_add_selection(AtkText *object, gint start, gint end) { (void)object; (void)start; (void)end; return FALSE; }
static gboolean text_remove_selection(AtkText *object, gint index) { (void)object; (void)index; return FALSE; }
static gboolean text_set_selection(AtkText *object, gint index, gint start, gint end) { (void)object; (void)index; (void)start; (void)end; return FALSE; }
static gboolean text_set_caret(AtkText *object, gint offset) { (void)object; (void)offset; return FALSE; }
static AtkAttributeSet *text_attributes(AtkText *object, gint offset, gint *start, gint *end) {
    (void)object; (void)offset; *start=-1; *end=-1; return NULL;
}
static AtkAttributeSet *text_defaults(AtkText *object) { (void)object; return NULL; }
static AtkTextRange **text_bounded(AtkText *object, AtkTextRectangle *rectangle, AtkCoordType coords, AtkTextClipType x, AtkTextClipType y) {
    (void)object; (void)rectangle; (void)coords; (void)x; (void)y; return NULL;
}
static gboolean text_scroll(AtkText *object, gint start, gint end, AtkScrollType type) { (void)object; (void)start; (void)end; (void)type; return FALSE; }
static gboolean text_scroll_point(AtkText *object, gint start, gint end, AtkCoordType coords, gint x, gint y) {
    (void)object; (void)start; (void)end; (void)coords; (void)x; (void)y; return FALSE;
}
static gboolean origin(ZdaNative *state, AtkCoordType coords, double *x, double *y) {
    if (!visible(state)) return FALSE;
    if (coords==ATK_XY_PARENT) { *x=0; *y=0; return TRUE; }
    if (coords==ATK_XY_WINDOW && (state->position_flags&ZLG_ACCESSIBILITY_WINDOW_ORIGIN)) { *x=state->window_x; *y=state->window_y; return TRUE; }
    if (coords==ATK_XY_SCREEN && (state->position_flags&ZLG_ACCESSIBILITY_SCREEN_ORIGIN)) { *x=state->screen_x; *y=state->screen_y; return TRUE; }
    return FALSE;
}
static gboolean clipped(ZdaNative *state, ZdaRect source, ZdaRect *out) {
    ZdaRect bounds=state->geometry->bounds;
    double left=fmax(0,fmax(bounds.x,source.x)), top=fmax(0,fmax(bounds.y,source.y));
    double right=fmin((double)state->area_width,fmin(bounds.x+bounds.width,source.x+source.width));
    double bottom=fmin((double)state->area_height,fmin(bounds.y+bounds.height,source.y+source.height));
    if (right<left || bottom<=top || (right==left && source.width!=0)) return FALSE;
    *out=(ZdaRect){left,top,right-left,bottom-top}; return TRUE;
}
static gboolean integer_rect(ZdaRect rect, double x, double y, gint *rx, gint *ry, gint *width, gint *height) {
    double left=floor(rect.x+x), top=floor(rect.y+y);
    double right=rect.width==0?left:ceil(rect.x+rect.width+x), bottom=ceil(rect.y+rect.height+y);
    if (!isfinite(left) || !isfinite(top) || left<INT_MIN || top<INT_MIN || right>INT_MAX || bottom>INT_MAX ||
        right-left>INT_MAX || bottom-top>INT_MAX) return FALSE;
    *rx=(gint)left; *ry=(gint)top; *width=(gint)(right-left); *height=(gint)(bottom-top); return TRUE;
}
static gboolean range_rect(ZdaNative *state, uint32_t start, uint32_t end, ZdaRect *out) {
    gboolean found=FALSE;
    for (uint32_t i=0;i<state->geometry->cell_count;++i) {
        const ZdaCell *cell=&state->geometry->cells[i];
        if (cell->end<=start || cell->start>=end) continue;
        ZdaRect rect;
        if (!clipped(state,cell->rectangle,&rect)) continue;
        if (!found) { *out=rect; found=TRUE; }
        else {
            double right=fmax(out->x+out->width,rect.x+rect.width), bottom=fmax(out->y+out->height,rect.y+rect.height);
            out->x=fmin(out->x,rect.x); out->y=fmin(out->y,rect.y);
            out->width=right-out->x; out->height=bottom-out->y;
        }
    }
    return found;
}
static void text_extents(AtkText *object, gint offset, gint *x, gint *y, gint *width, gint *height, AtkCoordType coords) {
    *x=-1; *y=-1; *width=-1; *height=-1;
    ZdaNative *state=(ZdaNative *)object;
    double ox,oy;
    if (!origin(state,coords,&ox,&oy) || offset<0 || (uint32_t)offset>=state->text->scalar_count) return;
    uint32_t unit=state->text->scalars[offset]; ZdaRect rect;
    gboolean found=FALSE;
    if ((uint32_t)offset==state->text->scalar_count-1) {
        for (uint32_t i=0;i<state->geometry->caret_count;++i) if (state->geometry->carets[i].position==unit &&
            clipped(state,state->geometry->carets[i].rectangle,&rect)) { found=TRUE; if (state->geometry->carets[i].affinity==1) break; }
    } else found=range_rect(state,unit,state->text->scalars[offset+1],&rect);
    if (found) integer_rect(rect,ox,oy,x,y,width,height);
}
static void text_range_extents(AtkText *object, gint start, gint end, AtkCoordType coords, AtkTextRectangle *out) {
    *out=(AtkTextRectangle){-1,-1,-1,-1};
    ZdaNative *state=(ZdaNative *)object; double ox,oy;
    if (!origin(state,coords,&ox,&oy) || start<0 || end<=start || (uint32_t)end>=state->text->scalar_count) return;
    ZdaRect rect;
    if (range_rect(state,state->text->scalars[start],state->text->scalars[end],&rect))
        integer_rect(rect,ox,oy,&out->x,&out->y,&out->width,&out->height);
}
static gint text_point(AtkText *object, gint x, gint y, AtkCoordType coords) {
    ZdaNative *state=(ZdaNative *)object; double ox,oy;
    if (!origin(state,coords,&ox,&oy)) return -1;
    double px=x-ox, py=y-oy; ZdaRect bounds;
    if (!clipped(state,state->geometry->bounds,&bounds) || px<bounds.x || px>=bounds.x+bounds.width || py<bounds.y || py>=bounds.y+bounds.height) return -1;
    const ZdaHitInput *hit=state->geometry->hit;
    if (!hit) return -1;
    if (hit->domain) {
        gboolean allowed=FALSE;
        for (uint32_t i=0;i<state->geometry->line_count;++i) {
            ZdaRect line;
            if (clipped(state,state->geometry->lines[i].rectangle,&line) &&
                px>=line.x && px<line.x+line.width && py>=line.y && py<line.y+line.height) { allowed=TRUE; break; }
        }
        if (!allowed) return -1;
    }
    /* The owned packet retains complete native stops and original block /
     * placement parameters. No visible-table approximation or owner callback. */
    ZdeHitResult result;
    if (zde_prepared_hit_query(&hit->packet,(float)px,(float)py,&result)) return -1;
    return zda_linux_scalar(state->text,(uint32_t)result.position);
}
static void component_extents(AtkComponent *object, gint *x, gint *y, gint *width, gint *height, AtkCoordType coords) {
    *x=-1; *y=-1; *width=-1; *height=-1;
    ZdaNative *state=(ZdaNative *)object; double ox,oy; ZdaRect rect;
    if (origin(state,coords,&ox,&oy) && clipped(state,state->geometry->bounds,&rect)) integer_rect(rect,ox,oy,x,y,width,height);
}
static gboolean component_contains(AtkComponent *object, gint x, gint y, AtkCoordType coords) {
    ZdaNative *state=(ZdaNative *)object; double ox,oy; ZdaRect rect;
    return origin(state,coords,&ox,&oy) && clipped(state,state->geometry->bounds,&rect) &&
        x-ox>=rect.x && x-ox<rect.x+rect.width && y-oy>=rect.y && y-oy<rect.y+rect.height;
}
static AtkObject *component_at_point(AtkComponent *object, gint x, gint y, AtkCoordType coords) { (void)object; (void)x; (void)y; (void)coords; return NULL; }
static gboolean component_focus(AtkComponent *object) { (void)object; return FALSE; }
static gboolean component_set_extents(AtkComponent *object, gint x, gint y, gint width, gint height, AtkCoordType coords) { (void)object; (void)x; (void)y; (void)width; (void)height; (void)coords; return FALSE; }
static gboolean component_set_position(AtkComponent *object, gint x, gint y, AtkCoordType coords) { (void)object; (void)x; (void)y; (void)coords; return FALSE; }
static gboolean component_set_size(AtkComponent *object, gint width, gint height) { (void)object; (void)width; (void)height; return FALSE; }
static AtkLayer component_layer(AtkComponent *object) { (void)object; return ATK_LAYER_WIDGET; }
static gint component_order(AtkComponent *object) { (void)object; return 0; }
static gdouble component_alpha(AtkComponent *object) { (void)object; return 1; }
static gboolean component_scroll(AtkComponent *object, AtkScrollType type) { (void)object; (void)type; return FALSE; }
static gboolean component_scroll_point(AtkComponent *object, AtkCoordType coords, gint x, gint y) { (void)object; (void)coords; (void)x; (void)y; return FALSE; }
static void text_interface(AtkTextIface *text) {
    text->get_text=text_get; text->get_character_at_offset=text_character;
    text->get_character_count=text_count; text->get_string_at_offset=text_string;
    text->get_text_before_offset=text_unsupported_boundary; text->get_text_at_offset=text_unsupported_boundary; text->get_text_after_offset=text_unsupported_boundary;
    text->get_caret_offset=text_caret; text->get_n_selections=text_selection_count; text->get_selection=text_selection;
    text->add_selection=text_add_selection; text->remove_selection=text_remove_selection; text->set_selection=text_set_selection; text->set_caret_offset=text_set_caret;
    text->get_run_attributes=text_attributes; text->get_default_attributes=text_defaults;
    text->get_character_extents=text_extents; text->get_range_extents=text_range_extents; text->get_offset_at_point=text_point;
    text->get_bounded_ranges=text_bounded; text->scroll_substring_to=text_scroll; text->scroll_substring_to_point=text_scroll_point;
}
static void component_interface(AtkComponentIface *component) {
    component->get_extents=component_extents; component->contains=component_contains;
    component->ref_accessible_at_point=component_at_point; component->grab_focus=component_focus;
    component->set_extents=component_set_extents; component->set_position=component_set_position; component->set_size=component_set_size;
    component->get_layer=component_layer; component->get_mdi_zorder=component_order; component->get_alpha=component_alpha;
    component->scroll_to=component_scroll; component->scroll_to_point=component_scroll_point;
}
