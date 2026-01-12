#include "Common.h"
#include "BFPlatform.h"

#if defined(__XTENSA__)
#define BFP_BAREMETAL
#endif
//#include <CoreFoundation/CFByteOrder.h>
//#include <mach/mach_time.h>
#include <sys/stat.h>
#if defined(__has_include)
#if __has_include(<dlfcn.h>)
#define BFP_HAS_DLOPEN
#include <dlfcn.h>
#endif
#else
#if !defined(BFP_BAREMETAL)
#define BFP_HAS_DLOPEN
#include <dlfcn.h>
#endif
#endif
#include <wchar.h>
#include <fcntl.h>
//#include <mach/clock.h>
//#include <mach/mach.h>
#include <time.h>
#include <dirent.h>
