#ifndef ZIGGURAT_WEBKIT_NATIVE_H
#define ZIGGURAT_WEBKIT_NATIVE_H
#include <stdint.h>
#include <stddef.h>
#include "webkit_local.h"
#include "webkit_remote.h"
#include "webkit_profile.h"

typedef struct ZwkState ZwkState;
typedef struct ZwkCaptureBudget ZwkCaptureBudget;
typedef struct ZwkFindBudget ZwkFindBudget;
typedef struct ZwkFindGate ZwkFindGate;
typedef struct ZwkFindCommand ZwkFindCommand;
#include "webkit_resources.h"
typedef struct ZwkFailure { uint32_t domain; int32_t code; } ZwkFailure;
/* known bit 0 is a total count, bit 1 is an active index. GTK step counts are
 * not full totals. Unknown is represented by the mask, never by index -1. */
typedef struct ZwkFindSnapshot { uint32_t known; int32_t matches,active_index; } ZwkFindSnapshot;
typedef void (*ZwkFindNotify)(void *,uint64_t,int,int,const ZwkFindSnapshot *);
ZwkFindBudget *zwk_find_budget_new(uint32_t);
int zwk_find_budget_limit(ZwkFindBudget *,uint32_t);
void zwk_find_budget_close(ZwkFindBudget *);
void zwk_find_budget_release(ZwkFindBudget *);
int zwk_find_prepare(ZwkState *,ZwkFindBudget *,ZwkFindNotify,const char *,size_t,uint32_t,ZwkFindCommand **);
/* commit always consumes its candidate, including a rejected commit. */
int zwk_find_commit(ZwkFindCommand *,uint64_t);
void zwk_find_abort(ZwkFindCommand *);
int zwk_find_action(ZwkState *,int,ZwkFindSnapshot *);
void zwk_find_cancel(ZwkState *,uint64_t);
void zwk_find_counts(uint32_t *,uint32_t *,uint32_t *,size_t *,size_t *);
/* Metadata uses the shared bounded UTF-16 callback format. Kind 6 is the private
 * pre-document invalidation, not a public STARTED event or new PageId. The
 * backend accepts UTF-8 and does not manufacture Windows failure codes. */
typedef struct ZwkPageEvent {
    int kind;
    uint64_t navigation_id;
    uint32_t flags;
    int32_t status;
    const uint16_t *value;
} ZwkPageEvent;
typedef void (*ZwkNotify)(void *,int,const uint16_t *,int32_t,const ZwkFailure *);
typedef int (*ZwkPageNotify)(void *,const ZwkPageEvent *);
typedef void (*ZwkScriptNotify)(void *,uint64_t,int,int32_t,const uint16_t *,const ZwkFailure *);
typedef void (*ZwkDeadline)(void *);
typedef struct ZwkInitializerInput {
    void *budget;
    const uint16_t *source;
    uint32_t units;
} ZwkInitializerInput;
typedef void (*ZwkInitializerNotify)(void *,uint64_t,uint32_t,int32_t);
typedef struct ZwkOptions {
    const char *html;
    const char *user_agent;
    double zoom;
    uint32_t max_pending, max_result_bytes, policy_flags;
    const ZwkLocalOptions *local;
    const ZwkRemoteOptions *remote;
    uint32_t region;
    ZwkProfileContext *profile_context;
    const ZwkInitializerInput *initializers;
    uint32_t developer_tools;
} ZwkOptions;
enum ZwkResult { ZWK_OK=0, ZWK_CLOSED=1, ZWK_FULL=2, ZWK_OOM=3, ZWK_INVALID=4, ZWK_NATIVE_FAILED=5, ZWK_NOT_READY=6, ZWK_NAVIGATION_PENDING=7, ZWK_IPC_DENIED=8, ZWK_NO_HISTORY=9, ZWK_NAVIGATION_CANCELLED=10, ZWK_GEOMETRY_NOT_APPLIED=11, ZWK_INITIALIZER_BUDGET=12, ZWK_DEVTOOLS_DISABLED=13 };
enum ZwkPolicyFailure { ZWK_POLICY_MISMATCH=1, ZWK_POLICY_TIMEOUT=2, ZWK_POLICY_PREPARATION=3 };

int zwk_create(void *native_window,const ZwkOptions *,ZwkNotify,ZwkPageNotify,ZwkScriptNotify,ZwkDeadline,void *,ZwkState **out);
/* Session creation owns an unparented WebKit widget, never a native toplevel.
 * Physical dimensions must be exactly representable at the GTK integer scale. */
