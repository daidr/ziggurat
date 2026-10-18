/* Explicit test-driver threads, no App/Window, no COM or message loop. Events
   model controlled process lifetimes for table interleavings. One separate
   group uses an actual child process HANDLE; neither proves browser behavior. */
#include "../src/webview/windows_profile_lifetime.h"
#include <stdio.h>
#include <wchar.h>

#define CHECK(x) do { if (!(x)) { fprintf(stderr,"profile lifetime:%d: %s\n",__LINE__,#x);return 0; } } while (0)
typedef struct TestDriver {
    HANDLE lock,ready,start,round,thread;
    ZwpwLifetime *value;
    DWORD main;
    int create_result,result,first_result,authority_result,tiny_result;
    uint32_t error;
    BOOL split;
    LONG held_retirement;
} TestDriver;
static TestDriver *current_driver;
void zwpw_test_lifetime_retired(ZwpwLifetime *value) {
    TestDriver *t=current_driver;
    if (t&&t->value==value&&t->split&&InterlockedCompareExchange(&t->held_retirement,1,0)==0) {
        SetEvent(t->round);
        WaitForSingleObject(t->start,INFINITE);
    }
}
static DWORD WINAPI driver_thread(void *input) {
    TestDriver *t=input;
    ZwpwLifetime *tiny=(ZwpwLifetime *)(uintptr_t)8;
    t->tiny_result=zwpw_lifetime_create(t->main,zwpw_lifetime_size()-1,t->lock,&tiny,&t->error);
    if (tiny||t->error) { t->create_result=ZWPW_INVALID;SetEvent(t->ready);return 1; }
    t->create_result=zwpw_lifetime_create(t->main,zwpw_lifetime_size(),t->lock,&t->value,&t->error);
    if (t->create_result==ZWPW_OK) zwpw_lifetime_ref(t->value); /* main's own pin */
    SetEvent(t->ready);
    if (t->create_result!=ZWPW_OK) return 0;
    WaitForSingleObject(t->start,INFINITE);
    /* A wrong-thread authority attempt cannot seal, publish or withdraw. */
    HANDLE probe=CreateEventW(NULL,TRUE,TRUE,NULL);
    HANDLE saved=probe;uint64_t token=99;
    t->authority_result=zwpw_lifetime_admit(t->value)==ZWPW_WRONG_THREAD&&
        zwpw_lifetime_check_main(t->value)==ZWPW_WRONG_THREAD&&
        zwpw_lifetime_withdraw(t->value)==ZWPW_WRONG_THREAD&&
        zwpw_lifetime_seal(t->value)==ZWPW_WRONG_THREAD&&
        zwpw_lifetime_publish(t->value,&probe,&token)==ZWPW_WRONG_THREAD&&probe==saved;
    CloseHandle(probe);
    if (t->split) {
        t->first_result=zwpw_lifetime_run(t->value,0,&t->error);
        SetEvent(t->round);
        WaitForSingleObject(t->start,INFINITE);
    }
    t->result=zwpw_lifetime_run(t->value,10000,&t->error);
    zwpw_lifetime_unref(t->value);
    return 0;
}
static int start(TestDriver *t,BOOL split) {
    *t=(TestDriver){0};t->main=GetCurrentThreadId();t->split=split;
    t->lock=CreateEventW(NULL,TRUE,FALSE,NULL);
    t->ready=CreateEventW(NULL,FALSE,FALSE,NULL);
    t->start=CreateEventW(NULL,FALSE,FALSE,NULL);
    t->round=CreateEventW(NULL,FALSE,FALSE,NULL);
    CHECK(t->lock&&t->ready&&t->start&&t->round);
    t->thread=CreateThread(NULL,0,driver_thread,t,0,NULL);CHECK(t->thread);
    CHECK(WaitForSingleObject(t->ready,10000)==WAIT_OBJECT_0);
    CHECK(t->create_result==ZWPW_OK&&t->value&&t->tiny_result==ZWPW_BUDGET_EXCEEDED);
    current_driver=t;
    /* The native domain owns an independent duplicate of this metadata lock. */
    CloseHandle(t->lock);t->lock=NULL;return 1;
}
static int finish(TestDriver *t) {
    CHECK(SetEvent(t->start));
    CHECK(WaitForSingleObject(t->thread,15000)==WAIT_OBJECT_0);
    CHECK(t->authority_result&&t->result==ZWPW_OK&&t->error==0);
    ZwpwLifetimeStats stats;
    CHECK(zwpw_lifetime_stats(t->value,&stats)==ZWPW_OK);
    CHECK(!stats.processes&&!stats.admissions&&!stats.running&&!stats.accepting);
    ZwpwLifetimeCounts counts;
    zwpw_lifetime_counts(&counts);
    CHECK(counts.domains==1&&!counts.processes&&counts.bytes==zwpw_lifetime_size());
    /* Driver is physically retired; one explicit main C pin keeps metadata
       charged until this final release, with no App or caller allocator. */
    zwpw_lifetime_unref(t->value);t->value=NULL;
    current_driver=NULL;
    CloseHandle(t->thread);CloseHandle(t->ready);CloseHandle(t->start);CloseHandle(t->round);
    zwpw_lifetime_counts(&counts);
    CHECK(!counts.domains&&!counts.processes&&!counts.bytes);return 1;
}
static int empty_and_authority(void) {
    ZwpwLifetime *bad=(ZwpwLifetime *)(uintptr_t)8;uint32_t error=9;
    CHECK(zwpw_lifetime_create(GetCurrentThreadId(),0,INVALID_HANDLE_VALUE,&bad,&error)==ZWPW_WRONG_THREAD);
    CHECK(!bad&&!error);
    TestDriver t;CHECK(start(&t,FALSE));
    CHECK(zwpw_lifetime_run(t.value,0,&error)==ZWPW_WRONG_THREAD);
    CHECK(zwpw_lifetime_seal(t.value)==ZWPW_OK);
    CHECK(zwpw_lifetime_admit(t.value)==ZWPW_CLOSED);
    CHECK(finish(&t));return 1;
}
static int duplicate_and_closed(void) {
    TestDriver t;CHECK(start(&t,FALSE));
    HANDLE original=CreateEventW(NULL,TRUE,TRUE,NULL),first=NULL,second=NULL;
    CHECK(original&&DuplicateHandle(GetCurrentProcess(),original,GetCurrentProcess(),&first,0,FALSE,DUPLICATE_SAME_ACCESS));
    CHECK(DuplicateHandle(GetCurrentProcess(),original,GetCurrentProcess(),&second,0,FALSE,DUPLICATE_SAME_ACCESS));
    uint64_t a=0,b=0;
    CHECK(zwpw_lifetime_admit(t.value)==ZWPW_OK);
    CHECK(zwpw_lifetime_publish(t.value,&first,&a)==ZWPW_OK&&!first&&a);
    CHECK(zwpw_lifetime_publish(t.value,&second,&b)==ZWPW_OK&&!second&&a==b);
    ZwpwLifetimeStats stats;CHECK(zwpw_lifetime_stats(t.value,&stats)==ZWPW_OK&&stats.processes==1);
    CHECK(zwpw_lifetime_matches(t.value,a)==ZWPW_OK);
    CHECK(zwpw_lifetime_withdraw(t.value)==ZWPW_OK);
    CHECK(zwpw_lifetime_withdraw(t.value)==ZWPW_INVALID);
    CHECK(zwpw_lifetime_seal(t.value)==ZWPW_OK);
    HANDLE denied=CreateEventW(NULL,TRUE,TRUE,NULL),saved=denied;uint64_t denied_token=1;
    CHECK(zwpw_lifetime_publish(t.value,&denied,&denied_token)==ZWPW_CLOSED&&denied==saved&&!denied_token);
    CloseHandle(denied);CHECK(finish(&t));CloseHandle(original);return 1;
}
static int capacity_timeout_and_reuse(void) {
    TestDriver t;CHECK(start(&t,TRUE));
    HANDLE events[ZWPW_PROCESS_CAPACITY];uint64_t old=0;
    CHECK(zwpw_lifetime_admit(t.value)==ZWPW_OK);
    for (uint32_t i=0;i<ZWPW_PROCESS_CAPACITY;++i) {
        events[i]=CreateEventW(NULL,TRUE,FALSE,NULL);CHECK(events[i]);
        HANDLE record=NULL;CHECK(DuplicateHandle(GetCurrentProcess(),events[i],GetCurrentProcess(),&record,0,FALSE,DUPLICATE_SAME_ACCESS));
        uint64_t token=0;CHECK(zwpw_lifetime_publish(t.value,&record,&token)==ZWPW_OK&&!record&&token);
        if (!i) old=token;
    }
    HANDLE extra=CreateEventW(NULL,TRUE,FALSE,NULL),saved=extra,extra_signal=NULL;uint64_t token=9;
    CHECK(extra);
    CHECK(DuplicateHandle(GetCurrentProcess(),extra,GetCurrentProcess(),&extra_signal,0,FALSE,DUPLICATE_SAME_ACCESS));
    CHECK(zwpw_lifetime_publish(t.value,&extra,&token)==ZWPW_FULL&&extra==saved&&!token);
    CHECK(SetEvent(t.start));
    CHECK(WaitForSingleObject(t.round,10000)==WAIT_OBJECT_0);
    CHECK(t.first_result==ZWPW_PROCESS_EXIT_PENDING&&!t.error);
    ZwpwLifetimeStats stats;
    CHECK(zwpw_lifetime_stats(t.value,&stats)==ZWPW_OK&&stats.processes==ZWPW_PROCESS_CAPACITY&&stats.admissions==1&&!stats.running);
    CHECK(zwpw_lifetime_matches(t.value,old)==ZWPW_OK);
    CHECK(SetEvent(events[0])&&SetEvent(t.start));
    /* Explicit compiled test-only hook pauses the worker after real handle
       close/credit return. No scheduler delay decides whether a slot retired. */
    CHECK(WaitForSingleObject(t.round,10000)==WAIT_OBJECT_0);
    CHECK(zwpw_lifetime_stats(t.value,&stats)==ZWPW_OK&&stats.processes==ZWPW_PROCESS_CAPACITY-1&&stats.admissions==1&&stats.running);
    CHECK(zwpw_lifetime_matches(t.value,old)==ZWPW_CLOSED);
    /* A timed-out worker retained the live table. Exactly the physically
       retired record is reusable; the old serial cannot authorize this one. */
    CHECK(zwpw_lifetime_publish(t.value,&extra,&token)==ZWPW_OK&&!extra&&token>old);
    CHECK(zwpw_lifetime_matches(t.value,token)==ZWPW_OK);
    CHECK(SetEvent(extra_signal));
    for (uint32_t i=0;i<ZWPW_PROCESS_CAPACITY;++i) CHECK(SetEvent(events[i]));
    CHECK(zwpw_lifetime_withdraw(t.value)==ZWPW_OK&&zwpw_lifetime_seal(t.value)==ZWPW_OK);
    CHECK(finish(&t));
    for (uint32_t i=0;i<ZWPW_PROCESS_CAPACITY;++i) CloseHandle(events[i]);
    CloseHandle(extra_signal);
    return 1;
}
static int actual_process(void) {
    TestDriver t;CHECK(start(&t,FALSE));
    WCHAR program[MAX_PATH],command[MAX_PATH+40];
    UINT length=GetSystemDirectoryW(program,MAX_PATH);CHECK(length&&length<MAX_PATH-10);
    wcscat(program,L"\\cmd.exe");
    int written=swprintf(command,MAX_PATH+40,L"\"%ls\" /d /c exit 0",program);
    CHECK(written>0);
    STARTUPINFOW startup={0};startup.cb=sizeof(startup);
    PROCESS_INFORMATION process={0};
    CHECK(CreateProcessW(program,command,NULL,NULL,FALSE,CREATE_NO_WINDOW,NULL,NULL,&startup,&process));
    CloseHandle(process.hThread);
    HANDLE duplicate=NULL;
    CHECK(DuplicateHandle(GetCurrentProcess(),process.hProcess,GetCurrentProcess(),&duplicate,SYNCHRONIZE,FALSE,0));
    uint64_t one=0,two=0;
    CHECK(zwpw_lifetime_publish(t.value,&process.hProcess,&one)==ZWPW_OK&&!process.hProcess);
    CHECK(zwpw_lifetime_publish(t.value,&duplicate,&two)==ZWPW_OK&&!duplicate&&one==two);
    CHECK(zwpw_lifetime_seal(t.value)==ZWPW_OK);
    CHECK(finish(&t));return 1;
}
int zwpw_test_lifetime(void) {
    CHECK(empty_and_authority());
    CHECK(duplicate_and_closed());
    CHECK(capacity_timeout_and_reuse());
    CHECK(actual_process());
    fprintf(stderr,"Windows Profile lifetime:4 groups capacity=%u bytes=%zu final_refs=0\n",
            ZWPW_PROCESS_CAPACITY,zwpw_lifetime_size());
    return 1;
}
