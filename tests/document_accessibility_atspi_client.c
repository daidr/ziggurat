#include <atspi/atspi.h>
#include <fcntl.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

#define CHECK(value) do { if (!(value)) { fprintf(stderr,"AT-SPI client:%u: %s\n",__LINE__,#value); exit(1); } } while (0)
static const char initial[]="a😀é אבג\r\nfull document\nlast hidden paragraph";
static AtspiAccessible *find(AtspiAccessible *node, unsigned depth) {
    if (depth>8) return NULL;
    GError *error=NULL;
    char *name=atspi_accessible_get_name(node,&error);
    if (error) { g_error_free(error); return NULL; }
    gboolean match=name && strcmp(name,"Ziggurat Linux document oracle")==0;
    g_free(name);
    if (match) return g_object_ref(node);
    int count=atspi_accessible_get_child_count(node,&error);
    if (error) { g_error_free(error); return NULL; }
    if (count>128) count=128;
    for (int i=0;i<count;++i) {
        AtspiAccessible *child=atspi_accessible_get_child_at_index(node,i,&error);
        if (error) { g_clear_error(&error); continue; }
        if (!child) continue;
        AtspiAccessible *result=find(child,depth+1);
        g_object_unref(child);
        if (result) return result;
    }
    return NULL;
}
static void events(void) {
    while (g_main_context_pending(NULL)) g_main_context_iteration(NULL,FALSE);
}
static gboolean text_equals(AtspiText *text, const char *wanted) {
    GError *error=NULL;
    char *value=atspi_text_get_text(text,0,-1,&error);
    gboolean equal=!error && value && strcmp(value,wanted)==0;
    g_clear_error(&error); g_free(value); return equal;
}
static void command(int fd, char value) { CHECK(write(fd,&value,1)==1); }
int main(int argc, char **argv) {
    CHECK(argc==2);
    int control=open(argv[1],O_WRONLY|O_NONBLOCK);
    CHECK(control>=0);
    CHECK(atspi_init()==0);
    atspi_set_timeout(3000,3000);
    AtspiAccessible *document=NULL;
    for (unsigned i=0;i<200 && !document;++i) {
        AtspiAccessible *desktop=atspi_get_desktop(0);
        if (desktop) { document=find(desktop,0); g_object_unref(desktop); }
        if (!document) { events(); g_usleep(25000); }
    }
    CHECK(document);
    AtspiText *text=atspi_accessible_get_text_iface(document);
    AtspiComponent *component=atspi_accessible_get_component_iface(document);
    CHECK(text && component);
    CHECK(!atspi_accessible_get_editable_text_iface(document));
    CHECK(!atspi_accessible_get_action_iface(document));
    CHECK(text_equals(text,initial));
    GError *error=NULL;
    CHECK(atspi_text_get_character_count(text,&error)==g_utf8_strlen(initial,-1) && !error);
    CHECK(atspi_text_get_character_at_offset(text,1,&error)==0x1f600 && !error);
    AtspiTextRange *ch=atspi_text_get_string_at_offset(text,1,ATSPI_TEXT_GRANULARITY_CHAR,&error);
    CHECK(ch && !error && ch->start_offset==1 && ch->end_offset==2 && strcmp(ch->content,"😀")==0);
    g_boxed_free(ATSPI_TYPE_TEXT_RANGE,ch);
    CHECK(atspi_text_get_n_selections(text,&error)==0 && !error);
    CHECK(!atspi_text_set_caret_offset(text,1,&error) && !error);
    CHECK(!atspi_component_grab_focus(component,&error) && !error);
    AtspiRect *rect=atspi_text_get_character_extents(text,1,ATSPI_COORD_TYPE_SCREEN,&error);
    CHECK(rect && !error && rect->width>0 && rect->height>0);
    int hit=atspi_text_get_offset_at_point(text,rect->x,rect->y+rect->height/2,ATSPI_COORD_TYPE_SCREEN,&error);
    CHECK(!error && hit>=0 && hit<=2);
    g_boxed_free(ATSPI_TYPE_RECT,rect);
    command(control,'r');
    gboolean replaced=FALSE;
    for (unsigned i=0;i<200 && !replaced;++i) {
        events(); replaced=text_equals(text,"external replacement 😀\n");
        if (!replaced) g_usleep(25000);
    }
    CHECK(replaced);
    command(control,'c');
    gboolean defunct=FALSE;
    for (unsigned i=0;i<200 && !defunct;++i) {
        events();
        AtspiStateSet *states=atspi_accessible_get_state_set(document);
        if (states) { defunct=atspi_state_set_contains(states,ATSPI_STATE_DEFUNCT); g_object_unref(states); }
        if (!defunct) g_usleep(25000);
    }
    CHECK(defunct);
    command(control,'q');
    close(control);
    g_object_unref(text); g_object_unref(component); g_object_unref(document);
    atspi_exit();
    puts("external AT-SPI passed: desktop discovery, genuine Text/Component, full Unicode/CHAR, read-only, screen geometry/point, replacement and defunct");
    return 0;
}
