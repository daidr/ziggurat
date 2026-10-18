#include <stddef.h>
static void wiped(const void *,size_t);
#define ZWK_POLICY_WIPE_OBSERVER wiped
#include "../src/webview/webkit_request_policy.h"
#include <stdio.h>
#include <stdlib.h>

static unsigned wipe_calls,wire_wipe_calls;
static void wiped(const void *value,size_t length){
    const unsigned char *bytes=value;
    for(size_t i=0;i<length;++i)if(bytes[i])abort();
    if(length==8*72)++wire_wipe_calls;else ++wipe_calls;
}

#define CHECK(value) do { if (!(value)) { fprintf(stderr,"request policy line %u: %s\n",__LINE__,#value); return 1; } } while (0)
static GVariant *config(guint abi,guint64 id,const char *origin,guint methods,gboolean loopback,const char *header,const char *value) {
    GVariantBuilder origins,headers;
    g_variant_builder_init(&origins,G_VARIANT_TYPE("a(sua(sbs)ay)"));
    g_variant_builder_init(&headers,G_VARIANT_TYPE("a(sbs)"));
    if (header) g_variant_builder_add(&headers,"(sbs)",header,value!=NULL,value?value:"");
    if (origin) g_variant_builder_add(&origins,"(su@a(sbs)@ay)",origin,methods,g_variant_builder_end(&headers),zwk_policy_secret(NULL));
    else g_variant_builder_clear(&headers);
    return g_variant_ref_sink(g_variant_new("(utb@a(sua(sbs)ay))",abi,id,loopback,g_variant_builder_end(&origins)));
}
static GVariant *decorated(const char *origin,const char *grant){
    GVariantBuilder rows,headers;
    unsigned char secret[32];memset(secret,0x5a,sizeof(secret));
    g_variant_builder_init(&rows,G_VARIANT_TYPE("a(sua(sbs)ay)"));
    g_variant_builder_init(&headers,G_VARIANT_TYPE("a(sbs)"));
    if(grant)g_variant_builder_add(&headers,"(sbs)",grant,FALSE,"");
    g_variant_builder_add(&rows,"(su@a(sbs)@ay)",origin,3u,g_variant_builder_end(&headers),zwk_policy_secret(secret));
    g_variant_builder_init(&headers,G_VARIANT_TYPE("a(sbs)"));
    g_variant_builder_add(&rows,"(su@a(sbs)@ay)","https://public.test",3u,g_variant_builder_end(&headers),zwk_policy_secret(NULL));
    return g_variant_ref_sink(g_variant_new("(utb@a(sua(sbs)ay))",ZWK_POLICY_ABI,(guint64)92,TRUE,g_variant_builder_end(&rows)));
}
int main(void) {
    GVariant *value=config(ZWK_POLICY_ABI,91,"https://EXAMPLE.test:443/",3,FALSE,"Content-Type","application/json");
    ZwkRequestPolicy *policy=zwk_request_policy_new(value); g_variant_unref(value);
    CHECK(policy && policy->id==91 && policy->count==1);
    CHECK(zwk_request_policy_ref(policy)==policy); zwk_request_policy_unref(policy);
    SoupMessageHeaders *headers=soup_message_headers_new(SOUP_MESSAGE_HEADERS_REQUEST);
    soup_message_headers_append(headers,"Accept","*/*");
    CHECK(zwk_request_policy_check(policy,"https://example.test/resource?a=b","GET",headers)==ZWK_REQUEST_ALLOW);
    CHECK(zwk_request_policy_check(policy,"https://example.test:444/resource","GET",headers)==ZWK_REQUEST_ORIGIN);
    CHECK(zwk_request_policy_check(policy,"https://example.test/resource","POST",headers)==ZWK_REQUEST_METHOD);
    CHECK(zwk_request_policy_check(policy,"https://example.test/resource","get",headers)==ZWK_REQUEST_METHOD);
    CHECK(zwk_request_policy_check(policy,"https://user@example.test/resource","GET",headers)==ZWK_REQUEST_INVALID);
    CHECK(zwk_request_policy_check(policy,"https://%65xample.test/resource","GET",headers)==ZWK_REQUEST_INVALID);
    CHECK(zwk_request_policy_check(policy,"file:///private/file","GET",headers)==ZWK_REQUEST_INVALID);
    CHECK(zwk_request_policy_check(policy,"http://example.test/resource","GET",headers)==ZWK_REQUEST_INVALID);
    CHECK(zwk_request_policy_check(policy,"https://example.test\\@other.test/resource","GET",headers)==ZWK_REQUEST_INVALID);
    soup_message_headers_append(headers,"Content-Type","application/json");
    CHECK(zwk_request_policy_check(policy,"https://example.test/resource","HEAD",headers)==ZWK_REQUEST_ALLOW);
    soup_message_headers_replace(headers,"Content-Type","text/plain");
    CHECK(zwk_request_policy_check(policy,"https://example.test/resource","GET",headers)==ZWK_REQUEST_HEADERS);
    soup_message_headers_remove(headers,"Content-Type");
    soup_message_headers_append(headers,"Not-X-Custom","value");
    CHECK(zwk_request_policy_check(policy,"https://example.test/resource","GET",headers)==ZWK_REQUEST_HEADERS);
    soup_message_headers_clear(headers);
    for (unsigned i=0;i<65;++i) { char name[32]; g_snprintf(name,sizeof(name),"Sec-Bounded-%u",i); soup_message_headers_append(headers,name,"v"); }
    CHECK(zwk_request_policy_check(policy,"https://example.test/resource","GET",headers)==ZWK_REQUEST_HEADERS);
    soup_message_headers_unref(headers); zwk_request_policy_unref(policy);
    const char *invalid[]={"http://example.test","https://127.1","https://2130706433","https://0x7f000001","https://127.00.0.1","https://example.test:0","https://example.test/path","https://example.test?query","https://example.test/#fragment","https://example.test.","https://127.0.0.1","https://localhost","https://[::1]","https://[::ffff:127.0.0.1]","https://[::127.0.0.1]","https://app.ziggurat.invalid"};
    for (size_t i=0;i<G_N_ELEMENTS(invalid);++i) {
        value=config(ZWK_POLICY_ABI,91,invalid[i],3,FALSE,NULL,NULL);
        CHECK(zwk_request_policy_new(value)==NULL); g_variant_unref(value);
    }
    value=config(ZWK_POLICY_ABI,91,"http://127.0.0.1:321",3,TRUE,NULL,NULL);
    policy=zwk_request_policy_new(value); g_variant_unref(value); CHECK(policy); zwk_request_policy_unref(policy);
    value=config(99,91,"https://example.test",3,FALSE,NULL,NULL);
    CHECK(zwk_request_policy_new(value)==NULL); g_variant_unref(value);
    value=config(ZWK_POLICY_ABI,0,"https://example.test",3,FALSE,NULL,NULL);
    CHECK(zwk_request_policy_new(value)==NULL); g_variant_unref(value);
    value=config(ZWK_POLICY_ABI,91,"https://example.test",3,FALSE,"Cookie",NULL);
    CHECK(zwk_request_policy_new(value)==NULL); g_variant_unref(value);
    value=config(ZWK_POLICY_ABI,91,"https://example.test",3,FALSE,"Proxy-Authorization",NULL);
    CHECK(zwk_request_policy_new(value)==NULL); g_variant_unref(value);
    value=config(ZWK_POLICY_ABI,91,NULL,0,FALSE,NULL,NULL);
    policy=zwk_request_policy_new(value); g_variant_unref(value); CHECK(policy && !policy->count); zwk_request_policy_unref(policy);
    value=decorated("https://example.test",NULL);
    policy=zwk_request_policy_new(value);g_variant_unref(value);CHECK(policy&&policy->decorates);
    headers=soup_message_headers_new(SOUP_MESSAGE_HEADERS_REQUEST);
    soup_message_headers_append(headers,"Authorization","attacker supplied");
    CHECK(zwk_request_policy_prepare(policy,"https://example.test/start","GET",headers)==ZWK_REQUEST_ALLOW);
    const char *authorization=soup_message_headers_get_one(headers,"Authorization");
    CHECK(authorization&&strlen(authorization)==71&&!memcmp(authorization,"Bearer 5a5a",11));
    CHECK(zwk_request_policy_prepare(policy,"https://public.test/redirect","GET",headers)==ZWK_REQUEST_ALLOW);
    CHECK(!soup_message_headers_get_one(headers,"Authorization"));
    CHECK(zwk_request_policy_prepare(policy,"https://example.test/back","GET",headers)==ZWK_REQUEST_ALLOW);
    CHECK(soup_message_headers_get_one(headers,"Authorization"));
    CHECK(zwk_request_policy_prepare(policy,"https://example.test/denied","POST",headers)==ZWK_REQUEST_METHOD);
    CHECK(!soup_message_headers_get_one(headers,"Authorization"));
    CHECK(zwk_request_policy_prepare(policy,"https://denied.test/","GET",headers)==ZWK_REQUEST_ORIGIN);
    soup_message_headers_clear(headers);
    for(unsigned i=0;i<63;++i){char name[32];g_snprintf(name,sizeof(name),"Sec-Budget-%u",i);soup_message_headers_append(headers,name,"v");}
    CHECK(zwk_request_policy_prepare(policy,"https://example.test/","GET",headers)==ZWK_REQUEST_ALLOW);
    soup_message_headers_append(headers,"Sec-Final","v");
    CHECK(zwk_request_policy_prepare(policy,"https://example.test/","GET",headers)==ZWK_REQUEST_HEADERS);
    CHECK(!soup_message_headers_get_one(headers,"Authorization"));
    GVariant *retained=g_variant_ref(policy->storage);
    unsigned calls=wipe_calls,wire_calls=wire_wipe_calls;
    CHECK(zwk_request_policy_ref(policy)==policy);zwk_request_policy_unref(policy);CHECK(wipe_calls==calls&&wire_wipe_calls==wire_calls);
    zwk_request_policy_unref(policy);CHECK(wipe_calls==calls&&wire_wipe_calls==wire_calls+1);
    g_variant_unref(retained);CHECK(wipe_calls==calls+1);
    soup_message_headers_unref(headers);
    value=decorated("http://127.0.0.1:321",NULL);CHECK(!zwk_request_policy_new(value));g_variant_unref(value);
    value=decorated("https://example.test","aUtHoRiZaTiOn");CHECK(!zwk_request_policy_new(value));g_variant_unref(value);
    value=config(ZWK_POLICY_ABI,93,"https://example.test",3,FALSE,"Authorization","existing");
    policy=zwk_request_policy_new(value);g_variant_unref(value);CHECK(policy&&!policy->decorates);
    headers=soup_message_headers_new(SOUP_MESSAGE_HEADERS_REQUEST);soup_message_headers_append(headers,"Authorization","existing");
    CHECK(zwk_request_policy_prepare(policy,"https://example.test/","GET",headers)==ZWK_REQUEST_ALLOW);
    CHECK(!strcmp(soup_message_headers_get_one(headers,"Authorization"),"existing"));
    soup_message_headers_unref(headers);zwk_request_policy_unref(policy);
    puts("WebProcess request policy: exact origins/methods/headers, bounded immutable config, default deny");
    return 0;
}
