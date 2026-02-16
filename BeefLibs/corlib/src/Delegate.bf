using System.Reflection;
using System.Collections;

namespace System
{
	[AlwaysInclude]
	class Delegate : IHashable
	{
	    void* mFuncPtr;
	    void* mTarget;

		public MethodInfo Method
		{
			get
			{
				if (mFuncPtr == null)
					return default;
				return DelegateMethodCache.GetMethodInfo(mFuncPtr);
			}
		}

		public static bool Equals(Delegate a, Delegate b)
		{
			if (a === null)
				return b === null;
			return a.Equals(b);
		}

		public virtual bool Equals(Delegate val)
		{
			if (this === val)
				return true;
			if (val == null)
				return false;
			return (mFuncPtr == val.mFuncPtr) && (mTarget == val.mTarget);
		}

		public Result<void*> GetFuncPtr()
	    {
			if (mTarget != null)
				return .Err; //("Delegate target method must be static");
	        return mFuncPtr;
	    }

		public void* GetTarget()
		{
#if BF_64_BIT && BF_ENABLE_OBJECT_DEBUG_FLAGS
			return (.)((int)mTarget & 0x7FFFFFFF'FFFFFFFF);
#else
			return mTarget;
#endif
		}

	    public void SetFuncPtr(void* ptr, void* target = null)
		{
			mTarget = target;
			mFuncPtr = ptr;
		}

		protected override void GCMarkMembers()
		{
			// Note- this is safe even if mTarget is not an object, because the GC does object address validation
#if BF_64_BIT && BF_ENABLE_OBJECT_DEBUG_FLAGS
			GC.Mark(Internal.UnsafeCastToObject((.)((int)mTarget & 0x7FFFFFFF'FFFFFFFF)));
#else
			GC.Mark(Internal.UnsafeCastToObject(mTarget));
#endif
		}

		public int GetHashCode()
		{
			return (int)mFuncPtr;
		}

		[Commutable]
		public static bool operator==(Delegate a, Delegate b)
		{
			if (a === null)
				return b === null;
			return a.Equals(b);
		}
	}

	delegate void Action();

	[AlwaysInclude]
	struct Function : int
	{

	}

	static class DelegateMethodCache
	{
		static Dictionary<int, MethodInfo> sMethodInfoCache = new .() ~ delete _;
		static bool sCacheBuilt;

		public static MethodInfo GetMethodInfo(void* funcPtr)
		{
			if (Compiler.IsComptime)
				return default;
			if (funcPtr == null)
				return default;

			BuildMethodInfoCache();

			MethodInfo methodInfo = default;
			if (sMethodInfoCache.TryGetValue((int)funcPtr, out methodInfo))
				return methodInfo;

			return default;
		}

		static void BuildMethodInfoCache()
		{
			if (sCacheBuilt)
				return;

			sCacheBuilt = true;
			Type.[Friend]GetType((.)0);
			for (var type in Type.Types)
			{
				if (var typeInstance = type as TypeInstance)
				{
					int methodCount = typeInstance.[Friend]mMethodDataCount;
					if (methodCount == 0)
						continue;

					let methodDataPtr = typeInstance.[Friend]mMethodDataPtr;
					if (methodDataPtr == null)
						continue;

					for (int i < methodCount)
					{
						let methodData = &methodDataPtr[i];
						if (methodData.mFuncPtr == null)
							continue;

						sMethodInfoCache[(int)methodData.mFuncPtr] = .(typeInstance, methodData);
					}
				}
			}
		}
	}
}
