#ifndef ZIGGURAT_WEBKIT_COOKIES_H
#define ZIGGURAT_WEBKIT_COOKIES_H
#include <stddef.h>
#include <stdint.h>
#include "webkit_profile.h"

typedef struct ZwkCookies ZwkCookies;
typedef struct ZwkCookieSlice { const unsigned char *ptr; size_t len; } ZwkCookieSlice;
typedef struct ZwkCookieRow {
    ZwkCookieSlice name,value,domain,path;
    int64_t expires;
    uint32_t flags,same_site;
} ZwkCookieRow;
enum { ZWK_COOKIE_SECURE=1,ZWK_COOKIE_HTTP_ONLY=2,ZWK_COOKIE_EXPIRES=4 };
enum { ZWK_COOKIE_QUERY=0,ZWK_COOKIE_SET=1,ZWK_COOKIE_DELETE=2,ZWK_COOKIE_CLEAR=3,ZWK_COOKIE_LIST_ALL=4,ZWK_COOKIE_REPLACE_ALL=5,ZWK_COOKIE_DELETE_KEY=6 };
typedef struct ZwkCookieRequest {
    uint32_t kind,filter_flags;
    ZwkCookieSlice url,name,value,domain,path;
    int64_t expires;
    uint32_t flags,same_site;
} ZwkCookieRequest;
typedef struct ZwkCookiesOptions { size_t bytes; uint32_t pending,rows; } ZwkCookiesOptions;
typedef struct ZwkCookiesStats { size_t bytes,peak_bytes; uint32_t pending; int accepting; } ZwkCookiesStats;
enum {
    ZWK_COOKIES_OK=0,ZWK_COOKIES_CLOSED=1,ZWK_COOKIES_FULL=2,
    ZWK_COOKIES_OOM=3,ZWK_COOKIES_INVALID=4,ZWK_COOKIES_WRONG_THREAD=5,
    ZWK_COOKIES_NATIVE=6,ZWK_COOKIES_CAPACITY=8,ZWK_COOKIES_CANCELLED=9,
    ZWK_COOKIES_UNSUPPORTED=10
};
/* Rows borrow the native result only through this synchronous callback. The
 * adapter never copies the engine's complete GList, nor bounds its allocation.
 * A callback may close the Zig owner; the operation independently pins C state.
 * A successful submit owns physical completion before calling the engine, even
 * if an engine completion happens synchronously. No error follows acceptance. */
typedef void (*ZwkCookiesComplete)(void *,uint64_t,int,uint32_t,int32_t,const ZwkCookieRow *,size_t);
int zwk_cookies_create(ZwkProfile *,const ZwkCookiesOptions *,ZwkCookies **out);
int zwk_cookies_check(ZwkCookies *);
int zwk_cookies_bind(ZwkCookies *,void *,ZwkCookiesComplete);
/* DELETE_KEY accepts only name/domain/path: all other fields, including
 * same_site, are zero. Its fixed expired Cookie is constructed after capture
 * and submitted by add_cookie, independently of expected-value DELETE. */
int zwk_cookies_submit(ZwkCookies *,uint64_t,const ZwkCookieRequest *);
/* Input is captured before SoupCookie construction and borrowed only through
 * return. Nonempty rows, descriptors, embedded GList and raw strings share the
 * 32 KiB per-Op input ceiling and the Store's requested-byte account. */
int zwk_cookies_replace(ZwkCookies *,uint64_t,const ZwkCookieRow *,size_t);
int zwk_cookies_cancel(ZwkCookies *,uint64_t);
/* Withdraw callbacks before cancellation. The owner reference survives seal;
 * close additionally consumes it. Late finish only touches C/GObject storage. */
int zwk_cookies_seal(ZwkCookies *);
int zwk_cookies_cancel_all(ZwkCookies *);
int zwk_cookies_close(ZwkCookies *);
int zwk_cookies_stats(ZwkCookies *,ZwkCookiesStats *);
size_t zwk_cookies_owner_size(void);
void zwk_cookies_counts(uint32_t *,uint32_t *,size_t *);
#ifdef ZWK_COOKIES_TESTING
void zwk_cookies_test_fail_after(int);
void zwk_cookies_test_synchronous_query(int);
/* Bit 0/1 independently hide the async/finish member of the optional pair.
 * This injection is confined to the independent native test object. */
void zwk_cookies_test_missing_list_api(unsigned);
void zwk_cookies_test_missing_replace_api(unsigned);
void zwk_cookies_test_cookie_fail_after(int);
size_t zwk_cookies_test_op_size(void);
#endif
#endif
