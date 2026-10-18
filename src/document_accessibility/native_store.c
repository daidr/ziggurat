#include "native_internal.h"
#include <string.h>
#include <math.h>
#include <assert.h>
#include "native_mapping.h"
#include "native_words.h"

static BOOL owner(ZdaNative *state) { return GetCurrentThreadId() == state->owner; }
void zda_store_retain(ZdaNative *state) { InterlockedIncrement(&state->refs); }
void zda_store_release(ZdaNative *state) {
    if (!InterlockedDecrement(&state->refs)) {
        assert(state->closed && !state->unicode);
        if (state->host) IRawElementProviderSimple_Release(state->host);
        zda_storage_release(state);
    }
}
void zda_text_retain(ZdaText *text) { if (text) InterlockedIncrement(&text->refs); }
void zda_text_release(ZdaText *text) { if (text && !InterlockedDecrement(&text->refs)) zda_storage_release(text); }
void zda_geometry_retain(ZdaGeometry *geometry) { if (geometry) InterlockedIncrement(&geometry->refs); }
void zda_geometry_release(ZdaGeometry *geometry) {
    if (geometry && !InterlockedDecrement(&geometry->refs)) {
        ZdaText *text=geometry->hit?geometry->hit->text:NULL;
        zda_storage_release(geometry);
        zda_text_release(text);
    }
}
void zda_native_stats(ZdaNative *state, ZdaStats *out) { zda_account_stats(state->account, out); }
ZdaAccount *zda_native_account(ZdaNative *state) { zda_account_retain(state->account); return state->account; }
int zda_store_create(void *hwnd, const ZdaSource *sources, uint32_t count,
    uint64_t bytes, uint32_t ranges, uint32_t outputs, ZdaEnqueue enqueue, void *context, ZdaNative **out) {
    if (!out) return ZDA_INVALID;
    *out = NULL;
    if (!sources || !count || count > ZDA_SOURCES || !outputs || outputs > UINT32_C(67108864)) return ZDA_INVALID;
    for (uint32_t i = 0; i < count; ++i) if (sources[i].name_length >= 128 || (sources[i].name_length && !sources[i].name)) return ZDA_INVALID;
    ZdaAccount *account = NULL;
    int result = zda_account_create(bytes, ranges, &account);
    if (result != ZDA_OK) return result;
    ZdaNative *state = NULL;
    result = zda_storage_create(account, ZDA_STATE, sizeof(*state), (void **)&state);
    zda_account_release(account);
    if (result != ZDA_OK) return result;
    memset(state, 0, sizeof(*state));
    state->refs = 1; InitializeSRWLock(&state->lock);
    state->owner = GetCurrentThreadId(); state->hwnd = hwnd; state->account = account;
    state->enqueue = enqueue; state->context = context; state->count = count; state->output_units = outputs;
    state->range_limit = ranges;
    for (uint32_t i = 0; i < count; ++i) {
        ZdaSpec *spec = &state->specs[i];
        spec->name_length = sources[i].name_length;
        if (spec->name_length) memcpy(spec->name, sources[i].name, spec->name_length * sizeof(WCHAR));
        spec->read_only = !!sources[i].read_only; spec->selectable = !!sources[i].selectable; spec->focusable = !!sources[i].focusable; spec->scrollable = !!sources[i].scrollable;
    }
    state->unicode = LoadLibraryExW(L"icu.dll", NULL, LOAD_LIBRARY_SEARCH_SYSTEM32);
    if (state->unicode) {
#define LOAD(field, symbol) do { FARPROC address = GetProcAddress(state->unicode, symbol); \
    _Static_assert(sizeof(state->field) == sizeof(address), "system function pointer ABI"); \
    memcpy(&state->field, &address, sizeof(address)); } while (0)
        LOAD(break_open, "ubrk_open"); LOAD(break_first, "ubrk_first");
        LOAD(break_next, "ubrk_next"); LOAD(break_close, "ubrk_close");
#undef LOAD
    }
    if (!state->unicode || !state->break_open || !state->break_first || !state->break_next || !state->break_close) {
        if (state->unicode) FreeLibrary(state->unicode);
        state->unicode = NULL; state->closed = TRUE;
        zda_store_release(state); return ZDA_UNAVAILABLE;
    }
    *out = state; return ZDA_OK;
}
BOOL zda_text_boundary(const ZdaText *text, uint32_t unit) {
    uint32_t lo = 0, hi = text->scalar_count;
    while (lo < hi) { uint32_t mid = lo + (hi - lo) / 2; if (text->scalars[mid] < unit) lo = mid + 1; else hi = mid; }
    return lo < text->scalar_count && text->scalars[lo] == unit;
}
static BOOL sum(size_t *size, size_t count, size_t unit, size_t align) {
    if (*size > SIZE_MAX - (align - 1)) return FALSE;
    size_t start = (*size + align - 1) & ~(align - 1);
    if (count > (SIZE_MAX - start) / unit) return FALSE;
    *size = start + count * unit; return TRUE;
}
int zda_native_enable_words(ZdaNative *state) {
    if(!state || !owner(state))return ZDA_INVALID;
    if(state->closed)return ZDA_CLOSED;
    if(state->text_features&ZDA_TEXT_STARTED)return ZDA_INVALID;
    if(!GetProcAddress(state->unicode,"ubrk_getRuleStatus"))return ZDA_UNAVAILABLE;
    state->text_features|=ZDA_WORD_UNITS;return ZDA_OK;
}
static int word_boundaries(ZdaNative *state,ZdaText *text) {
    FARPROC address=GetProcAddress(state->unicode,"ubrk_getRuleStatus");
    ZdaBreakStatus rule_status=NULL;
    _Static_assert(sizeof(address)==sizeof(rule_status),"system word status ABI");
    memcpy(&rule_status,&address,sizeof(address));
    if(!rule_status)return ZDA_UNAVAILABLE;
    int32_t status=0;
    void *iterator=state->break_open(1,"root",text->text,(int32_t)text->length,&status);
    if(!iterator || status>0){if(iterator)state->break_close(iterator);return ZDA_UNAVAILABLE;}
    ZdaWords words;
    int valid=zda_words_init(&words,zda_word_positions(text),text->scalar_count,text->length);
    uint32_t scalar=0;
    if(state->break_first(iterator)!=0)valid=0;
    while(valid) {
        int32_t at=state->break_next(iterator);if(at==-1)break;
        if(at<0 || (uint32_t)at>text->length){valid=0;break;}
        while(scalar<text->scalar_count && text->scalars[scalar]<(uint32_t)at)++scalar;
        if(scalar==text->scalar_count || text->scalars[scalar]!=(uint32_t)at || !zda_words_segment(&words,(uint32_t)at,rule_status(iterator)>=100))valid=0;
    }
    state->break_close(iterator);
    if(!valid || !zda_words_finish(&words))return ZDA_INVALID;
    uint32_t grapheme=0;
    for(uint32_t i=0;i<words.count;++i) {
        while(grapheme<text->grapheme_count && text->graphemes[grapheme]<words.positions[i])++grapheme;
        if(grapheme==text->grapheme_count || text->graphemes[grapheme]!=words.positions[i])return ZDA_INVALID;
    }
    text->word_count=words.count;return ZDA_OK;
}
int zda_native_text(ZdaNative *state, const ZdaTextInput *input, ZdaText **out) {
    if (!out) return ZDA_INVALID;
    *out = NULL;
    if (!owner(state) || !input || (input->text_length && !input->text) || !input->scalars || !input->paragraphs || !input->scalar_count || input->paragraph_count < 2 || input->text_length > state->output_units) return ZDA_INVALID;
    if (state->closed) return ZDA_CLOSED;
    state->text_features|=ZDA_TEXT_STARTED;
    uint32_t scalar = 0;
    for (uint32_t at = 0; at < input->text_length;) {
        if (scalar >= input->scalar_count || input->scalars[scalar++] != at) return ZDA_INVALID;
        WCHAR ch = input->text[at++];
        if (ch >= 0xd800 && ch <= 0xdbff) { if (at == input->text_length || input->text[at] < 0xdc00 || input->text[at++] > 0xdfff) return ZDA_INVALID; }
        else if (ch >= 0xdc00 && ch <= 0xdfff) return ZDA_INVALID;
    }
    if (scalar + 1 != input->scalar_count || input->scalars[scalar] != input->text_length || input->paragraphs[0] != 0 || input->paragraphs[input->paragraph_count - 1] != input->text_length) return ZDA_INVALID;
    uint32_t paragraph = 1;
    for (uint32_t at = 0; at < input->text_length; ++at) if (input->text[at] == '\n') {
        if (paragraph >= input->paragraph_count || input->paragraphs[paragraph++] != at + 1) return ZDA_INVALID;
    }
    if (paragraph + 1 != input->paragraph_count) return ZDA_INVALID;
    size_t bytes = sizeof(ZdaText);
    if (!sum(&bytes, input->text_length, sizeof(uint16_t), 2)) return ZDA_CAPACITY;
    size_t scalar_start = (bytes + 3) & ~(size_t)3;
    if (!sum(&bytes, input->scalar_count, sizeof(uint32_t), 4)) return ZDA_CAPACITY;
    size_t paragraph_start = bytes;
    if (!sum(&bytes, input->paragraph_count, sizeof(uint32_t), 4)) return ZDA_CAPACITY;
    size_t grapheme_start = bytes;
    if (!sum(&bytes, input->scalar_count, sizeof(uint32_t), 4)) return ZDA_CAPACITY;
    if ((state->text_features&ZDA_WORD_UNITS) && !sum(&bytes,input->scalar_count,sizeof(uint32_t),4)) return ZDA_CAPACITY;
    ZdaText *text = NULL;
    int result = zda_storage_create(state->account, ZDA_BLOB, bytes, (void **)&text);
    if (result != ZDA_OK) return result;
    memset(text, 0, sizeof(*text)); text->refs = 1; text->version = input->text_version;
    text->length = input->text_length; text->scalar_count = input->scalar_count; text->paragraph_count = input->paragraph_count;
    text->text = (uint16_t *)(text + 1); text->scalars = (uint32_t *)((char *)text + scalar_start);
    text->paragraphs = (uint32_t *)((char *)text + paragraph_start); text->graphemes = (uint32_t *)((char *)text + grapheme_start);
    if (text->length) memcpy(text->text, input->text, text->length * sizeof(uint16_t));
    memcpy(text->scalars, input->scalars, text->scalar_count * sizeof(uint32_t));
    memcpy(text->paragraphs, input->paragraphs, text->paragraph_count * sizeof(uint32_t));
    int32_t status = 0;
    void *iterator = state->break_open(0, NULL, text->text, (int32_t)text->length, &status);
    if (!iterator || status > 0) { if (iterator) state->break_close(iterator); zda_text_release(text); return ZDA_UNAVAILABLE; }
    for (int32_t at = state->break_first(iterator); at >= 0; at = state->break_next(iterator)) {
        if ((uint32_t)at > text->length || text->grapheme_count == text->scalar_count || !zda_text_boundary(text, (uint32_t)at)) { state->break_close(iterator); zda_text_release(text); return ZDA_INVALID; }
        text->graphemes[text->grapheme_count++] = (uint32_t)at;
    }
    state->break_close(iterator);
    if (!text->grapheme_count || text->graphemes[0] != 0 || text->graphemes[text->grapheme_count - 1] != text->length) { zda_text_release(text); return ZDA_INVALID; }
    if(state->text_features&ZDA_WORD_UNITS) {
        result=word_boundaries(state,text);
        if(result!=ZDA_OK){zda_text_release(text);return result;}
    }
    *out = text; return ZDA_OK;
}
static BOOL rect_valid(ZdaRect rect) {
    return isfinite(rect.x) && isfinite(rect.y) && isfinite(rect.width) && isfinite(rect.height) && fabs(rect.x) <= 1e12 && fabs(rect.y) <= 1e12 && rect.width >= 0 && rect.height >= 0 && rect.width <= 1e12 && rect.height <= 1e12;
}
_Static_assert(sizeof(ZdaCell) == 40 && sizeof(ZdaCaret) == 40 && sizeof(ZdaLine) == 40, "geometry array ABI");
_Static_assert(sizeof(ZdaGeometry) % _Alignof(ZdaCell) == 0 && _Alignof(ZdaCell) == _Alignof(ZdaCaret) && _Alignof(ZdaCaret) == _Alignof(ZdaLine), "geometry array alignment");
static int geometry_create(ZdaNative *state, uint32_t source, ZdaText *text, const ZdaGeometryInput *input, const ZdaHitInput *hit, ZdaGeometry **out) {
    if (!out) return ZDA_INVALID; *out = NULL;
    if (!owner(state) || !input || !rect_valid(input->bounds) || !isfinite(input->scale) || input->scale <= 0 || input->scale > 16 || input->cell_count > 16384 || (input->cell_count && !input->cells) || input->caret_count > 32768 || input->line_count > 4096 || (input->caret_count && !input->carets) || (input->line_count && !input->lines)) return ZDA_INVALID;
    if (state->closed) return ZDA_CLOSED;
    for (uint32_t i = 0; i < input->cell_count; ++i) if (input->cells[i].start > input->cells[i].end || !rect_valid(input->cells[i].rectangle)) return ZDA_INVALID;
    uint32_t covered = 0;
    for (uint32_t i = 0; i < input->line_count; ++i) {
        const ZdaLine *line = &input->lines[i];
        if (!rect_valid(line->rectangle) || line->rectangle.height <= 0 || !line->count || line->first != covered || line->count > input->caret_count - covered) return ZDA_INVALID;
        for (uint32_t j = 0; j < line->count; ++j) {
            const ZdaCaret *caret = &input->carets[covered + j];
            if (caret->affinity > 1 || !rect_valid(caret->rectangle) || caret->rectangle.height <= 0) return ZDA_INVALID;
            if (j) {
                const ZdaCaret *previous = caret - 1;
                if (previous->rectangle.x > caret->rectangle.x || (previous->rectangle.x == caret->rectangle.x && (previous->position > caret->position || (previous->position == caret->position && previous->affinity < caret->affinity)))) return ZDA_INVALID;
            }
        }
        covered += line->count;
    }
    if (covered != input->caret_count) return ZDA_INVALID;
    if (hit) {
        if (!text || zda_storage_account(text)!=state->account || hit->reserved || hit->domain>1 ||
            hit->text_version!=input->text_version || hit->projection_version!=input->projection_version || hit->scale!=input->scale ||
            (double)hit->packet.bounds.x!=input->bounds.x || (double)hit->packet.bounds.y!=input->bounds.y ||
            (double)hit->packet.bounds.width!=input->bounds.width || (double)hit->packet.bounds.height!=input->bounds.height) return ZDA_INVALID;
        int checked=zde_prepared_hit_validate(&hit->packet,32768,4096,UINT64_C(1048576),text->length);
        if (checked) return checked;
        for (uint32_t i=0;i<hit->packet.stop_count;++i) if (!zda_text_boundary(text,(uint32_t)hit->packet.stops[i].position)) return ZDA_INVALID;
        for (uint32_t i=0;i<input->cell_count;++i) if (!zda_text_boundary(text,input->cells[i].start) || !zda_text_boundary(text,input->cells[i].end)) return ZDA_INVALID;
        for (uint32_t i=0;i<input->caret_count;++i) if (!zda_text_boundary(text,input->carets[i].position)) return ZDA_INVALID;
    }
    size_t bytes = sizeof(ZdaGeometry);
    if (!sum(&bytes, input->cell_count, sizeof(ZdaCell), _Alignof(ZdaCell))) return ZDA_CAPACITY;
    const size_t caret_start = bytes;
    if (!sum(&bytes, input->caret_count, sizeof(ZdaCaret), _Alignof(ZdaCaret))) return ZDA_CAPACITY;
    const size_t line_start = bytes;
    if (!sum(&bytes, input->line_count, sizeof(ZdaLine), _Alignof(ZdaLine))) return ZDA_CAPACITY;
    size_t hit_header=0,hit_blocks=0,hit_lines=0,hit_stops=0,hit_placements=0;
    if (hit) {
        hit_header=bytes;
        if (!sum(&bytes,1,sizeof(ZdaOwnedHit),_Alignof(ZdaOwnedHit))) return ZDA_CAPACITY;
        hit_blocks=bytes;
        if (!sum(&bytes,hit->packet.block_count,sizeof(ZdeHitBlock),_Alignof(ZdeHitBlock))) return ZDA_CAPACITY;
        hit_lines=bytes;
        if (!sum(&bytes,hit->packet.line_count,sizeof(ZdeHitLine),_Alignof(ZdeHitLine))) return ZDA_CAPACITY;
        hit_stops=bytes;
        if (!sum(&bytes,hit->packet.stop_count,sizeof(ZdeHitStop),_Alignof(ZdeHitStop))) return ZDA_CAPACITY;
        hit_placements=bytes;
        if (!sum(&bytes,hit->packet.placement_count,sizeof(ZdeHitPlacement),_Alignof(ZdeHitPlacement))) return ZDA_CAPACITY;
    }
    ZdaGeometry *geometry = NULL;
    int result = zda_storage_create(state->account, ZDA_BLOB, bytes, (void **)&geometry);
    if (result != ZDA_OK) return result;
    memset(geometry, 0, sizeof(*geometry)); geometry->refs = 1; geometry->version = input->text_version;
    geometry->projection_version = input->projection_version; geometry->scale = input->scale; geometry->bounds = input->bounds;
    geometry->count = input->cell_count; geometry->cells = (ZdaCell *)(geometry + 1);
    geometry->caret_count = input->caret_count; geometry->line_count = input->line_count;
    geometry->carets = (ZdaCaret *)((char *)geometry + caret_start);
    geometry->lines = (ZdaLine *)((char *)geometry + line_start);
    if (geometry->count) memcpy(geometry->cells, input->cells, geometry->count * sizeof(ZdaCell));
    if (geometry->caret_count) memcpy(geometry->carets, input->carets, geometry->caret_count * sizeof(ZdaCaret));
    if (geometry->line_count) memcpy(geometry->lines, input->lines, geometry->line_count * sizeof(ZdaLine));
    if (hit) {
        ZdaOwnedHit *owned=(ZdaOwnedHit *)((char *)geometry+hit_header);
        owned->text=text; zda_text_retain(text); owned->source=source; owned->reserved=0; owned->input=*hit;
        ZdeHitPacket *packet=&owned->input.packet;
        packet->blocks=(ZdeHitBlock *)((char *)geometry+hit_blocks);
        packet->lines=(ZdeHitLine *)((char *)geometry+hit_lines);
        packet->stops=(ZdeHitStop *)((char *)geometry+hit_stops);
        packet->placements=hit->packet.placement_count?(ZdeHitPlacement *)((char *)geometry+hit_placements):NULL;
        memcpy((void *)packet->blocks,hit->packet.blocks,hit->packet.block_count*sizeof(ZdeHitBlock));
        memcpy((void *)packet->lines,hit->packet.lines,hit->packet.line_count*sizeof(ZdeHitLine));
        memcpy((void *)packet->stops,hit->packet.stops,hit->packet.stop_count*sizeof(ZdeHitStop));
        if (hit->packet.placement_count) memcpy((void *)packet->placements,hit->packet.placements,hit->packet.placement_count*sizeof(ZdeHitPlacement));
        geometry->hit=owned;
        AcquireSRWLockShared(&state->lock);
        const int current=state->closed?ZDA_CLOSED:source<state->count && state->sources[source].text==text?ZDA_OK:ZDA_UNAVAILABLE;
        ReleaseSRWLockShared(&state->lock);
        if (current!=ZDA_OK) { zda_geometry_release(geometry); return current; }
    }
    *out = geometry; return ZDA_OK;
}
int zda_native_geometry(ZdaNative *state,const ZdaGeometryInput *input,ZdaGeometry **out) {
    return geometry_create(state,UINT32_MAX,NULL,input,NULL,out);
}
int zda_native_geometry_hit(ZdaNative *state,uint32_t source,const ZdaGeometryInput *input,const ZdaHitInput *hit,ZdaGeometry **out) {
    if (!out) return ZDA_INVALID; *out=NULL;
    if (!owner(state) || !input || !hit || source>=state->count) return ZDA_INVALID;
    zda_store_retain(state);
    AcquireSRWLockShared(&state->lock);
    ZdaText *text=state->sources[source].text;
    const int ready=state->closed?ZDA_CLOSED:!text || text->version!=input->text_version?ZDA_UNAVAILABLE:ZDA_OK;
    if (ready==ZDA_OK) zda_text_retain(text);
    ReleaseSRWLockShared(&state->lock);
    int result=ready;
    if (result==ZDA_OK) {
        result=geometry_create(state,source,text,input,hit,out);
        zda_text_release(text);
    }
    zda_store_release(state);
    return result;
}
int zda_native_publish(ZdaNative *state, ZdaText *const *texts, const ZdaMetadata *meta, uint32_t count) {
    if (!owner(state) || count != state->count || !texts || !meta) return ZDA_INVALID;
    for (uint32_t i = 0; i < count; ++i) {
        if (!texts[i] || zda_storage_account(texts[i])!=state->account || meta[i].text_version != texts[i]->version || !meta[i].selection_count || meta[i].selection_count > ZDA_SELECTIONS || meta[i].primary >= meta[i].selection_count || !meta[i].selections) return ZDA_INVALID;
        for (uint32_t j = 0; j < meta[i].selection_count; ++j) if (!zda_text_boundary(texts[i], meta[i].selections[j].anchor) || !zda_text_boundary(texts[i], meta[i].selections[j].caret)) return ZDA_INVALID;
    }
    ZdaText *old[ZDA_SOURCES] = {0}; ZdaGeometry *retired[ZDA_SOURCES] = {0};
    AcquireSRWLockExclusive(&state->lock);
    if (state->closed) { ReleaseSRWLockExclusive(&state->lock); return ZDA_CLOSED; }
    if(state->geometry_serial==UINT64_MAX){ReleaseSRWLockExclusive(&state->lock);return ZDA_CAPACITY;}
    ++state->geometry_serial;
    for (uint32_t i = 0; i < count; ++i) zda_text_retain(texts[i]);
    for (uint32_t i = 0; i < count; ++i) {
        ZdaCurrent *current = &state->sources[i]; old[i] = current->text; current->text = texts[i];
        if (current->geometry && (current->geometry->version != texts[i]->version || (current->geometry->hit && current->geometry->hit->text!=texts[i]))) { retired[i] = current->geometry; current->geometry = NULL; }
        current->revision = meta[i].revision; current->count = meta[i].selection_count; current->primary = meta[i].primary;
        current->enabled = meta[i].enabled; current->focused = meta[i].focused; current->composing = meta[i].composing;
        memcpy(current->selections, meta[i].selections, current->count * sizeof(ZdaSelection));
    }
    ReleaseSRWLockExclusive(&state->lock);
    for (uint32_t i = 0; i < count; ++i) { zda_text_release(old[i]); zda_geometry_release(retired[i]); }
    return ZDA_OK;
}
int zda_native_enable_mapping(ZdaNative *state) {
    if (!owner(state)) return ZDA_INVALID;
    if (state->closed) return ZDA_CLOSED;
    if (state->mappings) return ZDA_INVALID;
    ZdaMapping *candidate = NULL;
    int result = zda_storage_create(state->account, ZDA_BLOB, state->count*sizeof(ZdaMapping), (void **)&candidate);
    if (result != ZDA_OK) return result;
    memset(candidate,0,state->count*sizeof(ZdaMapping));
    state->mappings=candidate; return ZDA_OK;
}
static int publish_geometry(ZdaNative *state, ZdaGeometry *const *geometry, const ZdaMapping *mappings, uint32_t count, BOOL presented, uint64_t epoch, ZdaAuxPlan *aux, const ZdaAuxGeometry *rects, uint32_t aux_count, double aux_scale, const ZdaMapping *aux_mapping, const ZdaPublication *publication) {
    if (!owner(state) || count != state->count || !geometry) return ZDA_INVALID;
    if (state->presentation_required && !presented) return ZDA_INVALID;
    if (presented && !state->presentation_required) return ZDA_INVALID;
    if (presented && !epoch) for (uint32_t i=0;i<count;++i) if (geometry[i]) return ZDA_INVALID;
    if (aux || aux_count) {
        if (!state->auxiliary || !aux || aux->state!=state || !rects || aux_count != aux->count || aux_count > state->auxiliary->capacity || !epoch || !isfinite(aux_scale) || aux_scale <= 0 || aux_scale > 16) return ZDA_INVALID;
        for (uint32_t i=0;i<aux_count;++i) {
            const ZdaAuxGeometry *r=&rects[i];
            if (!isfinite(r->x)||!isfinite(r->y)||!isfinite(r->width)||!isfinite(r->height)||fabs(r->x)>1e12||fabs(r->y)>1e12||r->width<0||r->height<0||r->width>1e12||r->height>1e12||r->flags>7||r->reserved) return ZDA_INVALID;
        }
    }
    if (mappings) {
        if (!state->mappings) return ZDA_INVALID;
        for (uint32_t i=0;i<count;++i) if (!zda_mapping_valid(&mappings[i])) return ZDA_INVALID;
    }
    if (aux_mapping || publication) {
        if (!state->auxiliary || !state->auxiliary->affine || !aux_mapping || !publication || !aux || !aux_count || !mappings || !zda_mapping_valid(aux_mapping) || !publication->generation || publication->generation==UINT64_MAX || publication->publication!=epoch || !publication->source || !publication->candidate || !publication->space_epoch || !publication->space_generation) return ZDA_INVALID;
        /* All three regions share matrices and authority, while their visible
           polygons can differ (for example a toolbar below the document). */
        for (uint32_t i=0;i<count;++i) if (memcmp(mappings[i].forward,aux_mapping->forward,sizeof(aux_mapping->forward)) || memcmp(mappings[i].inverse,aux_mapping->inverse,sizeof(aux_mapping->inverse))) return ZDA_INVALID;
    } else if (state->auxiliary && state->auxiliary->affine && aux_count) return ZDA_INVALID;
    ZdaGeometry *old[ZDA_SOURCES] = {0};
    ZdaAuxPlan *old_aux=NULL;
    AcquireSRWLockExclusive(&state->lock);
    if (state->closed) { ReleaseSRWLockExclusive(&state->lock); return ZDA_CLOSED; }
    for (uint32_t i = 0; i < count; ++i) {
        ZdaCurrent *source = &state->sources[i];
        if (geometry[i]) {
            if (zda_storage_account(geometry[i])!=state->account || !source->text || geometry[i]->version != source->text->version ||
                (geometry[i]->hit && (geometry[i]->hit->source!=i || geometry[i]->hit->text!=source->text || zda_storage_account(geometry[i]->hit->text)!=state->account))) { ReleaseSRWLockExclusive(&state->lock); return ZDA_INVALID; }
            for (uint32_t j = 0; j < geometry[i]->count; ++j) if (!zda_text_boundary(source->text, geometry[i]->cells[j].start) || !zda_text_boundary(source->text, geometry[i]->cells[j].end)) { ReleaseSRWLockExclusive(&state->lock); return ZDA_INVALID; }
            for (uint32_t j = 0; j < geometry[i]->caret_count; ++j) if (!zda_text_boundary(source->text, geometry[i]->carets[j].position)) { ReleaseSRWLockExclusive(&state->lock); return ZDA_INVALID; }
        }
    }
    if(state->geometry_serial==UINT64_MAX){ReleaseSRWLockExclusive(&state->lock);return ZDA_CAPACITY;}
    ++state->geometry_serial;
    for (uint32_t i = 0; i < count; ++i) zda_geometry_retain(geometry[i]);
    for (uint32_t i = 0; i < count; ++i) {
        old[i] = state->sources[i].geometry; state->sources[i].geometry = geometry[i];
        state->mapped[i] = mappings != NULL;
        if (mappings) state->mappings[i] = mappings[i];
    }
    if (presented) state->presentation_epoch = epoch;
    if (state->auxiliary) {
        old_aux=state->auxiliary->current;
        zda_auxiliary_retain(aux);
        state->auxiliary->current=aux;
        state->auxiliary->count=aux_count;
        state->auxiliary->scale=aux_scale;
        if (state->auxiliary->affine) {
            ZdaAuxMapping *affine=state->auxiliary->affine;
            affine->active=aux_mapping!=NULL;
            affine->publication=publication?*publication:(ZdaPublication){0};
            if(aux_mapping)affine->mapping=*aux_mapping;
        }
        if (aux_count) memcpy(state->auxiliary->geometry,rects,aux_count*sizeof(*rects));
    }
    ReleaseSRWLockExclusive(&state->lock);
    for (uint32_t i = 0; i < count; ++i) zda_geometry_release(old[i]);
    zda_auxiliary_release(old_aux);
    return ZDA_OK;
}
int zda_native_publish_geometry(ZdaNative *state, ZdaGeometry *const *geometry, uint32_t count) {
    return publish_geometry(state,geometry,NULL,count,FALSE,0,NULL,NULL,0,1,NULL,NULL);
}
int zda_native_publish_mapped(ZdaNative *state, ZdaGeometry *const *geometry, const ZdaMapping *mappings, uint32_t count) {
    if (!mappings) return ZDA_INVALID;
    return publish_geometry(state,geometry,mappings,count,FALSE,0,NULL,NULL,0,1,NULL,NULL);
}
int zda_native_enable_presentation(ZdaNative *state) {
    if (!owner(state) || state->presentation_required) return ZDA_INVALID;
    if (state->closed) return ZDA_CLOSED;
    state->presentation_required = TRUE; return ZDA_OK;
}
int zda_native_publish_presented(ZdaNative *state, ZdaGeometry *const *geometry, const ZdaMapping *mappings, uint32_t count, uint64_t epoch) {
    return publish_geometry(state,geometry,mappings,count,TRUE,epoch,NULL,NULL,0,1,NULL,NULL);
}
int zda_native_enable_auxiliary(ZdaNative *state, uint32_t capacity) {
    if (!owner(state)||state->count!=2||!state->presentation_required||state->auxiliary||!capacity||capacity>128) return ZDA_INVALID;
    if (state->closed) return ZDA_CLOSED;
    ZdaAuxiliary *candidate=NULL;
    size_t bytes=sizeof(*candidate)+capacity*sizeof(ZdaAuxGeometry);
    int result=zda_storage_create(state->account,ZDA_BLOB,bytes,(void **)&candidate);
    if(result!=ZDA_OK)return result;
    memset(candidate,0,bytes);candidate->capacity=capacity;candidate->scale=1;
    state->auxiliary=candidate;return ZDA_OK;
}
int zda_native_publish_auxiliary(ZdaNative *state,ZdaGeometry *const *geometry,uint32_t count,uint64_t epoch,ZdaAuxPlan *plan,const ZdaAuxGeometry *rects,uint32_t nodes,double scale) {
    if(!state->auxiliary)return ZDA_INVALID;
    return publish_geometry(state,geometry,NULL,count,TRUE,epoch,plan,rects,nodes,scale,NULL,NULL);
}
int zda_native_enable_auxiliary_mapping(ZdaNative *state) {
    if(!owner(state)||!state->auxiliary||state->auxiliary->affine||!state->mappings)return ZDA_INVALID;
    if(state->closed)return ZDA_CLOSED;
    ZdaAuxMapping *candidate=NULL;
    int result=zda_storage_create(state->account,ZDA_BLOB,sizeof(*candidate),(void **)&candidate);
    if(result!=ZDA_OK)return result;
    memset(candidate,0,sizeof(*candidate));state->auxiliary->affine=candidate;return ZDA_OK;
}
int zda_native_publish_auxiliary_mapped(ZdaNative *state,ZdaGeometry *const *geometry,const ZdaMapping *mappings,uint32_t count,uint64_t epoch,ZdaAuxPlan *plan,const ZdaAuxGeometry *rects,uint32_t nodes,double scale,const ZdaMapping *aux_mapping,const ZdaPublication *publication) {
    if(!state->auxiliary||!state->auxiliary->affine)return ZDA_INVALID;
    return publish_geometry(state,geometry,mappings,count,TRUE,epoch,plan,rects,nodes,scale,aux_mapping,publication);
}
void zda_native_invalidate(ZdaNative *state, uint32_t source) {
    assert(owner(state)); if (source >= state->count) return;
    AcquireSRWLockExclusive(&state->lock);
    ZdaText *text = state->sources[source].text; ZdaGeometry *geometry = state->sources[source].geometry;
    state->sources[source].text = NULL; state->sources[source].geometry = NULL;
    ReleaseSRWLockExclusive(&state->lock);
    zda_text_release(text); zda_geometry_release(geometry);
}
void zda_native_withdraw_geometry(ZdaNative *state,uint32_t invalid_text_mask) {
    assert(owner(state));
    ZdaGeometry *old[ZDA_SOURCES]={0}; ZdaText *texts[ZDA_SOURCES]={0}; ZdaAuxPlan *plan=NULL;
    const uint32_t count=state->count;
    AcquireSRWLockExclusive(&state->lock);
    for (uint32_t i=0;i<count;++i) {
        old[i]=state->sources[i].geometry; state->sources[i].geometry=NULL; state->mapped[i]=FALSE;
        if (invalid_text_mask&(1u<<i)) { texts[i]=state->sources[i].text; state->sources[i].text=NULL; }
    }
    state->presentation_epoch=0;
    if (state->auxiliary) {
        plan=state->auxiliary->current; state->auxiliary->current=NULL; state->auxiliary->count=0;
        if (state->auxiliary->affine) { state->auxiliary->affine->active=FALSE; memset(&state->auxiliary->affine->publication,0,sizeof(ZdaPublication)); }
    }
    ReleaseSRWLockExclusive(&state->lock);
    /* No counter increment or live owner read follows a foreign final free. */
    for (uint32_t i=0;i<count;++i) { zda_geometry_release(old[i]); zda_text_release(texts[i]); }
    zda_auxiliary_release(plan);
}
int zda_native_position(ZdaNative *state, double x, double y, double scale) {
    if (!owner(state) || !isfinite(x) || !isfinite(y) || fabs(x) > 1e12 || fabs(y) > 1e12 || !isfinite(scale) || scale <= 0 || scale > 16) return ZDA_INVALID;
    ZdaGeometry *old[ZDA_SOURCES] = {0};
    AcquireSRWLockExclusive(&state->lock);
    if (state->closed) { ReleaseSRWLockExclusive(&state->lock); return ZDA_CLOSED; }
    state->screen_x = x; state->screen_y = y; state->screen_scale = scale;
    for (uint32_t i = 0; i < state->count; ++i) if (state->sources[i].geometry && state->sources[i].geometry->scale != scale) {
        old[i] = state->sources[i].geometry; state->sources[i].geometry = NULL;
    }
    if(state->auxiliary&&state->auxiliary->scale!=scale)state->auxiliary->count=0;
    ReleaseSRWLockExclusive(&state->lock);
    for (uint32_t i = 0; i < state->count; ++i) zda_geometry_release(old[i]);
    return ZDA_OK;
}
HRESULT zda_acquire_mapped(ZdaNative *state, uint32_t source, uint64_t version, ZdaText **text, ZdaGeometry **geometry, ZdaCurrent *metadata, ZdaMapped *mapping, double *x, double *y) {
    *text = NULL; if (geometry) *geometry = NULL;
    AcquireSRWLockShared(&state->lock);
    ZdaCurrent *current = source < state->count ? &state->sources[source] : NULL;
    if (state->closed || !current || !current->text || (version != UINT64_MAX && current->text->version != version)) { ReleaseSRWLockShared(&state->lock); return UIA_E_ELEMENTNOTAVAILABLE; }
    *text = current->text; zda_text_retain(*text);
    if (geometry) { *geometry = current->geometry; zda_geometry_retain(*geometry); }
    if (metadata) *metadata = *current;
    if (mapping) zda_copy_mapping(state,source,mapping);
    if (x) *x=state->screen_x;
    if (y) *y=state->screen_y;
    ReleaseSRWLockShared(&state->lock); return S_OK;
}
HRESULT zda_acquire(ZdaNative *state, uint32_t source, uint64_t version, ZdaText **text, ZdaGeometry **geometry, ZdaCurrent *metadata) {
    return zda_acquire_mapped(state,source,version,text,geometry,metadata,NULL,NULL,NULL);
}
void zda_native_begin_close(ZdaNative *state) {
    assert(owner(state));
    ZdaText *texts[ZDA_SOURCES] = {0}; ZdaGeometry *geometry[ZDA_SOURCES] = {0};
    AcquireSRWLockExclusive(&state->lock);
    if (state->closed) { ReleaseSRWLockExclusive(&state->lock); return; }
    state->closed = TRUE; state->context = NULL; state->hwnd = NULL;
    ZdaMapping *mappings=state->mappings; state->mappings=NULL;
    if(state->auxiliary)state->auxiliary->count=0;
    zda_account_close(state->account);
    for (uint32_t i = 0; i < state->count; ++i) {
        texts[i] = state->sources[i].text; geometry[i] = state->sources[i].geometry;
        state->sources[i].text = NULL; state->sources[i].geometry = NULL;
    }
    ReleaseSRWLockExclusive(&state->lock);
    zda_storage_release(mappings);
    if (state->unicode) { HMODULE module = state->unicode; state->unicode = NULL; FreeLibrary(module); }
    for (uint32_t i = 0; i < state->count; ++i) { zda_text_release(texts[i]); zda_geometry_release(geometry[i]); }
}
