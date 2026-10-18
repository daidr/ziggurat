#define COBJMACROS
#include "../src/file_stream/windows_istream.h"
#include <stdio.h>
#define REQUIRE(x) do{if(!(x)){fprintf(stderr,"legacy/channel line %d: %s\n",__LINE__,#x);fflush(stderr);ExitProcess(1);}}while(0)
#ifdef ZWS_TEST_BASELINE_LAYOUT
size_t zws_before_stream_size(void);
size_t zws_before_control_size(void);
size_t zws_before_budget_size(void);
#endif
#include "windows_file_fixture.h"
typedef struct Read {IStream *stream;int result;} Read;
static DWORD WINAPI read_file(void *pointer){
    Read *r=pointer;r->result=1;IStream *stream=r->stream;
    unsigned char bytes[11003];ULONG read=0;LARGE_INTEGER move={0};ULARGE_INTEGER position;
    if(IStream_Seek(stream,move,STREAM_SEEK_SET,&position)!=S_OK||position.QuadPart)return 0;
    uint64_t offset=0;
    for(;;){
        HRESULT result=IStream_Read(stream,bytes,sizeof(bytes),&read);
        if(FAILED(result))return 0;
        for(ULONG i=0;i<read;i++)if(bytes[i]!=pattern(offset+i))return 0;
        offset+=read;if(result==S_FALSE)break;if(!read)return 0;
    }
    if(offset!=4*1024*1024)return 0;
    move.QuadPart=7;if(IStream_Seek(stream,move,STREAM_SEEK_SET,&position)!=S_OK||position.QuadPart!=7)return 0;
    if(IStream_Read(stream,bytes,32,&read)!=S_OK||read!=32)return 0;
    for(unsigned i=0;i<32;i++)if(bytes[i]!=pattern(7+i))return 0;
    move.QuadPart=-40;if(IStream_Seek(stream,move,STREAM_SEEK_CUR,NULL)!=STG_E_INVALIDFUNCTION)return 0;
    move.QuadPart=0;if(IStream_Seek(stream,move,STREAM_SEEK_CUR,&position)!=S_OK||position.QuadPart!=39)return 0;
    r->result=0;return 0;
}
typedef struct Sources {DWORD main;ZwsChannel *source[16],*producer[16];int result;} Sources;
static DWORD WINAPI prepare_sources(void *pointer){
    Sources *s=pointer;
    for(unsigned i=0;i<16;i++){uint32_t error=0;if(zws_channel_prepare(s->main,1,ZWS_MAX_BYTES,ZWS_GENERATED,&s->source[i],&s->producer[i],&error)!=0||error){s->result=1;break;}}
    return 0;
}
static DWORD WINAPI full_source(void *pointer){
    DWORD main=*(DWORD *)pointer;ZwsChannel *source=NULL,*producer=NULL;uint32_t error=42;
    REQUIRE(zws_channel_prepare(main,1,ZWS_MAX_BYTES,ZWS_GENERATED,&source,&producer,&error)==ZWS_FULL);
    REQUIRE(!source&&!producer&&!error);return 0;
}
static void zero(void){ZwsCounts c;zws_counts(&c);REQUIRE(!c.physical&&!c.controls&&!c.budgets&&!c.readers&&!c.candidates&&!c.rings);}
int zws_test_legacy(void){
    zero();REQUIRE(SUCCEEDED(CoInitializeEx(NULL,COINIT_APARTMENTTHREADED)));
    Fixture fixture={0};run_worker(file_worker,&fixture);REQUIRE(SUCCEEDED(fixture.result)&&fixture.length==4*1024*1024);
    FileBudget *budget=zwv_file_budget_create(8);REQUIRE(budget);
    for(int fail=0;fail<2;fail++){
        zws_test_fail_after(fail);IStream *stream=NULL;
        REQUIRE(file_stream_create(fixture.prepared,fixture.length,budget,&stream)==E_OUTOFMEMORY&&stream==NULL);
        ZwsCounts c;zws_counts(&c);REQUIRE(c.physical==0&&c.controls==0&&c.budgets==1&&c.rings==0&&zws_budget_live(budget)==0);
    }
    zws_test_fail_after(-1);IStream *stream=NULL;REQUIRE(file_stream_create(fixture.prepared,fixture.length,budget,&stream)==S_OK);
    REQUIRE(((FileStream *)stream)->physical.kind==ZWS_DIRECT_FILE);
    unsigned char byte;ULONG read=42;REQUIRE(IStream_Read(stream,&byte,1,&read)==E_UNEXPECTED&&read==0);
    AcquireSRWLockExclusive(&((FileStream *)stream)->lock);LARGE_INTEGER zero_move={0};
    REQUIRE(IStream_Seek(stream,zero_move,STREAM_SEEK_SET,NULL)==E_PENDING);ReleaseSRWLockExclusive(&((FileStream *)stream)->lock);
    Read reading={stream,1};run_worker(read_file,&reading);REQUIRE(reading.result==0);
    IStream_Release(stream);zwv_file_budget_release(budget);zero();

    Sources generated={0};generated.main=GetCurrentThreadId();run_worker(prepare_sources,&generated);REQUIRE(!generated.result);
    FileBudget *budgets[4]={0};IStream *direct[16]={0};ZwsReader *readers[16]={0};ZwsControl *controls[16]={0};
    for(unsigned group=0;group<4;group++){
        budgets[group]=zwv_file_budget_create(8);REQUIRE(budgets[group]);
        for(unsigned j=0;j<4;j++){
            unsigned i=group*4+j;REQUIRE(file_stream_create(fixture.prepared,fixture.length,budgets[group],&direct[i])==S_OK);
            ZwsCandidate *candidate=NULL;REQUIRE(zws_candidate_prepare(generated.source[i],budgets[group],0,&candidate)==0);
            readers[i]=zws_candidate_reader(candidate);zws_reader_add(readers[i]);zws_candidate_admit(candidate,0,&controls[i]);
            zws_source_release(generated.source[i]);generated.source[i]=NULL;
        }
        REQUIRE(zws_budget_live(budgets[group])==8);
    }
    ZwsCounts c;zws_counts(&c);REQUIRE(c.physical==32&&c.controls==32&&c.rings==16);
    IStream *full=NULL;REQUIRE(file_stream_create(fixture.prepared,fixture.length,budgets[0],&full)==E_PENDING&&!full);
    run_worker(full_source,&generated.main);
    for(unsigned i=0;i<16;i++){
        zws_control_cancel(controls[i]);zwv_file_control_cancel(((FileStream *)direct[i])->physical.control);
    }
    zws_reader_release(readers[0]);readers[0]=NULL;
    REQUIRE(zws_budget_live(budgets[0])==8&&zws_control_alive(controls[0]));
    run_worker(full_source,&generated.main);
    zws_producer_release(generated.producer[0]);generated.producer[0]=NULL;
    REQUIRE(!zws_control_alive(controls[0])&&zws_budget_live(budgets[0])==7);
    zws_counts(&c);REQUIRE(c.physical==31&&c.rings==15);
    REQUIRE(file_stream_create(fixture.prepared,fixture.length,budgets[0],&full)==S_OK);
    REQUIRE(((FileStream *)full)->physical.kind==ZWS_DIRECT_FILE);
    zws_counts(&c);REQUIRE(c.physical==32&&c.rings==15&&zws_budget_live(budgets[0])==8);
    IStream_Release(full);
    for(unsigned i=0;i<16;i++){
        if(readers[i])zws_reader_release(readers[i]);if(generated.producer[i])zws_producer_release(generated.producer[i]);
        zws_control_release(controls[i]);IStream_Release(direct[i]);
    }
    for(unsigned i=0;i<4;i++)zwv_file_budget_release(budgets[i]);zero();
    fixture.cleanup=1;run_worker(file_worker,&fixture);REQUIRE(fixture.result==S_OK);CoUninitialize();
#ifdef ZWS_TEST_BASELINE_LAYOUT
    fprintf(stderr,"Actual old/current declarations: FileStream=%zu/%zu Control=%zu/%zu Budget=%zu/%zu; old declaration origin in layout-extract.json\n",zws_before_stream_size(),sizeof(FileStream),zws_before_control_size(),sizeof(FileControl),zws_before_budget_size(),sizeof(FileBudget));
#endif
    fprintf(stderr,"Windows direct IStream + generated: exact 4MiB/Seek/UI refusal/OOM, mixed32 physical/8consumer/16rings, held producer and old control; direct=%zu prefix=%zu control=%zu budget=%zu; refs=0\n",sizeof(FileStream),sizeof(ZwsPhysical),sizeof(FileControl),sizeof(FileBudget));return 0;
}
