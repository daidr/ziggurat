#include <stdint.h>
#include <stdlib.h>

typedef void (*ZWakeCallback)(void *);
typedef struct { uint32_t states, handles, sources, dispatches; } ZWakeCounts;

#ifdef _WIN32
#define WIN32_LEAN_AND_MEAN
#include <windows.h>
typedef struct { HANDLE timer; } ZWake;
static LONG states, handles;
void *zgwake_create(void *context, ZWakeCallback callback) {
    (void)context; (void)callback;
    ZWake *state = calloc(1, sizeof(*state));
    if (!state) return NULL;
    state->timer = CreateWaitableTimerW(NULL, FALSE, NULL);
    if (!state->timer) { free(state); return NULL; }
    InterlockedIncrement(&states); InterlockedIncrement(&handles);
    return state;
}
void *zgwake_handle(ZWake *state) { return state->timer; }
int zgwake_arm(ZWake *state, uint64_t nanoseconds) {
    LARGE_INTEGER due;
    due.QuadPart = -(LONGLONG)((nanoseconds + 99) / 100);
    if (!due.QuadPart) due.QuadPart = -1;
    return SetWaitableTimer(state->timer, &due, 0, NULL, NULL, FALSE) != 0;
}
void zgwake_cancel(ZWake *state) { CancelWaitableTimer(state->timer); }
void zgwake_close(ZWake *state) {
    CloseHandle(state->timer);
    InterlockedDecrement(&handles); InterlockedDecrement(&states); free(state);
}
ZWakeCounts zgwake_counts(void) {
    return (ZWakeCounts){ (uint32_t)InterlockedCompareExchange(&states, 0, 0), (uint32_t)InterlockedCompareExchange(&handles, 0, 0), 0, 0 };
}
#elif defined(__APPLE__)
#include <CoreFoundation/CoreFoundation.h>
#include <stdatomic.h>
/* One repeating CFRunLoopTimer on the main run loop's common modes per owner,
   with an interval no deadline reaches: arming moves its next fire date and
   firing or cancelling parks it far away again, so it never repeats. */
