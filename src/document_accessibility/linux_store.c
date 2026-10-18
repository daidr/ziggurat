#include "linux_internal.h"
#include <math.h>
#include <string.h>

gboolean zda_linux_owner(const ZdaNative *state) { return state && state->owner==g_thread_self(); }
void zda_linux_retain(ZdaNative *state) { g_object_ref(state); }
void zda_linux_release(ZdaNative *state) { g_object_unref(state); }
int zda_linux_live(ZdaNative *state) {
    if (!zda_linux_owner(state)) return ZDA_INVALID;
    return state->closed?ZDA_CLOSED:ZDA_OK;
}
void zda_text_retain(ZdaText *text) { if (text) atomic_fetch_add(&text->refs,1); }
void zda_text_release(ZdaText *text) { if (text && atomic_fetch_sub(&text->refs,1)==1) zda_storage_release(text); }
void zda_geometry_retain(ZdaGeometry *geometry) { if (geometry) atomic_fetch_add(&geometry->refs,1); }
void zda_geometry_release(ZdaGeometry *geometry) { if (geometry && atomic_fetch_sub(&geometry->refs,1)==1) zda_storage_release(geometry); }
void zda_native_stats(ZdaNative *state, ZdaStats *out) { zda_account_stats(state->account,out); }
ZdaAccount *zda_native_account(ZdaNative *state) { zda_account_retain(state->account); return state->account; }
int32_t zda_linux_scalar(const ZdaText *text, uint32_t unit) {
    uint32_t lo=0, hi=text->scalar_count;
    while (lo<hi) { uint32_t mid=lo+(hi-lo)/2; if (text->scalars[mid]<unit) lo=mid+1; else hi=mid; }
    return lo<text->scalar_count && text->scalars[lo]==unit?(int32_t)lo:-1;
}
gboolean zda_linux_boundary(const ZdaText *text, uint32_t unit) { return zda_linux_scalar(text,unit)>=0; }
static gboolean sum(size_t *bytes, size_t count, size_t unit, size_t alignment) {
    if (*bytes>SIZE_MAX-(alignment-1)) return FALSE;
    size_t start=(*bytes+alignment-1)&~(alignment-1);
    if (count>(SIZE_MAX-start)/unit) return FALSE;
    *bytes=start+count*unit; return TRUE;
}
int zda_native_text(ZdaNative *state, const ZdaTextInput *input, ZdaText **out) {
    if (!out) return ZDA_INVALID;
    *out=NULL;
    int result=zda_linux_live(state);
    if (result) return result;
    if (!input || input->text_length>state->output_units ||
        (input->text_length && !input->text) || !input->scalars || !input->scalar_count ||
        input->scalar_count>input->text_length+1 || !input->paragraphs ||
        input->paragraph_count<2 || input->paragraph_count>input->text_length+2) return ZDA_INVALID;
    uint32_t scalar=0, paragraph=1;
    for (uint32_t at=0;at<input->text_length;) {
        if (scalar>=input->scalar_count || input->scalars[scalar++]!=at) return ZDA_INVALID;
        uint16_t ch=input->text[at++];
        if (!ch) return ZDA_INVALID; /* NUL has no faithful ATK string encoding. */
        if (ch>=0xd800 && ch<=0xdbff) {
            if (at==input->text_length || input->text[at]<0xdc00 || input->text[at++]>0xdfff) return ZDA_INVALID;
        } else if (ch>=0xdc00 && ch<=0xdfff) return ZDA_INVALID;
    }
    if (scalar+1!=input->scalar_count || input->scalars[scalar]!=input->text_length ||
        input->paragraphs[0]!=0 || input->paragraphs[input->paragraph_count-1]!=input->text_length) return ZDA_INVALID;
    for (uint32_t at=0;at<input->text_length;++at) if (input->text[at]=='\n') {
        if (paragraph>=input->paragraph_count || input->paragraphs[paragraph++]!=at+1) return ZDA_INVALID;
    }
    if (paragraph+1!=input->paragraph_count) return ZDA_INVALID;
    size_t bytes=sizeof(ZdaText);
    if (!sum(&bytes,input->text_length,sizeof(uint16_t),_Alignof(uint16_t))) return ZDA_CAPACITY;
    size_t scalars=(bytes+3)&~(size_t)3;
    if (!sum(&bytes,input->scalar_count,sizeof(uint32_t),_Alignof(uint32_t))) return ZDA_CAPACITY;
    size_t paragraphs=bytes;
    if (!sum(&bytes,input->paragraph_count,sizeof(uint32_t),_Alignof(uint32_t))) return ZDA_CAPACITY;
    ZdaText *text=NULL;
    result=zda_storage_create(state->account,ZDA_BLOB,bytes,(void **)&text);
    if (result) return result;
    memset(text,0,sizeof(*text)); atomic_init(&text->refs,1);
    text->account=state->account;
    text->version=input->text_version; text->length=input->text_length;
    text->scalar_count=input->scalar_count; text->paragraph_count=input->paragraph_count;
    text->text=(uint16_t *)(text+1); text->scalars=(uint32_t *)((char *)text+scalars);
    text->paragraphs=(uint32_t *)((char *)text+paragraphs);
    if (text->length) memcpy(text->text,input->text,text->length*sizeof(uint16_t));
    memcpy(text->scalars,input->scalars,text->scalar_count*sizeof(uint32_t));
    memcpy(text->paragraphs,input->paragraphs,text->paragraph_count*sizeof(uint32_t));
    *out=text; return ZDA_OK;
}
static uint32_t scalar_at(const ZdaText *text, uint32_t *at) {
    uint32_t ch=text->text[(*at)++];
    if (ch>=0xd800 && ch<=0xdbff) ch=0x10000+((ch-0xd800)<<10)+(text->text[(*at)++]-0xdc00);
    return ch;
}
/* Account != NULL is charged temporary notification storage. Otherwise this
 * is an independent GLib caller-owned output, freed with g_free by its caller. */
