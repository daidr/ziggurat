#include <stdint.h>
#include <stdio.h>
#include <string.h>
#include <unicode/ubrk.h>
#include "../src/document_accessibility/native_words.h"
#define CHECK(value) do { if(!(value)){fprintf(stderr,"word oracle line %d\n",__LINE__);return 1;} } while(0)

static int check(const UChar *source,int32_t length,const uint32_t *expected,uint32_t count) {
    UErrorCode error=U_ZERO_ERROR;
    UBreakIterator *iterator=ubrk_open(UBRK_WORD,"root",source,length,&error);
    CHECK(iterator && U_SUCCESS(error));
    uint32_t positions[128];ZdaWords words;
    CHECK(zda_words_init(&words,positions,128,(uint32_t)length));
    CHECK(ubrk_first(iterator)==0);
    for(int32_t at=ubrk_next(iterator);at!=UBRK_DONE;at=ubrk_next(iterator))
        CHECK(zda_words_segment(&words,(uint32_t)at,ubrk_getRuleStatus(iterator)>=UBRK_WORD_NUMBER));
    ubrk_close(iterator);
    CHECK(zda_words_finish(&words));
    if(words.count!=count || memcmp(positions,expected,count*sizeof(*positions))) {
        fprintf(stderr,"word oracle expected:");for(uint32_t i=0;i<count;++i)fprintf(stderr," %u",expected[i]);
        fprintf(stderr," actual:");for(uint32_t i=0;i<words.count;++i)fprintf(stderr," %u",positions[i]);
        fputc('\n',stderr);return 1;
    }
    /* Independent grapheme iterator: no emitted word boundary splits one. */
    error=U_ZERO_ERROR;iterator=ubrk_open(UBRK_CHARACTER,"root",source,length,&error);
    CHECK(iterator && U_SUCCESS(error));
    for(uint32_t i=0;i<count;++i)CHECK(ubrk_isBoundary(iterator,(int32_t)positions[i]));
    ubrk_close(iterator);return 0;
}
int main(void) {
    static const UChar english[]={ 'h','e','l','l','o',',',' ',' ','w','o','r','l','d','!','\r','\n' };
    static const UChar leading[]={ ' ','\t','a','b','c',',',' ','d','e','f',' ' };
    static const UChar cjk[]={0x4e2d,0x6587,0x6d4b,0x8bd5};
    static const UChar thai[]={0x0e20,0x0e32,0x0e29,0x0e32,0x0e44,0x0e17,0x0e22};
    static const UChar combined[]={ 'e',0x301,' ',0xd83d,0xde00,' ','x' };
    static const UChar emoji[]={0xd83d,0xdc69,0x200d,0xd83d,0xdcbb,' ','x'};
    static const UChar punctuation[]={'.','!',' ','\t','\n'};
    static const UChar empty[]={0};
    CHECK(!check(english,16,(const uint32_t[]){0,8,16},3));
    CHECK(!check(leading,11,(const uint32_t[]){0,2,7,11},4));
    CHECK(!check(cjk,4,(const uint32_t[]){0,2,4},3));
    CHECK(!check(thai,7,(const uint32_t[]){0,4,7},3));
    CHECK(!check(combined,7,(const uint32_t[]){0,6,7},3));
    CHECK(!check(emoji,7,(const uint32_t[]){0,6,7},3));
    CHECK(!check(punctuation,5,(const uint32_t[]){0,5},2));
    CHECK(!check(empty,0,(const uint32_t[]){0},1));
    uint32_t small[2]={99,99};ZdaWords bounded;
    CHECK(!zda_words_init(&bounded,small,0,2));
    CHECK(zda_words_init(&bounded,small,2,2));
    CHECK(!zda_words_segment(&bounded,0,1) && !zda_words_segment(&bounded,3,1));
    CHECK(zda_words_segment(&bounded,1,1) && zda_words_segment(&bounded,2,1));
    CHECK(!zda_words_finish(&bounded));
    puts("document words: 8 independent ICU/golden corpora, trailing/leading breaks, CJK/Thai, grapheme/surrogate/ZWJ and bounded rollback");
    return 0;
}
