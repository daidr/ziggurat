/* Windows API declarations shared by every Ziggurat module. Empty elsewhere.
 * NO_STRICT keeps opaque handles as untyped tokens rather than aligned
 * struct pointers. */
#if defined(_WIN32)
#define WIN32_LEAN_AND_MEAN 1
#define NO_STRICT 1
#include <windows.h>
#include <objbase.h>
#include <ole2.h>
#include <oleauto.h>
#include <imm.h>
#include <shellapi.h>
#include <shlobj.h>
#include <shlwapi.h>
#include <commctrl.h>
#include <wincred.h>
#include <sddl.h>
#include <tlhelp32.h>
#include <uiautomation.h>
#endif
