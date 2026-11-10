/* Whether frames present without waiting for the display, as the
   ZIGGURAT_UNCAPPED environment variable asks with 1 (true, on, yes); see
   pacing.zig. Read once, on the main thread, where a renderer first asks. */
#ifndef ZIGGURAT_PACING_H
#define ZIGGURAT_PACING_H
#include <stdlib.h>
#include <string.h>
#include <ctype.h>

static inline int zpacing_setting(const char *value) {
    if (!value) return 0;
    while (*value == ' ' || *value == '\t') value++;
    char word[8]; size_t n = 0;
    while (value[n] && value[n] != ' ' && value[n] != '\t') { if (n == sizeof word - 1) return 0; word[n] = (char)tolower((unsigned char)value[n]); n++; }
    word[n] = 0;
    return strcmp(word, "1") == 0 || strcmp(word, "true") == 0 || strcmp(word, "on") == 0 || strcmp(word, "yes") == 0;
}
static inline int zpacing_uncapped(void) {
    static int known = 0, value = 0;
    if (!known) { value = zpacing_setting(getenv("ZIGGURAT_UNCAPPED")); known = 1; }
    return value;
}
#endif
