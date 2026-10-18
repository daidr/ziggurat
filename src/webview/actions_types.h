/* Optional explicit policy storage, independent of Zig callback lifetimes. */
typedef struct ActionBudget {
    LONG refs, permission_limit, download_limit, permissions, downloads;
} ActionBudget;
typedef struct PermissionGrantInput { const WCHAR *origin;uint32_t kinds; } PermissionGrantInput;
typedef void (*PermissionOfferCallback)(void *,const WCHAR *,uint32_t,_Bool,void *);
typedef void (*DownloadOfferCallback)(void *,const WCHAR *,const WCHAR *,const WCHAR *,int64_t,void *);
typedef void (*DownloadNotifyCallback)(void *,uint64_t,uint32_t,uint64_t,int64_t,int32_t);
typedef struct ActionInput {
    ActionBudget *budget;
    const PermissionGrantInput *permissions;
    uint32_t permission_count;
    _Bool permission_gesture;
    PermissionOfferCallback permission_offer;
    const WCHAR *const *download_origins;
    uint32_t download_origin_count;
    uint64_t download_known_limit,download_received_limit;
    _Bool download_unknown;
    DownloadOfferCallback download_offer;
    DownloadNotifyCallback download_notify;
} ActionInput;
typedef struct ActionPolicy {
    ActionBudget *budget;
    PermissionGrantInput permissions[8];
    uint32_t permission_count;
    BOOL permission_gesture;
    PermissionOfferCallback permission_offer;
    WCHAR *download_origins[8];
    uint32_t download_origin_count;
    uint64_t download_known_limit,download_received_limit;
    BOOL download_unknown;
    DownloadOfferCallback download_offer;
    DownloadNotifyCallback download_notify;
} ActionPolicy;
typedef struct PermissionPending PermissionPending;
typedef struct DownloadPending DownloadPending;
static LONG action_budget_live,permission_request_live,download_request_live;
void zwv_action_counts(uint32_t *budgets,uint32_t *permissions,uint32_t *downloads) {
    *budgets=InterlockedCompareExchange(&action_budget_live,0,0);
    *permissions=InterlockedCompareExchange(&permission_request_live,0,0);
    *downloads=InterlockedCompareExchange(&download_request_live,0,0);
}
ActionBudget *zwv_action_budget_create(uint32_t permissions,uint32_t downloads) {
    if (permissions>8||downloads>4||(!permissions&&!downloads)) return NULL;
    ActionBudget *budget=calloc(1,sizeof(*budget));if (!budget) return NULL;
    budget->refs=1;budget->permission_limit=(LONG)permissions;budget->download_limit=(LONG)downloads;
    InterlockedIncrement(&action_budget_live);return budget;
}
void zwv_action_budget_limit(ActionBudget *budget,uint32_t permissions,uint32_t downloads) {
    if (permissions<=8&&downloads<=4) { InterlockedExchange(&budget->permission_limit,(LONG)permissions);InterlockedExchange(&budget->download_limit,(LONG)downloads); }
}
static void action_budget_add(ActionBudget *budget) { InterlockedIncrement(&budget->refs); }
void zwv_action_budget_release(ActionBudget *budget) {
    if (!InterlockedDecrement(&budget->refs)) { free(budget);InterlockedDecrement(&action_budget_live); }
}
static void action_policy_free(ActionPolicy *policy) {
    if (!policy) return;
    for (uint32_t i=0;i<policy->permission_count;i++) free((void *)policy->permissions[i].origin);
    for (uint32_t i=0;i<policy->download_origin_count;i++) free(policy->download_origins[i]);
    zwv_action_budget_release(policy->budget);free(policy);
}
static HRESULT action_policy_new(const ActionInput *input,ActionPolicy **out) {
    *out=NULL;if (!input) return S_OK;
    if (!input->budget||(!input->permission_count&&!input->download_origin_count)||input->permission_count>8||input->download_origin_count>8) return E_INVALIDARG;
    if (input->permission_count&&(!input->permissions||!input->permission_offer)) return E_INVALIDARG;
    if (input->download_origin_count&&(!input->download_origins||!input->download_offer||!input->download_notify||!input->download_known_limit||!input->download_received_limit)) return E_INVALIDARG;
    ActionPolicy *policy=calloc(1,sizeof(*policy));if (!policy) return E_OUTOFMEMORY;
    policy->budget=input->budget;action_budget_add(policy->budget);
    policy->permission_gesture=input->permission_gesture;policy->permission_offer=input->permission_offer;
    for (uint32_t i=0;i<input->permission_count;i++) {
        const PermissionGrantInput *grant=&input->permissions[i];
        if (!grant->origin||!*grant->origin||wcsnlen(grant->origin,1025)>1024||!grant->kinds||(grant->kinds&~8191u)) { action_policy_free(policy);return E_INVALIDARG; }
        for (const WCHAR *p=grant->origin;*p;p++) if (*p<=32||*p>=127||*p==L'*'||*p==L'?'||*p==L'#'||*p==L'%'||*p==L'@'||*p==L'\\') { action_policy_free(policy);return E_INVALIDARG; }
        WCHAR *origin=_wcsdup(grant->origin);if (!origin) { action_policy_free(policy);return E_OUTOFMEMORY; }
        policy->permissions[policy->permission_count++]=(PermissionGrantInput){origin,grant->kinds};
    }
    policy->download_known_limit=input->download_known_limit;policy->download_received_limit=input->download_received_limit;
    policy->download_unknown=input->download_unknown;policy->download_offer=input->download_offer;policy->download_notify=input->download_notify;
    for (uint32_t i=0;i<input->download_origin_count;i++) {
        const WCHAR *origin=input->download_origins[i];NetOrigin checked;
        if (!origin||wcsnlen(origin,1025)>1024||FAILED(parse_net_origin(origin,TRUE,TRUE,TRUE,&checked))) { action_policy_free(policy);return E_INVALIDARG; }
        WCHAR *copy=_wcsdup(origin);if (!copy) { action_policy_free(policy);return E_OUTOFMEMORY; }
        policy->download_origins[policy->download_origin_count++]=copy;
    }
    *out=policy;return S_OK;
}
