#include "../src/document_accessibility/native_internal.h"
/* Test-only layout evidence. No native operation, allocation or callback. */
void zdac_probe_storage(uint64_t *sizes) {
    sizes[0]=sizeof(ZdaNative);
    sizes[1]=sizeof(ZdaAction);
    sizes[2]=sizeof(ZdaAuxiliary);
    sizes[3]=sizeof(ZdaAuxMapping);
    sizes[4]=sizeof(ZdaPublication);
    sizes[5]=sizeof(ZdaAuxAction);
    sizes[6]=sizeof(ZdaAuxAccepted);
}
