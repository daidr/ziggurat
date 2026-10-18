/* Standalone native ownership oracle: actual generic host and the production
 * three-file provider, with only its explicit fallible C allocator faulted. */
#include "../src/platform/linux.c"
#include "../src/document_accessibility/linux_internal.h"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <math.h>

#define CHECK(value) do { if (!(value)) { fprintf(stderr,"DA owner:%u: %s\n",__LINE__,#value); exit(1); } } while (0)
static int event(void *context, const NativeEvent *value) { (void)context; (void)value; return 0; }
static void dispatch(void *context) { (void)context; }
static void empty(void) {
    uint32_t accounts,blocks; uint64_t bytes;
    zda_ledger_counts(&accounts,&blocks,&bytes); CHECK(!accounts && !blocks && !bytes);
}
static ZdaNative *create(void) {
    uint16_t name[]={'o','w','n','e','r'};
    ZdaSource spec={name,5,1,0,0,0}; ZdaError error={0}; ZdaNative *state=NULL;
    CHECK(zda_linux_create(&spec,1,1048576,32,1024,&error,&state)==ZDA_OK && state);
    CHECK(!error.domain && !error.code);
    name[0]='X'; CHECK(!strcmp(atk_object_get_name(ATK_OBJECT(state)),"owner"));
    return state;
}
static ZdaText *text_new(ZdaNative *state, uint64_t version, gboolean alternate) {
    uint16_t data[]={'a',0xd83d,0xde00,'b','\n'};
    uint32_t scalars[]={0,1,3,4,5}, paragraphs[]={0,5,5};
    if (alternate) data[0]='z';
    ZdaTextInput input={version,data,scalars,paragraphs,5,5,3}; ZdaText *text=NULL;
    CHECK(zda_native_text(state,&input,&text)==ZDA_OK && text);
    data[0]='X'; return text;
}
static int publish_at(ZdaNative *state, ZdaText *text, uint64_t revision, uint32_t caret) {
    ZdaSelection selection={0,caret}; ZdaMetadata metadata={text->version,revision,&selection,1,0,0,1,0};
    return zda_native_publish(state,&text,&metadata,1);
}
static int publish(ZdaNative *state, ZdaText *text, uint64_t revision) { return publish_at(state,text,revision,0); }
static void equals(ZdaNative *state, const char *expected) {
    char *text=atk_text_get_text(ATK_TEXT(state),0,-1);
    CHECK(text && !strcmp(text,expected)); g_free(text);
}
static ZdaGeometryInput geometry_input(ZdaCell *cells, ZdaCaret *carets, ZdaLine *lines) {
    cells[0]=(ZdaCell){0,1,{8,8,10,16}};
    cells[1]=(ZdaCell){1,3,{18,8,20,16}};
    cells[2]=(ZdaCell){3,4,{38,8,10,16}};
    for (unsigned i=0;i<5;++i) {
        static const uint32_t positions[]={0,1,3,4,5};
        static const double x[]={8,18,38,48,8};
        carets[i]=(ZdaCaret){positions[i],1,{x[i],i==4?24:8,0,16}};
    }
    lines[0]=(ZdaLine){0,4,{8,8,70,16}};
    lines[1]=(ZdaLine){4,1,{8,24,70,16}};
    return (ZdaGeometryInput){0,1,{8,8,70,40},cells,3,1,carets,5,lines,2};
}
static ZdaHitInput hit_input(ZdeHitBlock *blocks,ZdeHitLine *lines,ZdeHitStop *stops,double scale) {
    blocks[0]=(ZdeHitBlock){0,2,0,32};
    lines[0]=(ZdeHitLine){0,16,0,4}; lines[1]=(ZdeHitLine){16,16,4,1};
    static const uint32_t positions[]={0,1,3,4,5};
    static const float x[]={0,10,30,40,0};
    for (unsigned i=0;i<5;++i) stops[i]=(ZdeHitStop){x[i],1,positions[i]};
    return (ZdaHitInput){.revision=0,.text_version=0,.projection_version=1,.geometry_generation=1,.scale=scale,
        .packet={.bounds={8,8,70,40},.scroll_x=0,.mode=0,.block_count=1,.line_count=2,.stop_count=5,.placement_count=0,
            .blocks=blocks,.lines=lines,.stops=stops,.placements=NULL}};
}
typedef struct SignalProbe { unsigned removed,inserted; gboolean close_on_remove,close_on_insert; unsigned carets; } SignalProbe;
static void signal_caret(AtkText *object, int scalar, void *context) {
    (void)object; (void)scalar; ++((SignalProbe *)context)->carets;
}
typedef struct CaretProbe { unsigned count; int last; } CaretProbe;
static void changed_caret(AtkText *object, int scalar, void *context) {
    CaretProbe *probe=context; ++probe->count; probe->last=scalar;
    CHECK(atk_text_get_caret_offset(object)==scalar);
}
static void caret_events(void) {
    ZdaNative *state=create(); ZdaText *old=text_new(state,0,FALSE), *next=text_new(state,1,TRUE);
    CHECK(publish(state,old,0)==ZDA_OK);
    CaretProbe probe={0,-1};
    g_signal_connect(state,"text-caret-moved",G_CALLBACK(changed_caret),&probe);
    CHECK(publish_at(state,next,1,3)==ZDA_OK);
    CHECK(probe.count==1 && probe.last==2); /* Astral UTF16 unit3 is scalar2. */
    CHECK(publish_at(state,next,1,3)==ZDA_OK && probe.count==1);
    CHECK(publish_at(state,next,2,4)==ZDA_OK && probe.count==2 && probe.last==3);
    zda_text_release(old); zda_text_release(next);
    CHECK(zda_native_disconnect(state)==ZDA_OK); empty();
    puts("DA owner: changed-text/same-text exact scalar caret events; no duplicate");
}
static void removed(AtkText *object, int offset, int count, const char *payload, void *context) {
    SignalProbe *probe=context; ++probe->removed;
    CHECK(offset==0 && count==4 && !strcmp(payload,"a😀b\n"));
    equals((ZdaNative *)object,"z😀b\n");
    if (probe->close_on_remove) CHECK(zda_native_disconnect((ZdaNative *)object)==ZDA_OK);
    /* Outbound closure cannot retire this already-captured payload block. */
    CHECK(!strcmp(payload,"a😀b\n"));
}
static void inserted(AtkText *object, int offset, int count, const char *payload, void *context) {
    SignalProbe *probe=context; ++probe->inserted;
    CHECK(offset==0 && count==4 && !strcmp(payload,"z😀b\n"));
    equals((ZdaNative *)object,"z😀b\n");
    if (probe->close_on_insert) CHECK(zda_native_disconnect((ZdaNative *)object)==ZDA_OK);
    CHECK(!strcmp(payload,"z😀b\n"));
}
static gpointer wrong_thread(gpointer context) {
    CHECK(zda_linux_live(context)==ZDA_INVALID); return NULL;
}
static gpointer release_blobs(gpointer context) {
    void **values=context;
    zda_text_release(values[0]); zda_geometry_release(values[1]); zda_account_release(values[2]);
    return NULL;
}
static void check_empty(void) {
    ZdaNative *state=create();
    CHECK(atk_text_get_character_count(ATK_TEXT(state))==-1);
    uint16_t data=0; uint32_t scalars[]={0},paragraphs[]={0,0};
    ZdaTextInput input={0,&data,scalars,paragraphs,0,1,2}; ZdaText *text=NULL;
    CHECK(zda_native_text(state,&input,&text)==ZDA_OK);
    CHECK(publish(state,text,0)==ZDA_OK);
    CHECK(atk_text_get_character_count(ATK_TEXT(state))==0); equals(state,"");
    AtkObject *late=ATK_OBJECT(g_object_ref(state));
    CHECK(zda_native_disconnect(state)==ZDA_OK);
    CHECK(atk_text_get_character_count(ATK_TEXT(late))==-1);
    zda_text_release(text); g_object_unref(late); empty();
    puts("DA owner: unavailable -1 distinct from published empty 0");
}
static void invalid_and_oom(void) {
    uint16_t name[]={'x'}; ZdaSource spec={name,1,1,0,0,0}; ZdaError error;
    ZdaNative *state=(void *)1;
    CHECK(zda_linux_create(&spec,2,1048576,32,1024,&error,&state)==ZDA_INVALID && !state);
    spec.selectable=1;
    CHECK(zda_linux_create(&spec,1,1048576,32,1024,&error,&state)==ZDA_INVALID && !state);
    empty();
    spec.selectable=0; zda_linux_test_fail_after(0);
    CHECK(zda_linux_create(&spec,1,1048576,32,1024,&error,&state)==ZDA_OOM && !state);
    empty(); state=create();
    CHECK(atk_text_get_character_count(ATK_TEXT(state))==-1);
    uint16_t data[]={0}; uint32_t scalars[]={0,1}, paragraphs[]={0,1};
    ZdaTextInput input={0,data,scalars,paragraphs,1,2,2}; ZdaText *out=(void *)1;
    CHECK(zda_native_text(state,&input,&out)==ZDA_INVALID && !out);
    data[0]='x'; scalars[1]=0;
    CHECK(zda_native_text(state,&input,&out)==ZDA_INVALID && !out);
    scalars[1]=1; zda_linux_test_fail_after(0);
    CHECK(zda_native_text(state,&input,&out)==ZDA_OOM && !out);
    ZdaText *old=text_new(state,0,FALSE), *next=text_new(state,1,TRUE);
    CHECK(publish(state,old,0)==ZDA_OK); equals(state,"a😀b\n");
    for (int at=0;at<2;++at) {
        zda_linux_test_fail_after(at);
        CHECK(publish(state,next,1)==ZDA_OOM); equals(state,"a😀b\n");
    }
    GThread *thread=g_thread_new("DA wrong-thread",wrong_thread,state); g_thread_join(thread);
    ZdaStats stats; zda_native_stats(state,&stats);
    CHECK(stats.states==1 && stats.providers==1 && stats.ranges==0 && stats.blobs==2 && stats.peak_bytes>=stats.bytes);
    zda_text_release(old); zda_text_release(next);
    CHECK(zda_native_disconnect(state)==ZDA_OK); empty();
    puts("DA owner: invalid/NUL/tables/actual allocator OOM+reserved peak/wrong-thread");
}
static void signals(unsigned close_mode) {
    ZdaNative *state=create(); ZdaText *old=text_new(state,0,FALSE), *next=text_new(state,1,TRUE);
    CHECK(publish(state,old,0)==ZDA_OK);
    SignalProbe probe={.close_on_remove=close_mode==1,.close_on_insert=close_mode==2};
    g_signal_connect(state,"text-remove::system",G_CALLBACK(removed),&probe);
    g_signal_connect(state,"text-insert::system",G_CALLBACK(inserted),&probe);
    g_signal_connect(state,"text-caret-moved",G_CALLBACK(signal_caret),&probe);
    /* The late client reference is separate from Bridge initial ownership. */
    AtkObject *late=ATK_OBJECT(g_object_ref(state));
    CHECK(publish_at(state,next,1,close_mode?3:0)==ZDA_OK);
    CHECK(probe.removed==1 && probe.inserted==(close_mode==1?0U:1U));
    CHECK(!probe.carets); /* Either foreign close prevents the changed event. */
    if (!close_mode) CHECK(zda_native_disconnect(state)==ZDA_OK);
    CHECK(!atk_text_get_text(ATK_TEXT(late),0,-1));
    zda_text_release(old); zda_text_release(next); g_object_unref(late); empty();
    puts("DA owner: exact modern remove/insert payload and reentrant disconnect");
}
int main(void) {
    int error=0; NativeApp *app=zlg_app_create(NULL,dispatch,&error);
    CHECK(app && !error); empty(); check_empty(); invalid_and_oom(); caret_events(); signals(0); signals(1); signals(2);
    NativeWindow *native=zlg_window_create_mode_host(NULL,event,"DA owner",80,60,0,0,NULL,0,0,1,0,1,&error);
    CHECK(native && !error);
    ZdaNative *state=create(); CHECK(zda_linux_prepare(state,native)==ZDA_OK);
    CHECK(zda_linux_mount(state)==ZDA_OK);
    GtkAllocation allocation={0,0,80,60}; gtk_widget_size_allocate(native->area,&allocation);
    double scale=0; CHECK(zda_linux_position(state,&scale)==ZDA_OK && scale==gtk_widget_get_scale_factor(native->area));
    ZdaText *text=text_new(state,0,FALSE); CHECK(publish(state,text,0)==ZDA_OK);
    ZdaCell cells[3]; ZdaCaret carets[5]; ZdaLine lines[2];
    ZdaGeometryInput input=geometry_input(cells,carets,lines); input.scale=scale;
    ZdaGeometry *geometry=(void *)1;
    cells[1].start=2;
    CHECK(zda_native_geometry(state,&input,&geometry)==ZDA_INVALID && !geometry);
    cells[1].start=1; zda_linux_test_fail_after(0);
    CHECK(zda_native_geometry(state,&input,&geometry)==ZDA_OOM && !geometry);
    CHECK(zda_native_geometry(state,&input,&geometry)==ZDA_OK && geometry);
    CHECK(zda_native_publish_geometry(state,&geometry,1)==ZDA_OK);
    CHECK(atk_text_get_offset_at_point(ATK_TEXT(state),20,12,ATK_XY_PARENT)==-1); /* No guessed fallback. */
    zda_geometry_release(geometry); geometry=NULL;
    ZdeHitBlock hit_blocks[1]; ZdeHitLine hit_lines[2]; ZdeHitStop hit_stops[5];
    ZdaHitInput hit=hit_input(hit_blocks,hit_lines,hit_stops,scale);
    hit.packet.mode=7;
    CHECK(zda_linux_geometry_hit(state,&input,&hit,&geometry)==ZDA_INVALID && !geometry);
    hit.packet.mode=0;
    zda_linux_test_fail_after(0);
    CHECK(zda_linux_geometry_hit(state,&input,&hit,&geometry)==ZDA_OOM && !geometry);
    CHECK(zda_linux_geometry_hit(state,&input,&hit,&geometry)==ZDA_OK && geometry);
    CHECK(zda_native_publish_geometry(state,&geometry,1)==ZDA_OK);
    hit_stops[1].position=3; /* The C geometry has already copied its payload. */
    gint x,y,width,height;
    atk_text_get_character_extents(ATK_TEXT(state),1,&x,&y,&width,&height,ATK_XY_PARENT);
    CHECK(x==18 && y==8 && width==20 && height==16);
    CHECK(atk_text_get_offset_at_point(ATK_TEXT(state),20,12,ATK_XY_PARENT)==1);
    hit_stops[1].position=1;
    ZdaCaret filtered_caret=carets[4]; ZdaLine filtered_line={0,1,{8,24,70,16}};
    ZdaGeometryInput filtered=input;
    filtered.cells=NULL; filtered.cell_count=0; filtered.carets=&filtered_caret; filtered.caret_count=1;
    filtered.lines=&filtered_line; filtered.line_count=1; hit.domain=1;
    ZdaGeometry *filtered_geometry=NULL;
    CHECK(zda_linux_geometry_hit(state,&filtered,&hit,&filtered_geometry)==ZDA_OK);
    CHECK(zda_native_publish_geometry(state,&filtered_geometry,1)==ZDA_OK);
    CHECK(atk_text_get_offset_at_point(ATK_TEXT(state),20,12,ATK_XY_PARENT)==-1);
    CHECK(atk_text_get_offset_at_point(ATK_TEXT(state),20,28,ATK_XY_PARENT)==4);
    filtered.carets=NULL; filtered.caret_count=0; filtered.lines=NULL; filtered.line_count=0;
    ZdaGeometry *empty_geometry=NULL;
    CHECK(zda_linux_geometry_hit(state,&filtered,&hit,&empty_geometry)==ZDA_OK);
    CHECK(zda_native_publish_geometry(state,&empty_geometry,1)==ZDA_OK);
    CHECK(atk_text_get_offset_at_point(ATK_TEXT(state),20,28,ATK_XY_PARENT)==-1);
    CHECK(zda_native_publish_geometry(state,&geometry,1)==ZDA_OK);
    zda_geometry_release(filtered_geometry); zda_geometry_release(empty_geometry);
    ZdeHitResult unchanged={99,1,0};
    CHECK(zde_prepared_hit_query(&hit.packet,NAN,0,&unchanged)==ZDA_INVALID && unchanged.position==99);
    AtkStateSet *states=atk_object_ref_state_set(ATK_OBJECT(state));
    CHECK(!atk_state_set_contains_state(states,ATK_STATE_SHOWING)); g_object_unref(states);
    ZdaAccount *account=zda_native_account(state);
    AtkObject *late=ATK_OBJECT(g_object_ref(state));
    zlg_window_destroy(native); /* Raw native token mark closes C ingress. */
    CHECK(zda_linux_live(state)==ZDA_CLOSED && !atk_text_get_text(ATK_TEXT(late),0,-1));
    CHECK(zda_native_disconnect(state)==ZDA_OK);
    CHECK(zda_account_reserve_host(account,8)==ZDA_CLOSED);
    zlg_app_destroy(app); CHECK(!zlg_resource_count());
    g_object_unref(late); /* Owner-thread ATK release, even after App. */
    void *blobs[]={text,geometry,account};
    GThread *thread=g_thread_new("DA C-only release",release_blobs,blobs); g_thread_join(thread);
    empty();
    unsigned tokens,registered,mounted; zlg_accessibility_counts(&tokens,&registered,&mounted);
    CHECK(!tokens && !registered && !mounted);
    printf("DA owner passed: 8 groups; actual State/provider one GObject=%zu Text=%zu Geometry=%zu; late blobs/account C-only cross-thread\n",sizeof(ZdaNative),sizeof(ZdaText),sizeof(ZdaGeometry));
    printf("Prepared hit C ABI: Header=%zu Packet=%zu Block=%zu Line=%zu Stop=%zu Placement=%zu Result=%zu\n",sizeof(ZdaHitInput),sizeof(ZdeHitPacket),sizeof(ZdeHitBlock),sizeof(ZdeHitLine),sizeof(ZdeHitStop),sizeof(ZdeHitPlacement),sizeof(ZdeHitResult));
    return 0;
}
