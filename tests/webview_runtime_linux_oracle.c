#define _GNU_SOURCE
#include <dlfcn.h>
#include <pthread.h>
#include <stdio.h>

struct probe { const char *path; int failed; };

static void *run(void *pointer)
{
    struct probe *probe = pointer;
    void *library = dlopen(probe->path, RTLD_NOW | RTLD_LOCAL);
    if (!library) { fprintf(stderr, "oracle load: %s\n", dlerror()); probe->failed = 1; return NULL; }
    const char *names[3] = {"webkit_get_major_version", "webkit_get_minor_version", "webkit_get_micro_version"};
    unsigned (*get[3])(void);
    for (unsigned i = 0; i < 3; ++i) {
        dlerror();
        *(void **)(&get[i]) = dlsym(library, names[i]);
        const char *error = dlerror();
        if (error || !get[i]) {
            fprintf(stderr, "oracle symbol: %s\n", error ? error : "noncallable entry");
            probe->failed = 1;
            break;
        }
    }
    if (!probe->failed) printf("%u.%u.%u\n", get[0](), get[1](), get[2]());
    if (dlclose(library)) { fprintf(stderr, "oracle close: %s\n", dlerror()); probe->failed = 1; }
    return NULL;
}

int main(int argc, char **argv)
{
    if (argc != 2 || argv[1][0] != '/') return 2;
    struct probe probe = {argv[1], 0};
    pthread_t worker;
    if (pthread_create(&worker, NULL, run, &probe)) return 3;
    if (pthread_join(worker, NULL)) return 4;
    return probe.failed;
}
