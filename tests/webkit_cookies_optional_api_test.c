#include "../src/webview/webkit_cookies.h"
#include <webkit2/webkit2.h>
#include <fcntl.h>
#include <unistd.h>

/* Compile the production adapter with just one optional symbol renamed to an
 * absent weak ELF symbol. This fixture neither implements a fake engine nor
 * counts as running the minimum supported engine version. */
#define REQUIRE(value) do { if (!(value)) { g_printerr("cookie optional API assertion %s:%d: %s\n",__FILE__,__LINE__,#value);return __LINE__; } } while (0)
static unsigned completions;
static void completed(void *context,uint64_t token,int status,uint32_t domain,int32_t code,const ZwkCookieRow *rows,size_t count) {
    (void)context;(void)token;(void)status;(void)domain;(void)code;(void)rows;(void)count;
    ++completions;
}
static int submit(ZwkCookies *store,uint64_t token) {
#ifdef ZWK_COOKIES_TEST_REPLACE_COMPAT
    const ZwkCookieRow row={{(const unsigned char *)"key",3},{(const unsigned char *)"value",5},{(const unsigned char *)"optional-replace.test",21},{(const unsigned char *)"/",1},0,0,1};
    return zwk_cookies_replace(store,token,&row,1);
#else
    ZwkCookieRequest request={0};request.kind=ZWK_COOKIE_LIST_ALL;
    return zwk_cookies_submit(store,token,&request);
#endif
}
int main(int argc,char **argv) {
    REQUIRE(argc==2 && gtk_init_check(NULL,NULL));
    char *folder=g_strdup_printf("%s/optional-pair-XXXXXX",argv[1]);
    REQUIRE(g_mkdtemp(folder));
    char *data=g_build_filename(folder,"data",NULL);
    char *cache=g_build_filename(folder,"cache",NULL);
    char *cookies=g_build_filename(folder,"cookies.sqlite",NULL);
    char *lock=g_build_filename(folder,"owner.lock",NULL);
    REQUIRE(g_mkdir_with_parents(data,0700)==0 && g_mkdir_with_parents(cache,0700)==0);
    int fd=open(lock,O_CREAT|O_RDWR|O_CLOEXEC,0600);REQUIRE(fd>=0);
    ZwkProfile *profile=NULL;int system_error=0;
    ZwkProfileOptions profile_options={1,1024u*1024u,8};
    REQUIRE(zwk_profile_create(fd,data,cache,cookies,&profile_options,&profile,&system_error)==ZWK_PROFILE_OK);
    close(fd);
    ZwkCookies *store=NULL;ZwkCookiesOptions options={65536,1,1};
    REQUIRE(zwk_cookies_create(profile,&options,&store)==ZWK_COOKIES_OK);
    REQUIRE(zwk_cookies_bind(store,&completions,completed)==ZWK_COOKIES_OK);
    ZwkCookiesStats before,after;REQUIRE(zwk_cookies_stats(store,&before)==ZWK_COOKIES_OK);
    zwk_cookies_test_fail_after(0);
    REQUIRE(submit(store,1)==ZWK_COOKIES_UNSUPPORTED);
    REQUIRE(zwk_cookies_stats(store,&after)==ZWK_COOKIES_OK);
    REQUIRE(!completions && !after.pending && before.bytes==after.bytes && before.peak_bytes==after.peak_bytes);
    zwk_cookies_test_fail_after(-1);
    REQUIRE(zwk_cookies_seal(store)==ZWK_COOKIES_OK);
    REQUIRE(submit(store,2)==ZWK_COOKIES_CLOSED);
    REQUIRE(zwk_cookies_close(store)==ZWK_COOKIES_OK);
    REQUIRE(zwk_profile_close(profile)==ZWK_PROFILE_OK);
    uint32_t owners=1,ops=1;size_t bytes=1;
    zwk_cookies_counts(&owners,&ops,&bytes);REQUIRE(!owners && !ops && !bytes);
    zwk_profile_counts(&owners,&ops,&bytes);REQUIRE(!owners && !ops && !bytes);
    g_free(lock);g_free(cookies);g_free(cache);g_free(data);g_free(folder);
    g_print("CookieStore ELF absent optional symbol: Unsupported before malloc, callback or physical slot; closed priority and final native counts zero\n");
    return 0;
}
