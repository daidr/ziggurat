#include "../src/https_resources/transport_linux.h"
#include <libsoup/soup.h>
#include <stdio.h>
#include <string.h>
#define REQUIRE(value) do { if(!(value)){fprintf(stderr,"transport native failed line %d: %s\n",__LINE__,#value);return 1;} } while(0)
static int empty(void) {
    ZhtCounts counts;zht_counts(&counts);
    return !counts.owners && !counts.servers && !counts.bytes;
}
int zht_test_mismatch(const uint8_t *pem,size_t length) {
    ZhtOptions options={65536,13,17,pem,length};ZhtFailure failure;ZhtOwner *owner=NULL;
    REQUIRE(empty());
    int result=zht_create(&options,&owner,&failure);
    if(result==ZHT_OK){REQUIRE(owner && !failure.domain);zht_close(owner);zht_unref(owner);}
    else REQUIRE(result==ZHT_NATIVE && !owner && failure.domain);
    REQUIRE(empty());return result;
}
int zht_test_run(const uint8_t *pem,size_t length) {
    /* Deliberate caller reservations, not guesses at a Zig layout. */
    ZhtOptions options={65536,13,17,pem,length};
    ZhtFailure failure;ZhtOwner *owner=NULL;
    REQUIRE(empty());
    ZhtOptions tiny=options;tiny.bytes=1;
    REQUIRE(zht_create(&tiny,&owner,&failure)==ZHT_CAPACITY && !owner && !failure.domain && empty());
    zht_test_allocation_limit(0);
    REQUIRE(zht_create(&options,&owner,&failure)==ZHT_OOM && !owner && !failure.domain && empty());
    zht_test_allocation_limit(-1);
    const uint8_t invalid[]="invalid native certificate";
    ZhtOptions invalid_options=options;invalid_options.pem=invalid;invalid_options.length=sizeof(invalid)-1;
    REQUIRE(zht_create(&invalid_options,&owner,&failure)==ZHT_NATIVE && !owner && failure.domain && empty());
    REQUIRE(zht_create(&options,&owner,&failure)==ZHT_OK && owner && !failure.domain);
    ZhtStats stats;REQUIRE(zht_stats(owner,&stats)==ZHT_OK && stats.accepting && stats.port && stats.bytes==zht_owner_size());
    REQUIRE(stats.peak_bytes==stats.bytes+options.zig_bytes+options.temporary_bytes);
    ZhtLease lease={0};REQUIRE(zht_lease_begin(owner,&lease)==ZHT_OK && lease.port==stats.port && lease.server);
    gboolean raw=FALSE;g_object_get(lease.server,"raw-paths",&raw,NULL);REQUIRE(raw);
    GSList *listeners=soup_server_get_listeners(lease.server);
    REQUIRE(g_slist_length(listeners)==1);g_slist_free(listeners);
    REQUIRE(zht_seal(owner)==ZHT_OK);
    REQUIRE(!soup_server_get_listeners(lease.server));
    ZhtLease rejected={0};REQUIRE(zht_lease_begin(owner,&rejected)==ZHT_CLOSED && !rejected.owner);
    REQUIRE(zht_stats(owner,&stats)==ZHT_OK && !stats.accepting);
    REQUIRE(zht_lease_finish(&lease)==ZHT_CLOSED && !lease.owner && !lease.server);
    zht_close(owner);zht_unref(owner);REQUIRE(empty());
    REQUIRE(zht_create(&options,&owner,&failure)==ZHT_OK);
    REQUIRE(zht_lease_begin(owner,&lease)==ZHT_OK);
    zht_close(owner);zht_unref(owner);
    ZhtCounts counts;zht_counts(&counts);
    REQUIRE(counts.owners==1 && counts.servers==1 && counts.bytes==zht_owner_size());
    REQUIRE(zht_lease_finish(&lease)==ZHT_CLOSED && empty());
    ZhtLease old[16]={{0}};
    for(unsigned i=0;i<16;++i) {
        REQUIRE(zht_create(&options,&owner,&failure)==ZHT_OK);
        REQUIRE(zht_lease_begin(owner,&old[i])==ZHT_OK);
        zht_close(owner);zht_unref(owner);
    }
    zht_counts(&counts);REQUIRE(counts.owners==16 && counts.servers==16 && counts.bytes==16*zht_owner_size());
    REQUIRE(zht_create(&options,&owner,&failure)==ZHT_FULL && !owner && !failure.domain);
    for(unsigned i=0;i<16;++i)REQUIRE(zht_lease_finish(&old[i])==ZHT_CLOSED);
    REQUIRE(empty());
    fprintf(stderr,"owned HTTPS transport: budget/OOM/native-error/actual-listener/raw-paths/seal/late-server/process-full8 groups; resources0\n");
    return 0;
}
