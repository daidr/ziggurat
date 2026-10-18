#ifndef ZIGGURAT_DOCUMENT_ACCESSIBILITY_WORDS_H
#define ZIGGURAT_DOCUMENT_ACCESSIBILITY_WORDS_H
#include <stdint.h>

/* Preparation-only stream. ICU supplies lexical segments; each word owns the
   following punctuation/space up to the next word. A leading nonword run is a
   separate unit. Storage is the Text candidate's scalar-boundary capacity. */
typedef struct ZdaWords {
    uint32_t *positions, capacity, count, length, next;
} ZdaWords;
static int zda_words_init(ZdaWords *words,uint32_t *positions,uint32_t capacity,uint32_t length) {
    if(!positions || !capacity)return 0;
    *words=(ZdaWords){positions,capacity,1,length,0};positions[0]=0;return 1;
}
static int zda_words_segment(ZdaWords *words,uint32_t end,int lexical) {
    if(end<=words->next || end>words->length)return 0;
    if(lexical && words->next!=words->positions[words->count-1]) {
        if(words->count==words->capacity)return 0;
        words->positions[words->count++]=words->next;
    }
    words->next=end;return 1;
}
static int zda_words_finish(ZdaWords *words) {
    if(words->next!=words->length)return 0;
    if(words->positions[words->count-1]!=words->length) {
        if(words->count==words->capacity)return 0;
        words->positions[words->count++]=words->length;
    }
    return 1;
}
#endif
