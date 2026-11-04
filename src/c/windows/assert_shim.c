/* Windows builds that use Zig's self-hosted backend link with Zig's own COFF
 * linker. mingw-w64 implements _assert() as a wrapper around the UCRT export
 * renamed through NAME_EXPORTAS (__msvcrt_assert == _assert), an import type
 * that linker cannot read yet. Providing _assert here keeps the mingw wrapper
 * out of the link while preserving the CRT's message and abort behaviour. */
#include <stdio.h>
#include <stdlib.h>

void __cdecl _assert(const char *message, const char *file, unsigned line) {
    fprintf(stderr, "Assertion failed: %s, file %s, line %u\n", message, file, line);
    fflush(stderr);
    abort();
}