int zwk_session_create(const ZwkOptions *,uint32_t width,uint32_t height,ZwkNotify,ZwkPageNotify,ZwkScriptNotify,ZwkDeadline,void *,ZwkState **out);
int zwk_session_mount(ZwkState *,void *native_window,int32_t left,int32_t top,int32_t right,int32_t bottom,int visible,uint64_t epoch);
int zwk_session_park(ZwkState *,uint64_t epoch);
int zwk_session_size(ZwkState *,uint32_t *width,uint32_t *height);
void zwk_session_parent_destroying(ZwkState *,uint64_t epoch);
void zwk_close(ZwkState *);
int zwk_evaluate(ZwkState *,const char *,uint64_t);
void zwk_evaluate_cancel(ZwkState *,uint64_t);
int zwk_post(ZwkState *,const char *);
int zwk_zoom(ZwkState *,double *,int write);
int zwk_user_agent(ZwkState *,const char *set,char **get);
/* op: 0 query, 1 enable, 2 disable and close, 3 show. The inspector is a
 * separate engine-owned toplevel; docking into the content host is refused. */
int zwk_devtools(ZwkState *,int op,int *enabled,int *visible);
void zwk_devtools_counts(uint32_t *shown);
void zwk_string_free(char *);
int zwk_deadline_arm(ZwkState *,uint64_t nanoseconds);
void zwk_deadline_cancel(ZwkState *);
int zwk_refresh(ZwkState *);
int zwk_navigate_remote(ZwkState *,const char *);
int zwk_navigate_local(ZwkState *,const char *);
int zwk_history(ZwkState *,int forward);
int zwk_stop(ZwkState *);
int zwk_focus(ZwkState *);
int zwk_viewport(ZwkState *, int32_t left, int32_t top, int32_t right, int32_t bottom, int visible);
void zwk_last_failure(ZwkState *,ZwkFailure *);
void zwk_counts(uint32_t *states,uint32_t *callbacks,uint32_t *views);
/* Optional trusted future-document batch. prepare captures UTF-8 and owns the
 * native gate, without an SDK mutation or callback-context transfer. activate
 * may synchronously notify after the registration slot is withdrawn. */
void *zwk_initializer_budget_create(size_t,int32_t *);
size_t zwk_initializer_budget_limit(void *);
void zwk_initializer_budget_retain(void *);
void zwk_initializer_budget_unref(void *);
_Bool zwk_initializer_budget_reserve(void *,size_t);
void zwk_initializer_budget_release(void *,size_t);
void zwk_initializer_counts(uint32_t *,uint32_t *,uint32_t *,uint64_t *);
int zwk_initializers_prepare(ZwkState *,const ZwkInitializerInput *,uint64_t,ZwkInitializerNotify);
void zwk_initializers_activate(ZwkState *);
void zwk_initializers_abandon(ZwkState *);
void zwk_initializers_cancel(ZwkState *,uint64_t);
_Bool zwk_initializers_try_cancel(ZwkState *,uint64_t);
_Bool zwk_initializers_blocked(ZwkState *);
/* Capture is separately opted in. The C-only budget survives native restart;
 * all physical tasks, including cancelled/closed old Views, share its quota.
 * A process hard limit of eight tasks also bounds PNG reservations across
 * attachments. Cairo/engine surfaces and encoder scratch are not this budget. */
enum ZwkCaptureResult { ZWK_CAPTURE_OK=0,ZWK_CAPTURE_NATIVE=1,ZWK_CAPTURE_LIMIT=2,ZWK_CAPTURE_INVALID=3,ZWK_CAPTURE_OOM=4 };
typedef void (*ZwkCaptureNotify)(void *,uint64_t,int,const unsigned char *,size_t,const ZwkFailure *);
ZwkCaptureBudget *zwk_capture_budget_new(uint32_t,uint32_t,ZwkCaptureNotify);
int zwk_capture_budget_limit(ZwkCaptureBudget *,uint32_t,uint32_t);
void zwk_capture_budget_close(ZwkCaptureBudget *);
void zwk_capture_budget_release(ZwkCaptureBudget *);
int zwk_capture_enable(ZwkState *,ZwkCaptureBudget *);
int zwk_capture_start(ZwkState *,uint64_t);
/* Shares the capture owner and its cancel/notify; the result has no bytes. */
int zwk_clear_start(ZwkState *,uint64_t);
void zwk_capture_cancel(ZwkState *,uint64_t);
void zwk_capture_counts(uint32_t *,uint32_t *,size_t *,size_t *);
int zwk_recovery_begin(ZwkState *);
void zwk_recovery_cancel(ZwkState *);
void zwk_recovery_dispatch(ZwkState *);
ZwkState *zwk_recovery_anchor(ZwkNotify,void *);
#endif
