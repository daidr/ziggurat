/* Compiled content rule lists, kept by WebKitGTK's content filter store.
 * Every function runs on the GTK main thread. A compile operation owns its
 * store, rules and identifiers until its last asynchronous step returns; a
 * cancelled operation finishes those steps without calling its owner. */
#include <webkit2/webkit2.h>
#include <string.h>
#include "webkit_content_rules.h"

#define HASH_DIGITS 16

struct ZwkContentCompile {
    WebKitUserContentFilterStore *store;
    GBytes *source;
    char *id, *identifier;
    ZwkContentDone done;
    void *context;
    gboolean cancelled;
};

static gint live_compiles;

static void compile_free(ZwkContentCompile *op) {
    g_object_unref(op->store);
    if (op->source) g_bytes_unref(op->source);
    g_free(op->id); g_free(op->identifier); g_free(op);
    g_atomic_int_add(&live_compiles,-1);
}
static void compile_finish(ZwkContentCompile *op,WebKitUserContentFilter *filter,const GError *error) {
    if (!op->cancelled && op->done) {
        ZwkContentDone done=op->done; op->done=NULL;
        done(op->context,filter,error?error->domain==WEBKIT_USER_CONTENT_FILTER_ERROR&&error->code==WEBKIT_USER_CONTENT_FILTER_ERROR_INVALID_SOURCE:0,
            error?error->domain:0,error?error->code:0);
    } else if (filter) webkit_user_content_filter_unref(filter);
    compile_free(op);
}

/* A name of a list compiled for id from other rules: id, "-", and a hash of
 * HASH_DIGITS lowercase hexadecimal digits other than the current one. */
static gboolean stale(const char *id,const char *current,const char *name) {
    size_t length=strlen(id);
    if (!strcmp(name,current) || strncmp(name,id,length) || name[length]!='-' || strlen(name+length+1)!=HASH_DIGITS) return FALSE;
    for (const char *c=name+length+1;*c;c++) if (!((*c>='0'&&*c<='9')||(*c>='a'&&*c<='f'))) return FALSE;
    return TRUE;
}
static void removed(GObject *store,GAsyncResult *result,gpointer data) {
    (void)data;
    GError *error=NULL;
    webkit_user_content_filter_store_remove_finish(WEBKIT_USER_CONTENT_FILTER_STORE(store),result,&error);
    g_clear_error(&error);
}
typedef struct { char *id, *current; } Sweep;
static void listed(GObject *object,GAsyncResult *result,gpointer data) {
    Sweep *sweep=data;
    WebKitUserContentFilterStore *store=WEBKIT_USER_CONTENT_FILTER_STORE(object);
    gchar **names=webkit_user_content_filter_store_fetch_identifiers_finish(store,result);
    for (gchar **name=names;name&&*name;name++)
        if (stale(sweep->id,sweep->current,*name)) webkit_user_content_filter_store_remove(store,*name,NULL,removed,NULL);
    g_strfreev(names);
    g_free(sweep->id); g_free(sweep->current); g_free(sweep);
}
/* Removes the lists the store keeps for id but the current one. The store
 * object stays referenced by its pending calls. */
static void sweep(ZwkContentCompile *op) {
    Sweep *sweep=g_try_new0(Sweep,1);
    if (!sweep) return;
    sweep->id=g_strdup(op->id); sweep->current=g_strdup(op->identifier);
    webkit_user_content_filter_store_fetch_identifiers(op->store,NULL,listed,sweep);
}
static void saved(GObject *store,GAsyncResult *result,gpointer data) {
    ZwkContentCompile *op=data;
    GError *error=NULL;
    WebKitUserContentFilter *filter=webkit_user_content_filter_store_save_finish(WEBKIT_USER_CONTENT_FILTER_STORE(store),result,&error);
    if (filter) sweep(op);
    compile_finish(op,filter,error);
    g_clear_error(&error);
}
static void loaded(GObject *store,GAsyncResult *result,gpointer data) {
    ZwkContentCompile *op=data;
    GError *error=NULL;
    WebKitUserContentFilter *filter=webkit_user_content_filter_store_load_finish(WEBKIT_USER_CONTENT_FILTER_STORE(store),result,&error);
    g_clear_error(&error);
    if (filter || op->cancelled) { compile_finish(op,filter,NULL); return; }
    webkit_user_content_filter_store_save(op->store,op->identifier,op->source,NULL,saved,op);
}

int zwk_content_compile(const char *directory,const char *id,const char *identifier,const char *rules,size_t length,ZwkContentDone done,void *context,ZwkContentCompile **out) {
    *out=NULL;
    if (!directory || !id || !identifier || !rules || !done || !g_path_is_absolute(directory)) return ZWK_CONTENT_INVALID;
    if (g_mkdir_with_parents(directory,0700)!=0) return ZWK_CONTENT_STORAGE;
    ZwkContentCompile *op=g_try_new0(ZwkContentCompile,1);
    if (!op) return ZWK_CONTENT_OOM;
    op->store=webkit_user_content_filter_store_new(directory);
    op->source=g_bytes_new(rules,length);
    op->id=g_strdup(id); op->identifier=g_strdup(identifier);
    op->done=done; op->context=context;
    g_atomic_int_inc(&live_compiles);
    webkit_user_content_filter_store_load(op->store,op->identifier,NULL,loaded,op);
    *out=op;
    return ZWK_CONTENT_OK;
}
void zwk_content_cancel(ZwkContentCompile *op) {
    if (op) { op->cancelled=TRUE; op->done=NULL; op->context=NULL; }
}
void zwk_content_filter_unref(void *filter) {
    if (filter) webkit_user_content_filter_unref(filter);
}
const char *zwk_content_filter_identifier(void *filter) {
    return webkit_user_content_filter_get_identifier(filter);
}
uint32_t zwk_content_compile_count(void) { return (uint32_t)g_atomic_int_get(&live_compiles); }
