#include <gio/gio.h>
#include <glib.h>

/* Adds a file to the user's recently used files, the list file choosers and
 * file managers show as Recent. It edits the same bookmark file GTK uses,
 * synchronously: 0 on success, 1 for a bad path, 2 when the list cannot be
 * written. */
int zsr_recent_add(const char *path, const char *app_name) {
    GError *error = NULL;
    char *uri = g_filename_to_uri(path, NULL, &error);
    if (!uri) {
        g_clear_error(&error);
        return 1;
    }
    char *file = g_build_filename(g_get_user_data_dir(), "recently-used.xbel", NULL);
    GBookmarkFile *bookmarks = g_bookmark_file_new();
    int status = 0;
    if (!g_bookmark_file_load_from_file(bookmarks, file, &error)) {
        /* A missing list starts empty; an unreadable one is not replaced. */
        if (!g_error_matches(error, G_FILE_ERROR, G_FILE_ERROR_NOENT)) status = 2;
        g_clear_error(&error);
    }
    if (status == 0) {
        gboolean uncertain = FALSE;
        char *type = g_content_type_guess(path, NULL, 0, &uncertain);
        char *mime = type ? g_content_type_get_mime_type(type) : NULL;
        g_bookmark_file_set_mime_type(bookmarks, uri, mime ? mime : "application/octet-stream");
        char *exec = g_strdup_printf("%s %%u", g_get_prgname() ? g_get_prgname() : app_name);
        g_bookmark_file_add_application(bookmarks, uri, app_name, exec);
        GDateTime *now = g_date_time_new_now_utc();
        g_bookmark_file_set_visited_date_time(bookmarks, uri, now);
        g_date_time_unref(now);
        char *directory = g_path_get_dirname(file);
        if (g_mkdir_with_parents(directory, 0700) != 0 || !g_bookmark_file_to_file(bookmarks, file, &error)) status = 2;
        g_clear_error(&error);
        g_free(directory);
        g_free(exec);
        g_free(mime);
        g_free(type);
    }
    g_bookmark_file_free(bookmarks);
    g_free(file);
    g_free(uri);
    return status;
}
