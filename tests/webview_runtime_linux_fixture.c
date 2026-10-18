#define _GNU_SOURCE
#include <errno.h>
#include <fcntl.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <sys/syscall.h>
#include <unistd.h>

/* A test-owned DSO, never a substitute for the real WebKit version oracle. */
static unsigned counts[3];
static uint64_t getter_thread;

static void write_byte(int fd, char value)
{
    ssize_t count;
    do count = write(fd, &value, 1); while (count < 0 && errno == EINTR);
    if (count != 1) abort();
}

static void event(char value)
{
    const char *path = getenv("ZIGGURAT_RUNTIME_FIXTURE_LOG");
    if (!path) return;
    int fd = open(path, O_WRONLY | O_APPEND | O_CLOEXEC);
    if (fd < 0) abort();
    write_byte(fd, value);
    if (close(fd)) abort();
}

__attribute__((constructor)) static void loaded(void)
{
    event('L');
    const char *gate = getenv("ZIGGURAT_RUNTIME_FIXTURE_GATE");
    if (gate) {
        int ready, resume;
        char value;
        if (sscanf(gate, "%d:%d", &ready, &resume) != 2) abort();
        write_byte(ready, 'R');
        ssize_t count;
        do count = read(resume, &value, 1); while (count < 0 && errno == EINTR);
        if (count != 1 || value != 'C') abort();
    }
}

__attribute__((destructor)) static void unloaded(void) { event('D'); }

static unsigned observed(unsigned at, unsigned value)
{
    counts[at]++;
    getter_thread = (uint64_t)syscall(SYS_gettid);
    event((char)('a' + at));
    return value;
}

#ifndef RUNTIME_FIXTURE_OMIT_MAJOR
unsigned webkit_get_major_version(void) { return observed(0, 7); }
#endif
#ifndef RUNTIME_FIXTURE_OMIT_MINOR
unsigned webkit_get_minor_version(void) { return observed(1, 41); }
#endif
#ifndef RUNTIME_FIXTURE_OMIT_MICRO
unsigned webkit_get_micro_version(void) { return observed(2, 923); }
#endif

void ziggurat_runtime_fixture_counts(unsigned output[3], uint64_t *thread)
{
    for (unsigned i = 0; i < 3; ++i) output[i] = counts[i];
    *thread = getter_thread;
}
