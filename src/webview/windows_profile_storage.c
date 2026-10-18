#include "windows_profile_storage.h"
#include <aclapi.h>
#include <appmodel.h>
#include <assert.h>
#include <stdlib.h>
#include <string.h>
#include <wchar.h>

#define PATH_CAP 4096u
#define SECURITY_CAP 4096u
struct ZwpwStorage {
    HANDLE root, data, lock;
    ZwpwLifetime *domain;
    size_t allocation;
    char *root_utf8,*data_utf8;
    WCHAR *data_utf16;
};
static volatile LONG storage_owners;
static volatile LONG64 storage_bytes;
typedef struct Security {
    SECURITY_DESCRIPTOR descriptor;
    SECURITY_ATTRIBUTES attributes;
    union { void *align; unsigned char bytes[256]; } user;
    union { void *align; unsigned char bytes[256]; } acl;
    unsigned char system[SECURITY_MAX_SID_SIZE];
    PSID owner;
} Security;
static int native_failure(uint32_t *error,DWORD code) {
    if (error) *error=code;return ZWPW_NATIVE_FAILED;
}
static int private_security(Security *s,uint32_t *error) {
    HANDLE token=NULL;DWORD length=0;
    if (!OpenProcessToken(GetCurrentProcess(),TOKEN_QUERY,&token)) return native_failure(error,GetLastError());
    BOOL ok=GetTokenInformation(token,TokenUser,s->user.bytes,sizeof(s->user.bytes),&length);
    DWORD code=ok?ERROR_SUCCESS:GetLastError();CloseHandle(token);
    if (!ok) return native_failure(error,code);
    s->owner=((TOKEN_USER *)s->user.bytes)->User.Sid;
    DWORD system_length=sizeof(s->system);
    if (!CreateWellKnownSid(WinLocalSystemSid,NULL,s->system,&system_length)) return native_failure(error,GetLastError());
    ACL *acl=(ACL *)s->acl.bytes;
    DWORD flags=CONTAINER_INHERIT_ACE|OBJECT_INHERIT_ACE;
    if (!InitializeAcl(acl,sizeof(s->acl.bytes),ACL_REVISION)||
        !AddAccessAllowedAceEx(acl,ACL_REVISION,flags,FILE_ALL_ACCESS,s->owner)||
        !AddAccessAllowedAceEx(acl,ACL_REVISION,flags,FILE_ALL_ACCESS,s->system)||
        !InitializeSecurityDescriptor(&s->descriptor,SECURITY_DESCRIPTOR_REVISION)||
        !SetSecurityDescriptorOwner(&s->descriptor,s->owner,FALSE)||
        !SetSecurityDescriptorDacl(&s->descriptor,TRUE,acl,FALSE)||
        !SetSecurityDescriptorControl(&s->descriptor,SE_DACL_PROTECTED,SE_DACL_PROTECTED))
        return native_failure(error,GetLastError());
    s->attributes=(SECURITY_ATTRIBUTES){sizeof(SECURITY_ATTRIBUTES),&s->descriptor,FALSE};
    return ZWPW_OK;
}
static int validate_private(HANDLE handle,BOOL directory,Security *s,uint32_t *error) {
    BY_HANDLE_FILE_INFORMATION info;
    if (!GetFileInformationByHandle(handle,&info)) return native_failure(error,GetLastError());
    if ((info.dwFileAttributes&FILE_ATTRIBUTE_REPARSE_POINT)||
        !!(info.dwFileAttributes&FILE_ATTRIBUTE_DIRECTORY)!=!!directory||
        (!directory&&info.nNumberOfLinks!=1)) return ZWPW_INVALID;
    union { void *align; unsigned char bytes[SECURITY_CAP]; } buffer;
    DWORD required=0;
    if (!GetKernelObjectSecurity(handle,OWNER_SECURITY_INFORMATION|DACL_SECURITY_INFORMATION,
        (SECURITY_DESCRIPTOR *)buffer.bytes,sizeof(buffer.bytes),&required)) return native_failure(error,GetLastError());
    PSID owner=NULL;BOOL defaulted=FALSE,present=FALSE;ACL *acl=NULL;
    if (!GetSecurityDescriptorOwner(buffer.bytes,&owner,&defaulted)||!owner||!EqualSid(owner,s->owner)||
        !GetSecurityDescriptorDacl(buffer.bytes,&present,&acl,&defaulted)||!present||!acl) return ZWPW_INVALID;
    BOOL owner_allowed=FALSE;
    for (DWORD i=0;i<acl->AceCount;++i) {
        ACE_HEADER *header=NULL;
        if (!GetAce(acl,i,(void **)&header)) return native_failure(error,GetLastError());
        if (header->AceFlags&INHERIT_ONLY_ACE) continue;
        /* Conservatively reject unfamiliar allow forms; deny entries do not
           enlarge access. Prepared storage is an explicit private directory. */
        if (header->AceType==ACCESS_DENIED_ACE_TYPE) continue;
        if (header->AceType!=ACCESS_ALLOWED_ACE_TYPE) return ZWPW_INVALID;
        ACCESS_ALLOWED_ACE *ace=(ACCESS_ALLOWED_ACE *)header;
        PSID sid=&ace->SidStart;
        if (!IsValidSid(sid)||(!EqualSid(sid,s->owner)&&!EqualSid(sid,s->system))) return ZWPW_INVALID;
        if (EqualSid(sid,s->owner)&&(ace->Mask&FILE_ALL_ACCESS)==FILE_ALL_ACCESS) owner_allowed=TRUE;
    }
    return owner_allowed?ZWPW_OK:ZWPW_INVALID;
}
static int open_directory(const WCHAR *path,BOOL create,Security *s,HANDLE *out,uint32_t *error) {
    *out=NULL;
    if (create&&!CreateDirectoryW(path,&s->attributes)&&GetLastError()!=ERROR_ALREADY_EXISTS)
        return native_failure(error,GetLastError());
    HANDLE handle=CreateFileW(path,FILE_READ_ATTRIBUTES|READ_CONTROL,FILE_SHARE_READ|FILE_SHARE_WRITE,
        NULL,OPEN_EXISTING,FILE_FLAG_BACKUP_SEMANTICS|FILE_FLAG_OPEN_REPARSE_POINT,NULL);
    if (handle==INVALID_HANDLE_VALUE) return native_failure(error,GetLastError());
    int status=ZWPW_OK;
    if (create) status=validate_private(handle,TRUE,s,error);
    else {
        FILE_ATTRIBUTE_TAG_INFO info;
        if (!GetFileInformationByHandleEx(handle,FileAttributeTagInfo,&info,sizeof(info))) status=native_failure(error,GetLastError());
        else if (!(info.FileAttributes&FILE_ATTRIBUTE_DIRECTORY)||(info.FileAttributes&FILE_ATTRIBUTE_REPARSE_POINT)) status=ZWPW_INVALID;
    }
    if (status) CloseHandle(handle);else *out=handle;
    return status;
}
static int valid_path(const WCHAR *path,size_t length) {
    if (length<4||length>=PATH_CAP-32||!((path[0]>='A'&&path[0]<='Z')||(path[0]>='a'&&path[0]<='z'))||path[1]!=':'||path[2]!='\\') return ZWPW_INVALID;
    size_t begin=3;
    for (size_t i=3;i<=length;++i) {
        WCHAR ch=path[i];
        if (i<length&&(ch<' '||ch=='/'||ch==':'||ch=='"'||ch=='<'||ch=='>'||ch=='|'||ch=='?'||ch=='*')) return ZWPW_INVALID;
        if (i==length||ch=='\\') {
            size_t count=i-begin;
            if (!count||path[i-1]=='.'||path[i-1]==' ') return ZWPW_INVALID;
            begin=i+1;
        }
    }
    return ZWPW_OK;
}
static int arguments_clean(uint32_t *error) {
    WCHAR one[2];SetLastError(ERROR_SUCCESS);
    DWORD length=GetEnvironmentVariableW(L"WEBVIEW2_ADDITIONAL_BROWSER_ARGUMENTS",one,2);
    if (length) return ZWPW_INVALID;
    DWORD code=GetLastError();
    if (code!=ERROR_SUCCESS&&code!=ERROR_ENVVAR_NOT_FOUND) return native_failure(error,code);
    WCHAR app[PATH_CAP],executable[PATH_CAP];UINT32 app_length=PATH_CAP;
    LONG app_status=GetCurrentApplicationUserModelId(&app_length,app);
    if (app_status!=ERROR_SUCCESS&&app_status!=APPMODEL_ERROR_NO_APPLICATION) return native_failure(error,(DWORD)app_status);
    DWORD n=GetModuleFileNameW(NULL,executable,PATH_CAP);
    if (!n||n>=PATH_CAP) return native_failure(error,n?ERROR_BUFFER_OVERFLOW:GetLastError());
    const WCHAR *basename=wcsrchr(executable,'\\');basename=basename?basename+1:executable;
    const WCHAR *names[3]={app_status==ERROR_SUCCESS?app:NULL,basename,L"*"};
    HKEY roots[2]={HKEY_LOCAL_MACHINE,HKEY_CURRENT_USER};
    for (unsigned root=0;root<2;++root) {
        HKEY key=NULL;
        LSTATUS opened=RegOpenKeyExW(roots[root],L"Software\\Policies\\Microsoft\\Edge\\WebView2\\AdditionalBrowserArguments",0,KEY_QUERY_VALUE,&key);
        if (opened==ERROR_FILE_NOT_FOUND||opened==ERROR_PATH_NOT_FOUND) continue;
        if (opened!=ERROR_SUCCESS) return native_failure(error,(DWORD)opened);
        int result=ZWPW_OK;BOOL found=FALSE;
        for (unsigned name=0;name<3&&!found;++name) if (names[name]) {
            DWORD type=0,bytes=sizeof(one);
            LSTATUS value=RegQueryValueExW(key,names[name],NULL,&type,(BYTE *)one,&bytes);
            if (value==ERROR_FILE_NOT_FOUND) continue;
            found=TRUE;
            if (value==ERROR_MORE_DATA) result=ZWPW_INVALID;
            else if (value!=ERROR_SUCCESS) result=native_failure(error,(DWORD)value);
            else if (type!=REG_SZ||bytes!=sizeof(WCHAR)||one[0]!=0) result=ZWPW_INVALID;
        }
        RegCloseKey(key);
        if (found||result) return result;
    }
    return ZWPW_OK;
}
int zwpw_storage_create(uint32_t main_thread,const char *input,size_t length,size_t bytes,
                        ZwpwStorage **out,uint32_t *error) {
    if (error) *error=0;if (!out) return ZWPW_INVALID;*out=NULL;
    if (GetCurrentThreadId()==main_thread) return ZWPW_WRONG_THREAD;
    if (!main_thread||!input||!length||length>=PATH_CAP) return ZWPW_INVALID;
    /* Both path representations are owned stack captures before foreign work. */
    char utf8[PATH_CAP];memcpy(utf8,input,length);utf8[length]=0;
    if (memchr(utf8,0,length)) return ZWPW_INVALID;
    WCHAR path[PATH_CAP];
    int units=MultiByteToWideChar(CP_UTF8,MB_ERR_INVALID_CHARS,utf8,(int)length,path,PATH_CAP-1);
    if (!units) return native_failure(error,GetLastError());path[units]=0;
    int result=valid_path(path,(size_t)units);if (result) return result;
    if (GetDriveTypeW((WCHAR[]){path[0],':','\\',0})!=DRIVE_FIXED) return ZWPW_INVALID;
    result=arguments_clean(error);if (result) return result;
    Security security;result=private_security(&security,error);if (result) return result;
    HANDLE root=NULL,data=NULL,lock=NULL;
    for (size_t i=3;i<(size_t)units;++i) if (path[i]=='\\') {
        path[i]=0;HANDLE ancestor=NULL;result=open_directory(path,FALSE,&security,&ancestor,error);path[i]='\\';
        if (result) goto failed;CloseHandle(ancestor);
    }
    result=open_directory(path,TRUE,&security,&root,error);if (result) goto failed;
    WCHAR canonical[PATH_CAP];
    DWORD full=GetFinalPathNameByHandleW(root,canonical,PATH_CAP,FILE_NAME_NORMALIZED|VOLUME_NAME_DOS);
    if (!full||full>=PATH_CAP) { result=native_failure(error,full?ERROR_BUFFER_OVERFLOW:GetLastError());goto failed; }
    if (full<7||wcsncmp(canonical,L"\\\\?\\",4)) { result=ZWPW_INVALID;goto failed; }
    memmove(path,canonical+4,(full-3)*sizeof(WCHAR));
    size_t root_units=full-4;
    result=valid_path(path,root_units);if (result) goto failed;
    wcscpy(path+root_units,L"\\data");
    result=open_directory(path,TRUE,&security,&data,error);if (result) goto failed;
    wcscpy(path+root_units,L"\\.ziggurat-profile.lock");
    lock=CreateFileW(path,GENERIC_READ|GENERIC_WRITE|READ_CONTROL,FILE_SHARE_READ|FILE_SHARE_WRITE,
        &security.attributes,OPEN_ALWAYS,FILE_FLAG_OPEN_REPARSE_POINT,NULL);
    if (lock==INVALID_HANDLE_VALUE) { lock=NULL;result=native_failure(error,GetLastError());goto failed; }
    result=validate_private(lock,FALSE,&security,error);if (result) goto failed;
    OVERLAPPED overlap={0};
    if (!LockFileEx(lock,LOCKFILE_EXCLUSIVE_LOCK|LOCKFILE_FAIL_IMMEDIATELY,0,1,0,&overlap)) {
        DWORD code=GetLastError();result=code==ERROR_LOCK_VIOLATION?ZWPW_BUSY:native_failure(error,code);goto failed;
    }
    path[root_units]=0;
    int root_bytes=WideCharToMultiByte(CP_UTF8,WC_ERR_INVALID_CHARS,path,-1,NULL,0,NULL,NULL);
    wcscpy(path+root_units,L"\\data");
    int data_bytes=WideCharToMultiByte(CP_UTF8,WC_ERR_INVALID_CHARS,path,-1,NULL,0,NULL,NULL);
    if (!root_bytes||!data_bytes) { result=native_failure(error,GetLastError());goto failed; }
    if (root_bytes>(int)PATH_CAP||data_bytes>(int)PATH_CAP) { result=ZWPW_INVALID;goto failed; }
    size_t allocation=sizeof(ZwpwStorage)+(size_t)root_bytes+(size_t)data_bytes+sizeof(WCHAR)-1+(root_units+6)*sizeof(WCHAR);
    size_t domain_bytes=zwpw_lifetime_size();
    if (allocation>bytes||domain_bytes>bytes-allocation) { result=ZWPW_BUDGET_EXCEEDED;goto failed; }
    ZwpwStorage *s=calloc(1,allocation);
    if (!s) { result=ZWPW_OUT_OF_MEMORY;goto failed; }
    result=zwpw_lifetime_create(main_thread,bytes-allocation,lock,&s->domain,error);
    if (result) { free(s);goto failed; }
    s->allocation=allocation;s->root=root;s->data=data;s->lock=lock;
    s->root_utf8=(char *)(s+1);s->data_utf8=s->root_utf8+root_bytes;
    /* UTF16 must remain aligned even when the two UTF8 lengths are odd. */
    uintptr_t wide=((uintptr_t)(s->data_utf8+data_bytes)+sizeof(WCHAR)-1)&~(uintptr_t)(sizeof(WCHAR)-1);
    s->data_utf16=(WCHAR *)wide;
    wcscpy(s->data_utf16,path);
    WideCharToMultiByte(CP_UTF8,WC_ERR_INVALID_CHARS,path,-1,s->data_utf8,data_bytes,NULL,NULL);
    path[root_units]=0;
    WideCharToMultiByte(CP_UTF8,WC_ERR_INVALID_CHARS,path,-1,s->root_utf8,root_bytes,NULL,NULL);
    InterlockedIncrement(&storage_owners);InterlockedAdd64(&storage_bytes,(LONG64)allocation);
    *out=s;return ZWPW_OK;
failed:
    if (lock) CloseHandle(lock);if (data) CloseHandle(data);if (root) CloseHandle(root);return result;
}
void zwpw_storage_unref(ZwpwStorage *s) {
    ZwpwLifetime *domain=s->domain;HANDLE root=s->root,data=s->data,lock=s->lock;size_t bytes=s->allocation;
    s->domain=NULL;s->root=s->data=s->lock=NULL;
    CloseHandle(lock);CloseHandle(data);CloseHandle(root);zwpw_lifetime_unref(domain);free(s);
    InterlockedAdd64(&storage_bytes,-(LONG64)bytes);InterlockedDecrement(&storage_owners);
}
void zwpw_storage_paths(ZwpwStorage *s,ZwpwStoragePaths *out) { *out=(ZwpwStoragePaths){s->root_utf8,s->data_utf8,s->data_utf16}; }
ZwpwLifetime *zwpw_storage_domain(ZwpwStorage *s) { return s->domain; }
size_t zwpw_storage_size(ZwpwStorage *s) { return s->allocation+zwpw_lifetime_size(); }
size_t zwpw_storage_bound(void) { return sizeof(ZwpwStorage)+4*PATH_CAP+sizeof(WCHAR)-1+zwpw_lifetime_size(); }
void zwpw_storage_counts(uint32_t *owners,size_t *bytes) {
    *owners=(uint32_t)InterlockedCompareExchange(&storage_owners,0,0);*bytes=(size_t)InterlockedCompareExchange64(&storage_bytes,0,0);
}
