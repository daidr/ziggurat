#define _POSIX_C_SOURCE 200809L
#include <glib.h>
#include <glib-unix.h>
#include <errno.h>
#include <fcntl.h>
#include <signal.h>
#include <unistd.h>

/* SIGINT and SIGTERM as a quit request. The handler only writes a byte to a
   pipe that the default GLib main context watches, so the request reaches
   Zig on the main thread from the event loop. A second signal exits at once
   with the conventional 128 + signal status, also while the main thread is
   busy or a quit was cancelled. Signals ignored when the process started,
   such as SIGINT of a background job, stay ignored. */

typedef void (*Requested)(void *context, int signal);
static const int handled[2] = { SIGINT, SIGTERM };
static struct sigaction previous[2];
static int installed[2];
static int pipe_fds[2] = { -1, -1 };
static volatile sig_atomic_t received;
static guint source;
static Requested requested;
static void *requested_context;

static void handler(int signal) {
    if (received) _exit(128 + signal);
    received = signal;
    int saved = errno;
    char byte = (char)signal;
    ssize_t ignored = write(pipe_fds[1], &byte, 1);
    (void)ignored;
    errno = saved;
}

static gboolean readable(gint fd, GIOCondition condition, gpointer unused) {
    (void)condition; (void)unused;
    char bytes[16];
    while (read(fd, bytes, sizeof bytes) > 0) {}
    if (requested) requested(requested_context, (int)received);
    return G_SOURCE_CONTINUE;
}

static void close_pipe(void) {
    for (int i = 0; i < 2; i++) if (pipe_fds[i] >= 0) { close(pipe_fds[i]); pipe_fds[i] = -1; }
}

/* Returns 0, 1 when already active, or 2 with errno-like failure. */
int zsg_signals_start(Requested callback, void *context, int *failure) {
    if (source) return 1;
    if (pipe(pipe_fds) != 0) { *failure = errno; return 2; }
    for (int i = 0; i < 2; i++) {
        fcntl(pipe_fds[i], F_SETFD, FD_CLOEXEC);
        fcntl(pipe_fds[i], F_SETFL, fcntl(pipe_fds[i], F_GETFL) | O_NONBLOCK);
    }
    received = 0;
    requested = callback;
    requested_context = context;
    source = g_unix_fd_add(pipe_fds[0], G_IO_IN, readable, NULL);
    for (int i = 0; i < 2; i++) {
        struct sigaction current;
        installed[i] = 0;
        if (sigaction(handled[i], NULL, &current) != 0) continue;
        if (current.sa_handler == SIG_IGN) continue;
        struct sigaction action = { 0 };
        action.sa_handler = handler;
        sigemptyset(&action.sa_mask);
        action.sa_flags = SA_RESTART;
        if (sigaction(handled[i], &action, &previous[i]) == 0) installed[i] = 1;
    }
    return 0;
}

void zsg_signals_stop(void) {
    if (!source) return;
    for (int i = 0; i < 2; i++) if (installed[i]) { sigaction(handled[i], &previous[i], NULL); installed[i] = 0; }
    g_source_remove(source);
    source = 0;
    requested = NULL;
    requested_context = NULL;
    close_pipe();
}

/* For tests: whether the signal has this module's handler. */
int zsg_signals_installed(int signal) {
    struct sigaction current;
    return sigaction(signal, NULL, &current) == 0 && current.sa_handler == handler;
}
