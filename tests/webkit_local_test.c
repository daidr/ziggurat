#include <webkit2/webkit2.h>
static gboolean fail_copy;
static gboolean fail_budget;
static unsigned copy_calls;
static gpointer try_copy_allocation(gsize size) { ++copy_calls; return fail_copy?NULL:g_try_malloc(size); }
static gpointer try_budget_allocation(gsize count,gsize size) { return fail_budget?NULL:g_try_malloc0_n(count,size); }
#define g_try_malloc try_copy_allocation
#undef g_try_new0
#define g_try_new0(type,count) ((type *)try_budget_allocation((count),sizeof(type)))
#include "../src/webview/webkit_local_impl.h"
#undef g_try_malloc
#undef g_try_new0
#include <stdio.h>

#define CHECK(value) do { if (!(value)) { fprintf(stderr,"local policy line %u: %s\n",__LINE__,#value); return 1; } } while (0)
static int request_policy(void) {
    ZwkLocalBudget *budget=zwk_local_budget_new(8,32*1024*1024); CHECK(budget);
    char name[]="X-Explicit",value[]="allowed",origin[]="asset://app.ziggurat.invalid";
    ZwkLocalHeaderGrant rows[]={{name,value},{"X-Any",NULL},{"X-Empty",""}};
    const char *origins[]={origin};
    ZwkLocalPolicy policy={.methods=127,.headers=rows,.header_count=3,.origins=origins,.origin_count=1};
    ZwkLocalOptions options={.scheme="asset",.host="app.ziggurat.invalid",.start_path="/document",.max_response_bytes=1024,.budget=budget,.ipc=1,.policy=&policy};
    LocalData local={0}; CHECK(local_prepare(&local,&options));
    CHECK(local.count==0 && local_policy(&local) && local_ipc(&local));
    size_t policy_bytes=0; CHECK(local_policy_size("asset",&policy,&policy_bytes));
    printf("custom policy sizes: LocalData=%zu LocalOptions=%zu Policy=%zu Grant=%zu captured_policy=%zu; default policy prefix=0\n",sizeof(LocalData),sizeof(ZwkLocalOptions),sizeof(ZwkLocalPolicy),sizeof(ZwkLocalHeaderGrant),policy_bytes);
    name[0]='?'; value[0]='?'; origin[0]='?';
    CHECK(!strcmp(local_policy(&local)->headers[0].name,"X-Explicit") && !strcmp(local_policy(&local)->headers[0].value,"allowed") && !strcmp(local_policy(&local)->origins[0],"asset://app.ziggurat.invalid"));
    SoupMessageHeaders *headers=soup_message_headers_new(SOUP_MESSAGE_HEADERS_REQUEST);
    soup_message_headers_append(headers,"Accept","*/*");
    soup_message_headers_append(headers,"x-explicit","allowed");
    CHECK(local_request_allowed(&local,"GET",headers) && local_request_allowed(&local,"HEAD",headers));
    CHECK(!local_request_allowed(&local,"POST",headers) && !local_request_allowed(&local,"TRACE",headers) && !local_request_allowed(&local,"get",headers) && !local_request_allowed(&local,NULL,headers));
    soup_message_headers_append(headers,"Origin","asset://app.ziggurat.invalid");
    const char *methods[]={"GET","HEAD","POST","PUT","PATCH","DELETE","OPTIONS"};
    for(unsigned i=0;i<G_N_ELEMENTS(methods);++i) CHECK(local_request_allowed(&local,methods[i],headers));
    soup_message_headers_append(headers,"Origin","asset://app.ziggurat.invalid"); CHECK(!local_request_allowed(&local,"POST",headers));
    soup_message_headers_replace(headers,"Origin","null"); CHECK(!local_request_allowed(&local,"GET",headers));
    soup_message_headers_replace(headers,"Origin","asset://other.ziggurat.invalid"); CHECK(!local_request_allowed(&local,"POST",headers));
    soup_message_headers_replace(headers,"Origin","asset://app.ziggurat.invalid");
    soup_message_headers_replace(headers,"X-Explicit","wrong"); CHECK(!local_request_allowed(&local,"GET",headers));
    soup_message_headers_replace(headers,"X-Explicit","allowed");
    soup_message_headers_append(headers,"X-Any",""); soup_message_headers_append(headers,"X-Empty",""); CHECK(local_request_allowed(&local,"POST",headers));
    soup_message_headers_replace(headers,"X-Any","anything"); CHECK(local_request_allowed(&local,"POST",headers));
    soup_message_headers_replace(headers,"X-Empty","not-empty"); CHECK(!local_request_allowed(&local,"POST",headers));
    soup_message_headers_remove(headers,"X-Empty");
    soup_message_headers_append(headers,"Content-Type","text/plain"); CHECK(!local_request_allowed(&local,"POST",headers));
    soup_message_headers_remove(headers,"Content-Type");
    soup_message_headers_append(headers,"Unlisted","bad"); CHECK(!local_request_allowed(&local,"GET",headers));
    soup_message_headers_clear(headers);
    for (unsigned i=0;i<64;++i) { char key[32]; g_snprintf(key,sizeof(key),"Sec-Field-%u",i); soup_message_headers_append(headers,key,""); }
    CHECK(local_request_allowed(&local,"GET",headers));
    soup_message_headers_append(headers,"Sec-Overflow",""); CHECK(!local_request_allowed(&local,"GET",headers));
    soup_message_headers_clear(headers); char large[2050]; memset(large,'a',sizeof(large)); large[2048]=0;
    for (unsigned i=0;i<8;++i) { char key[32]; g_snprintf(key,sizeof(key),"Sec-Field-%u",i); soup_message_headers_append(headers,key,large); }
    CHECK(!local_request_allowed(&local,"GET",headers));
    soup_message_headers_clear(headers); soup_message_headers_append(headers,"Sec-Field",large); CHECK(local_request_allowed(&local,"GET",headers));
    large[2048]='a'; large[2049]=0; soup_message_headers_replace(headers,"Sec-Field",large); CHECK(!local_request_allowed(&local,"GET",headers));
    soup_message_headers_unref(headers); local_finish(&local);
    /* Independent native input validation; no allocation/ref transfer on
       malformed configuration, including an empty-resource policy prefix. */
    name[0]='X'; value[0]='a'; origin[0]='a';
    const ZwkLocalHeaderGrant reserved_grant[]={{"Origin",NULL}};
    const char *invalid_origins[]={"null"};
    for (unsigned scenario=0;scenario<9;++scenario) {
        ZwkLocalPolicy invalid=policy;
        switch(scenario) {
        case 0: invalid.methods=0; break;
        case 1: invalid.methods=128; break;
        case 2: invalid.reserved=1; break;
        case 3: invalid.header_count=17; break;
        case 4: invalid.origin_count=9; break;
        case 5: invalid.headers=NULL; break;
        case 6: invalid.origins=NULL; break;
        case 7: invalid.headers=reserved_grant; invalid.header_count=1; break;
        default: invalid.origins=invalid_origins; invalid.origin_count=1; break;
        }
        unsigned before=copy_calls;
        options.policy=&invalid; local=(LocalData){0}; CHECK(!local_prepare(&local,&options) && !local.storage && !local.budget && copy_calls==before); local_finish(&local);
    }
    const char *accepted[]={"asset://app.ziggurat.invalid","https://example.test","http://127.0.0.1:54321","https://[::ffff:7f00:1]","https://[2001:db8::1]"};
    for (unsigned i=0;i<G_N_ELEMENTS(accepted);++i) CHECK(local_origin("asset",accepted[i]));
    const char *denied[]={"*","null","asset://app.ziggurat.invalid/","asset://app.ziggurat.invalid:1","https://example.test:443","https://EXAMPLE.test","https://user@example.test","https://example.test/path","other://host","https://[::ffff:127.0.0.1]","http://127.1"};
    for (unsigned i=0;i<G_N_ELEMENTS(denied);++i) CHECK(!local_origin("asset",denied[i]));
    options.policy=&policy; local=(LocalData){0}; fail_copy=TRUE;
    CHECK(!local_prepare(&local,&options) && !local.storage && !local.budget); fail_copy=FALSE; local_finish(&local);
    options.policy=NULL; local=(LocalData){0}; CHECK(local_prepare(&local,&options) && !local_policy(&local));
    CHECK((char *)local.resources==local.storage && local_ipc(&local));
    headers=soup_message_headers_new(SOUP_MESSAGE_HEADERS_REQUEST);
    CHECK(local_request_allowed(&local,"GET",headers) && local_request_allowed(&local,"HEAD",headers) && !local_request_allowed(&local,"POST",headers));
    soup_message_headers_append(headers,"Origin","asset://app.ziggurat.invalid"); CHECK(!local_request_allowed(&local,"GET",headers));
    soup_message_headers_unref(headers); local_finish(&local); zwk_local_budget_release(budget);
    puts("custom request policy: seven methods, observed headers, exact Origin, default gate, capture/OOM and empty-resource prefix passed");
    return 0;
}
int main(void) {
    CHECK(request_policy()==0);
    char path[4097];
    CHECK(local_uri("asset","app.ziggurat.invalid","asset://app.ziggurat.invalid/document?a=b#part",path));
    CHECK(!strcmp(path,"/document"));
    const char *denied[]={"asset://other.ziggurat.invalid/document","other://app.ziggurat.invalid/document","asset://user@app.ziggurat.invalid/document","asset://app.ziggurat.invalid:1/document","asset://app.ziggurat.invalid/%2fdocument","asset://app.ziggurat.invalid/a/../document","asset://app.ziggurat.invalid/./document","asset://app.ziggurat.invalid/%2e%2e/document","asset://app.ziggurat.invalid/%00document","asset://app.ziggurat.invalid\\other/document","file:///document","asset://%61pp.ziggurat.invalid/document"};
    for (size_t i=0;i<G_N_ELEMENTS(denied);++i) {
        if (local_uri("asset","app.ziggurat.invalid",denied[i],path)) { fprintf(stderr,"unexpected URI: %s\n",denied[i]); return 1; }
    }
    fail_budget=TRUE;
    CHECK(!zwk_local_budget_new(2,32));
    fail_budget=FALSE;
    uint32_t budgets,streams,bytes; zwk_local_counts(&budgets,&streams,&bytes);
    CHECK(!budgets && !streams && !bytes);
    ZwkLocalBudget *budget=zwk_local_budget_new(2,32);
    CHECK(budget);
    fail_copy=TRUE;
    CHECK(!local_stream(budget,"retained",8));
    fail_copy=FALSE;
    char input[]="retained";
    GInputStream *first=local_stream(budget,input,sizeof(input)-1),*second=local_stream(budget,NULL,0);
    CHECK(first && second && !local_stream(budget,NULL,0));
    zwk_local_counts(&budgets,&streams,&bytes);
    CHECK(budgets==1 && streams==2 && bytes==8);
    memset(input,'?',sizeof(input)-1);
    zwk_local_budget_limit(budget,1,1);
    CHECK(!local_stream(budget,NULL,0));
    g_object_unref(second);
    CHECK(!local_stream(budget,NULL,0));
    zwk_local_budget_release(budget);
    char output[8]; gsize count=0;
    CHECK(g_input_stream_read_all(first,output,sizeof(output),&count,NULL,NULL) && count==8 && !memcmp(output,"retained",8));
    CHECK(g_input_stream_read(first,output,sizeof(output),NULL,NULL)==0);
    CHECK(g_input_stream_close(first,NULL,NULL));
    zwk_local_counts(&budgets,&streams,&bytes);
    CHECK(budgets==1 && streams==1 && bytes==8);
    g_object_unref(first);
    zwk_local_counts(&budgets,&streams,&bytes); CHECK(!budgets && !streams && !bytes);
    budget=zwk_local_budget_new(8,32*1024*1024); CHECK(budget);
    ZwkLocalResource resource={.path="/value",.path_length=6,.mime="text/plain",.mime_length=10,.bytes=(const uint8_t *)"value",.length=5};
    ZwkLocalOptions options={.scheme="asset",.host="app.ziggurat.invalid",.start_path="/document",.resources=&resource,.count=1,.max_response_bytes=1024,.budget=budget,.ipc=1};
    LocalData local={0}; CHECK(local_prepare(&local,&options));
    CHECK(!strcmp(local.url,"asset://app.ziggurat.invalid/document") && local.count==1 && !strcmp(local.resources[0].mime,"text/plain"));
    CHECK(strstr(local.csp,"connect-src asset://app.ziggurat.invalid;") && strstr(local.csp,"worker-src 'none'"));
    local_clear(&local); local_finish(&local); zwk_local_budget_release(budget);
    zwk_local_counts(&budgets,&streams,&bytes); CHECK(!budgets && !streams && !bytes);
    budget=zwk_local_budget_new(8,32*1024*1024); CHECK(budget);
    options.budget=budget; local=(LocalData){0}; fail_copy=TRUE;
    CHECK(!local_prepare(&local,&options)); local_finish(&local); fail_copy=FALSE;
    GInputStream *held[32]; ZwkLocalBudget *owners[5];
    for (unsigned i=0;i<5;++i) { owners[i]=i?zwk_local_budget_new(8,32*1024*1024):budget; CHECK(owners[i]); }
    for (unsigned i=0;i<32;++i) { held[i]=local_stream(owners[i/8],NULL,0); CHECK(held[i]); }
    CHECK(!local_stream(owners[4],NULL,0));
    for (unsigned i=0;i<5;++i) zwk_local_budget_release(owners[i]);
    zwk_local_counts(&budgets,&streams,&bytes); CHECK(budgets==4 && streams==32 && !bytes);
    for (unsigned i=0;i<32;++i) g_object_unref(held[i]);
    zwk_local_counts(&budgets,&streams,&bytes); CHECK(!budgets && !streams && !bytes);
    puts("custom local policy: parsed authority/routes, copied metadata, late memory stream bytes/physical slots=0");
    return 0;
}
