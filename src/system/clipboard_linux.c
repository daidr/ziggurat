#include <gtk/gtk.h>
#include <stdint.h>
#include <string.h>

/* GTK selection glue for system.clipboard. The Zig Board owns policy; this
 * file owns only GTK references and copies. Offers and reads keep their own
 * storage, so a late GTK callback after Board close never reaches Zig. */

enum { KIND_TEXT, KIND_HTML, KIND_PNG, KIND_FILES, KIND_CUSTOM };
enum { STATUS_DATA, STATUS_UNAVAILABLE, STATUS_MALFORMED, STATUS_TOO_MANY_FILES, STATUS_FORMATS };
enum { FLAG_TEXT = 1, FLAG_HTML = 2, FLAG_PNG = 4, FLAG_FILES = 8 };
#define MAX_FILES 1024
#define GNOME_VARIANT 0x10000u

typedef struct ZscItem { int kind; const char *name; size_t name_len; const uint8_t *data; size_t len; } ZscItem;
typedef struct ZscCallbacks {
    void (*changed)(void *owner);
    void (*lost)(void *owner);
    int (*render)(void *owner, size_t index, void *sink);
    void (*read_done)(void *request, int status, const uint8_t *data, size_t len, uint32_t flags);
} ZscCallbacks;
typedef struct ZscBoard ZscBoard;
typedef struct ZscEntry { int kind; GdkAtom target; GBytes *data; } ZscEntry;
typedef struct ZscOffer { ZscBoard *board; gboolean lazy; size_t count; ZscEntry entries[16]; } ZscOffer;
struct ZscBoard { GtkClipboard *clipboard; void *owner; ZscCallbacks callbacks; gulong changed; ZscOffer *current; };
typedef struct ZscRead { ZscBoard *board; void *request; int kind; gboolean fallback, starting; int status; uint32_t flags; GBytes *deferred; } ZscRead;
typedef struct ZscSink { GByteArray *bytes; } ZscSink;

static gint resources;
uint32_t zsc_resource_count(void) { return (uint32_t)g_atomic_int_get(&resources); }

static void owner_changed(GtkClipboard *clipboard, GdkEvent *event, gpointer data) {
    (void)clipboard; (void)event;
    ZscBoard *board = data;
    if (board->owner) board->callbacks.changed(board->owner);
}
ZscBoard *zsc_board_create(void *owner, const ZscCallbacks *callbacks) {
    GdkDisplay *display = gdk_display_get_default();
    if (!display) return NULL;
    ZscBoard *board = g_try_new0(ZscBoard, 1);
    if (!board) return NULL;
    g_atomic_int_inc(&resources);
    board->clipboard = gtk_clipboard_get_for_display(display, GDK_SELECTION_CLIPBOARD);
    board->owner = owner;
    board->callbacks = *callbacks;
    board->changed = g_signal_connect(board->clipboard, "owner-change", G_CALLBACK(owner_changed), board);
    return board;
}

