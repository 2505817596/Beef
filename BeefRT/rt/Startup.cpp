#include "BfObjects.h"

namespace bf
{
	namespace System
	{
		class Internal
		{
		public:
			static void BfStaticCtor();
			static void BfStaticDtor();
			static void Shutdown_Internal();
		};
	}
}

#if defined(__XTENSA__)
extern "C" void _ZN2bf6System7Runtime11RuntimeInit14__BfStaticCtorEv();
extern "C" void _ZN2bf6System9Threading6Thread17RuntimeThreadInit14__BfStaticCtorEv();
#endif

static bool gBfRuntimeStarted = false;

extern "C" BFRT_EXPORT void BfRuntime_Startup()
{
	if (gBfRuntimeStarted)
		return;
	gBfRuntimeStarted = true;
#if defined(__XTENSA__)
	_ZN2bf6System9Threading6Thread17RuntimeThreadInit14__BfStaticCtorEv();
	_ZN2bf6System7Runtime11RuntimeInit14__BfStaticCtorEv();
#endif
	bf::System::Internal::BfStaticCtor();
}

extern "C" BFRT_EXPORT void BfRuntime_Shutdown()
{
	if (!gBfRuntimeStarted)
		return;
	gBfRuntimeStarted = false;
	bf::System::Internal::Shutdown_Internal();
	bf::System::Internal::BfStaticDtor();
}
