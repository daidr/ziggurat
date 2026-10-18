/* Private implementation included by native_windows.c after provider helpers. */
static BOOL auxiliary_key_equal(const ZdaAuxKey *a,const ZdaAuxKey *b) {
    return a->namespace_id==b->namespace_id&&a->comparison==b->comparison&&a->item==b->item&&a->kind==b->kind&&a->variant==b->variant;
}
static int auxiliary_index(ZdaNative *s,const ZdaAuxKey *key) {
    if(!s->auxiliary||!s->auxiliary->current)return -1;
    for(uint32_t i=0;i<s->auxiliary->count;++i)if(auxiliary_key_equal(&s->auxiliary->current->entries[i].node.key,key))return (int)i;
    return -1;
}
void zda_auxiliary_retain(ZdaAuxPlan *p){if(p)InterlockedIncrement(&p->refs);}
void zda_auxiliary_release(ZdaAuxPlan *p){
    if(!p||InterlockedDecrement(&p->refs))return;
    for(uint32_t i=0;i<p->count;++i)if(p->entries[i].provider)provider_release(p->entries[i].provider);
    zda_storage_release(p);
}
static BOOL auxiliary_name_valid(const uint16_t *name,uint32_t count){
    for(uint32_t i=0;i<count;++i){uint16_t u=name[i];if(!u)return FALSE;if(u>=0xd800&&u<=0xdbff){if(++i==count||name[i]<0xdc00||name[i]>0xdfff)return FALSE;}else if(u>=0xdc00&&u<=0xdfff)return FALSE;}
    return TRUE;
}
int zda_native_auxiliary(ZdaNative *s,const ZdaAuxNode *nodes,uint32_t count,const uint16_t *names,uint32_t length,ZdaAuxPlan **out){
    if(!out)return ZDA_INVALID;*out=NULL;
    if(GetCurrentThreadId()!=s->owner||!s->auxiliary||!count||count>s->auxiliary->capacity||!nodes||!names||length>32768)return ZDA_INVALID;
    if(s->closed)return ZDA_CLOSED;
    if(!auxiliary_name_valid(names,length))return ZDA_INVALID;
    for(uint32_t i=0;i<count;++i){const ZdaAuxNode*n=&nodes[i];
        if(!n->key.namespace_id||!n->key.comparison||!n->frame_id||n->key.kind>2||(n->expanded&~3u)||(n->key.kind!=2&&(n->expanded&1))||(n->key.kind==0&&(n->expanded&2))||n->name_start>length||n->name_length>length-n->name_start)return ZDA_INVALID;
        if(!auxiliary_name_valid(names+n->name_start,n->name_length))return ZDA_INVALID;
        if(i==0){if(n->parent!=UINT32_MAX||n->key.kind)return ZDA_INVALID;}else if(n->parent>=i)return ZDA_INVALID;
        for(uint32_t j=0;j<i;++j)if(n->frame_id==nodes[j].frame_id||auxiliary_key_equal(&n->key,&nodes[j].key))return ZDA_INVALID;
    }
    size_t bytes=sizeof(ZdaAuxPlan)+count*sizeof(ZdaAuxEntry)+length*sizeof(WCHAR);
    ZdaAuxPlan*p=NULL;int result=zda_storage_create(s->account,ZDA_BLOB,bytes,(void**)&p);if(result!=ZDA_OK)return result;
    memset(p,0,bytes);p->refs=1;p->state=s;p->count=count;p->name_length=length;p->entries=(ZdaAuxEntry*)(p+1);p->names=(WCHAR*)(p->entries+count);
    memcpy(p->names,names,length*sizeof(WCHAR));
    for(uint32_t i=0;i<count;++i){p->entries[i].node=nodes[i];HRESULT hr=create_provider(s,AUX_SOURCE,&p->entries[i].provider);if(FAILED(hr)){zda_auxiliary_release(p);return hr==E_OUTOFMEMORY?ZDA_OOM:hr==HRESULT_FROM_WIN32(ERROR_NOT_ENOUGH_QUOTA)?ZDA_CAPACITY:ZDA_UNAVAILABLE;}p->entries[i].provider->key=nodes[i].key;}
    *out=p;return ZDA_OK;
}
static HRESULT auxiliary_bounds(ZdaProvider*p,struct UiaRect*out,BOOL*offscreen){
    if(!out)return E_POINTER;*out=(struct UiaRect){0};ZdaNative*s=p->state;
    AcquireSRWLockShared(&s->lock);int at=auxiliary_index(s,&p->key);
    if(s->closed||at<0){ReleaseSRWLockShared(&s->lock);return UIA_E_ELEMENTNOTAVAILABLE;}
    const ZdaAuxGeometry*g=&s->auxiliary->geometry[at];ZdaRect r;BOOL visible=zda_auxiliary_rectangle(s->auxiliary,g,&r);
    if(visible)*out=(struct UiaRect){s->screen_x+r.x*s->auxiliary->scale,s->screen_y+r.y*s->auxiliary->scale,r.width*s->auxiliary->scale,r.height*s->auxiliary->scale};
    if(offscreen)*offscreen=!visible;ReleaseSRWLockShared(&s->lock);return S_OK;
}
static HRESULT auxiliary_property(ZdaProvider*p,PROPERTYID id,VARIANT*out){
    ZdaNative*s=p->state;AcquireSRWLockShared(&s->lock);int at=auxiliary_index(s,&p->key);
    if(s->closed||at<0){ReleaseSRWLockShared(&s->lock);return UIA_E_ELEMENTNOTAVAILABLE;}
    const ZdaAuxNode*n=&s->auxiliary->current->entries[at].node;const ZdaAuxGeometry*g=&s->auxiliary->geometry[at];HRESULT hr=S_OK;
    if(id==UIA_NamePropertyId){out->vt=VT_BSTR;out->bstrVal=SysAllocStringLen(s->auxiliary->current->names+n->name_start,n->name_length);if(!out->bstrVal)hr=E_OUTOFMEMORY;}
    else if(id==UIA_ControlTypePropertyId){out->vt=VT_I4;out->lVal=p->key.kind==1?UIA_ButtonControlTypeId:UIA_GroupControlTypeId;}
    else if(id==UIA_IsEnabledPropertyId||id==UIA_HasKeyboardFocusPropertyId||id==UIA_IsOffscreenPropertyId||id==UIA_IsControlElementPropertyId||id==UIA_IsContentElementPropertyId||id==UIA_IsKeyboardFocusablePropertyId||id==UIA_IsInvokePatternAvailablePropertyId||id==UIA_IsExpandCollapsePatternAvailablePropertyId){
        ZdaRect visible;BOOL value=id==UIA_IsEnabledPropertyId?(g->flags&1)!=0:id==UIA_HasKeyboardFocusPropertyId?(g->flags&2)!=0:id==UIA_IsOffscreenPropertyId?!zda_auxiliary_rectangle(s->auxiliary,g,&visible):id==UIA_IsKeyboardFocusablePropertyId?(n->expanded&2)!=0:id==UIA_IsInvokePatternAvailablePropertyId?p->key.kind==1:id==UIA_IsExpandCollapsePatternAvailablePropertyId?p->key.kind==2:TRUE;
        out->vt=VT_BOOL;out->boolVal=value?VARIANT_TRUE:VARIANT_FALSE;
    }
    ReleaseSRWLockShared(&s->lock);return hr;
}
static HRESULT auxiliary_navigate(ZdaProvider*p,enum NavigateDirection direction,IRawElementProviderFragment**out){
    ZdaNative*s=p->state;AcquireSRWLockShared(&s->lock);int at=auxiliary_index(s,&p->key);
    if(s->closed||at<0){ReleaseSRWLockShared(&s->lock);return UIA_E_ELEMENTNOTAVAILABLE;}
    ZdaAuxPlan*plan=s->auxiliary->current;ZdaProvider*next=NULL;uint32_t parent=plan->entries[at].node.parent;
    if(direction==NavigateDirection_Parent)next=parent==UINT32_MAX?s->root:plan->entries[parent].provider;
    else if(direction==NavigateDirection_PreviousSibling&&at==0)next=s->providers[s->count-1];
    else if(direction==NavigateDirection_FirstChild||direction==NavigateDirection_LastChild){for(uint32_t i=0;i<plan->count;++i)if(plan->entries[i].node.parent==(uint32_t)at){next=plan->entries[i].provider;if(direction==NavigateDirection_FirstChild)break;}}
    else if(direction==NavigateDirection_PreviousSibling){for(int i=at-1;i>=0;--i)if(plan->entries[i].node.parent==parent){next=plan->entries[i].provider;break;}}
    else if(direction==NavigateDirection_NextSibling){for(uint32_t i=(uint32_t)at+1;i<plan->count;++i)if(plan->entries[i].node.parent==parent){next=plan->entries[i].provider;break;}}
    if(next){provider_add(next);*out=&next->fragment;}ReleaseSRWLockShared(&s->lock);return S_OK;
}
static HRESULT auxiliary_request(ZdaProvider*p,uint32_t kind){
    ZdaNative*s=p->state;AcquireSRWLockExclusive(&s->lock);int at=auxiliary_index(s,&p->key);
    if(s->closed||at<0||!s->context||!s->enqueue){ReleaseSRWLockExclusive(&s->lock);return UIA_E_ELEMENTNOTAVAILABLE;}
    if(!s->presentation_epoch){ReleaseSRWLockExclusive(&s->lock);return UIA_E_NOTSUPPORTED;}
    const ZdaAuxGeometry*g=&s->auxiliary->geometry[at];
    if(!(g->flags&1)){ReleaseSRWLockExclusive(&s->lock);return UIA_E_ELEMENTNOTENABLED;}
    ZdaRect visible;if(!zda_auxiliary_rectangle(s->auxiliary,g,&visible)){ReleaseSRWLockExclusive(&s->lock);return UIA_E_INVALIDOPERATION;}
    for(uint32_t i=0;i<s->count;++i)if(!s->sources[i].enabled||s->sources[i].composing){ReleaseSRWLockExclusive(&s->lock);return UIA_E_INVALIDOPERATION;}
    if(kind==4?!(s->auxiliary->current->entries[at].node.expanded&2):((kind==1&&p->key.kind!=1)||(kind!=1&&p->key.kind!=2))){ReleaseSRWLockExclusive(&s->lock);return UIA_E_NOTSUPPORTED;}
    ZdaAction*action=NULL;for(uint32_t i=0;i<ZDA_ACTIONS;++i)if(!s->actions[i].used){action=&s->actions[i];break;}
    if(!action){ReleaseSRWLockExclusive(&s->lock);return HRESULT_FROM_WIN32(ERROR_NOT_ENOUGH_QUOTA);}
    *action=(ZdaAction){.state=s,.used=TRUE,.presentation_epoch=s->presentation_epoch,.source=AUX_SOURCE,.kind=kind,.auxiliary_key=p->key};
    if(s->auxiliary->affine)s->auxiliary->affine->action_serial[action-s->actions]=s->geometry_serial;
    zda_store_retain(s);BOOL accepted=s->enqueue(s->context,action);
    if(!accepted)action->used=FALSE;ReleaseSRWLockExclusive(&s->lock);
    if(!accepted)zda_store_release(s);return accepted?S_OK:HRESULT_FROM_WIN32(ERROR_NOT_ENOUGH_QUOTA);
}
static ZdaProvider*invoke_self(IInvokeProvider*p){return(ZdaProvider*)((char*)p - offsetof(ZdaProvider,invoke));}
static ZdaProvider*expand_self(IExpandCollapseProvider*p){return(ZdaProvider*)((char*)p - offsetof(ZdaProvider,expand));}
static HRESULT STDMETHODCALLTYPE invoke_query(IInvokeProvider*p,REFIID iid,void**out){return provider_query(invoke_self(p),iid,out);}
static ULONG STDMETHODCALLTYPE invoke_add(IInvokeProvider*p){return provider_add(invoke_self(p));}
static ULONG STDMETHODCALLTYPE invoke_release(IInvokeProvider*p){return provider_release(invoke_self(p));}
static HRESULT STDMETHODCALLTYPE invoke_call(IInvokeProvider*p){return auxiliary_request(invoke_self(p),1);}
static const IInvokeProviderVtbl invoke_vtable={invoke_query,invoke_add,invoke_release,invoke_call};
static HRESULT STDMETHODCALLTYPE expand_query(IExpandCollapseProvider*p,REFIID iid,void**out){return provider_query(expand_self(p),iid,out);}
static ULONG STDMETHODCALLTYPE expand_add(IExpandCollapseProvider*p){return provider_add(expand_self(p));}
static ULONG STDMETHODCALLTYPE expand_release(IExpandCollapseProvider*p){return provider_release(expand_self(p));}
static HRESULT STDMETHODCALLTYPE expand_call(IExpandCollapseProvider*p){return auxiliary_request(expand_self(p),2);}
static HRESULT STDMETHODCALLTYPE collapse_call(IExpandCollapseProvider*p){return auxiliary_request(expand_self(p),3);}
static HRESULT STDMETHODCALLTYPE expand_state(IExpandCollapseProvider*iface,enum ExpandCollapseState*out){
    if(!out)return E_POINTER;ZdaProvider*p=expand_self(iface);ZdaNative*s=p->state;
    AcquireSRWLockShared(&s->lock);int at=auxiliary_index(s,&p->key);
    if(s->closed||at<0){ReleaseSRWLockShared(&s->lock);return UIA_E_ELEMENTNOTAVAILABLE;}
    *out=(s->auxiliary->current->entries[at].node.expanded&1)?ExpandCollapseState_Expanded:ExpandCollapseState_Collapsed;ReleaseSRWLockShared(&s->lock);return S_OK;
}
static const IExpandCollapseProviderVtbl expand_vtable={expand_query,expand_add,expand_release,expand_call,collapse_call,expand_state};
void*zda_native_auxiliary_provider(ZdaNative*s,const ZdaAuxKey*key){
    AcquireSRWLockShared(&s->lock);int at=key?auxiliary_index(s,key):-1;ZdaProvider*p=!s->closed&&at>=0?s->auxiliary->current->entries[at].provider:NULL;
    if(p)provider_add(p);ReleaseSRWLockShared(&s->lock);return p?&p->simple:NULL;
}
int zda_native_take_auxiliary_action(void*ptr,ZdaAuxAction*out){
    ZdaAction*a=ptr;ZdaNative*s=a->state;assert(GetCurrentThreadId()==s->owner);if(!out)return 0;AcquireSRWLockShared(&s->lock);
    if(!a->used||a->source!=AUX_SOURCE){ReleaseSRWLockShared(&s->lock);return 0;}
    int at=auxiliary_index(s,&a->auxiliary_key);
    BOOL valid=!s->closed&&s->context&&a->presentation_epoch==s->presentation_epoch&&at>=0;
    if(valid){const ZdaAuxGeometry*g=&s->auxiliary->geometry[at];ZdaRect visible;valid=(g->flags&1)&&zda_auxiliary_rectangle(s->auxiliary,g,&visible)&&(a->kind!=4||(s->auxiliary->current->entries[at].node.expanded&2));}
    if(valid&&s->auxiliary->affine)valid=s->auxiliary->affine->active&&s->auxiliary->affine->action_serial[a-s->actions]==s->geometry_serial;
    if(valid)*out=(ZdaAuxAction){.context=s->context,.key=a->auxiliary_key,.presentation_epoch=a->presentation_epoch,.kind=a->kind,.publication=s->auxiliary->affine?s->auxiliary->affine->publication:(ZdaPublication){0}};
    ReleaseSRWLockShared(&s->lock);return valid;
}
static void auxiliary_accepted(ZdaNative*s,uint32_t i,ZdaAuxAccepted*out){
    const ZdaAuxNode*n=&s->auxiliary->current->entries[i].node;const ZdaAuxGeometry*g=&s->auxiliary->geometry[i];ZdaRect visible;
    *out=(ZdaAuxAccepted){.key=n->key,.presentation_epoch=s->presentation_epoch,.flags=(g->flags&3)|(zda_auxiliary_rectangle(s->auxiliary,g,&visible)?4u:0u)|((n->expanded&2)?8u:0u)|((n->expanded&1)?16u:0u),.frame_id=n->frame_id,.publication=s->auxiliary->affine?s->auxiliary->affine->publication:(ZdaPublication){0}};
}
int zda_native_auxiliary_accepted(ZdaNative*s,uint64_t frame_id,ZdaAuxAccepted*out){
    if(!s||!out||GetCurrentThreadId()!=s->owner)return ZDA_INVALID;
    AcquireSRWLockShared(&s->lock);
    if(s->closed){ReleaseSRWLockShared(&s->lock);return ZDA_CLOSED;}
    if(s->auxiliary&&s->presentation_epoch)for(uint32_t i=0;i<s->auxiliary->count;++i){const ZdaAuxNode*n=&s->auxiliary->current->entries[i].node;if(n->frame_id==frame_id){auxiliary_accepted(s,i,out);ReleaseSRWLockShared(&s->lock);return ZDA_OK;}}
    ReleaseSRWLockShared(&s->lock);return ZDA_UNAVAILABLE;
}
int zda_native_auxiliary_accepted_key(ZdaNative*s,const ZdaAuxKey*key,ZdaAuxAccepted*out){
    if(!s||!key||!out||GetCurrentThreadId()!=s->owner)return ZDA_INVALID;
    AcquireSRWLockShared(&s->lock);
    if(s->closed){ReleaseSRWLockShared(&s->lock);return ZDA_CLOSED;}
    int at=auxiliary_index(s,key);if(at>=0&&s->presentation_epoch){auxiliary_accepted(s,(uint32_t)at,out);ReleaseSRWLockShared(&s->lock);return ZDA_OK;}
    ReleaseSRWLockShared(&s->lock);return ZDA_UNAVAILABLE;
}