static void offer_free(ZscOffer *offer) {
    for (size_t i = 0; i < offer->count; i++) if (offer->entries[i].data) g_bytes_unref(offer->entries[i].data);
    g_free(offer);
    g_atomic_int_add(&resources, -1);
}
static void sink_into(GtkSelectionData *selection, int kind, guint variant, const uint8_t *data, size_t len) {
    GdkAtom target = gtk_selection_data_get_target(selection);
    if (kind == KIND_TEXT) { gtk_selection_data_set_text(selection, (const gchar *)data, (gint)len); return; }
    if (kind != KIND_FILES) { gtk_selection_data_set(selection, target, 8, data, (gint)len); return; }
    GString *list = g_string_new(variant ? "copy" : NULL);
    size_t start = 0;
    for (size_t i = 0; i <= len; i++) {
        if (i < len && data[i]) continue;
        gchar *path = g_strndup((const gchar *)data + start, i - start);
        gchar *uri = g_filename_to_uri(path, NULL, NULL);
        g_free(path);
        start = i + 1;
        if (!uri) continue;
        if (variant || list->len) g_string_append(list, variant ? "\n" : "\r\n");
        g_string_append(list, uri);
        g_free(uri);
    }
    if (!variant) g_string_append(list, "\r\n");
    gtk_selection_data_set(selection, target, 8, (const guchar *)list->str, (gint)list->len);
    g_string_free(list, TRUE);
}
static void offer_get(GtkClipboard *clipboard, GtkSelectionData *selection, guint info, gpointer data) {
    (void)clipboard;
    ZscOffer *offer = data;
    size_t index = info & 0xffffu;
    if (index >= offer->count) return;
    ZscEntry *entry = &offer->entries[index];
    if (!offer->lazy) {
        gsize len = 0;
        const uint8_t *bytes = g_bytes_get_data(entry->data, &len);
        sink_into(selection, entry->kind, info & GNOME_VARIANT, bytes, len);
        return;
    }
    ZscBoard *board = offer->board;
    if (!board || !board->owner || board->current != offer) return;
    ZscSink sink = { g_byte_array_new() };
    if (board->callbacks.render(board->owner, index, &sink)) sink_into(selection, entry->kind, info & GNOME_VARIANT, sink.bytes->data, sink.bytes->len);
    g_byte_array_unref(sink.bytes);
}
static void offer_clear(GtkClipboard *clipboard, gpointer data) {
    (void)clipboard;
    ZscOffer *offer = data;
    ZscBoard *board = offer->board;
    if (board && board->current == offer) {
        board->current = NULL;
        if (board->owner) board->callbacks.lost(board->owner);
    }
    offer_free(offer);
}
int zsc_sink_set(void *sink, const uint8_t *data, size_t len) {
    ZscSink *state = sink;
    if (len > G_MAXINT) return 0;
    g_byte_array_append(state->bytes, data, (guint)len);
    return 1;
}

/* Copies eager data first; set_with_data then calls the previous offer's
 * clear function, which may end a live lazy offer through callbacks.lost. */
static int publish(ZscBoard *board, const ZscItem *items, size_t count, gboolean lazy) {
    ZscOffer *offer = g_try_new0(ZscOffer, 1);
    if (!offer) return 0;
    g_atomic_int_inc(&resources);
    offer->board = board; offer->lazy = lazy; offer->count = count;
    GtkTargetList *list = gtk_target_list_new(NULL, 0);
    for (size_t i = 0; i < count; i++) {
        const ZscItem *item = &items[i];
        ZscEntry *entry = &offer->entries[i];
        entry->kind = item->kind;
        if (!lazy) entry->data = g_bytes_new(item->data, item->len);
        switch (item->kind) {
        case KIND_TEXT: gtk_target_list_add_text_targets(list, (guint)i); break;
        case KIND_HTML: gtk_target_list_add(list, gdk_atom_intern_static_string("text/html"), 0, (guint)i); break;
        case KIND_PNG: gtk_target_list_add(list, gdk_atom_intern_static_string("image/png"), 0, (guint)i); break;
        case KIND_FILES:
            gtk_target_list_add(list, gdk_atom_intern_static_string("text/uri-list"), 0, (guint)i);
            gtk_target_list_add(list, gdk_atom_intern_static_string("x-special/gnome-copied-files"), 0, (guint)i | GNOME_VARIANT);
            break;
        default: {
            gchar *name = g_strndup(item->name, item->name_len);
            gtk_target_list_add(list, gdk_atom_intern(name, FALSE), 0, (guint)i);
            g_free(name);
        }
        }
    }
    gint n = 0;
    GtkTargetEntry *targets = gtk_target_table_new_from_list(list, &n);
    gtk_target_list_unref(list);
    gboolean ok = gtk_clipboard_set_with_data(board->clipboard, targets, (guint)n, offer_get, offer_clear, offer);
    gtk_target_table_free(targets, n);
    if (!ok) { offer_free(offer); return 0; }
    board->current = offer;
    return 1;
}
int zsc_board_write(ZscBoard *board, const ZscItem *items, size_t count) { return publish(board, items, count, FALSE); }
int zsc_board_offer(ZscBoard *board, const ZscItem *items, size_t count) { return publish(board, items, count, TRUE); }
void zsc_board_revoke(ZscBoard *board) {
    if (board->current && board->current->lazy) gtk_clipboard_clear(board->clipboard);
}
/* Eager data keeps serving from its own copy after the Board closes; a lazy
 * offer cannot render without its provider and is cleared. */
