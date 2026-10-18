#include "native_internal.h"
#include <string.h>
#define CHECK(value) do { if (!(value)) return __LINE__; } while (0)
static DWORD WINAPI late_blob(void *text) { zda_text_release(text); return 0; }
static void counts(uint32_t *accounts, uint32_t *blocks, uint64_t *bytes) { zda_ledger_counts(accounts, blocks, bytes); }
static int word_case(ZdaNative *state,const uint16_t *units,uint32_t length,const uint32_t *expected,uint32_t count) {
    uint32_t scalars[128],paragraphs[128],scalar_count=0,paragraph_count=1;
    CHECK(length<127);paragraphs[0]=0;
    for(uint32_t i=0;i<length;) {
        scalars[scalar_count++]=i;
        i+=units[i]>=0xd800 && units[i]<=0xdbff?2u:1u;
    }
    scalars[scalar_count++]=length;
    for(uint32_t i=0;i<length;++i)if(units[i]=='\n')paragraphs[paragraph_count++]=i+1;
    paragraphs[paragraph_count++]=length;
    const ZdaTextInput input={2,units,scalars,paragraphs,length,scalar_count,paragraph_count};
    ZdaText *candidate=NULL;CHECK(zda_native_text(state,&input,&candidate)==ZDA_OK);
    CHECK(candidate->word_count==count && !memcmp(zda_word_positions(candidate),expected,count*sizeof(*expected)));
    zda_text_release(candidate);return 0;
}
static int word_store(void) {
    uint32_t accounts,blocks;uint64_t bytes;counts(&accounts,&blocks,&bytes);
    const ZdaSource spec={L"Words",5,0,1,1,0};
    const uint16_t units[]={' ','\t','h','e','l','l','o',',',' ','w','o','r','l','d','!',' ','\r','\n'};
    uint32_t scalar[19];for(uint32_t i=0;i<19;++i)scalar[i]=i;
    const uint32_t paragraphs[]={0,18,18};
    const ZdaTextInput input={1,units,scalar,paragraphs,18,19,3};
    const uint32_t words[]={0,2,9,18};uint64_t default_text_bytes=0;
    for(unsigned enabled=0;enabled<2;++enabled) {
        ZdaNative *state=NULL;CHECK(zda_store_create(NULL,&spec,1,32768,4,128,NULL,NULL,&state)==ZDA_OK);
        if(enabled)CHECK(zda_native_enable_words(state)==ZDA_OK);
        ZdaStats before;zda_native_stats(state,&before);
        ZdaText *text=NULL;CHECK(zda_native_text(state,&input,&text)==ZDA_OK);
        CHECK(zda_native_enable_words(state)==ZDA_INVALID);
        ZdaStats after;zda_native_stats(state,&after);
        if(enabled) {
            CHECK(text->word_count==4 && !memcmp(zda_word_positions(text),words,sizeof(words)));
            CHECK(after.bytes-before.bytes==default_text_bytes+sizeof(scalar));
            const uint16_t cjk[]={0x4e2d,0x6587,0x6d4b,0x8bd5},thai[]={0x0e20,0x0e32,0x0e29,0x0e32,0x0e44,0x0e17,0x0e22};
            const uint16_t combined[]={'e',0x301,' ',0xd83d,0xde00,' ','x'},emoji[]={0xd83d,0xdc69,0x200d,0xd83d,0xdcbb,' ','x'};
            const uint16_t punctuation[]={'.','!',' ','\t','\n'},empty[]={0};
            CHECK(!word_case(state,cjk,4,(const uint32_t[]){0,2,4},3));
            CHECK(!word_case(state,thai,7,(const uint32_t[]){0,4,7},3));
            CHECK(!word_case(state,combined,7,(const uint32_t[]){0,6,7},3));
            CHECK(!word_case(state,emoji,7,(const uint32_t[]){0,6,7},3));
            CHECK(!word_case(state,punctuation,5,(const uint32_t[]){0,5},2));
            CHECK(!word_case(state,empty,0,(const uint32_t[]){0},1));
        } else {CHECK(!text->word_count);default_text_bytes=after.bytes-before.bytes;}
        const size_t remaining=(size_t)(after.byte_limit-after.bytes);
        CHECK(zda_account_reserve_host(state->account,remaining)==ZDA_OK);
        ZdaText *rejected=NULL;CHECK(zda_native_text(state,&input,&rejected)==ZDA_CAPACITY && !rejected);
        zda_account_release_host(state->account,remaining);
        CHECK(text->length==18 && (!enabled || text->word_count==4));
        const ZdaSelection selection={0,0};const ZdaMetadata metadata={1,1,&selection,1,0,0,1,0};
        CHECK(zda_native_publish(state,&text,&metadata,1)==ZDA_OK);
        zda_native_begin_close(state);CHECK(zda_native_enable_words(state)==ZDA_CLOSED);zda_store_release(state);
        CHECK(text->length==18 && (!enabled || !memcmp(zda_word_positions(text),words,sizeof(words))));
        HANDLE thread=CreateThread(NULL,0,late_blob,text,0,NULL);CHECK(thread);
        CHECK(WaitForSingleObject(thread,5000)==WAIT_OBJECT_0);CloseHandle(thread);
    }
    uint32_t final_accounts,final_blocks;uint64_t final_bytes;counts(&final_accounts,&final_blocks,&final_bytes);
    CHECK(final_accounts==accounts && final_blocks==blocks && final_bytes==bytes);return 0;
}
int zda_test_store(void) {
    int words=word_store();if(words)return words;
    uint32_t before_accounts, before_blocks; uint64_t before_bytes;
    counts(&before_accounts, &before_blocks, &before_bytes);
    const WCHAR name[] = L"Document";
    const ZdaSource spec = { name, 8, 0, 1, 1, 0 };
    ZdaNative *state = NULL;
    CHECK(zda_store_create(NULL, &spec, 1, 32768, 4, 256, NULL, NULL, &state) == ZDA_OK);
    const uint16_t units[] = { 'a', 0xd83d, 0xde00, 'e', 0x301, '\n' };
    const uint32_t scalars[] = { 0, 1, 3, 4, 5, 6 }, paragraphs[] = { 0, 6, 6 };
    const ZdaTextInput input = { 1, units, scalars, paragraphs, 6, 6, 3 };
    ZdaText *candidate = NULL;
    CHECK(zda_native_text(state, &input, &candidate) == ZDA_OK);
    const uint32_t expected_graphemes[] = { 0, 1, 3, 5, 6 };
    CHECK(candidate->grapheme_count == 5 && !memcmp(candidate->graphemes, expected_graphemes, sizeof(expected_graphemes)));
    const ZdaSelection selected = { 0, 0 };
    ZdaMetadata meta = { 1, 3, &selected, 1, 0, 1, 1, 0 };
    CHECK(zda_native_publish(state, &candidate, &meta, 1) == ZDA_OK);
    zda_text_release(candidate);
    const ZdaCell cell = { 1, 3, { 4, 5, 8, 16 } };
    const ZdaGeometryInput geometry_input = { 1, 7, { 4, 5, 200, 100 }, &cell, 1, 2, NULL, 0, NULL, 0 };
    ZdaGeometry *geometry = NULL;
    CHECK(zda_native_geometry(state, &geometry_input, &geometry) == ZDA_OK);
    CHECK(zda_native_publish_geometry(state, &geometry, 1) == ZDA_OK);
    zda_geometry_release(geometry);
    const ZdaCaret stops[] = { { 1, 1, { 4, 5, 0, 16 } }, { 3, 0, { 12, 5, 0, 16 } } };
    const ZdaLine visual_line = { 0, 2, { 4, 5, 200, 16 } };
    ZdaGeometryInput with_stops = geometry_input;
    with_stops.carets = stops; with_stops.caret_count = 2;
    with_stops.lines = &visual_line; with_stops.line_count = 1;
    CHECK(zda_native_geometry(state, &with_stops, &geometry) == ZDA_OK);
    CHECK(zda_native_publish_geometry(state, &geometry, 1) == ZDA_OK);
    zda_geometry_release(geometry);
    ZdaCaret invalid_stops[2]; memcpy(invalid_stops, stops, sizeof(stops)); invalid_stops[0].position = 2;
    with_stops.carets = invalid_stops;
    CHECK(zda_native_geometry(state, &with_stops, &geometry) == ZDA_OK);
    CHECK(zda_native_publish_geometry(state, &geometry, 1) == ZDA_INVALID);
    zda_geometry_release(geometry);
    with_stops.caret_count = 32769;
    CHECK(zda_native_geometry(state, &with_stops, &geometry) == ZDA_INVALID && !geometry);
    with_stops.caret_count = 2;
    const ZdaLine broken_line = { 1, 2, { 4, 5, 200, 16 } }; with_stops.lines = &broken_line;
    CHECK(zda_native_geometry(state, &with_stops, &geometry) == ZDA_INVALID && !geometry);
    const ZdaCell split_surrogate = { 2, 3, { 4, 5, 8, 16 } };
    ZdaGeometryInput bad = geometry_input; bad.cells = &split_surrogate;
    CHECK(zda_native_geometry(state, &bad, &geometry) == ZDA_OK);
    CHECK(zda_native_publish_geometry(state, &geometry, 1) == ZDA_INVALID);
    zda_geometry_release(geometry);
    ZdaText *text = NULL; ZdaGeometry *current = NULL; ZdaCurrent metadata;
    CHECK(zda_acquire(state, 0, 1, &text, &current, &metadata) == S_OK);
    CHECK(current && current->projection_version == 7 && metadata.revision == 3 && current->caret_count == 2 && current->line_count == 1 && current->carets[0].rectangle.width == 0);
    zda_geometry_release(current); zda_text_release(text);
    ZdaTextInput next = input; next.text_version = 2;
    CHECK(zda_native_text(state, &next, &candidate) == ZDA_OK);
    meta.text_version = 2; meta.revision = 4;
    CHECK(zda_native_publish(state, &candidate, &meta, 1) == ZDA_OK);
    zda_text_release(candidate);
    CHECK(zda_acquire(state, 0, 1, &text, NULL, NULL) == (HRESULT)UIA_E_ELEMENTNOTAVAILABLE);
    CHECK(zda_acquire(state, 0, 2, &text, &current, NULL) == S_OK);
    CHECK(!current);
    // A getter already holding an immutable text ref can finish after its
    // state and source owner disappear. It never calls any Zig code.
    zda_native_begin_close(state);
    zda_store_release(state);
    CHECK(text->length == 6 && text->text[2] == 0xde00);
    HANDLE thread = CreateThread(NULL, 0, late_blob, text, 0, NULL);
    CHECK(thread != NULL);
    CHECK(WaitForSingleObject(thread, 5000) == WAIT_OBJECT_0);
    CloseHandle(thread);
    uint32_t after_accounts, after_blocks; uint64_t after_bytes;
    counts(&after_accounts, &after_blocks, &after_bytes);
    CHECK(after_accounts == before_accounts && after_blocks == before_blocks && after_bytes == before_bytes);
    return 0;
}
typedef struct Race { ZdaNative *state; volatile LONG stop, failed; } Race;
static DWORD WINAPI read_current(void *pointer) {
    Race *race = pointer;
    CoInitializeEx(NULL, COINIT_MULTITHREADED);
    while (!InterlockedCompareExchange(&race->stop, 0, 0)) {
        ZdaText *text = NULL;
        HRESULT result = zda_acquire(race->state, 0, UINT64_MAX, &text, NULL, NULL);
        if (SUCCEEDED(result)) {
            if (text->length != 1 || (text->text[0] != 'a' && text->text[0] != 'b')) InterlockedExchange(&race->failed, 1);
            zda_text_release(text);
        } else if (result != (HRESULT)UIA_E_ELEMENTNOTAVAILABLE) InterlockedExchange(&race->failed, 1);
    }
    zda_store_release(race->state);
    CoUninitialize(); return 0;
}
int zda_test_store_race(void) {
    uint32_t before_accounts, before_blocks; uint64_t before_bytes;
    counts(&before_accounts, &before_blocks, &before_bytes);
    const ZdaSource source = { NULL, 0, 0, 1, 1, 0 };
    ZdaNative *state = NULL;
    CHECK(zda_store_create(NULL, &source, 1, 32768, 4, 256, NULL, NULL, &state) == ZDA_OK);
    const uint16_t a[] = { 'a' }, b[] = { 'b' }; const uint32_t scalars[] = { 0, 1 }, paragraphs[] = { 0, 1 };
    ZdaTextInput inputs[2] = { { 1, a, scalars, paragraphs, 1, 2, 2 }, { 2, b, scalars, paragraphs, 1, 2, 2 } };
    ZdaText *candidates[2] = {0};
    for (int i = 0; i < 2; ++i) CHECK(zda_native_text(state, &inputs[i], &candidates[i]) == ZDA_OK);
    const ZdaSelection selection = {0}; ZdaMetadata meta = { 1, 1, &selection, 1, 0, 0, 1, 0 };
    Race race = { state, 0, 0 }; zda_store_retain(state);
    HANDLE thread = CreateThread(NULL, 0, read_current, &race, 0, NULL); CHECK(thread != NULL);
    for (int i = 0; i < 2000; ++i) {
        int index = i & 1; meta.text_version = index + 1; meta.revision = (uint64_t)i;
        CHECK(zda_native_publish(state, &candidates[index], &meta, 1) == ZDA_OK);
    }
    for (int i = 0; i < 2; ++i) zda_text_release(candidates[i]);
    zda_native_begin_close(state);
    InterlockedExchange(&race.stop, 1);
    zda_store_release(state);
    CHECK(WaitForSingleObject(thread, 5000) == WAIT_OBJECT_0); CloseHandle(thread);
    CHECK(!race.failed);
    uint32_t after_accounts, after_blocks; uint64_t after_bytes;
    counts(&after_accounts, &after_blocks, &after_bytes);
    CHECK(after_accounts == before_accounts && after_blocks == before_blocks && after_bytes == before_bytes);
    return 0;
}
