#ifndef ZIGGURAT_LINUX_POINTER_H
#define ZIGGURAT_LINUX_POINTER_H

#include <stddef.h>
#include <stdint.h>

/* Private synchronous GTK/Core wire. It never owns an SDK object, a Core
 * owner, or an allocation. NativeEvent kind 24 borrows this value only until
 * emit returns; kind 3/4 borrow the smaller ticket below. */
enum ZlgPointerPhase {
    ZLG_POINTER_DOWN_BEGIN=0, ZLG_POINTER_DOWN_FINISH=1,
    ZLG_POINTER_UP_BEGIN=2, ZLG_POINTER_UP_FINISH=3,
    ZLG_POINTER_MOTION=4, ZLG_POINTER_LOSS=5, ZLG_POINTER_DOMAIN=6
};
enum ZlgPointerDisposition {
    ZLG_POINTER_DELIVERED=0, ZLG_POINTER_CONSUMED=1, ZLG_POINTER_DENIED=2
};
enum ZlgPointerButton {
    ZLG_POINTER_PRIMARY=0, ZLG_POINTER_SECONDARY=1, ZLG_POINTER_MIDDLE=2,
    ZLG_POINTER_BACK=3, ZLG_POINTER_FORWARD=4
};
#define ZLG_POINTER_UNKNOWN UINT32_MAX
/* Existing NativeEvent flags reserve this bit for a synchronous borrowed
 * u64 operation in context, after native loss/domain withdrawal. */
#define ZLG_POINTER_REVOKED 0x100

typedef struct ZlgPointerFacts {
    uint64_t operation;
    uint64_t sequence; /* Only mutable begin output; zero means unpaired. */
    uint32_t phase, button, modifiers, qualified;
    uint32_t tick_ms, interval_ms, edges, disposition;
    double sample_x, sample_y, min_x, max_x, min_y, max_y;
} ZlgPointerFacts;

/* Receipt/count/eligibility live in Core's one fixed raw Owner. The bridge
 * resolves this sequence against that current owner rather than trusting a
 * larger mutable copy of its receipt on the C stack. */
typedef struct ZlgPointerTicket {
    uint64_t operation, sequence;
    uint32_t button, modifiers;
} ZlgPointerTicket;

_Static_assert(sizeof(ZlgPointerFacts)==96,"pointer facts ABI size");
_Static_assert(_Alignof(ZlgPointerFacts)==8,"pointer facts ABI alignment");
_Static_assert(offsetof(ZlgPointerFacts,operation)==0,"pointer operation offset");
_Static_assert(offsetof(ZlgPointerFacts,sequence)==8,"pointer sequence offset");
_Static_assert(offsetof(ZlgPointerFacts,phase)==16,"pointer phase offset");
_Static_assert(offsetof(ZlgPointerFacts,tick_ms)==32,"pointer tick offset");
_Static_assert(offsetof(ZlgPointerFacts,sample_x)==48,"pointer sample offset");
_Static_assert(sizeof(ZlgPointerTicket)==24,"pointer ticket ABI size");
_Static_assert(_Alignof(ZlgPointerTicket)==8,"pointer ticket ABI alignment");

#endif
