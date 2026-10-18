#ifndef ZIGGURAT_WINDOWS_PHYSICAL_H
#define ZIGGURAT_WINDOWS_PHYSICAL_H
#include "windows_core.h"
/* Private common metadata. Direct IStream storage contains only this small
 * prefix; it does not acquire a channel ring/events/producer state. */
struct FileControl {LONG refs,cancelled,alive;HANDLE cancel_event;};
struct ZwsBudget {LONG refs,live,limit;};
typedef struct ZwsPhysical {
    LONG refs,binding;DWORD ui_thread;uint32_t kind;
    ZwsControl *control;ZwsBudget *budget;
} ZwsPhysical;
typedef struct ZwsRetirement {ZwsControl *control;ZwsBudget *budget;} ZwsRetirement;
int zws_physical_reserve(void);
void *zws_native_alloc(size_t);
void zws_physical_unreserve(void);
int zws_control_create(ZwsControl **,uint32_t *win32_error);
int zws_budget_reserve(ZwsBudget *);
void zws_budget_unreserve(ZwsBudget *);
/* Withdraw before freeing adapter/channel payload. Retire only after all of
 * that physical storage and its foreign handles have actually been freed. */
ZwsRetirement zws_physical_withdraw(ZwsPhysical *);
void zws_physical_retire(ZwsRetirement);
#endif
