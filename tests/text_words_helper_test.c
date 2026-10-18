#include <stdio.h>
#include <string.h>
#include "../src/ui/text_layout_words_impl.h"

#define CHECK(c) do { if (!(c)) { fprintf(stderr,"FAIL %d: %s\n",__LINE__,#c); return 1; } } while (0)

static int continuous_nonword(void) {
    uint32_t ends[8]={0}, count=99;
    ZtlWordWriter writer;
    CHECK(ztl_word_writer_init(&writer,ends,8,8)==ZTL_WORD_OK);
    CHECK(ztl_word_writer_segment(&writer,2,1)==ZTL_WORD_OK);
    CHECK(ztl_word_writer_segment(&writer,3,0)==ZTL_WORD_OK);
    CHECK(ztl_word_writer_segment(&writer,4,0)==ZTL_WORD_OK);
    CHECK(ztl_word_writer_segment(&writer,6,1)==ZTL_WORD_OK);
    CHECK(ztl_word_writer_segment(&writer,7,0)==ZTL_WORD_OK);
    CHECK(ztl_word_writer_segment(&writer,8,0)==ZTL_WORD_OK);
    CHECK(ztl_word_writer_finish(&writer,&count)==ZTL_WORD_OK);
    const uint32_t expected[]={2,4,6,8};
    CHECK(count==4);
    CHECK(!memcmp(ends,expected,sizeof expected));
    return 0;
}
static int capacity_refusal(void) {
    ZtlWordWriter writer;
    uint32_t count=99;
    CHECK(ztl_word_writer_init(&writer,NULL,0,1)==ZTL_WORD_CAPACITY);
    CHECK(ztl_word_writer_finish(&writer,&count)==ZTL_WORD_CAPACITY);
    CHECK(count==99);
    return 0;
}
static int empty_and_finish(void) {
    ZtlWordWriter writer;
    uint32_t count=99;
    CHECK(ztl_word_writer_init(&writer,NULL,0,0)==ZTL_WORD_OK);
    CHECK(ztl_word_writer_finish(&writer,&count)==ZTL_WORD_OK && count==0);
    CHECK(ztl_word_writer_segment(&writer,1,0)==ZTL_WORD_INVALID);
    count=99;
    CHECK(ztl_word_writer_finish(&writer,&count)==ZTL_WORD_INVALID && count==99);
    return 0;
}
static int adjacent_lexical_and_leading(void) {
    ZtlWordWriter writer;
    uint32_t ends[5]={0},count=0;
    CHECK(ztl_word_writer_init(&writer,ends,5,9)==ZTL_WORD_OK);
    CHECK(ztl_word_writer_segment(&writer,1,0)==ZTL_WORD_OK);
    CHECK(ztl_word_writer_segment(&writer,3,0)==ZTL_WORD_OK);
    CHECK(ztl_word_writer_segment(&writer,4,1)==ZTL_WORD_OK);
    CHECK(ztl_word_writer_segment(&writer,5,1)==ZTL_WORD_OK);
    CHECK(ztl_word_writer_segment(&writer,9,0)==ZTL_WORD_OK);
    CHECK(ztl_word_writer_finish(&writer,&count)==ZTL_WORD_OK && count==4);
    const uint32_t expected[]={3,4,5,9};
    CHECK(!memcmp(ends,expected,sizeof expected));
    return 0;
}
static int capacity_keeps_coalescing(void) {
    ZtlWordWriter writer;
    uint32_t ends[2]={0,UINT32_C(0xabcdef01)},count=99;
    CHECK(ztl_word_writer_init(&writer,ends,1,UINT32_MAX)==ZTL_WORD_OK);
    CHECK(ztl_word_writer_segment(&writer,1,0)==ZTL_WORD_OK);
    CHECK(ztl_word_writer_segment(&writer,UINT32_MAX,0)==ZTL_WORD_OK);
    CHECK(ztl_word_writer_finish(&writer,&count)==ZTL_WORD_OK && count==1);
    CHECK(ends[0]==UINT32_MAX && ends[1]==UINT32_C(0xabcdef01));
    CHECK(ztl_word_writer_init(&writer,ends,1,2)==ZTL_WORD_OK);
    CHECK(ztl_word_writer_segment(&writer,1,1)==ZTL_WORD_OK);
    CHECK(ztl_word_writer_segment(&writer,2,1)==ZTL_WORD_CAPACITY);
    CHECK(ends[0]==1 && ends[1]==UINT32_C(0xabcdef01));
    count=99;
    CHECK(ztl_word_writer_finish(&writer,&count)==ZTL_WORD_CAPACITY && count==99);
    return 0;
}
static int invalid_streams(void) {
    ZtlWordWriter writer;
    uint32_t ends[4]={0},count=99;
    CHECK(ztl_word_writer_init(NULL,ends,4,3)==ZTL_WORD_INVALID);
    CHECK(ztl_word_writer_init(&writer,NULL,1,0)==ZTL_WORD_INVALID);
    CHECK(ztl_word_writer_init(&writer,ends,4,3)==ZTL_WORD_OK);
    CHECK(ztl_word_writer_segment(&writer,0,0)==ZTL_WORD_INVALID);
    CHECK(ztl_word_writer_segment(&writer,3,1)==ZTL_WORD_INVALID);
    CHECK(ztl_word_writer_finish(&writer,&count)==ZTL_WORD_INVALID && count==99);
    CHECK(ztl_word_writer_init(&writer,ends,4,3)==ZTL_WORD_OK);
    CHECK(ztl_word_writer_segment(&writer,4,0)==ZTL_WORD_INVALID);
    CHECK(ztl_word_writer_init(&writer,ends,4,3)==ZTL_WORD_OK);
    CHECK(ztl_word_writer_segment(&writer,1,2)==ZTL_WORD_INVALID);
    CHECK(ztl_word_writer_init(&writer,ends,4,3)==ZTL_WORD_OK);
    CHECK(ztl_word_writer_segment(&writer,2,1)==ZTL_WORD_OK);
    CHECK(ztl_word_writer_segment(&writer,1,0)==ZTL_WORD_INVALID);
    CHECK(ztl_word_writer_init(&writer,ends,4,3)==ZTL_WORD_OK);
    CHECK(ztl_word_writer_segment(&writer,2,1)==ZTL_WORD_OK);
    CHECK(ztl_word_writer_finish(&writer,&count)==ZTL_WORD_INVALID && count==99);
    CHECK(ztl_word_writer_segment(NULL,1,0)==ZTL_WORD_INVALID);
    CHECK(ztl_word_writer_finish(NULL,&count)==ZTL_WORD_INVALID);
    return 0;
}
static int exhaustive_short_partitions(void) {
    unsigned cases=0;
    for (uint32_t length=1;length<=8;++length) for (unsigned mask=0;mask<(1u<<length);++mask) {
        /* Independent reference: lexical positions are singleton words; a
         * nonword unit is the entire next run of zero bits. */
        uint32_t wanted[8],used=0;
        for (uint32_t i=0;i<length;) {
            if (mask&(1u<<i)) ++i;
            else do { ++i; } while (i<length && !(mask&(1u<<i)));
            wanted[used++]=i;
        }
        for (uint32_t capacity=0;capacity<=length;++capacity) {
            uint32_t ends[9],count=99;
            for (unsigned i=0;i<9;++i) ends[i]=UINT32_C(0xabcdef01);
            ZtlWordWriter writer;
            int result=ztl_word_writer_init(&writer,ends,capacity,length);
            for (uint32_t i=0;i<length && !result;++i) result=ztl_word_writer_segment(&writer,i+1,(mask&(1u<<i))!=0);
            if (capacity<used) {
                CHECK(result==ZTL_WORD_CAPACITY);
                CHECK(ztl_word_writer_finish(&writer,&count)==ZTL_WORD_CAPACITY && count==99);
            } else {
                CHECK(result==ZTL_WORD_OK);
                CHECK(ztl_word_writer_finish(&writer,&count)==ZTL_WORD_OK && count==used);
                CHECK(!memcmp(ends,wanted,used*sizeof(uint32_t)));
            }
            CHECK(ends[capacity]==UINT32_C(0xabcdef01));
            ++cases;
        }
    }
    printf("text word writer exhaustive cases=%u\n",cases);
    return 0;
}
int main(void) {
    if (continuous_nonword()) return 1;
    if (capacity_refusal()) return 1;
    if (empty_and_finish()) return 1;
    if (adjacent_lexical_and_leading()) return 1;
    if (capacity_keeps_coalescing()) return 1;
    if (invalid_streams()) return 1;
    if (exhaustive_short_partitions()) return 1;
    puts("text word writer PASS: 7 groups, lexical/nonword partition, empty/progress/EOF/capacity/failure latch/canaries");
    return 0;
}
