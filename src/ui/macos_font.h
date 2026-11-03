#ifndef ZIGGURAT_MACOS_FONT_H
#define ZIGGURAT_MACOS_FONT_H
/* Core Text fonts for the text command, shared by the Core Graphics and
   Metal renderers so both lay text out with the same fonts. */
#include <CoreText/CoreText.h>
#include <math.h>
#include <string.h>
/* CSS-style weights to Core Text weight traits. */
static inline double weight_trait(uint16_t weight){
    static const double traits[9]={-0.8,-0.6,-0.4,0,0.23,0.3,0.4,0.56,0.62};
    int index=(int)lround((double)weight/100)-1;if(index<0)index=0;if(index>8)index=8;return traits[index];
}
static inline CTFontRef create_font(const char *named,float size,uint16_t weight,int italic,int monospace){
    if(named&&(!strcmp(named,"Serif")||!strcmp(named,"serif")||!strcmp(named,"ui-serif")))named="Times New Roman";
    int system=!named||!named[0]||!strcmp(named,"Sans")||!strcmp(named,"sans-serif")||!strcmp(named,"system-ui");
    int fixed=monospace&&(!named||!named[0]||!strcmp(named,"Monospace")||!strcmp(named,"monospace"));
    if(named&&(!strcmp(named,"Monospace")||!strcmp(named,"monospace")||!strcmp(named,"ui-monospace"))){system=1;fixed=1;}
    CFMutableDictionaryRef attributes=CFDictionaryCreateMutable(NULL,0,&kCFTypeDictionaryKeyCallBacks,&kCFTypeDictionaryValueCallBacks);
    CFMutableDictionaryRef traits=CFDictionaryCreateMutable(NULL,0,&kCFTypeDictionaryKeyCallBacks,&kCFTypeDictionaryValueCallBacks);
    if(!attributes||!traits){if(attributes)CFRelease(attributes);if(traits)CFRelease(traits);return NULL;}
    double trait=weight_trait(weight);CFNumberRef weight_number=CFNumberCreate(NULL,kCFNumberDoubleType,&trait);
    uint32_t symbolic=italic?kCTFontItalicTrait:0;CFNumberRef symbolic_number=CFNumberCreate(NULL,kCFNumberSInt32Type,&symbolic);
    if(weight_number){CFDictionarySetValue(traits,kCTFontWeightTrait,weight_number);CFRelease(weight_number);}
    if(symbolic_number){CFDictionarySetValue(traits,kCTFontSymbolicTrait,symbolic_number);CFRelease(symbolic_number);}
    CFDictionarySetValue(attributes,kCTFontTraitsAttribute,traits);CFRelease(traits);
    CTFontDescriptorRef descriptor=NULL;
    if(system){
        CTFontRef base=CTFontCreateUIFontForLanguage(fixed||monospace?kCTFontUIFontUserFixedPitch:kCTFontUIFontSystem,size,NULL);
        if(base){CTFontDescriptorRef from=CTFontCopyFontDescriptor(base);CFRelease(base);if(from){descriptor=CTFontDescriptorCreateCopyWithAttributes(from,attributes);CFRelease(from);}}
    }else{
        CFStringRef family=CFStringCreateWithCString(NULL,named,kCFStringEncodingUTF8);
        if(family){CFDictionarySetValue(attributes,kCTFontFamilyNameAttribute,family);CFRelease(family);descriptor=CTFontDescriptorCreateWithAttributes(attributes);}
    }
    CFRelease(attributes);if(!descriptor)return NULL;
    CTFontRef font=CTFontCreateWithFontDescriptor(descriptor,size,NULL);CFRelease(descriptor);return font;
}
/* The line a text command draws: its UTF-8 text in font, truncated with
   an ellipsis to width. NULL with *failed clear draws nothing. */
static inline CTLineRef text_line(CTFontRef font,const char *text,uint32_t length,double width,CGFloat *ascent,CGFloat *descent,int *failed){
    *failed=1;
    CFStringRef string=CFStringCreateWithBytes(NULL,(const UInt8 *)text,length,kCFStringEncodingUTF8,false);if(!string)return NULL;
    const void *keys[2]={kCTFontAttributeName,kCTForegroundColorFromContextAttributeName};const void *values[2]={font,kCFBooleanTrue};
    CFDictionaryRef attributes=CFDictionaryCreate(NULL,keys,values,2,&kCFTypeDictionaryKeyCallBacks,&kCFTypeDictionaryValueCallBacks);
    CFAttributedStringRef attributed=attributes?CFAttributedStringCreate(NULL,string,attributes):NULL;CFRelease(string);
    CTLineRef line=attributed?CTLineCreateWithAttributedString(attributed):NULL;if(attributed)CFRelease(attributed);
    if(!line){if(attributes)CFRelease(attributes);return NULL;}
    CGFloat leading=0;double advance=CTLineGetTypographicBounds(line,ascent,descent,&leading);
    if(advance>width){
        CFAttributedStringRef ellipsis=CFAttributedStringCreate(NULL,CFSTR("…"),attributes);
        CTLineRef token=ellipsis?CTLineCreateWithAttributedString(ellipsis):NULL;if(ellipsis)CFRelease(ellipsis);
        CTLineRef truncated=token?CTLineCreateTruncatedLine(line,width,kCTLineTruncationEnd,token):NULL;if(token)CFRelease(token);
        CFRelease(line);line=truncated;
    }
    CFRelease(attributes);*failed=0;return line;
}
#endif
