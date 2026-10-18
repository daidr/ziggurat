#ifndef ZIGGURAT_BOUNDED_STREAM_H
#define ZIGGURAT_BOUNDED_STREAM_H
/* Fixed-budget memory stream. No file I/O, realloc, decoder or UI access. */
static LONG owned_tool_streams;
typedef struct BoundedStream {
    IStream iface;
    LONG refs;
    CRITICAL_SECTION mutex;
    unsigned char *bytes;
    size_t capacity, length, position;
    HRESULT failure;
    BOOL sealed;
} BoundedStream;
static HRESULT STDMETHODCALLTYPE bounded_query(IStream *p,REFIID iid,void **out) {
    if (!out) return E_POINTER; *out=NULL;
    if (!IsEqualIID(iid,&IID_IUnknown) && !IsEqualIID(iid,&IID_IStream) && !IsEqualIID(iid,&IID_ISequentialStream)) return E_NOINTERFACE;
    *out=p; InterlockedIncrement(&((BoundedStream *)p)->refs); return S_OK;
}
static ULONG STDMETHODCALLTYPE bounded_add(IStream *p) { return InterlockedIncrement(&((BoundedStream *)p)->refs); }
static ULONG STDMETHODCALLTYPE bounded_release(IStream *p) {
    BoundedStream *s=(BoundedStream *)p; LONG refs=InterlockedDecrement(&s->refs);
    if (!refs) { DeleteCriticalSection(&s->mutex); free(s->bytes); free(s); InterlockedDecrement(&owned_tool_streams); }
    return refs;
}
static HRESULT STDMETHODCALLTYPE bounded_read(IStream *p,void *out,ULONG requested,ULONG *actual) {
    BoundedStream *s=(BoundedStream *)p; if (actual) *actual=0;
    if (requested && !out) return STG_E_INVALIDPOINTER;
    EnterCriticalSection(&s->mutex);
    size_t available=s->position<s->length?s->length-s->position:0;
    size_t count=requested<available?requested:available;
    if (count) memcpy(out,s->bytes+s->position,count);
    s->position+=count;
    LeaveCriticalSection(&s->mutex);
    if (actual) *actual=(ULONG)count;
    return count==requested?S_OK:S_FALSE;
}
static HRESULT STDMETHODCALLTYPE bounded_write(IStream *p,const void *source,ULONG count,ULONG *actual) {
    BoundedStream *s=(BoundedStream *)p; if (actual) *actual=0;
    if (count && !source) return STG_E_INVALIDPOINTER;
    EnterCriticalSection(&s->mutex);
    HRESULT hr=s->failure;
    if (SUCCEEDED(hr) && s->sealed) hr=STG_E_ACCESSDENIED;
    if (SUCCEEDED(hr) && count>s->capacity-s->position) hr=s->failure=STG_E_MEDIUMFULL;
    if (SUCCEEDED(hr)) {
        if (s->position>s->length) memset(s->bytes+s->length,0,s->position-s->length);
        if (count) memcpy(s->bytes+s->position,source,count);
        s->position+=count; if (s->position>s->length) s->length=s->position;
        if (actual) *actual=count;
    }
    LeaveCriticalSection(&s->mutex); return hr;
}
static HRESULT STDMETHODCALLTYPE bounded_seek(IStream *p,LARGE_INTEGER offset,DWORD origin,ULARGE_INTEGER *out) {
    BoundedStream *s=(BoundedStream *)p; EnterCriticalSection(&s->mutex);
    uint64_t base=origin==STREAM_SEEK_SET?0:origin==STREAM_SEEK_CUR?s->position:s->length;
    HRESULT hr=S_OK;
    uint64_t distance=offset.QuadPart<0?(uint64_t)(-(offset.QuadPart+1))+1:(uint64_t)offset.QuadPart;
    uint64_t position=0;
    if (origin>STREAM_SEEK_END || (offset.QuadPart<0?distance>base:distance>s->capacity-base)) hr=STG_E_INVALIDFUNCTION;
    else {
        position=offset.QuadPart<0?base-distance:base+distance;
        s->position=(size_t)position;
        if (out) out->QuadPart=position;
    }
    LeaveCriticalSection(&s->mutex); return hr;
}
static HRESULT STDMETHODCALLTYPE bounded_size(IStream *p,ULARGE_INTEGER size) {
    BoundedStream *s=(BoundedStream *)p; EnterCriticalSection(&s->mutex);
    HRESULT hr=s->failure;
    if (SUCCEEDED(hr) && s->sealed) hr=STG_E_ACCESSDENIED;
    if (SUCCEEDED(hr) && size.QuadPart>s->capacity) hr=s->failure=STG_E_MEDIUMFULL;
    if (SUCCEEDED(hr)) {
        if (size.QuadPart>s->length) memset(s->bytes+s->length,0,(size_t)size.QuadPart-s->length);
        s->length=(size_t)size.QuadPart;
    }
    LeaveCriticalSection(&s->mutex); return hr;
}
static HRESULT STDMETHODCALLTYPE bounded_copy(IStream *p,IStream *destination,ULARGE_INTEGER count,ULARGE_INTEGER *read,ULARGE_INTEGER *written) {
    (void)p;(void)destination;(void)count; if (read) read->QuadPart=0; if (written) written->QuadPart=0; return E_NOTIMPL;
}
static HRESULT STDMETHODCALLTYPE bounded_commit(IStream *p,DWORD flags) { (void)p;(void)flags;return S_OK; }
static HRESULT STDMETHODCALLTYPE bounded_revert(IStream *p) { (void)p;return E_NOTIMPL; }
static HRESULT STDMETHODCALLTYPE bounded_region(IStream *p,ULARGE_INTEGER offset,ULARGE_INTEGER length,DWORD type) { (void)p;(void)offset;(void)length;(void)type;return STG_E_INVALIDFUNCTION; }
static HRESULT STDMETHODCALLTYPE bounded_stat(IStream *p,STATSTG *out,DWORD flags) {
    (void)flags; if (!out) return STG_E_INVALIDPOINTER;
    BoundedStream *s=(BoundedStream *)p; EnterCriticalSection(&s->mutex);
    memset(out,0,sizeof(*out)); out->type=STGTY_STREAM; out->cbSize.QuadPart=s->length; out->grfMode=STGM_READWRITE;
    LeaveCriticalSection(&s->mutex); return S_OK;
}
static HRESULT STDMETHODCALLTYPE bounded_clone(IStream *p,IStream **out) { (void)p; if (out) *out=NULL;return E_NOTIMPL; }
static IStreamVtbl bounded_vtable={bounded_query,bounded_add,bounded_release,bounded_read,bounded_write,bounded_seek,bounded_size,bounded_copy,bounded_commit,bounded_revert,bounded_region,bounded_region,bounded_stat,bounded_clone};
static BoundedStream *bounded_stream_new(size_t capacity) {
    if (!capacity || capacity>16u*1024u*1024u) return NULL;
    BoundedStream *s=calloc(1,sizeof(*s)); if (!s) return NULL;
    s->bytes=malloc(capacity); if (!s->bytes) { free(s); return NULL; }
    s->iface.lpVtbl=&bounded_vtable; s->refs=1; s->capacity=capacity;
    if (!InitializeCriticalSectionEx(&s->mutex,0,0)) { free(s->bytes); free(s); return NULL; }
    InterlockedIncrement(&owned_tool_streams); return s;
}
static HRESULT bounded_stream_seal(BoundedStream *s) {
    EnterCriticalSection(&s->mutex); s->sealed=TRUE; HRESULT hr=s->failure; LeaveCriticalSection(&s->mutex); return hr;
}
#endif
