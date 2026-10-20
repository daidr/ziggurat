/* Secret Service access through libsecret, loaded on first use so that the
   library stays optional at run time: a session without it reports that no
   credential store is available instead of failing to start. Every function
   blocks and may run on any thread; libsecret's synchronous calls run their
   own main context. Items use the generic secret schema with the string
   attributes `service` and `account`, labelled "service/account", so other
   programs that store secrets the same way read the same items.

   Results: 0 done, 1 not found, 2 no credential store, 3 failure (GError
   code in *code), 4 destination too small. */
#define _GNU_SOURCE
#include <dlfcn.h>
#include <gio/gio.h>
#include <string.h>

typedef struct _SecretSchema SecretSchema;
typedef struct _SecretValue SecretValue;
typedef SecretSchema *(*SchemaNewv)(const gchar *, int, GHashTable *);
typedef SecretValue *(*ValueNew)(const gchar *, gssize, const gchar *);
typedef const gchar *(*ValueGet)(SecretValue *, gsize *);
typedef void (*ValueUnref)(gpointer);
typedef gboolean (*StoreBinary)(const SecretSchema *, GHashTable *, const gchar *, const gchar *, SecretValue *, GCancellable *, GError **);
typedef SecretValue *(*LookupBinary)(const SecretSchema *, GHashTable *, GCancellable *, GError **);
typedef gboolean (*Clear)(const SecretSchema *, GHashTable *, GCancellable *, GError **);

typedef struct {
    int available;
    SchemaNewv schema_newv;
    ValueNew value_new;
    ValueGet value_get;
    ValueUnref value_unref;
    StoreBinary store;
    LookupBinary lookup;
    Clear clear;
    SecretSchema *schema;
} Api;

static Api api;
static GOnce loaded = G_ONCE_INIT;
static GMutex bus_lock;
static GDBusConnection *bus;

static gpointer load(gpointer unused) {
    (void)unused;
    void *library = dlopen("libsecret-1.so.0", RTLD_NOW | RTLD_LOCAL);
    if (!library) return NULL;
    api.schema_newv = (SchemaNewv)dlsym(library, "secret_schema_newv");
    api.value_new = (ValueNew)dlsym(library, "secret_value_new");
    api.value_get = (ValueGet)dlsym(library, "secret_value_get");
    api.value_unref = (ValueUnref)dlsym(library, "secret_value_unref");
    /* The binary variants arrived in libsecret 0.19. */
    api.store = (StoreBinary)dlsym(library, "secret_password_storev_binary_sync");
    api.lookup = (LookupBinary)dlsym(library, "secret_password_lookupv_binary_sync");
    api.clear = (Clear)dlsym(library, "secret_password_clearv_sync");
    if (!api.schema_newv || !api.value_new || !api.value_get || !api.value_unref || !api.store || !api.lookup || !api.clear) return NULL;
    GHashTable *types = g_hash_table_new_full(g_str_hash, g_str_equal, g_free, NULL);
    /* SECRET_SCHEMA_ATTRIBUTE_STRING */
    g_hash_table_insert(types, g_strdup("service"), GINT_TO_POINTER(0));
    g_hash_table_insert(types, g_strdup("account"), GINT_TO_POINTER(0));
    /* SECRET_SCHEMA_NONE: the schema name is matched, as other programs store it. */
    api.schema = api.schema_newv("org.freedesktop.Secret.Generic", 0, types);
    g_hash_table_unref(types);
    api.available = api.schema != NULL;
    return NULL;
}

/* The session bus the Secret Service lives on; GIO shares the connection with
   libsecret. Returns 0 when there is none. */
static int ready(void) {
    g_once(&loaded, load, NULL);
    if (!api.available) return 0;
    g_mutex_lock(&bus_lock);
    if (!bus) {
        GError *failure = NULL;
        bus = g_bus_get_sync(G_BUS_TYPE_SESSION, NULL, &failure);
        if (failure) g_error_free(failure);
    }
    int result = bus != NULL;
    g_mutex_unlock(&bus_lock);
    return result;
}

/* A bus without the Secret Service reports an unknown service or a name
   without an owner; those mean no store, anything else a failure. */
static int failed(GError *failure, int *code) {
    int result = 3;
    if (failure->domain == G_DBUS_ERROR && (failure->code == G_DBUS_ERROR_SERVICE_UNKNOWN || failure->code == G_DBUS_ERROR_NAME_HAS_NO_OWNER || failure->code == G_DBUS_ERROR_NO_SERVER)) result = 2;
    *code = failure->code;
    g_error_free(failure);
    return result;
}

static GHashTable *attributes(const char *service, size_t service_length, const char *account, size_t account_length) {
    GHashTable *table = g_hash_table_new_full(g_str_hash, g_str_equal, g_free, g_free);
    g_hash_table_insert(table, g_strdup("service"), g_strndup(service, service_length));
    g_hash_table_insert(table, g_strdup("account"), g_strndup(account, account_length));
    return table;
}

int zss_secret_set(const char *service, size_t service_length, const char *account, size_t account_length, const char *secret, size_t secret_length, int *code) {
    *code = 0;
    if (!ready()) return 2;
    GHashTable *table = attributes(service, service_length, account, account_length);
    gchar *label = g_strdup_printf("%.*s/%.*s", (int)service_length, service, (int)account_length, account);
    static const char empty = 0;
    SecretValue *value = api.value_new(secret_length ? secret : &empty, (gssize)secret_length, "application/octet-stream");
    GError *failure = NULL;
    gboolean stored = api.store(api.schema, table, NULL, label, value, NULL, &failure);
    api.value_unref(value);
    g_free(label);
    g_hash_table_unref(table);
    if (failure) return failed(failure, code);
    return stored ? 0 : 3;
}

int zss_secret_get(const char *service, size_t service_length, const char *account, size_t account_length, char *destination, size_t capacity, size_t *length, int *code) {
    *code = 0;
    *length = 0;
    if (!ready()) return 2;
    GHashTable *table = attributes(service, service_length, account, account_length);
    GError *failure = NULL;
    SecretValue *value = api.lookup(api.schema, table, NULL, &failure);
    g_hash_table_unref(table);
    if (failure) {
        if (value) api.value_unref(value);
        return failed(failure, code);
    }
    if (!value) return 1;
    gsize size = 0;
    const gchar *bytes = api.value_get(value, &size);
    int result = 0;
    if (size > capacity) result = 4;
    else {
        if (size) memcpy(destination, bytes, size);
        *length = size;
    }
    api.value_unref(value);
    return result;
}

int zss_secret_delete(const char *service, size_t service_length, const char *account, size_t account_length, int *code) {
    *code = 0;
    if (!ready()) return 2;
    GHashTable *table = attributes(service, service_length, account, account_length);
    GError *failure = NULL;
    /* False without an error: there was nothing to delete. */
    api.clear(api.schema, table, NULL, &failure);
    g_hash_table_unref(table);
    if (failure) return failed(failure, code);
    return 0;
}
