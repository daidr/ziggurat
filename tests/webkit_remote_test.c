#include "../src/webview/webkit_native.h"
#include "../src/webview/webkit_remote_impl.h"
#include <stdio.h>
#define CHECK(value) do{if(!(value)){fprintf(stderr,"remote config line %u: %s\n",__LINE__,#value);return 1;}}while(0)
_Static_assert(sizeof(ZwkRemoteHeader)==16,"remote header ABI");
_Static_assert(sizeof(ZwkRemoteOrigin)==40,"remote origin ABI");
_Static_assert(sizeof(ZwkRemoteOptions)==48,"remote options ABI");
int main(void){
    char initial[]="https://example.test/start",header_value[]="application/json";
    ZwkRemoteHeader headers[]={{"Content-Type",header_value},{"X-Empty",""},{"X-Any",NULL}};
    ZwkRemoteOrigin origins[]={
        {"https://example.test",7u,3u,headers,3,NULL},
        {"https://navigation.test",1u,0u,NULL,0,NULL}
    };
    ZwkRemoteOptions input={initial,"/app/policy",origins,2,5000,0,0,0};
    RemoteData *data=NULL;
    CHECK(remote_create(&input,&data)==ZWK_OK&&data&&data->id);
    memset(initial,'x',sizeof(initial)-1);memset(header_value,'y',sizeof(header_value)-1);
    CHECK(!strcmp(data->url,"https://example.test/start"));
    CHECK(remote_navigate(data,"HTTPS://EXAMPLE.test:443/other"));
    CHECK(!remote_navigate(data,"https://navigation.test/other"));
    CHECK(remote_grants(data,"https://example.test")==7u);
    CHECK(remote_same_uri(data,"HTTPS://EXAMPLE.test:443","https://example.test/"));
    CHECK(!remote_same_uri(data,"https://example.test/?a=%26b","https://example.test/?a=&b"));
    CHECK(!remote_same_uri(data,"https://example.test/a","https://example.test/b"));
    CHECK(remote_fragment_change(data,"https://example.test/a#first","https://example.test/a#next"));
    CHECK(!remote_fragment_change(data,"https://example.test/a?q=1#first","https://example.test/a?q=2#next"));
    CHECK(strstr(data->csp,"worker-src 'none'")&&strstr(data->csp,"frame-src 'none'")&&strstr(data->csp,"form-action 'none'"));
    CHECK(!strstr(data->csp,"ws:")&&!strstr(data->csp,"wss:")&&!strstr(data->csp,"navigation.test"));
    CHECK(!strcmp(data->ipc_json,"['https://example.test']"));
    SoupMessageHeaders *request=soup_message_headers_new(SOUP_MESSAGE_HEADERS_REQUEST);
    soup_message_headers_append(request,"Content-Type","application/json");
    CHECK(zwk_request_policy_check(data->requests,"https://example.test/api","GET",request)==ZWK_REQUEST_ALLOW);
    CHECK(zwk_request_policy_check(data->requests,"https://navigation.test/api","GET",request)==ZWK_REQUEST_ORIGIN);
    soup_message_headers_unref(request);remote_free(data);
    input.url="https://example.test/start";headers[0].value="application/json";
    input.directory="relative";data=(RemoteData *)1;CHECK(remote_create(&input,&data)==ZWK_INVALID&&!data);
    input.directory="/app/policy";input.timeout_ms=0;CHECK(remote_create(&input,&data)==ZWK_INVALID&&!data);
    input.timeout_ms=5000;origins[0].flags=1;CHECK(remote_create(&input,&data)==ZWK_INVALID&&!data);
    origins[0].flags=7;origins[1].origin="HTTPS://EXAMPLE.test:443/";CHECK(remote_create(&input,&data)==ZWK_INVALID&&!data);
    origins[1].origin="https://navigation.test";headers[0].name="Cookie";CHECK(remote_create(&input,&data)==ZWK_INVALID&&!data);
    headers[0].name="Content-Type";input.count=33;CHECK(remote_create(&input,&data)==ZWK_INVALID&&!data);
    puts("Remote native config: owned immutable policy, separate navigation/request/IPC, fixed bounded CSP, invalid candidates rejected");
    return 0;
}
