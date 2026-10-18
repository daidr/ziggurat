#ifndef ZIGGURAT_WINDOWS_PROFILE_STORAGE_H
#define ZIGGURAT_WINDOWS_PROFILE_STORAGE_H
#include "windows_profile_lifetime.h"

typedef struct ZwpwStorage ZwpwStorage;
typedef struct ZwpwStoragePaths {
    const char *root, *data;
    const WCHAR *data_w;
} ZwpwStoragePaths;
/* Worker-only filesystem preparation. Input bytes are captured before the
   first native call. No directories are removed, no policy is written. */
int zwpw_storage_create(uint32_t main_thread,const char *root,size_t length,
                        size_t bytes,ZwpwStorage **out,uint32_t *system_error);
void zwpw_storage_unref(ZwpwStorage *);
void zwpw_storage_paths(ZwpwStorage *,ZwpwStoragePaths *);
ZwpwLifetime *zwpw_storage_domain(ZwpwStorage *);
size_t zwpw_storage_size(ZwpwStorage *);
/* Conservative charge for any accepted canonical path, no native work. */
size_t zwpw_storage_bound(void);
void zwpw_storage_counts(uint32_t *owners,size_t *bytes);
#endif
