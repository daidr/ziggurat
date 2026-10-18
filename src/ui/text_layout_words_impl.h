#ifndef ZIGGURAT_TEXT_LAYOUT_WORDS_IMPL_H
#define ZIGGURAT_TEXT_LAYOUT_WORDS_IMPL_H
#include <stdint.h>

/* Construction-only stream over one immutable text. Units remain the native
 * adapter's until its caller validates/converts the completed partition.
 * Segment failures latch; finish writes count only on success. Reinitialize to
 * reuse. Candidate bytes may change before a failure and are never published. */
enum { ZTL_WORD_OK=0, ZTL_WORD_INVALID=1, ZTL_WORD_CAPACITY=2 };
typedef struct ZtlWordWriter {
    uint32_t *ends;
    uint32_t capacity, count, length, next;
    int previous_lexical, failed, finished;
} ZtlWordWriter;

static int ztl_word_writer_init(ZtlWordWriter *writer, uint32_t *ends,
    uint32_t capacity, uint32_t length) {
    if (!writer) return ZTL_WORD_INVALID;
    *writer=(ZtlWordWriter){.ends=ends,.capacity=capacity,.length=length};
    if ((capacity && !ends) || (length && !capacity)) {
        writer->failed=capacity?ZTL_WORD_INVALID:ZTL_WORD_CAPACITY;
        return writer->failed;
    }
    return ZTL_WORD_OK;
}
static int ztl_word_writer_segment(ZtlWordWriter *writer, uint32_t end, int lexical) {
    if (!writer) return ZTL_WORD_INVALID;
    if (writer->failed) return writer->failed;
    if (writer->finished || (lexical!=0 && lexical!=1) || end<=writer->next || end>writer->length) {
        writer->failed=ZTL_WORD_INVALID;
        return writer->failed;
    }
    if (!lexical && writer->count && !writer->previous_lexical) {
        writer->ends[writer->count-1]=end;
    } else if (writer->count==writer->capacity) {
        writer->failed=ZTL_WORD_CAPACITY;
        return writer->failed;
    } else {
        writer->ends[writer->count++]=end;
    }
    writer->next=end;
    writer->previous_lexical=lexical;
    return ZTL_WORD_OK;
}
static int ztl_word_writer_finish(ZtlWordWriter *writer, uint32_t *count) {
    if (!writer || !count) return ZTL_WORD_INVALID;
    if (writer->failed) return writer->failed;
    if (writer->finished || writer->next!=writer->length) {
        writer->failed=ZTL_WORD_INVALID;
        return writer->failed;
    }
    writer->finished=1;
    *count=writer->count;
    return ZTL_WORD_OK;
}
#endif