void zsc_board_destroy(ZscBoard *board) {
    zsc_board_revoke(board);
    if (board->current) board->current->board = NULL;
    board->current = NULL;
    board->owner = NULL;
    g_signal_handler_disconnect(board->clipboard, board->changed);
    g_free(board);
    g_atomic_int_add(&resources, -1);
}

static void read_finish(ZscRead *read, int status, const uint8_t *data, size_t len, uint32_t flags);
static gboolean read_deferred(gpointer data) {
    ZscRead *read = data;
    gsize len = 0;
    const uint8_t *bytes = g_bytes_get_data(read->deferred, &len);
    read->starting = FALSE;
    read_finish(read, read->status, bytes, len, read->flags);
    return G_SOURCE_REMOVE;
}
/* GTK answers a request synchronously when this process owns the selection.
 * Such a result is copied and delivered from an idle source instead, so no
 * result callback ever runs inside zsc_read_start. */
static void read_finish(ZscRead *read, int status, const uint8_t *data, size_t len, uint32_t flags) {
    if (read->starting) {
        read->status = status; read->flags = flags;
        read->deferred = g_bytes_new(data, len);
        return;
    }
    if (read->request) read->board->callbacks.read_done(read->request, status, data, len, flags);
    if (read->deferred) g_bytes_unref(read->deferred);
    g_free(read);
    g_atomic_int_add(&resources, -1);
}
static gboolean valid_text(const gchar *data, size_t len) {
    return g_utf8_validate(data, (gssize)len, NULL) && !memchr(data, 0, len);
}
static void text_received(GtkClipboard *clipboard, const gchar *text, gpointer data) {
    (void)clipboard;
    if (!text) { read_finish(data, STATUS_UNAVAILABLE, NULL, 0, 0); return; }
    size_t len = strlen(text);
    read_finish(data, g_utf8_validate(text, (gssize)len, NULL) ? STATUS_DATA : STATUS_MALFORMED, (const uint8_t *)text, len, 0);
}
static void uris_received(GtkClipboard *clipboard, gchar **uris, gpointer data) {
    (void)clipboard;
    if (!uris || !uris[0]) { read_finish(data, STATUS_UNAVAILABLE, NULL, 0, 0); return; }
    GByteArray *out = g_byte_array_new();
    int status = STATUS_DATA;
    size_t count = 0;
    for (gchar **uri = uris; *uri && status == STATUS_DATA; uri++) {
        gchar *path = g_filename_from_uri(*uri, NULL, NULL);
        if (!path) continue; /* Non-local URIs are not paths. */
        size_t len = strlen(path);
        if (++count > MAX_FILES) status = STATUS_TOO_MANY_FILES;
        else if (!g_utf8_validate(path, (gssize)len, NULL)) status = STATUS_MALFORMED;
        else {
            if (out->len) g_byte_array_append(out, (const guint8 *)"", 1);
            g_byte_array_append(out, (const guint8 *)path, (guint)len);
        }
        g_free(path);
    }
    if (status == STATUS_DATA && count == 0) status = STATUS_UNAVAILABLE;
    read_finish(data, status, out->data, out->len, 0);
    g_byte_array_unref(out);
}
static void image_received(GtkClipboard *clipboard, GdkPixbuf *pixbuf, gpointer data) {
    (void)clipboard;
    gchar *buffer = NULL;
    gsize len = 0;
    if (!pixbuf) { read_finish(data, STATUS_UNAVAILABLE, NULL, 0, 0); return; }
    if (!gdk_pixbuf_save_to_buffer(pixbuf, &buffer, &len, "png", NULL, NULL)) { read_finish(data, STATUS_MALFORMED, NULL, 0, 0); return; }
    read_finish(data, STATUS_DATA, (const uint8_t *)buffer, len, 0);
    g_free(buffer);
}
static void contents_received(GtkClipboard *clipboard, GtkSelectionData *selection, gpointer data) {
    ZscRead *read = data;
    gint length = selection ? gtk_selection_data_get_length(selection) : -1;
    const guchar *bytes = length >= 0 ? gtk_selection_data_get_data(selection) : NULL;
    if (read->kind == KIND_PNG && (length <= 0 || !read->request)) {
        /* Other image targets convert through GdkPixbuf into a PNG stream. */
        if (read->request && !read->fallback) { read->fallback = TRUE; gtk_clipboard_request_image(clipboard, image_received, read); return; }
        read_finish(read, STATUS_UNAVAILABLE, NULL, 0, 0);
        return;
    }
    if (length < 0 || (length == 0 && read->kind != KIND_CUSTOM)) { read_finish(read, STATUS_UNAVAILABLE, NULL, 0, 0); return; }
    if (read->kind != KIND_HTML) { read_finish(read, STATUS_DATA, bytes, (size_t)length, 0); return; }
    /* Some browsers publish text/html as UTF-16 with a byte order mark. */
    gchar *converted = NULL;
    gsize len = (gsize)length;
    const gchar *text = (const gchar *)bytes;
    if (len >= 2 && ((bytes[0] == 0xff && bytes[1] == 0xfe) || (bytes[0] == 0xfe && bytes[1] == 0xff))) {
        converted = g_convert(text, (gssize)len, "UTF-8", "UTF-16", NULL, &len, NULL);
        if (!converted) { read_finish(read, STATUS_MALFORMED, NULL, 0, 0); return; }
        text = converted;
    }
    while (len && text[len - 1] == 0) len--;
    if (len >= 3 && (guchar)text[0] == 0xef && (guchar)text[1] == 0xbb && (guchar)text[2] == 0xbf) { text += 3; len -= 3; }
    read_finish(read, valid_text(text, len) ? STATUS_DATA : STATUS_MALFORMED, (const uint8_t *)text, len, 0);
    g_free(converted);
}
static void targets_received(GtkClipboard *clipboard, GdkAtom *targets, gint count, gpointer data) {
    (void)clipboard;
    uint32_t flags = 0;
    if (targets && count > 0) {
        if (gtk_targets_include_text(targets, count)) flags |= FLAG_TEXT;
        if (gtk_targets_include_image(targets, count, FALSE)) flags |= FLAG_PNG;
        if (gtk_targets_include_uri(targets, count)) flags |= FLAG_FILES;
        GdkAtom html = gdk_atom_intern_static_string("text/html");
        for (gint i = 0; i < count; i++) if (targets[i] == html) flags |= FLAG_HTML;
    }
    read_finish(data, STATUS_FORMATS, NULL, 0, flags);
}
/* GTK always invokes the request callback, with NULL data on failure, from
 * the main loop. Cancellation only clears the Zig request pointer. */
