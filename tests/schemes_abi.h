static int scheme_abi_cases(void) {
    LONG before=live_handlers;int failed=0;
    const WCHAR *origins[]={L"asset://fixture",L"https://example.test"};
    WCHAR name[]=L"asset";
    SchemeInput input={name,TRUE,origins,2};
    ICoreWebView2EnvironmentOptions *options=NULL;
    if (FAILED(scheme_options_new(NULL,0,NULL,&options))||options||live_handlers!=before) return 1;
    if (FAILED(scheme_options_new(&input,1,NULL,&options))||!options) return 1;
    {
        /* Browser arguments alone still make options, and only they report them. */
        ICoreWebView2EnvironmentOptions *arguments=NULL;WCHAR *text=NULL;
        if (FAILED(scheme_options_new(NULL,0,L"--autoplay-policy=no-user-gesture-required",&arguments))||!arguments) return 1;
        if (FAILED(ICoreWebView2EnvironmentOptions_get_AdditionalBrowserArguments(arguments,&text))||!text||wcscmp(text,L"--autoplay-policy=no-user-gesture-required")) failed++;
        CoTaskMemFree(text);text=NULL;
        if (FAILED(ICoreWebView2EnvironmentOptions_get_AdditionalBrowserArguments(options,&text))||text) failed++;
        CoTaskMemFree(text);
        ICoreWebView2EnvironmentOptions_Release(arguments);
    }
    NativeHeader own_origin[]={ {L"Origin",L"asset://fixture"} }, foreign[]={ {L"Origin",L"asset://other"} }, opaque[]={ {L"Origin",L"null"} }, repeated[]={ {L"Origin",L"asset://fixture"},{L"origin",L"asset://fixture"} };
    if (!scheme_request_origin_allowed(options,L"asset://fixture/",0,NULL,0)||scheme_request_origin_allowed(options,L"asset://fixture/",2,NULL,0)||!scheme_request_origin_allowed(options,L"asset://fixture/",2,own_origin,1)||scheme_request_origin_allowed(options,L"asset://fixture/",0,foreign,1)||scheme_request_origin_allowed(options,L"asset://fixture/",0,opaque,1)||scheme_request_origin_allowed(options,L"asset://fixture/",0,repeated,2)||scheme_request_origin_allowed(options,L"unknown://fixture/",2,own_origin,1)) failed++;
    const WCHAR *nonexact[]={L"ASSET://fixture",L"asset://FIXTURE",L"asset://fixture/",L" asset://fixture",L"asset://fixture ",L"asset://fixture:123",L"asset://user@fixture"};
    for (size_t i=0;i<sizeof(nonexact)/sizeof(*nonexact);i++) { NativeHeader header={L"Origin",(WCHAR *)nonexact[i]};if (scheme_request_origin_allowed(options,L"asset://fixture/",2,&header,1)) failed++; }
    for (int method=2;method<=6;method++) if (scheme_request_origin_allowed(options,L"asset://fixture/",method,NULL,0)) failed++;
    name[0]=L'x';
    WCHAR *version=NULL;
    if (FAILED(ICoreWebView2EnvironmentOptions_get_TargetCompatibleBrowserVersion(options,&version))||!version||wcscmp(version,L"154.0.4258.31")) failed++;
    CoTaskMemFree(version);
    ICoreWebView2EnvironmentOptions4 *extended=NULL;
    HRESULT hr=ICoreWebView2EnvironmentOptions_QueryInterface(options,&IID_ICoreWebView2EnvironmentOptions4,(void **)&extended);
    if (FAILED(hr)||!extended) { ICoreWebView2EnvironmentOptions_Release(options);return 1; }
    IUnknown *identity=NULL;
    if (FAILED(ICoreWebView2EnvironmentOptions4_QueryInterface(extended,&IID_IUnknown,(void **)&identity))||(void *)identity!=(void *)options) failed++;
    if (identity) ICoreWebView2EnvironmentOptions_Release((ICoreWebView2EnvironmentOptions *)identity);
    ICoreWebView2CustomSchemeRegistration **items=NULL;UINT32 count=0;
    hr=ICoreWebView2EnvironmentOptions4_GetCustomSchemeRegistrations(extended,&count,&items);
    ICoreWebView2EnvironmentOptions_Release(options);ICoreWebView2EnvironmentOptions4_Release(extended);
    if (FAILED(hr)||count!=1||!items) return failed+1;
    /* Options have died. A returned registration and every returned string are
       independent; releasing those refs cannot reach the original Zig metadata. */
    WCHAR *copied=NULL;BOOL value=FALSE;UINT32 origin_count=0;WCHAR **copied_origins=NULL;
    if (FAILED(ICoreWebView2CustomSchemeRegistration_get_SchemeName(items[0],&copied))||!copied||wcscmp(copied,L"asset")) failed++;
    CoTaskMemFree(copied);
    if (FAILED(ICoreWebView2CustomSchemeRegistration_get_TreatAsSecure(items[0],&value))||!value) failed++;
    value=FALSE;if (FAILED(ICoreWebView2CustomSchemeRegistration_get_HasAuthorityComponent(items[0],&value))||!value) failed++;
    hr=ICoreWebView2CustomSchemeRegistration_GetAllowedOrigins(items[0],&origin_count,&copied_origins);
    if (FAILED(hr)||origin_count!=2||!copied_origins||wcscmp(copied_origins[0],origins[0])||wcscmp(copied_origins[1],origins[1])) failed++;
    if (ICoreWebView2CustomSchemeRegistration_put_TreatAsSecure(items[0],FALSE)!=E_ACCESSDENIED||ICoreWebView2CustomSchemeRegistration_put_HasAuthorityComponent(items[0],FALSE)!=E_ACCESSDENIED||ICoreWebView2CustomSchemeRegistration_SetAllowedOrigins(items[0],0,NULL)!=E_ACCESSDENIED) failed++;
    ICoreWebView2CustomSchemeRegistration_Release(items[0]);CoTaskMemFree(items);
    for (UINT32 i=0;i<origin_count;i++) CoTaskMemFree(copied_origins[i]);CoTaskMemFree(copied_origins);
    if (live_handlers!=before) failed++;
    input.name=L"https";if (scheme_options_new(&input,1,NULL,&options)!=E_INVALIDARG||options||live_handlers!=before) failed++;
    const WCHAR *pattern[]={L"https://*.example.test"};input.name=L"asset";input.origins=pattern;input.origin_count=1;
    if (scheme_options_new(&input,1,NULL,&options)!=E_INVALIDARG||options||live_handlers!=before) failed++;
    const struct { const WCHAR *uri;BOOL allowed; } cases[]={
        {L"asset://fixture/",TRUE},{L"asset://fixture/file?q=1#fragment",TRUE},
        {L"asset://other/",FALSE},{L"asset://fixture.evil/",FALSE},{L"asset://fixture:80/",FALSE},
        {L"asset://@fixture/",FALSE},{L"asset://user@fixture/",FALSE},{L"asset://%66ixture/",FALSE},
        {L"asset://fixture./",FALSE},{L"asset:///file",FALSE},{L"asset:path",FALSE},
        {L"asset://fixture\\file",FALSE},{L"asset2://fixture/",FALSE},{L"https://fixture/",FALSE}
    };
    for (size_t i=0;i<sizeof(cases)/sizeof(*cases);i++) if (scheme_uri_matches(cases[i].uri,L"asset://fixture/")!=cases[i].allowed) { failed++;fprintf(stderr,"custom scheme authority case %zu\n",i); }
    for (int enabled=0;enabled<2;enabled++) {
        UriProbe probe={0};State *s=uri_state(&probe,FALSE);if (!s) return failed+1;
        free(s->local_prefix);free(s->document_source);
        s->local_prefix=_wcsdup(L"asset://fixture/");s->document_source=_wcsdup(L"asset://fixture/");s->custom_site=TRUE;s->local_ipc=enabled;
        if (!s->local_prefix||!s->document_source) { release(s);return failed+1; }
        ProbeSender sender={{&sender_vtable},L"asset://fixture/"};ProbeMessage args={{&message_vtable},L"asset://fixture/",&probe};MessageHandler handler={0};handler.state=s;
        message_invoke(&handler.iface,&sender.iface,&args.iface);
        if (probe.messages!=(unsigned)enabled||probe.reads!=(unsigned)enabled) failed++;
        NetOrigin origin;if (cookie_origin(s,L"asset://fixture/",&origin)!=E_ACCESSDENIED||cookie_origin(s,L"https://fixture/",&origin)!=E_ACCESSDENIED) failed++;
        if (remote_grants(&s->remote,L"asset://fixture/")) failed++;
        release(s);
    }
    if (failed) fprintf(stderr,"scheme COM/authority/IPC ABI failures=%d\n",failed);
    return failed;
}
