#include <stdio.h>
#include <stdlib.h>
void __cdecl _assert(const char *message, const char *file, unsigned line) {
    fprintf(stderr, "Assertion failed: %s, file %s, line %u\n", message, file, line);
    fflush(stderr);
    abort();
}
