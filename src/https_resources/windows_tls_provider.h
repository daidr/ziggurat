#ifndef ZIGGURAT_WINDOWS_TLS_PROVIDER_H
#define ZIGGURAT_WINDOWS_TLS_PROVIDER_H
#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <stdint.h>
#include <stddef.h>
typedef struct ZhtpProvider ZhtpProvider;
typedef struct ZhtpConnection ZhtpConnection;
enum { ZHTP_OK=0,ZHTP_READ=1,ZHTP_WRITE=2,ZHTP_EOF=3,ZHTP_INVALID=4,
    ZHTP_UI_THREAD=5,ZHTP_THREAD=6,ZHTP_OOM=7,ZHTP_BUDGET=8,ZHTP_BUSY=9,ZHTP_NATIVE=10 };
enum { ZHTP_IO_AGAIN=-1,ZHTP_IO_FAILED=-2 };
typedef int (*ZhtpSend)(void *,const unsigned char *,size_t);
typedef int (*ZhtpReceive)(void *,unsigned char *,size_t);
typedef struct ZhtpIO {void *context;ZhtpSend send;ZhtpReceive receive;} ZhtpIO;
typedef struct ZhtpStats {size_t live,peak,limit;uint32_t connections;} ZhtpStats;
/* All payload calls and destruction run on this original explicit worker.
 * Bounded immutable PEM inputs are copied/parsed before returning. Native
 * failure preserves the actual provider code. No App, store or thread owner. */
int zhtp_create(uint64_t main_thread,const unsigned char *certificate,size_t certificate_length,
    const unsigned char *key,size_t key_length,size_t budget,ZhtpProvider **,int *native_error);
int zhtp_destroy(ZhtpProvider **);
int zhtp_stats(ZhtpProvider *,ZhtpStats *);
int zhtp_connection_create(ZhtpProvider *,ZhtpIO,ZhtpConnection **,int *native_error);
int zhtp_connection_destroy(ZhtpConnection **);
int zhtp_handshake(ZhtpConnection *,int *native_error);
int zhtp_read(ZhtpConnection *,unsigned char *,size_t,size_t *,int *native_error);
/* WANT_WRITE/READ requires retry with the same bytes/length, stable until the
 * operation retires. Send credit does not mean peer/page consumption. */
int zhtp_write(ZhtpConnection *,const unsigned char *,size_t,size_t *,int *native_error);
int zhtp_shutdown(ZhtpConnection *,int *native_error);
uint32_t zhtp_provider_count(void);
uint32_t zhtp_domain_count(void);
#ifdef ZHTP_TESTING
int zhtp_client_create(uint64_t,size_t,ZhtpProvider **,int *);
int zhtp_peer_matches(ZhtpConnection *,const unsigned char *,size_t);
void zhtp_test_fail_after(int);
void zhtp_test_rng_fail(int);
int zhtp_test_reseed(ZhtpProvider *,int *native_error);
#endif
#endif