char *zda_linux_utf8(const ZdaText *text, uint32_t start, uint32_t end, ZdaAccount *account, int *error) {
    *error=ZDA_INVALID;
    if (!text || start>end || end>text->length || !zda_linux_boundary(text,start) || !zda_linux_boundary(text,end)) return NULL;
    size_t bytes=1;
    for (uint32_t at=start;at<end;) {
        uint32_t ch=scalar_at(text,&at);
        size_t count=ch<0x80?1:ch<0x800?2:ch<0x10000?3:4;
        if (bytes>SIZE_MAX-count) { *error=ZDA_CAPACITY; return NULL; }
        bytes+=count;
    }
    char *result=NULL;
    if (account) *error=zda_storage_create(account,ZDA_BLOB,bytes,(void **)&result);
    else { result=zda_linux_allocate(bytes); *error=result?ZDA_OK:ZDA_OOM; }
    if (!result) return NULL;
    size_t offset=0;
    for (uint32_t at=start;at<end;) offset+=(size_t)g_unichar_to_utf8(scalar_at(text,&at),result+offset);
    result[offset]=0; return result;
}
static gboolean rect_valid(ZdaRect rect) {
    return isfinite(rect.x) && isfinite(rect.y) && isfinite(rect.width) && isfinite(rect.height) &&
        fabs(rect.x)<=1e12 && fabs(rect.y)<=1e12 && rect.width>=0 && rect.height>=0 && rect.width<=1e12 && rect.height<=1e12;
}
static int geometry_create(ZdaNative *state, const ZdaGeometryInput *input, const ZdaHitInput *hit, ZdaGeometry **out) {
    if (!out) return ZDA_INVALID;
    *out=NULL;
    int result=zda_linux_live(state);
    if (result) return result;
    if (!state->ready || !state->text) return ZDA_UNAVAILABLE;
    if (!input || input->text_version!=state->text->version ||
        !rect_valid(input->bounds) || !isfinite(input->scale) || input->scale<=0 || input->scale>16 ||
        input->cell_count>16384 || input->caret_count>32768 || input->line_count>4096 ||
        (input->cell_count && !input->cells) || (input->caret_count && !input->carets) ||
        (input->line_count && !input->lines)) return ZDA_INVALID;
    for (uint32_t i=0;i<input->cell_count;++i) {
        const ZdaCell *cell=&input->cells[i];
        if (cell->start>cell->end || !zda_linux_boundary(state->text,cell->start) ||
            !zda_linux_boundary(state->text,cell->end) || !rect_valid(cell->rectangle)) return ZDA_INVALID;
    }
    uint32_t covered=0;
    for (uint32_t i=0;i<input->line_count;++i) {
        const ZdaLine *line=&input->lines[i];
        if (!rect_valid(line->rectangle) || line->rectangle.height<=0 || !line->count ||
            line->first!=covered || line->count>input->caret_count-covered) return ZDA_INVALID;
        for (uint32_t j=0;j<line->count;++j) {
            const ZdaCaret *caret=&input->carets[covered+j];
            if (caret->affinity>1 || !rect_valid(caret->rectangle) || caret->rectangle.height<=0 ||
                !zda_linux_boundary(state->text,caret->position)) return ZDA_INVALID;
            if (j) {
                const ZdaCaret *previous=caret-1;
                if (previous->rectangle.x>caret->rectangle.x || (previous->rectangle.x==caret->rectangle.x &&
                    (previous->position>caret->position || (previous->position==caret->position && previous->affinity<caret->affinity)))) return ZDA_INVALID;
            }
        }
        covered+=line->count;
    }
    if (covered!=input->caret_count) return ZDA_INVALID;
    if (hit) {
        if (hit->reserved || hit->domain>1 || hit->text_version!=input->text_version ||
            hit->projection_version!=input->projection_version || hit->scale!=input->scale ||
            (double)hit->packet.bounds.x!=input->bounds.x || (double)hit->packet.bounds.y!=input->bounds.y ||
            (double)hit->packet.bounds.width!=input->bounds.width || (double)hit->packet.bounds.height!=input->bounds.height) return ZDA_INVALID;
        result=zde_prepared_hit_validate(&hit->packet,32768,4096,UINT64_C(1048576),state->text->length);
        if (result) return result;
        for (uint32_t i=0;i<hit->packet.stop_count;++i)
            if (!zda_linux_boundary(state->text,(uint32_t)hit->packet.stops[i].position)) return ZDA_INVALID;
    }
    _Static_assert(sizeof(ZdaGeometry)%_Alignof(ZdaCell)==0,"geometry alignment");
    size_t bytes=sizeof(ZdaGeometry);
    if (!sum(&bytes,input->cell_count,sizeof(ZdaCell),_Alignof(ZdaCell))) return ZDA_CAPACITY;
    size_t carets=bytes;
    if (!sum(&bytes,input->caret_count,sizeof(ZdaCaret),_Alignof(ZdaCaret))) return ZDA_CAPACITY;
    size_t lines=bytes;
    if (!sum(&bytes,input->line_count,sizeof(ZdaLine),_Alignof(ZdaLine))) return ZDA_CAPACITY;
    size_t hit_header=0,hit_blocks=0,hit_lines=0,hit_stops=0,hit_placements=0;
    if (hit) {
        hit_header=bytes;
        if (!sum(&bytes,1,sizeof(ZdaHitInput),_Alignof(ZdaHitInput))) return ZDA_CAPACITY;
        hit_blocks=bytes;
        if (!sum(&bytes,hit->packet.block_count,sizeof(ZdeHitBlock),_Alignof(ZdeHitBlock))) return ZDA_CAPACITY;
        hit_lines=bytes;
        if (!sum(&bytes,hit->packet.line_count,sizeof(ZdeHitLine),_Alignof(ZdeHitLine))) return ZDA_CAPACITY;
        hit_stops=bytes;
        if (!sum(&bytes,hit->packet.stop_count,sizeof(ZdeHitStop),_Alignof(ZdeHitStop))) return ZDA_CAPACITY;
        hit_placements=bytes;
        if (!sum(&bytes,hit->packet.placement_count,sizeof(ZdeHitPlacement),_Alignof(ZdeHitPlacement))) return ZDA_CAPACITY;
    }
    ZdaGeometry *geometry=NULL;
    result=zda_storage_create(state->account,ZDA_BLOB,bytes,(void **)&geometry);
    if (result) return result;
    memset(geometry,0,sizeof(*geometry)); atomic_init(&geometry->refs,1);
    geometry->account=state->account;
    geometry->version=input->text_version; geometry->projection_version=input->projection_version;
    geometry->scale=input->scale; geometry->bounds=input->bounds;
    geometry->cell_count=input->cell_count; geometry->caret_count=input->caret_count; geometry->line_count=input->line_count;
    geometry->cells=(ZdaCell *)(geometry+1); geometry->carets=(ZdaCaret *)((char *)geometry+carets);
    geometry->lines=(ZdaLine *)((char *)geometry+lines);
    if (geometry->cell_count) memcpy(geometry->cells,input->cells,geometry->cell_count*sizeof(ZdaCell));
    if (geometry->caret_count) memcpy(geometry->carets,input->carets,geometry->caret_count*sizeof(ZdaCaret));
    if (geometry->line_count) memcpy(geometry->lines,input->lines,geometry->line_count*sizeof(ZdaLine));
    if (hit) {
        ZdaHitInput *owned=(ZdaHitInput *)((char *)geometry+hit_header);
        *owned=*hit;
        owned->packet.blocks=(ZdeHitBlock *)((char *)geometry+hit_blocks);
        owned->packet.lines=(ZdeHitLine *)((char *)geometry+hit_lines);
        owned->packet.stops=(ZdeHitStop *)((char *)geometry+hit_stops);
        owned->packet.placements=hit->packet.placement_count?(ZdeHitPlacement *)((char *)geometry+hit_placements):NULL;
        memcpy((void *)owned->packet.blocks,hit->packet.blocks,hit->packet.block_count*sizeof(ZdeHitBlock));
        memcpy((void *)owned->packet.lines,hit->packet.lines,hit->packet.line_count*sizeof(ZdeHitLine));
        memcpy((void *)owned->packet.stops,hit->packet.stops,hit->packet.stop_count*sizeof(ZdeHitStop));
        if (hit->packet.placement_count) memcpy((void *)owned->packet.placements,hit->packet.placements,hit->packet.placement_count*sizeof(ZdeHitPlacement));
        geometry->hit=owned;
    }
    *out=geometry; return ZDA_OK;
}
int zda_native_geometry(ZdaNative *state,const ZdaGeometryInput *input,ZdaGeometry **out) {
    return geometry_create(state,input,NULL,out);
}
int zda_linux_geometry_hit(ZdaNative *state,const ZdaGeometryInput *input,const ZdaHitInput *hit,ZdaGeometry **out) {
    if (!hit) { if (out) *out=NULL; return ZDA_INVALID; }
    return geometry_create(state,input,hit,out);
}
int zda_native_publish(ZdaNative *state, ZdaText *const *texts, const ZdaMetadata *metadata, uint32_t count) {
    int result=zda_linux_live(state);
    if (result) return result;
    if (count!=1 || !texts || !texts[0] || texts[0]->account!=state->account || !metadata || metadata->text_version!=texts[0]->version ||
        !metadata->selection_count || metadata->selection_count>64 ||
        metadata->primary>=metadata->selection_count || !metadata->selections ||
        metadata->focused>1 || metadata->enabled>1 || metadata->composing>1) return ZDA_INVALID;
    ZdaText *text=texts[0];
    for (uint32_t i=0;i<metadata->selection_count;++i) if (!zda_linux_boundary(text,metadata->selections[i].anchor) ||
        !zda_linux_boundary(text,metadata->selections[i].caret)) return ZDA_INVALID;
    ZdaText *old=state->text;
    int32_t old_caret=old?zda_linux_scalar(old,state->caret):-1;
    uint32_t next_caret=metadata->selections[metadata->primary].caret;
    int32_t new_caret=zda_linux_scalar(text,next_caret);
    uint64_t next_revision=metadata->revision;
    gboolean changed=!old || old->version!=text->version;
    char *removed=NULL, *inserted=NULL;
    if (changed && old) { removed=zda_linux_utf8(old,0,old->length,state->account,&result); if (!removed) return result; }
    if (changed) {
        inserted=zda_linux_utf8(text,0,text->length,state->account,&result);
        if (!inserted) { zda_storage_release(removed); return result; }
    }
    zda_linux_retain(state);
    zda_text_retain(text); state->text=text; state->ready=TRUE;
    state->revision=next_revision; state->caret=next_caret;
    state->enabled=metadata->enabled!=0; state->composing=metadata->composing!=0;
    ZdaGeometry *geometry=NULL;
    if (state->geometry && (state->geometry->version!=text->version || state->composing)) {
        geometry=state->geometry; state->geometry=NULL;
    }
    if (changed) zda_linux_notify_text(state,old?old->scalar_count-1:0,removed,text->scalar_count-1,inserted);
    /* Text and metadata publish atomically before any signal. A foreign
     * remove/insert tail may already have withdrawn or superseded it; never
     * lend that newer publication an old caret event. Unchanged ordinals do
     * not generate a duplicate notification. */
    if (new_caret!=old_caret && new_caret>=0 && !state->closed && state->ready &&
        state->text==text && state->revision==next_revision && state->caret==next_caret)
        g_signal_emit_by_name(state,"text-caret-moved",new_caret);
    zda_storage_release(removed); zda_storage_release(inserted);
    zda_geometry_release(geometry); zda_text_release(old);
    zda_linux_release(state);
    return ZDA_OK;
}
int zda_native_publish_geometry(ZdaNative *state, ZdaGeometry *const *geometry, uint32_t count) {
    int result=zda_linux_live(state);
    if (result) return result;
    if (!geometry || count!=1) return ZDA_INVALID;
    if (geometry[0] && (!state->ready || !state->text || state->composing ||
        geometry[0]->account!=state->account || geometry[0]->version!=state->text->version || geometry[0]->scale!=state->scale)) return ZDA_INVALID;
    zda_linux_retain(state);
    zda_geometry_retain(geometry[0]);
    ZdaGeometry *old=state->geometry; state->geometry=geometry[0];
    zda_linux_notify_geometry(state);
    zda_geometry_release(old); zda_linux_release(state);
    return ZDA_OK;
}
void zda_native_invalidate(ZdaNative *state, uint32_t source) {
    if (!zda_linux_owner(state) || source || state->closed) return;
    /* Retain old text for the next exact remove payload, but do not expose it
     * as the new committed version. One old current + candidate is bounded. */
    state->ready=FALSE;
    ZdaGeometry *geometry=state->geometry; state->geometry=NULL;
    zda_geometry_release(geometry);
}
void zda_linux_mark(void *object) {
    ZdaNative *state=object;
    state->closed=TRUE; state->ready=FALSE;
}
void zda_linux_drop_current(ZdaNative *state) {
    ZdaText *text=state->text; ZdaGeometry *geometry=state->geometry;
    state->text=NULL; state->geometry=NULL; state->ready=FALSE;
    zda_text_release(text); zda_geometry_release(geometry);
}
void zda_native_begin_close(ZdaNative *state) {
    if (!zda_linux_owner(state)) return;
    zda_linux_mark(state); zda_account_close(state->account);
}
int zda_linux_position(ZdaNative *state, double *scale) {
    int result=zda_linux_live(state);
    if (result) return result;
    if (!scale || !state->binding) return ZDA_INVALID;
    zda_linux_retain(state);
    ZlgAccessibilityPosition position;
    int code=zlg_accessibility_position(state->binding,&position);
    if (code==ZLG_ACCESSIBILITY_OK && !state->closed) {
        ZdaGeometry *old=NULL;
        if (state->geometry && state->geometry->scale!=position.scale) { old=state->geometry; state->geometry=NULL; }
        state->window_x=position.window_x; state->window_y=position.window_y;
        state->screen_x=position.screen_x; state->screen_y=position.screen_y;
        state->area_width=position.width; state->area_height=position.height;
        state->scale=position.scale; state->position_flags=position.flags;
        *scale=(double)position.scale;
        zda_geometry_release(old); result=ZDA_OK;
    } else result=state->closed || code==ZLG_ACCESSIBILITY_CLOSED?ZDA_CLOSED:
        code==ZLG_ACCESSIBILITY_BUSY?ZDA_LINUX_BUSY:ZDA_INVALID;
    zda_linux_release(state); return result;
}