typedef struct {
    CFRunLoopTimerRef timer;
    void *context;
    ZWakeCallback callback;
    unsigned callbacks;
    CFAbsoluteTime due;
    int armed;
    int closed;
} ZWake;
static atomic_uint states, sources, dispatches;
static const CFTimeInterval parked = 1.0e10;
static void release_state(ZWake *state) { atomic_fetch_sub(&states, 1); free(state); }
static void ready(CFRunLoopTimerRef timer, void *data) {
    ZWake *state = data;
    /* A cancel earlier in the same run loop pass wins over a fire the run
       loop had already selected. */
    if (state->closed || !state->armed) return;
    /* The run loop schedules on its own clock and can call a hair before the
       deadline by this one. Moving the date inside the callout keeps it: the
       run loop only advances a repeating timer whose date the callout left. */
    if (CFAbsoluteTimeGetCurrent() < state->due) {
        CFRunLoopTimerSetNextFireDate(timer, state->due);
        return;
    }
    state->armed = 0;
    CFRunLoopTimerSetNextFireDate(timer, CFAbsoluteTimeGetCurrent() + parked);
    state->callbacks++;
    atomic_fetch_add(&dispatches, 1);
    ZWakeCallback callback = state->callback;
    void *context = state->context;
    callback(context);
    state->callbacks--;
    atomic_fetch_sub(&dispatches, 1);
    if (state->closed && !state->callbacks) release_state(state);
}
void *zgwake_create(void *context, ZWakeCallback callback) {
    ZWake *state = calloc(1, sizeof(*state));
    if (!state) return NULL;
    CFRunLoopTimerContext timer_context = { 0, state, NULL, NULL, NULL };
    state->timer = CFRunLoopTimerCreate(NULL, CFAbsoluteTimeGetCurrent() + parked, parked, 0, 0, ready, &timer_context);
    if (!state->timer) { free(state); return NULL; }
    atomic_fetch_add(&sources, 1); atomic_fetch_add(&states, 1);
    state->context = context; state->callback = callback;
    CFRunLoopAddTimer(CFRunLoopGetMain(), state->timer, kCFRunLoopCommonModes);
    return state;
}
void *zgwake_handle(ZWake *state) { (void)state; return NULL; }
int zgwake_arm(ZWake *state, uint64_t nanoseconds) {
    if (state->closed) return 0;
    const CFAbsoluteTime due = CFAbsoluteTimeGetCurrent() + (double)nanoseconds / 1.0e9;
    state->due = due;
    state->armed = 1;
    CFRunLoopTimerSetNextFireDate(state->timer, due);
    return 1;
}
void zgwake_cancel(ZWake *state) {
    if (state->closed) return;
    state->armed = 0;
    CFRunLoopTimerSetNextFireDate(state->timer, CFAbsoluteTimeGetCurrent() + parked);
}
void zgwake_close(ZWake *state) {
    state->closed = 1; state->armed = 0; state->context = NULL; state->callback = NULL;
    CFRunLoopTimerRef timer = state->timer; state->timer = NULL;
    CFRunLoopTimerInvalidate(timer);
    CFRelease(timer);
    atomic_fetch_sub(&sources, 1);
    if (!state->callbacks) release_state(state);
}
ZWakeCounts zgwake_counts(void) {
    return (ZWakeCounts){ atomic_load(&states), 0, atomic_load(&sources), atomic_load(&dispatches) };
}
#else
#include <glib.h>
typedef struct {
    GSource *source;
    void *context;
    ZWakeCallback callback;
    unsigned callbacks;
    int closed;
} ZWake;
static gint states, sources, dispatches;
static void release_state(ZWake *state) { g_atomic_int_add(&states, -1); free(state); }
static gboolean ready(gpointer data) {
    ZWake *state = data;
    /* Another ready source may have cancelled or rearmed this one after the
       main context selected it. A stale dispatch cannot fire a new deadline. */
    gint64 due = g_source_get_ready_time(state->source);
    if (due < 0 || due > g_get_monotonic_time()) return G_SOURCE_CONTINUE;
    state->callbacks++;
    g_atomic_int_inc(&dispatches);
    g_source_set_ready_time(state->source, -1);
    ZWakeCallback callback = state->callback;
    void *context = state->context;
    callback(context);
    state->callbacks--;
    g_atomic_int_add(&dispatches, -1);
    if (state->closed && !state->callbacks) release_state(state);
    return G_SOURCE_CONTINUE;
}
static gboolean dispatch(GSource *source, GSourceFunc callback, gpointer data) {
    (void)source;
    return callback ? callback(data) : G_SOURCE_CONTINUE;
}
static void finalize(GSource *source) { (void)source; g_atomic_int_add(&sources, -1); }
static GSourceFuncs functions = { NULL, NULL, dispatch, finalize, NULL, NULL };
void *zgwake_create(void *context, ZWakeCallback callback) {
    ZWake *state = calloc(1, sizeof(*state));
    if (!state) return NULL;
    state->source = g_source_new(&functions, sizeof(GSource));
    g_atomic_int_inc(&sources); g_atomic_int_inc(&states);
    state->context = context; state->callback = callback;
    g_source_set_callback(state->source, ready, state, NULL);
    g_source_set_name(state->source, "ziggurat-one-shot");
    g_source_set_ready_time(state->source, -1);
    if (!g_source_attach(state->source, g_main_context_default())) {
        g_source_destroy(state->source); g_source_unref(state->source);
        release_state(state); return NULL;
    }
    return state;
}
void *zgwake_handle(ZWake *state) { (void)state; return NULL; }
int zgwake_arm(ZWake *state, uint64_t nanoseconds) {
    if (state->closed) return 0;
    gint64 now = g_get_monotonic_time();
    uint64_t delay = (nanoseconds + 999) / 1000;
    if (!delay) delay = 1;
    if (delay > (uint64_t)(G_MAXINT64 - now)) return 0;
    g_source_set_ready_time(state->source, now + (gint64)delay);
    return 1;
}
void zgwake_cancel(ZWake *state) {
    if (!state->closed) g_source_set_ready_time(state->source, -1);
}
void zgwake_close(ZWake *state) {
    state->closed = 1; state->context = NULL; state->callback = NULL;
    GSource *source = state->source; state->source = NULL;
    g_source_destroy(source); g_source_unref(source);
    if (!state->callbacks) release_state(state);
}
ZWakeCounts zgwake_counts(void) {
    return (ZWakeCounts){ (uint32_t)g_atomic_int_get(&states), 0, (uint32_t)g_atomic_int_get(&sources), (uint32_t)g_atomic_int_get(&dispatches) };
}
#endif