void *zsc_read_start(ZscBoard *board, void *request, int formats, int kind, const char *name, size_t name_len) {
    ZscRead *read = g_try_new0(ZscRead, 1);
    if (!read) return NULL;
    g_atomic_int_inc(&resources);
    read->board = board; read->request = request; read->kind = kind; read->starting = TRUE;
    if (formats) gtk_clipboard_request_targets(board->clipboard, targets_received, read);
    else switch (kind) {
    case KIND_TEXT: gtk_clipboard_request_text(board->clipboard, text_received, read); break;
    case KIND_FILES: gtk_clipboard_request_uris(board->clipboard, uris_received, read); break;
    case KIND_HTML: gtk_clipboard_request_contents(board->clipboard, gdk_atom_intern_static_string("text/html"), contents_received, read); break;
    case KIND_PNG: gtk_clipboard_request_contents(board->clipboard, gdk_atom_intern_static_string("image/png"), contents_received, read); break;
    default: {
        gchar *target = g_strndup(name, name_len);
        gtk_clipboard_request_contents(board->clipboard, gdk_atom_intern(target, FALSE), contents_received, read);
        g_free(target);
    }
    }
    if (read->deferred) g_idle_add(read_deferred, read);
    else read->starting = FALSE;
    return read;
}
void zsc_read_cancel(void *read) { ((ZscRead *)read)->request = NULL; }
