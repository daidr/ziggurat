#ifndef ZIGGURAT_WINDOWS_FILE_FIXTURE_H
#define ZIGGURAT_WINDOWS_FILE_FIXTURE_H
/* Private regular-file fixture shared by direct and pumped consumer tests. */
typedef struct Fixture {WCHAR path[MAX_PATH];HANDLE borrowed,prepared;uint64_t length;int cleanup;HRESULT result;} Fixture;
static unsigned char pattern(uint64_t i){return (unsigned char)(i*37+11);}
static DWORD WINAPI file_worker(void *pointer){
    Fixture *f=pointer;f->result=E_FAIL;
    if(f->cleanup){
        LARGE_INTEGER zero={0},position;
        if(!SetFilePointerEx(f->borrowed,zero,&position,FILE_CURRENT)||position.QuadPart!=3)return 0;
        if(!SetFilePointerEx(f->prepared,zero,&position,FILE_CURRENT)||position.QuadPart!=0)return 0;
        CloseHandle(f->borrowed);CloseHandle(f->prepared);f->borrowed=f->prepared=NULL;
        if(!DeleteFileW(f->path))return 0;f->result=S_OK;return 0;
    }
    WCHAR directory[MAX_PATH];DWORD length=GetEnvironmentVariableW(L"ZIGGURAT_STREAM_TEST_ROOT",directory,MAX_PATH);
    if(!length||length>=MAX_PATH||!GetTempFileNameW(directory,L"zws",0,f->path))return 0;
    HANDLE output=CreateFileW(f->path,GENERIC_WRITE,0,NULL,TRUNCATE_EXISTING,FILE_ATTRIBUTE_NORMAL,NULL);
    if(output==INVALID_HANDLE_VALUE)return 0;
    unsigned char bytes[65536];for(unsigned i=0;i<sizeof(bytes);i++)bytes[i]=pattern(i);
    f->length=4*1024*1024;
    for(uint64_t at=0;at<f->length;at+=sizeof(bytes)){
        DWORD written=0;if(!WriteFile(output,bytes,sizeof(bytes),&written,NULL)||written!=sizeof(bytes)){CloseHandle(output);return 0;}
    }
    CloseHandle(output);
    f->borrowed=CreateFileW(f->path,GENERIC_READ,FILE_SHARE_READ|FILE_SHARE_DELETE,NULL,OPEN_EXISTING,FILE_ATTRIBUTE_NORMAL,NULL);
    if(f->borrowed==INVALID_HANDLE_VALUE){f->borrowed=NULL;return 0;}
    LARGE_INTEGER three;three.QuadPart=3;if(!SetFilePointerEx(f->borrowed,three,NULL,FILE_BEGIN))return 0;
    f->result=zwv_file_prepare(f->borrowed,ZWS_MAX_BYTES,&f->prepared,&f->length);return 0;
}
static void run_worker(LPTHREAD_START_ROUTINE procedure,void *argument){
    HANDLE thread=CreateThread(NULL,0,procedure,argument,0,NULL);REQUIRE(thread);
    REQUIRE(WaitForSingleObject(thread,15000)==WAIT_OBJECT_0);CloseHandle(thread);
}
#endif
