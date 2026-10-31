/* Application fonts through the Core Text font manager, registered for this
   process, and the system's font families. */
#include <CoreText/CoreText.h>
#include <stdint.h>
#include <string.h>
#include <strings.h>

static uint64_t generation;

uint64_t zfont_generation(void) { return generation; }

/* Registers the font file for this process. 0 on success. */
int zfont_add_file(const char *path) {
    CFURLRef url = CFURLCreateFromFileSystemRepresentation(NULL, (const UInt8 *)path, (CFIndex)strlen(path), false);
    if (!url) return 1;
    CFErrorRef error = NULL;
    bool registered = CTFontManagerRegisterFontsForURL(url, kCTFontManagerScopeProcess, &error);
    CFRelease(url);
    if (!registered) {
        /* The same file registered again is not a failure. */
        int already = error && CFErrorGetCode(error) == kCTFontManagerErrorAlreadyRegistered;
        if (error) CFRelease(error);
        if (!already) return 1;
    }
    generation++;
    return 0;
}

typedef void (*ZfontEach)(void *context, const char *name, int monospaced);

static int monospaced(CFStringRef family) {
    const void *keys[1] = {kCTFontFamilyNameAttribute};
    const void *values[1] = {family};
    CFDictionaryRef attributes = CFDictionaryCreate(NULL, keys, values, 1, &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
    if (!attributes) return 0;
    CTFontDescriptorRef descriptor = CTFontDescriptorCreateWithAttributes(attributes);
    CFRelease(attributes);
    if (!descriptor) return 0;
    CTFontRef font = CTFontCreateWithFontDescriptor(descriptor, 12, NULL);
    CFRelease(descriptor);
    if (!font) return 0;
    int result = (CTFontGetSymbolicTraits(font) & kCTFontMonoSpaceTrait) != 0;
    CFRelease(font);
    return result;
}

/* The available families, without hidden ones (whose names start with a
   period). */
int zfont_list(void *context, ZfontEach each) {
    CFArrayRef families = CTFontManagerCopyAvailableFontFamilyNames();
    if (!families) return 1;
    char name[1024];
    for (CFIndex i = 0; i < CFArrayGetCount(families); i++) {
        CFStringRef family = CFArrayGetValueAtIndex(families, i);
        if (!CFStringGetCString(family, name, sizeof(name), kCFStringEncodingUTF8) || !name[0] || name[0] == '.') continue;
        each(context, name, monospaced(family));
    }
    CFRelease(families);
    return 0;
}
