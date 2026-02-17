#include "BeCppCodeGen.h"

#include "BeefySysLib/FileStream.h"

#include <atomic>
#include <cmath>
#include <cstring>
#include <filesystem>
#include <unordered_map>
#include <vector>

USING_NS_BF;

namespace
{
static bool IsCppIdentStart(char c)
{
	return ((c >= 'A') && (c <= 'Z')) || ((c >= 'a') && (c <= 'z')) || (c == '_');
}

static bool IsCppIdentChar(char c)
{
	return IsCppIdentStart(c) || ((c >= '0') && (c <= '9'));
}

static bool IsValidCppIdentifier(const StringImpl& name)
{
	if (name.IsEmpty())
		return false;
	if (!IsCppIdentStart(name[0]))
		return false;
	for (int i = 1; i < (int)name.length(); i++)
	{
		if (!IsCppIdentChar(name[i]))
			return false;
	}
	return true;
}

static String SanitizeIdentifier(const StringImpl& inName, const StringImpl& fallback)
{
	if (inName.IsEmpty())
		return fallback;

	String outName;
	outName.Reserve((int)inName.length() + 8);
	for (int i = 0; i < (int)inName.length(); i++)
	{
		char c = inName[i];
		outName += IsCppIdentChar(c) ? c : '_';
	}

	if (outName.IsEmpty())
		return fallback;
	if (!IsCppIdentStart(outName[0]))
		outName.Insert(0, '_');
	return outName;
}

static uint32 StableStringHash(const StringImpl& str)
{
	uint32 hash = 2166136261u; // FNV-1a
	for (int i = 0; i < (int)str.length(); i++)
	{
		hash ^= (uint8)str[i];
		hash *= 16777619u;
	}
	if (hash == 0)
		hash = 1;
	return hash;
}

static String MakeStableSymbolName(const StringImpl& inName, const StringImpl& fallback)
{
	// Keep ABI names stable when already legal C++ identifiers (for imports/exports like malloc/main/Bfp*).
	if (IsValidCppIdentifier(inName))
		return String(inName);

	String baseName = SanitizeIdentifier(inName, fallback);
	uint32 nameHash = StableStringHash(inName);
	return StrFormat("%s_h%08X", baseName.c_str(), nameHash);
}

static String GetInt64LiteralExpr(int64 value)
{
	// '-9223372036854775808' is parsed as an unsigned literal by some compilers.
	// Keep INT64_MIN in a subtraction form to avoid warnings in generated code.
	if (value == (((int64)-9223372036854775807LL) - 1LL))
		return "(-9223372036854775807LL - 1LL)";
	return StrFormat("%lldLL", (long long)value);
}

static bool IsKnownCRuntimeFunction(const StringImpl& name)
{
	return (name == "malloc") ||
		(name == "free") ||
		(name == "memcpy") ||
		(name == "memmove") ||
		(name == "memset") ||
		(name == "select") ||
		(name == "exit") ||
		(name == "strtod") ||
		(name == "strtof") ||
		(name == "strtold") ||
		(name == "strtol") ||
		(name == "strtoll") ||
		(name == "strtoul") ||
		(name == "strtoull") ||
		(name == "abort");
}

static bool IsImplicitEmptyCtorDecl(BeFunction* beFunc)
{
	if ((beFunc == NULL) || (!beFunc->IsDecl()))
		return false;
	auto funcType = beFunc->GetFuncType();
	if ((funcType == NULL) || (funcType->mIsVarArg))
		return false;
	if ((funcType->mReturnType == NULL) || (funcType->mReturnType->mTypeCode != BeTypeCode_None))
		return false;
	if (!funcType->mParams.IsEmpty())
		return false;
	// Pattern for Itanium constructor with no args/void return.
	return beFunc->mName.EndsWith("C1Ev");
}

static int NormalizeSize(int size)
{
	if (size <= 0)
		return 1;
	return size;
}

static int NormalizeAlign(int align)
{
	if (align <= 0)
		return 1;
	if ((align & (align - 1)) != 0)
		return 1;
	return align;
}

static int GetStride(BeType* type)
{
	int size = NormalizeSize(type->mSize);
	int align = NormalizeAlign(type->mAlign);
	return BF_ALIGN(size, align);
}

static int GetAggregateElementByteOffset(BeType* aggType, int idx)
{
	if (aggType == NULL)
		return 0;

	switch (aggType->mTypeCode)
	{
	case BeTypeCode_Struct:
	{
		auto structType = (BeStructType*)aggType;
		if ((idx >= 0) && (idx < (int)structType->mMembers.size()))
			return structType->mMembers[idx].mByteOffset;
		return 0;
	}
	case BeTypeCode_SizedArray:
	{
		auto arrayType = (BeSizedArrayType*)aggType;
		return idx * GetStride(arrayType->mElementType);
	}
	case BeTypeCode_Vector:
	{
		auto vectorType = (BeVectorType*)aggType;
		return idx * GetStride(vectorType->mElementType);
	}
	default:
		return 0;
	}
}

static bool IsPointerType(BeType* type)
{
	return (type != NULL) && ((type->mTypeCode == BeTypeCode_Pointer) || (type->mTypeCode == BeTypeCode_NullPtr));
}

static bool IsIntegralType(BeType* type)
{
	if (type == NULL)
		return false;
	return (type->mTypeCode == BeTypeCode_Boolean) ||
		(type->mTypeCode == BeTypeCode_Int8) ||
		(type->mTypeCode == BeTypeCode_Int16) ||
		(type->mTypeCode == BeTypeCode_Int32) ||
		(type->mTypeCode == BeTypeCode_Int64) ||
		(type->mTypeCode == BeTypeCode_CmpResult);
}

static bool IsBoolLikeType(BeType* type)
{
	if (type == NULL)
		return false;
	return (type->mTypeCode == BeTypeCode_Boolean) || (type->mTypeCode == BeTypeCode_CmpResult);
}

static bool IsFloatType(BeType* type)
{
	if (type == NULL)
		return false;
	return (type->mTypeCode == BeTypeCode_Float) || (type->mTypeCode == BeTypeCode_Double);
}

static bool IsScalarType(BeType* type)
{
	return IsIntegralType(type) || IsFloatType(type) || IsPointerType(type);
}

static const char* GetUnsignedCmpCastType(BeType* type)
{
	if (type == NULL)
		return "uint64_t";

	switch (type->mTypeCode)
	{
	case BeTypeCode_Boolean:
	case BeTypeCode_CmpResult:
	case BeTypeCode_Int8:
		return "uint8_t";
	case BeTypeCode_Int16:
		return "uint16_t";
	case BeTypeCode_Int32:
		return "uint32_t";
	case BeTypeCode_Int64:
		return "uint64_t";
	case BeTypeCode_Pointer:
	case BeTypeCode_NullPtr:
		return "uintptr_t";
	default:
		return "uint64_t";
	}
}

static const char* GetUnsignedMathCastType(BeType* type)
{
	// For unsigned arithmetic/shift we must preserve operand bit width.
	// Widening int32 to uint64 before shifting breaks bit-accurate ops like SHA1 rotl.
	return GetUnsignedCmpCastType(type);
}

static String GetOpaqueCppType(BeType* type)
{
	return StrFormat("::bf::OpaqueValue<%d, %d>", NormalizeSize(type->mSize), NormalizeAlign(type->mAlign));
}

static String GetCppType(BeType* type)
{
	switch (type->mTypeCode)
	{
	case BeTypeCode_None:
		return "void";
	case BeTypeCode_NullPtr:
		return "void*";
	case BeTypeCode_Boolean:
		return "bool";
	case BeTypeCode_Int8:
		return "int8_t";
	case BeTypeCode_Int16:
		return "int16_t";
	case BeTypeCode_Int32:
		return "int32_t";
	case BeTypeCode_Int64:
		return "int64_t";
	case BeTypeCode_Float:
		return "float";
	case BeTypeCode_Double:
		return "double";
	case BeTypeCode_Pointer:
	{
		auto ptrType = (BePointerType*)type;
		if (ptrType->mElementType->mTypeCode == BeTypeCode_Function)
			return "void*";
		auto elemType = GetCppType(ptrType->mElementType);
		if (elemType == "void")
			return "void*";
		return elemType + "*";
	}
	case BeTypeCode_CmpResult:
		return "bool";
	case BeTypeCode_Function:
		return "void*";
	case BeTypeCode_Struct:
	case BeTypeCode_SizedArray:
	case BeTypeCode_Vector:
	case BeTypeCode_M128:
	case BeTypeCode_M256:
	case BeTypeCode_M512:
	default:
		return GetOpaqueCppType(type);
	}
}

static void AppendEscapedBlockComment(StringImpl& outStr, const StringImpl& commentText)
{
	outStr += "/*\n";
	for (int i = 0; i < (int)commentText.length(); i++)
	{
		char c = commentText[i];
		if ((c == '*') && (i + 1 < (int)commentText.length()) && (commentText[i + 1] == '/'))
		{
			outStr += "* /";
			i++;
			continue;
		}
		outStr += c;
	}
	outStr += "\n*/\n";
}

static String EscapeStringLiteral(const StringImpl& str)
{
	String out;
	out += '"';
	for (int i = 0; i < (int)str.length(); i++)
	{
		uint8 c = (uint8)str[i];
		switch (c)
		{
		case '\\': out += "\\\\"; break;
		case '"': out += "\\\""; break;
		case '\n': out += "\\n"; break;
		case '\r': out += "\\r"; break;
		case '\t': out += "\\t"; break;
		default:
			if (c < 32 || c >= 127)
				out += StrFormat("\\x%02X", c);
			else
				out += (char)c;
		}
	}
	out += '"';
	return out;
}

class CppEmitter
{
public:
	BeModule* mModule;
	String mOut;

	std::unordered_map<BeFunction*, String> mFunctionNames;
	std::unordered_map<BeGlobalVariable*, String> mGlobalNames;
	std::unordered_map<BeValue*, String> mValueNames;
	std::unordered_map<BeBlock*, int> mBlockIds;
	std::unordered_map<BeFunction*, std::vector<String>> mParamNames;
	std::unordered_map<BeAllocaInst*, String> mAllocaStorageNames;

	int mUniqueId;

public:
	CppEmitter(BeModule* beModule)
	{
		mModule = beModule;
		mUniqueId = 0;
	}

	String MakeUniqueName(const StringImpl& base)
	{
		String result = base;
		result += StrFormat("_%d", mUniqueId++);
		return result;
	}

	String GetFunctionName(BeFunction* beFunc)
	{
		auto itr = mFunctionNames.find(beFunc);
		if (itr != mFunctionNames.end())
			return itr->second;

		String name = MakeStableSymbolName(beFunc->mName, StrFormat("bf_fn_%d", (int)mFunctionNames.size()));
		mFunctionNames[beFunc] = name;
		return name;
	}

	String GetGlobalName(BeGlobalVariable* globalVar)
	{
		auto itr = mGlobalNames.find(globalVar);
		if (itr != mGlobalNames.end())
			return itr->second;

		String name = MakeStableSymbolName(globalVar->mName, StrFormat("bf_global_%d", (int)mGlobalNames.size()));
		mGlobalNames[globalVar] = name;
		return name;
	}

	String GetLinkNameSuffix(const StringImpl& originalName, const StringImpl& emittedName)
	{
		if (originalName == emittedName)
			return "";
		return StrFormat(" BF_LINKNAME(%s)", EscapeStringLiteral(originalName).c_str());
	}

	String GetFunctionLinkNameSuffix(BeFunction* beFunc)
	{
		if ((beFunc == NULL) || (beFunc->mLinkageType == BfIRLinkageType_Internal))
			return "";
		return GetLinkNameSuffix(beFunc->mName, GetFunctionName(beFunc));
	}

	String GetGlobalLinkNameSuffix(BeGlobalVariable* globalVar)
	{
		if ((globalVar == NULL) || (globalVar->mLinkageType == BfIRLinkageType_Internal))
			return "";
		return GetLinkNameSuffix(globalVar->mName, GetGlobalName(globalVar));
	}

	String GetValueName(BeValue* value)
	{
		auto itr = mValueNames.find(value);
		if (itr != mValueNames.end())
			return itr->second;

		if (auto arg = BeValueDynCast<BeArgument>(value))
		{
			auto func = mModule->mActiveFunction;
			auto& paramNames = mParamNames[func];
			if ((arg->mArgIdx >= 0) && (arg->mArgIdx < (int)paramNames.size()))
				return paramNames[arg->mArgIdx];
		}

		if (auto inst = BeValueDynCast<BeInst>(value))
		{
			String baseName = inst->mName != NULL ? String(inst->mName) : StrFormat("v%d", (int)mValueNames.size());
			String name = SanitizeIdentifier(baseName, "v");
			name = MakeUniqueName(name);
			mValueNames[value] = name;
			return name;
		}

		String unknown = MakeUniqueName("v_unknown");
		mValueNames[value] = unknown;
		return unknown;
	}

	BeFunctionType* GetFunctionType(BeValue* funcVal)
	{
		auto type = funcVal->GetType();
		while ((type != NULL) && (type->mTypeCode == BeTypeCode_Pointer))
			type = ((BePointerType*)type)->mElementType;
		if ((type != NULL) && (type->mTypeCode == BeTypeCode_Function))
			return (BeFunctionType*)type;
		return NULL;
	}

	String CastExpr(BeType* dstType, BeType* srcType, const StringImpl& expr)
	{
		if ((dstType == NULL) || (srcType == NULL))
			return expr;
		if (dstType == srcType)
			return expr;

		auto dstTypeName = GetCppType(dstType);

		if (IsPointerType(dstType))
		{
			if (IsPointerType(srcType))
				return StrFormat("reinterpret_cast<%s>(%s)", dstTypeName.c_str(), expr.c_str());
			return StrFormat("reinterpret_cast<%s>((uintptr_t)(%s))", dstTypeName.c_str(), expr.c_str());
		}

		if (IsPointerType(srcType))
			return StrFormat("static_cast<%s>((uintptr_t)(%s))", dstTypeName.c_str(), expr.c_str());

		if (IsScalarType(dstType) && IsScalarType(srcType))
			return StrFormat("static_cast<%s>(%s)", dstTypeName.c_str(), expr.c_str());

		return expr;
	}

	String GetZeroExpr(BeType* type)
	{
		if (type == NULL)
			return "0";

		auto typeName = GetCppType(type);
		if (IsPointerType(type))
			return "nullptr";
		if (IsBoolLikeType(type))
			return "false";
		if (IsIntegralType(type) || IsFloatType(type))
			return StrFormat("static_cast<%s>(0)", typeName.c_str());
		return StrFormat("%s{}", typeName.c_str());
	}

	String GetConstantExpr(BeConstant* constant)
	{
		auto type = constant->GetType();
		auto typeName = GetCppType(type);

		if (auto typeOfConst = BeValueDynCast<BeTypeOfConstant>(constant))
			return StrFormat("static_cast<%s>(%d)", typeName.c_str(), typeOfConst->mBfTypeId);

		if (auto stringConst = BeValueDynCast<BeStringConstant>(constant))
			return EscapeStringLiteral(stringConst->mString);

		if (auto castConst = BeValueDynCast<BeCastConstant>(constant))
		{
			String innerExpr = GetConstantExpr(castConst->mTarget);
			return CastExpr(castConst->mType, castConst->mTarget->GetType(), innerExpr);
		}

		if (auto gep1 = BeValueDynCast<BeGEP1Constant>(constant))
		{
			String baseExpr = GetConstantExpr(gep1->mTarget);
			return StrFormat("reinterpret_cast<%s>(reinterpret_cast<uint8_t*>(%s) + ((intptr_t)%d))",
				typeName.c_str(), baseExpr.c_str(), gep1->mIdx0 * GetStride(((BePointerType*)gep1->mTarget->GetType())->mElementType));
		}

		if (auto gep2 = BeValueDynCast<BeGEP2Constant>(constant))
		{
			String baseExpr = GetConstantExpr(gep2->mTarget);
			auto ptrType = (BePointerType*)gep2->mTarget->GetType();
			int byteOffset = gep2->mIdx0 * GetStride(ptrType->mElementType);
			if (ptrType->mElementType->mTypeCode == BeTypeCode_Struct)
			{
				auto structType = (BeStructType*)ptrType->mElementType;
				if ((gep2->mIdx1 >= 0) && (gep2->mIdx1 < (int)structType->mMembers.size()))
					byteOffset += structType->mMembers[gep2->mIdx1].mByteOffset;
			}
			else if (ptrType->mElementType->mTypeCode == BeTypeCode_SizedArray)
			{
				auto arrayType = (BeSizedArrayType*)ptrType->mElementType;
				byteOffset += gep2->mIdx1 * GetStride(arrayType->mElementType);
			}
			else if (ptrType->mElementType->mTypeCode == BeTypeCode_Vector)
			{
				auto vectorType = (BeVectorType*)ptrType->mElementType;
				byteOffset += gep2->mIdx1 * GetStride(vectorType->mElementType);
			}
			return StrFormat("reinterpret_cast<%s>(reinterpret_cast<uint8_t*>(%s) + ((intptr_t)%d))",
				typeName.c_str(), baseExpr.c_str(), byteOffset);
		}

		if (auto extractConst = BeValueDynCast<BeExtractValueConstant>(constant))
		{
			int byteOffset = GetAggregateElementByteOffset(extractConst->mTarget->GetType(), extractConst->mIdx0);
			String aggExpr = GetConstantExpr(extractConst->mTarget);
			String tmpName = MakeUniqueName("extract_const");
			return StrFormat("([]() -> %s { auto %s = %s; return *reinterpret_cast<%s*>(reinterpret_cast<uint8_t*>(&%s) + ((intptr_t)%d)); })()",
				typeName.c_str(), tmpName.c_str(), aggExpr.c_str(), typeName.c_str(), tmpName.c_str(), byteOffset);
		}

		if (auto structConst = BeValueDynCast<BeStructConstant>(constant))
		{
			if (structConst->mMemberValues.IsEmpty())
				return StrFormat("%s{}", typeName.c_str());
			return StrFormat("%s{}", typeName.c_str());
		}

		if (BeValueDynCast<BeUndefConstant>(constant) != NULL)
			return GetZeroExpr(type);

		if (IsPointerType(type))
		{
			if (constant->IsNull())
				return "nullptr";

			if (auto targetFunc = BeValueDynCast<BeFunction>(constant))
				return StrFormat("reinterpret_cast<%s>(&%s)", typeName.c_str(), GetFunctionName(targetFunc).c_str());
			if (auto targetGlobal = BeValueDynCast<BeGlobalVariable>(constant))
				return StrFormat("reinterpret_cast<%s>(&%s)", typeName.c_str(), GetGlobalName(targetGlobal).c_str());

			if (constant->mTarget != NULL)
			{
				bool isKnownTarget = false;
				for (auto beFunc : mModule->mFunctions)
				{
					if ((BeConstant*)beFunc == constant->mTarget)
					{
						isKnownTarget = true;
						break;
					}
				}
				if (!isKnownTarget)
				{
					for (auto globalVar : mModule->mGlobalVariables)
					{
						if ((BeConstant*)globalVar == constant->mTarget)
						{
							isKnownTarget = true;
							break;
						}
					}
				}

				if ((isKnownTarget) && (constant->mTarget != constant))
				{
					if (auto targetFunc = BeValueDynCast<BeFunction>(constant->mTarget))
						return StrFormat("reinterpret_cast<%s>(&%s)", typeName.c_str(), GetFunctionName(targetFunc).c_str());
					if (auto targetGlobal = BeValueDynCast<BeGlobalVariable>(constant->mTarget))
						return StrFormat("reinterpret_cast<%s>(&%s)", typeName.c_str(), GetGlobalName(targetGlobal).c_str());

					String targetExpr = GetConstantExpr(constant->mTarget);
					return StrFormat("reinterpret_cast<%s>(%s)", typeName.c_str(), targetExpr.c_str());
				}
			}

			return StrFormat("reinterpret_cast<%s>((uintptr_t)0x%llx)", typeName.c_str(), (unsigned long long)constant->mUInt64);
		}

		switch (type->mTypeCode)
		{
		case BeTypeCode_Boolean:
			return constant->mBool ? "true" : "false";
		case BeTypeCode_Int8:
			return StrFormat("static_cast<int8_t>(%d)", (int)constant->mInt8);
		case BeTypeCode_Int16:
			return StrFormat("static_cast<int16_t>(%d)", (int)constant->mInt16);
		case BeTypeCode_Int32:
			return StrFormat("static_cast<int32_t>(%d)", (int)constant->mInt32);
		case BeTypeCode_Int64:
			return StrFormat("static_cast<int64_t>(%s)", GetInt64LiteralExpr((int64)constant->mInt64).c_str());
		case BeTypeCode_Float:
			return StrFormat("static_cast<float>(%.9g)", (float)constant->mDouble);
		case BeTypeCode_Double:
			return StrFormat("static_cast<double>(%.17g)", constant->mDouble);
		default:
			return StrFormat("%s{}", typeName.c_str());
		}
	}

	bool RequiresRuntimeGlobalInit(BeConstant* constant)
	{
		if (constant == NULL)
			return false;
		if (BeValueDynCast<BeStructConstant>(constant) != NULL)
			return true;
		if (auto castConst = BeValueDynCast<BeCastConstant>(constant))
			return RequiresRuntimeGlobalInit(castConst->mTarget);
		return false;
	}

	String GetBytePtrExpr(const StringImpl& basePtrExpr, int byteOffset)
	{
		if (byteOffset == 0)
			return StrFormat("reinterpret_cast<uint8_t*>(%s)", basePtrExpr.c_str());
		return StrFormat("reinterpret_cast<uint8_t*>(%s) + ((intptr_t)%d)", basePtrExpr.c_str(), byteOffset);
	}

	void EmitConstantStore(BeConstant* constant, BeType* dstType, const StringImpl& basePtrExpr, int byteOffset)
	{
		if ((constant == NULL) || (dstType == NULL))
			return;

		if (auto castConst = BeValueDynCast<BeCastConstant>(constant))
		{
			if (dstType->IsComposite())
			{
				EmitConstantStore(castConst->mTarget, dstType, basePtrExpr, byteOffset);
				return;
			}
		}

		if (auto structConst = BeValueDynCast<BeStructConstant>(constant))
		{
			if (dstType->mTypeCode == BeTypeCode_Struct)
			{
				auto structType = (BeStructType*)dstType;
				int memberCount = BF_MIN((int)structConst->mMemberValues.size(), (int)structType->mMembers.size());
				for (int memberIdx = 0; memberIdx < memberCount; memberIdx++)
				{
					auto& member = structType->mMembers[memberIdx];
					EmitConstantStore(structConst->mMemberValues[memberIdx], member.mType, basePtrExpr, byteOffset + member.mByteOffset);
				}
				return;
			}
			if (dstType->mTypeCode == BeTypeCode_SizedArray)
			{
				auto arrayType = (BeSizedArrayType*)dstType;
				int stride = GetStride(arrayType->mElementType);
				int memberCount = BF_MIN((int)structConst->mMemberValues.size(), arrayType->mLength);
				for (int memberIdx = 0; memberIdx < memberCount; memberIdx++)
					EmitConstantStore(structConst->mMemberValues[memberIdx], arrayType->mElementType, basePtrExpr, byteOffset + memberIdx * stride);
				return;
			}
			if (dstType->mTypeCode == BeTypeCode_Vector)
			{
				auto vectorType = (BeVectorType*)dstType;
				int stride = GetStride(vectorType->mElementType);
				int memberCount = BF_MIN((int)structConst->mMemberValues.size(), vectorType->mLength);
				for (int memberIdx = 0; memberIdx < memberCount; memberIdx++)
					EmitConstantStore(structConst->mMemberValues[memberIdx], vectorType->mElementType, basePtrExpr, byteOffset + memberIdx * stride);
				return;
			}
		}

		if (BeValueDynCast<BeUndefConstant>(constant) != NULL)
			return;

		if (auto strConst = BeValueDynCast<BeStringConstant>(constant))
		{
			int targetSize = NormalizeSize(dstType->mSize);
			for (int i = 0; i < targetSize; i++)
			{
				uint8 c = 0;
				if (i < (int)strConst->mString.length())
					c = (uint8)strConst->mString[i];
				String dstPtrExpr = GetBytePtrExpr(basePtrExpr, byteOffset + i);
				mOut += StrFormat("\t*reinterpret_cast<uint8_t*>(%s) = static_cast<uint8_t>(0x%02X);\n", dstPtrExpr.c_str(), c);
			}
			return;
		}

		if (dstType->IsComposite())
			return;

		String dstPtrExpr = GetBytePtrExpr(basePtrExpr, byteOffset);
		String valueExpr = GetConstantExpr(constant);
		valueExpr = CastExpr(dstType, constant->GetType(), valueExpr);
		mOut += StrFormat("\t*reinterpret_cast<%s*>(%s) = %s;\n",
			GetCppType(dstType).c_str(), dstPtrExpr.c_str(), valueExpr.c_str());
	}

	String GetValueExpr(BeValue* value)
	{
		if (auto constant = BeValueDynCast<BeConstant>(value))
			return GetConstantExpr(constant);
		if (auto arg = BeValueDynCast<BeArgument>(value))
			return GetValueName(arg);
		if (auto globalVar = BeValueDynCast<BeGlobalVariable>(value))
			return StrFormat("&%s", GetGlobalName(globalVar).c_str());
		if (auto beFunc = BeValueDynCast<BeFunction>(value))
			return StrFormat("&%s", GetFunctionName(beFunc).c_str());
		if (auto intrin = BeValueDynCast<BeIntrinsic>(value))
			return StrFormat("/*intrin:%s*/nullptr", intrin->mName.c_str());
		if (auto inst = BeValueDynCast<BeInst>(value))
		{
			auto itr = mValueNames.find(inst);
			if (itr != mValueNames.end())
				return itr->second;

			// Some helper/metadata instructions may survive as operands without being materialized
			// as local declarations in the current function body.
			if (auto callInst = BeValueDynCast<BeCallInst>(inst))
			{
				if (callInst->mInlineResult != NULL)
					return GetValueExpr(callInst->mInlineResult);
			}
			if (auto aliasInst = BeValueDynCast<BeAliasValueInst>(inst))
				return GetValueExpr(aliasInst->mPtr);
			if (auto lifeFenceInst = BeValueDynCast<BeLifetimeFenceInst>(inst))
				return GetValueExpr(lifeFenceInst->mPtr);
			if (auto setCanMergeInst = BeValueDynCast<BeSetCanMergeInst>(inst))
				return GetValueExpr(setCanMergeInst->mVal);

			return GetValueName(inst);
		}
		return "0";
	}

	String GetIntrinsicBinaryExpr(BeCallInst* callInst, const char* op)
	{
		if (callInst->mArgs.size() < 2)
			return "0";
		auto lhs = GetValueExpr(callInst->mArgs[0].mValue);
		auto rhs = GetValueExpr(callInst->mArgs[1].mValue);
		return StrFormat("((%s) %s (%s))", lhs.c_str(), op, rhs.c_str());
	}

	const char* GetAtomicMemoryOrderExpr(int memoryKind)
	{
		switch (memoryKind & BfIRAtomicOrdering_ORDERMASK)
		{
		case BfIRAtomicOrdering_Unordered:
		case BfIRAtomicOrdering_Relaxed:
			return "std::memory_order_relaxed";
		case BfIRAtomicOrdering_Acquire:
			return "std::memory_order_acquire";
		case BfIRAtomicOrdering_Release:
			return "std::memory_order_release";
		case BfIRAtomicOrdering_AcqRel:
			return "std::memory_order_acq_rel";
		case BfIRAtomicOrdering_SeqCst:
		default:
			return "std::memory_order_seq_cst";
		}
	}

	int GetAtomicOrderingArg(BeCallInst* callInst, int argIdx)
	{
		if ((argIdx >= 0) && (argIdx < (int)callInst->mArgs.size()))
		{
			if (auto orderConst = BeValueDynCast<BeConstant>(callInst->mArgs[argIdx].mValue))
				return (int)orderConst->mInt64;
		}
		return BfIRAtomicOrdering_SeqCst;
	}

	String GetAtomicOrderingExpr(int orderKind)
	{
		return StrFormat("(%d)", orderKind & BfIRAtomicOrdering_ORDERMASK);
	}

	bool WantsAtomicModifiedResult(int orderKind)
	{
		return (orderKind & BfIRAtomicOrdering_ReturnModified) != 0;
	}

	String GetBinaryOpExpr(BeBinaryOpInst* binaryOpInst)
	{
		auto lhs = GetValueExpr(binaryOpInst->mLHS);
		auto rhs = GetValueExpr(binaryOpInst->mRHS);
		auto resultType = binaryOpInst->GetType();
		auto resultTypeName = GetCppType(resultType);
		auto unsignedCastType = GetUnsignedMathCastType(resultType);
		auto lhsUnsigned = StrFormat("(%s)(%s)", unsignedCastType, lhs.c_str());
		auto rhsUnsigned = StrFormat("(%s)(%s)", unsignedCastType, rhs.c_str());

		switch (binaryOpInst->mOpKind)
		{
		case BeBinaryOpKind_Add: return StrFormat("((%s) + (%s))", lhs.c_str(), rhs.c_str());
		case BeBinaryOpKind_Subtract: return StrFormat("((%s) - (%s))", lhs.c_str(), rhs.c_str());
		case BeBinaryOpKind_Multiply: return StrFormat("((%s) * (%s))", lhs.c_str(), rhs.c_str());
		case BeBinaryOpKind_SDivide: return StrFormat("((%s) / (%s))", lhs.c_str(), rhs.c_str());
		case BeBinaryOpKind_UDivide:
			return StrFormat("((%s)((%s) / (%s)))", resultTypeName.c_str(), lhsUnsigned.c_str(), rhsUnsigned.c_str());
		case BeBinaryOpKind_SModulus: return StrFormat("((%s) %% (%s))", lhs.c_str(), rhs.c_str());
		case BeBinaryOpKind_UModulus:
			return StrFormat("((%s)((%s) %% (%s)))", resultTypeName.c_str(), lhsUnsigned.c_str(), rhsUnsigned.c_str());
		case BeBinaryOpKind_BitwiseAnd: return StrFormat("((%s) & (%s))", lhs.c_str(), rhs.c_str());
		case BeBinaryOpKind_BitwiseOr: return StrFormat("((%s) | (%s))", lhs.c_str(), rhs.c_str());
		case BeBinaryOpKind_ExclusiveOr: return StrFormat("((%s) ^ (%s))", lhs.c_str(), rhs.c_str());
		case BeBinaryOpKind_LeftShift:
			return StrFormat("((%s)((%s) << (uint32_t)(%s)))", resultTypeName.c_str(), lhsUnsigned.c_str(), rhs.c_str());
		case BeBinaryOpKind_RightShift:
			return StrFormat("((%s)((%s) >> (uint32_t)(%s)))", resultTypeName.c_str(), lhsUnsigned.c_str(), rhs.c_str());
		case BeBinaryOpKind_ARightShift: return StrFormat("((%s) >> (uint32_t)(%s))", lhs.c_str(), rhs.c_str());
		case BeBinaryOpKind_Equality: return StrFormat("((%s) == (%s))", lhs.c_str(), rhs.c_str());
		case BeBinaryOpKind_InEquality: return StrFormat("((%s) != (%s))", lhs.c_str(), rhs.c_str());
		case BeBinaryOpKind_GreaterThan: return StrFormat("((%s) > (%s))", lhs.c_str(), rhs.c_str());
		case BeBinaryOpKind_LessThan: return StrFormat("((%s) < (%s))", lhs.c_str(), rhs.c_str());
		case BeBinaryOpKind_GreaterThanOrEqual: return StrFormat("((%s) >= (%s))", lhs.c_str(), rhs.c_str());
		case BeBinaryOpKind_LessThanOrEqual: return StrFormat("((%s) <= (%s))", lhs.c_str(), rhs.c_str());
		default:
			return "0";
		}
	}

		String GetCmpExpr(BeCmpInst* cmpInst)
		{
		auto lhs = GetValueExpr(cmpInst->mLHS);
		auto rhs = GetValueExpr(cmpInst->mRHS);
		auto lhsUnsignedCast = GetUnsignedCmpCastType(cmpInst->mLHS != NULL ? cmpInst->mLHS->GetType() : NULL);
		auto rhsUnsignedCast = GetUnsignedCmpCastType(cmpInst->mRHS != NULL ? cmpInst->mRHS->GetType() : NULL);
		auto lhsUnsigned = StrFormat("(%s)(%s)", lhsUnsignedCast, lhs.c_str());
		auto rhsUnsigned = StrFormat("(%s)(%s)", rhsUnsignedCast, rhs.c_str());

		switch (cmpInst->mCmpKind)
		{
		case BeCmpKind_SLT:
		case BeCmpKind_OLT:
			return StrFormat("((%s) < (%s))", lhs.c_str(), rhs.c_str());
		case BeCmpKind_SLE:
		case BeCmpKind_OLE:
			return StrFormat("((%s) <= (%s))", lhs.c_str(), rhs.c_str());
		case BeCmpKind_ULT:
			return StrFormat("((%s) < (%s))", lhsUnsigned.c_str(), rhsUnsigned.c_str());
		case BeCmpKind_ULE:
			return StrFormat("((%s) <= (%s))", lhsUnsigned.c_str(), rhsUnsigned.c_str());
		case BeCmpKind_EQ:
		case BeCmpKind_OEQ:
			return StrFormat("((%s) == (%s))", lhs.c_str(), rhs.c_str());
		case BeCmpKind_NE:
		case BeCmpKind_UNE:
			return StrFormat("((%s) != (%s))", lhs.c_str(), rhs.c_str());
		case BeCmpKind_SGT:
		case BeCmpKind_OGT:
			return StrFormat("((%s) > (%s))", lhs.c_str(), rhs.c_str());
		case BeCmpKind_SGE:
		case BeCmpKind_OGE:
			return StrFormat("((%s) >= (%s))", lhs.c_str(), rhs.c_str());
		case BeCmpKind_UGT:
			return StrFormat("((%s) > (%s))", lhsUnsigned.c_str(), rhsUnsigned.c_str());
		case BeCmpKind_UGE:
			return StrFormat("((%s) >= (%s))", lhsUnsigned.c_str(), rhsUnsigned.c_str());
		case BeCmpKind_Sign:
			return StrFormat("((%s) < 0)", lhs.c_str());
		default:
			return "false";
			}
		}

		String GetGEPExpr(BeGEPInst* gepInst)
		{
		auto ptrType = (BePointerType*)gepInst->mPtr->GetType();
		auto elemType = ptrType->mElementType;
		auto resultTypeName = GetCppType(gepInst->GetType());
		auto baseExpr = GetValueExpr(gepInst->mPtr);
		auto idx0Expr = GetValueExpr(gepInst->mIdx0);

		String offsetExpr;
		if (gepInst->mIdx1 == NULL)
		{
			offsetExpr = StrFormat("((intptr_t)(%s) * %d)", idx0Expr.c_str(), GetStride(elemType));
		}
		else
		{
			auto idx1Expr = GetValueExpr(gepInst->mIdx1);
			if (elemType->mTypeCode == BeTypeCode_Struct)
			{
				int memberOffset = 0;
				if (auto idx1Const = BeValueDynCast<BeConstant>(gepInst->mIdx1))
				{
					auto structType = (BeStructType*)elemType;
					int idx = (int)idx1Const->mInt64;
					if ((idx >= 0) && (idx < (int)structType->mMembers.size()))
						memberOffset = structType->mMembers[idx].mByteOffset;
				}
				offsetExpr = StrFormat("(((intptr_t)(%s) * %d) + %d)", idx0Expr.c_str(), GetStride(elemType), memberOffset);
			}
			else if (elemType->mTypeCode == BeTypeCode_SizedArray)
			{
				auto arrType = (BeSizedArrayType*)elemType;
				offsetExpr = StrFormat("(((intptr_t)(%s) * %d) + ((intptr_t)(%s) * %d))",
					idx0Expr.c_str(), GetStride(arrType), idx1Expr.c_str(), GetStride(arrType->mElementType));
			}
			else if (elemType->IsVector())
			{
				auto vecType = (BeVectorType*)elemType;
				offsetExpr = StrFormat("(((intptr_t)(%s) * %d) + ((intptr_t)(%s) * %d))",
					idx0Expr.c_str(), GetStride(vecType), idx1Expr.c_str(), GetStride(vecType->mElementType));
			}
			else
			{
				offsetExpr = "0";
			}
		}

		return StrFormat("reinterpret_cast<%s>(reinterpret_cast<uint8_t*>(%s) + %s)", resultTypeName.c_str(), baseExpr.c_str(), offsetExpr.c_str());
	}

	bool EmitIntrinsicCall(BeCallInst* callInst, BeIntrinsic* intrinsic, bool hasRet)
	{
		auto emitAssign = [&](const StringImpl& expr)
		{
			if (hasRet)
				mOut += StrFormat("\t%s = %s;\n", GetValueName(callInst).c_str(), expr.c_str());
			else
				mOut += StrFormat("\t%s;\n", expr.c_str());
		};

		auto emitAtomicRMW = [&](const char* fetchExpr, const char* modifiedExpr) -> bool
		{
			if (callInst->mArgs.size() < 2)
			{
				mOut += "\tstd::abort();\n";
				return true;
			}

			auto ptrTypeVal = callInst->mArgs[0].mValue->GetType();
			if ((ptrTypeVal == NULL) || (ptrTypeVal->mTypeCode != BeTypeCode_Pointer))
			{
				mOut += "\tstd::abort();\n";
				return true;
			}
			auto ptrType = (BePointerType*)ptrTypeVal;
			if (ptrType->mElementType == NULL)
			{
				mOut += "\tstd::abort();\n";
				return true;
			}

			auto elemType = ptrType->mElementType;
			String elemTypeName = GetCppType(elemType);
			String locExpr = GetValueExpr(callInst->mArgs[0].mValue);
			String valueExpr = CastExpr(elemType, callInst->mArgs[1].mValue->GetType(), GetValueExpr(callInst->mArgs[1].mValue));
			int orderKind = GetAtomicOrderingArg(callInst, 2);
			String orderExpr = GetAtomicOrderingExpr(orderKind);

			if (hasRet)
			{
				const char* opExpr = WantsAtomicModifiedResult(orderKind) ? modifiedExpr : fetchExpr;
				emitAssign(StrFormat("%s(reinterpret_cast<%s*>(%s), %s, %s)",
					opExpr, elemTypeName.c_str(), locExpr.c_str(), valueExpr.c_str(), orderExpr.c_str()));
			}
			else
			{
				mOut += StrFormat("\t(void)%s(reinterpret_cast<%s*>(%s), %s, %s);\n",
					modifiedExpr, elemTypeName.c_str(), locExpr.c_str(), valueExpr.c_str(), orderExpr.c_str());
			}
			return true;
		};

		switch (intrinsic->mKind)
		{
		case BfIRIntrinsic_MemSet:
			if (callInst->mArgs.size() >= 3)
				emitAssign(StrFormat("std::memset(%s, (int)%s, (size_t)%s)",
					GetValueExpr(callInst->mArgs[0].mValue).c_str(),
					GetValueExpr(callInst->mArgs[1].mValue).c_str(),
					GetValueExpr(callInst->mArgs[2].mValue).c_str()));
			else
				mOut += "\tstd::abort();\n";
			return true;
		case BfIRIntrinsic_MemCpy:
			if (callInst->mArgs.size() >= 3)
				emitAssign(StrFormat("std::memcpy(%s, %s, (size_t)%s)",
					GetValueExpr(callInst->mArgs[0].mValue).c_str(),
					GetValueExpr(callInst->mArgs[1].mValue).c_str(),
					GetValueExpr(callInst->mArgs[2].mValue).c_str()));
			else
				mOut += "\tstd::abort();\n";
			return true;
		case BfIRIntrinsic_MemMove:
			if (callInst->mArgs.size() >= 3)
				emitAssign(StrFormat("std::memmove(%s, %s, (size_t)%s)",
					GetValueExpr(callInst->mArgs[0].mValue).c_str(),
					GetValueExpr(callInst->mArgs[1].mValue).c_str(),
					GetValueExpr(callInst->mArgs[2].mValue).c_str()));
			else
				mOut += "\tstd::abort();\n";
			return true;
		case BfIRIntrinsic_Malloc:
			if ((callInst->mArgs.size() >= 1) && hasRet)
				emitAssign(StrFormat("std::malloc((size_t)%s)", GetValueExpr(callInst->mArgs[0].mValue).c_str()));
			else
				mOut += "\tstd::abort();\n";
			return true;
		case BfIRIntrinsic_Free:
			if (callInst->mArgs.size() >= 1)
				emitAssign(StrFormat("std::free(%s)", GetValueExpr(callInst->mArgs[0].mValue).c_str()));
			else
				mOut += "\tstd::abort();\n";
			return true;
		case BfIRIntrinsic_DebugTrap:
			mOut += "\tstd::abort();\n";
			return true;
		case BfIRIntrinsic_Abs:
			if ((callInst->mArgs.size() >= 1) && hasRet)
				emitAssign(StrFormat("std::abs(%s)", GetValueExpr(callInst->mArgs[0].mValue).c_str()));
			else
				mOut += "\tstd::abort();\n";
			return true;
		case BfIRIntrinsic_Sqrt:
			if ((callInst->mArgs.size() >= 1) && hasRet)
				emitAssign(StrFormat("std::sqrt(%s)", GetValueExpr(callInst->mArgs[0].mValue).c_str()));
			else
				mOut += "\tstd::abort();\n";
			return true;
		case BfIRIntrinsic_Sin:
			if ((callInst->mArgs.size() >= 1) && hasRet)
				emitAssign(StrFormat("std::sin(%s)", GetValueExpr(callInst->mArgs[0].mValue).c_str()));
			else
				mOut += "\tstd::abort();\n";
			return true;
		case BfIRIntrinsic_Cos:
			if ((callInst->mArgs.size() >= 1) && hasRet)
				emitAssign(StrFormat("std::cos(%s)", GetValueExpr(callInst->mArgs[0].mValue).c_str()));
			else
				mOut += "\tstd::abort();\n";
			return true;
		case BfIRIntrinsic_Add:
			if (hasRet)
				emitAssign(GetIntrinsicBinaryExpr(callInst, "+"));
			else
				mOut += "\tstd::abort();\n";
			return true;
		case BfIRIntrinsic_Sub:
			if (hasRet)
				emitAssign(GetIntrinsicBinaryExpr(callInst, "-"));
			else
				mOut += "\tstd::abort();\n";
			return true;
		case BfIRIntrinsic_Mul:
			if (hasRet)
				emitAssign(GetIntrinsicBinaryExpr(callInst, "*"));
			else
				mOut += "\tstd::abort();\n";
			return true;
			case BfIRIntrinsic_Div:
				if (hasRet)
					emitAssign(GetIntrinsicBinaryExpr(callInst, "/"));
				else
					mOut += "\tstd::abort();\n";
				return true;
			case BfIRIntrinsic_Cast:
				if ((callInst->mArgs.size() >= 1) && hasRet)
				{
					auto retType = callInst->GetType();
					auto argVal = callInst->mArgs[0].mValue;
					emitAssign(CastExpr(retType, argVal->GetType(), GetValueExpr(argVal)));
				}
				else
					mOut += "\tstd::abort();\n";
				return true;
				case BfIRIntrinsic_Mod:
					if (hasRet)
						emitAssign(GetIntrinsicBinaryExpr(callInst, "%"));
					else
						mOut += "\tstd::abort();\n";
				return true;
				case BfIRIntrinsic_AtomicAdd:
					return emitAtomicRMW("__atomic_fetch_add", "__atomic_add_fetch");
				case BfIRIntrinsic_AtomicSub:
					return emitAtomicRMW("__atomic_fetch_sub", "__atomic_sub_fetch");
				case BfIRIntrinsic_AtomicAnd:
					return emitAtomicRMW("__atomic_fetch_and", "__atomic_and_fetch");
				case BfIRIntrinsic_AtomicOr:
					return emitAtomicRMW("__atomic_fetch_or", "__atomic_or_fetch");
				case BfIRIntrinsic_AtomicXor:
					return emitAtomicRMW("__atomic_fetch_xor", "__atomic_xor_fetch");
				case BfIRIntrinsic_AtomicNAnd:
					return emitAtomicRMW("__atomic_fetch_nand", "__atomic_nand_fetch");
				case BfIRIntrinsic_AtomicLoad:
				{
					if (callInst->mArgs.empty())
					{
						mOut += "\tstd::abort();\n";
						return true;
					}

					auto ptrTypeVal = callInst->mArgs[0].mValue->GetType();
					if ((ptrTypeVal == NULL) || (ptrTypeVal->mTypeCode != BeTypeCode_Pointer))
					{
						mOut += "\tstd::abort();\n";
						return true;
					}
					auto ptrType = (BePointerType*)ptrTypeVal;
					if (ptrType->mElementType == NULL)
					{
						mOut += "\tstd::abort();\n";
						return true;
					}

					auto elemType = ptrType->mElementType;
					String elemTypeName = GetCppType(elemType);
					String locExpr = GetValueExpr(callInst->mArgs[0].mValue);
					int orderKind = GetAtomicOrderingArg(callInst, 1);
					String orderExpr = GetAtomicOrderingExpr(orderKind);
					String loadExpr = StrFormat("__atomic_load_n(reinterpret_cast<%s*>(%s), %s)",
						elemTypeName.c_str(), locExpr.c_str(), orderExpr.c_str());
					if (hasRet)
						emitAssign(loadExpr);
					else
						mOut += StrFormat("\t(void)%s;\n", loadExpr.c_str());
					return true;
				}
				case BfIRIntrinsic_AtomicStore:
				{
					if (callInst->mArgs.size() < 2)
					{
						mOut += "\tstd::abort();\n";
						return true;
					}

					auto ptrTypeVal = callInst->mArgs[0].mValue->GetType();
					if ((ptrTypeVal == NULL) || (ptrTypeVal->mTypeCode != BeTypeCode_Pointer))
					{
						mOut += "\tstd::abort();\n";
						return true;
					}
					auto ptrType = (BePointerType*)ptrTypeVal;
					if (ptrType->mElementType == NULL)
					{
						mOut += "\tstd::abort();\n";
						return true;
					}

					auto elemType = ptrType->mElementType;
					String elemTypeName = GetCppType(elemType);
					String locExpr = GetValueExpr(callInst->mArgs[0].mValue);
					String valueExpr = CastExpr(elemType, callInst->mArgs[1].mValue->GetType(), GetValueExpr(callInst->mArgs[1].mValue));
					int orderKind = GetAtomicOrderingArg(callInst, 2);
					String orderExpr = GetAtomicOrderingExpr(orderKind);
					mOut += StrFormat("\t__atomic_store_n(reinterpret_cast<%s*>(%s), %s, %s);\n",
						elemTypeName.c_str(), locExpr.c_str(), valueExpr.c_str(), orderExpr.c_str());
					if (hasRet)
						emitAssign(valueExpr);
					return true;
				}
				case BfIRIntrinsic_AtomicXChg:
				{
					if (callInst->mArgs.size() < 2)
					{
						mOut += "\tstd::abort();\n";
						return true;
					}

					auto ptrTypeVal = callInst->mArgs[0].mValue->GetType();
					if ((ptrTypeVal == NULL) || (ptrTypeVal->mTypeCode != BeTypeCode_Pointer))
					{
						mOut += "\tstd::abort();\n";
						return true;
					}
					auto ptrType = (BePointerType*)ptrTypeVal;
					if (ptrType->mElementType == NULL)
					{
						mOut += "\tstd::abort();\n";
						return true;
					}

					auto elemType = ptrType->mElementType;
					String elemTypeName = GetCppType(elemType);
					String locExpr = GetValueExpr(callInst->mArgs[0].mValue);
					String valueExpr = CastExpr(elemType, callInst->mArgs[1].mValue->GetType(), GetValueExpr(callInst->mArgs[1].mValue));
					int orderKind = GetAtomicOrderingArg(callInst, 2);
					String orderExpr = GetAtomicOrderingExpr(orderKind);
					String xchgExpr = StrFormat("__atomic_exchange_n(reinterpret_cast<%s*>(%s), %s, %s)",
						elemTypeName.c_str(), locExpr.c_str(), valueExpr.c_str(), orderExpr.c_str());
					if (hasRet)
					{
						if (WantsAtomicModifiedResult(orderKind))
							emitAssign(StrFormat("([&]() -> %s { (void)%s; return %s; })()", elemTypeName.c_str(), xchgExpr.c_str(), valueExpr.c_str()));
						else
							emitAssign(xchgExpr);
					}
					else
					{
						mOut += StrFormat("\t(void)%s;\n", xchgExpr.c_str());
					}
					return true;
				}
				case BfIRIntrinsic_AtomicCmpStore:
				case BfIRIntrinsic_AtomicCmpStore_Weak:
				case BfIRIntrinsic_AtomicCmpXChg:
					if (callInst->mArgs.size() >= 3)
				{
					auto cmpType = callInst->mArgs[1].mValue->GetType();
					String cmpTypeName = GetCppType(cmpType);
					String locExpr = GetValueExpr(callInst->mArgs[0].mValue);
					String cmpExpr = CastExpr(cmpType, callInst->mArgs[1].mValue->GetType(), GetValueExpr(callInst->mArgs[1].mValue));
					String valExpr = CastExpr(cmpType, callInst->mArgs[2].mValue->GetType(), GetValueExpr(callInst->mArgs[2].mValue));
					bool isWeak = intrinsic->mKind == BfIRIntrinsic_AtomicCmpStore_Weak;
					const char* weakExpr = isWeak ? "true" : "false";

					if (intrinsic->mKind == BfIRIntrinsic_AtomicCmpXChg)
					{
						emitAssign(StrFormat("([&]() -> %s { %s _expected = %s; __atomic_compare_exchange_n(reinterpret_cast<%s*>(%s), &_expected, %s, %s, __ATOMIC_SEQ_CST, __ATOMIC_SEQ_CST); return _expected; })()",
							cmpTypeName.c_str(), cmpTypeName.c_str(), cmpExpr.c_str(), cmpTypeName.c_str(), locExpr.c_str(), valExpr.c_str(), weakExpr));
					}
					else
					{
						emitAssign(StrFormat("([&]() -> bool { %s _expected = %s; return __atomic_compare_exchange_n(reinterpret_cast<%s*>(%s), &_expected, %s, %s, __ATOMIC_SEQ_CST, __ATOMIC_SEQ_CST); })()",
							cmpTypeName.c_str(), cmpExpr.c_str(), cmpTypeName.c_str(), locExpr.c_str(), valExpr.c_str(), weakExpr));
					}
				}
					else
						mOut += "\tstd::abort();\n";
					return true;
				case BfIRIntrinsic_AtomicFence:
				{
					if (callInst->mArgs.empty())
					{
						// Compiler barrier-only variant.
						emitAssign("std::atomic_signal_fence(std::memory_order_seq_cst)");
						return true;
					}

					const char* memoryOrderExpr = "std::memory_order_seq_cst";
					if (auto orderConst = BeValueDynCast<BeConstant>(callInst->mArgs[0].mValue))
						memoryOrderExpr = GetAtomicMemoryOrderExpr((int)orderConst->mInt64);
					emitAssign(StrFormat("std::atomic_thread_fence(%s)", memoryOrderExpr));
					return true;
				}
				default:
					mOut += StrFormat("\t// Unsupported intrinsic %s\n", intrinsic->mName.c_str());
					mOut += "\tstd::abort();\n";
					return true;
			}
	}

	String BuildFunctionPointerType(BeFunctionType* funcType)
	{
		String str;
		str += GetCppType(funcType->mReturnType);
		str += "(*)(";
		for (int i = 0; i < (int)funcType->mParams.size(); i++)
		{
			if (i != 0)
				str += ", ";
			str += GetCppType(funcType->mParams[i].mType);
		}
		if (funcType->mIsVarArg)
		{
			if (!funcType->mParams.IsEmpty())
				str += ", ";
			str += "...";
		}
		else if (funcType->mParams.IsEmpty())
		{
			str += "void";
		}
		str += ")";
		return str;
	}

	String BuildCallExpr(BeCallInst* callInst)
	{
		auto adjustCRuntimeArg = [&](const StringImpl& funcName, int argIdx, const StringImpl& argExpr) -> String
		{
			auto isStrToFloat = (funcName == "strtod") || (funcName == "strtof") || (funcName == "strtold");
			auto isStrToInt = (funcName == "strtol") || (funcName == "strtoll") || (funcName == "strtoul") || (funcName == "strtoull");
			if (isStrToFloat || isStrToInt)
			{
				if (argIdx == 0)
					return StrFormat("reinterpret_cast<const char*>(%s)", argExpr.c_str());
				if (argIdx == 1)
					return StrFormat("reinterpret_cast<char**>(%s)", argExpr.c_str());
			}
			return argExpr;
		};

		String callTarget;
		String targetFuncName;
		if (auto targetFunc = BeValueDynCast<BeFunction>(callInst->mFunc))
		{
			callTarget = GetFunctionName(targetFunc);
			targetFuncName = targetFunc->mName;
		}
		else
		{
			auto funcType = GetFunctionType(callInst->mFunc);
			if (funcType == NULL)
				return "(std::abort(), 0)";
			String funcTypeStr = BuildFunctionPointerType(funcType);
			callTarget = StrFormat("reinterpret_cast<%s>(%s)", funcTypeStr.c_str(), GetValueExpr(callInst->mFunc).c_str());
		}

		String expr = callTarget;
		if (targetFuncName == "select")
		{
			if (callInst->mArgs.size() == 5)
			{
				String a0 = GetValueExpr(callInst->mArgs[0].mValue);
				String a1 = GetValueExpr(callInst->mArgs[1].mValue);
				String a2 = GetValueExpr(callInst->mArgs[2].mValue);
				String a3 = GetValueExpr(callInst->mArgs[3].mValue);
				String a4 = GetValueExpr(callInst->mArgs[4].mValue);
				return StrFormat("reinterpret_cast<int(*)(int, void*, void*, void*, void*)>(&::select)((int)(%s), (void*)(%s), (void*)(%s), (void*)(%s), (void*)(%s))",
					a0.c_str(), a1.c_str(), a2.c_str(), a3.c_str(), a4.c_str());
			}
		}
		expr += "(";
		for (int argIdx = 0; argIdx < (int)callInst->mArgs.size(); argIdx++)
		{
			if (argIdx != 0)
				expr += ", ";
			String argExpr = GetValueExpr(callInst->mArgs[argIdx].mValue);
			if (!targetFuncName.IsEmpty())
				argExpr = adjustCRuntimeArg(targetFuncName, argIdx, argExpr);
			expr += argExpr;
		}
		expr += ")";
		return expr;
	}

	void EmitPhiAssignments(BeBlock* srcBlock, BeBlock* dstBlock)
	{
		for (auto inst : dstBlock->mInstructions)
		{
			auto phiInst = BeValueDynCast<BePhiInst>(inst);
			if (phiInst == NULL)
				break;

			BeValue* incomingVal = NULL;
			for (auto incoming : phiInst->mIncoming)
			{
				if (incoming->mBlock == srcBlock)
				{
					incomingVal = incoming->mValue;
					break;
				}
			}
			if (incomingVal == NULL)
				continue;

			String dstName = GetValueName(phiInst);
			String srcExpr = GetValueExpr(incomingVal);
			String assignExpr = CastExpr(phiInst->GetType(), incomingVal->GetType(), srcExpr);
			mOut += StrFormat("\t%s = %s;\n", dstName.c_str(), assignExpr.c_str());
		}
	}

	void EmitJump(BeBlock* srcBlock, BeBlock* dstBlock)
	{
		EmitPhiAssignments(srcBlock, dstBlock);
		mOut += StrFormat("\tgoto bb_%d;\n", mBlockIds[dstBlock]);
	}

	String BuildFunctionSignature(BeFunction* beFunc, bool createParamNames)
	{
		auto funcType = beFunc->GetFuncType();
		String sig;
		bool isEntryMain = (GetFunctionName(beFunc) == "main");

		if (beFunc->mLinkageType == BfIRLinkageType_Internal)
			sig += "static ";
		else if (isEntryMain)
		{
			// Keep standard C++ entry signature shape to avoid host compiler diagnostics.
		}
		else
			sig += "extern \"C\" ";

		sig += GetCppType(funcType->mReturnType);
		sig += " ";
		sig += GetFunctionName(beFunc);
		sig += "(";

		auto& paramNames = mParamNames[beFunc];
		if (createParamNames)
			paramNames.clear();
			for (int paramIdx = 0; paramIdx < (int)funcType->mParams.size(); paramIdx++)
			{
				if (paramIdx != 0)
					sig += ", ";
				String typeName = GetCppType(funcType->mParams[paramIdx].mType);
				if (typeName == "void")
					typeName = "void*";
				if (isEntryMain)
				{
					if (paramIdx == 0)
						typeName = "int";
				else if ((paramIdx == 1) && (typeName == "void*"))
					typeName = "char**";
			}
			String paramName;
			if (createParamNames)
			{
				String paramBase;
				if (paramIdx < (int)beFunc->mParams.size())
					paramBase = beFunc->mParams[paramIdx].mName;
				if (paramBase.IsEmpty())
					paramBase = StrFormat("p%d", paramIdx);
				paramName = SanitizeIdentifier(paramBase, StrFormat("p%d", paramIdx));
				paramName = MakeUniqueName(paramName);
				paramNames.push_back(paramName);
			}
			else if (paramIdx < (int)paramNames.size())
			{
				paramName = paramNames[paramIdx];
			}
			else
			{
				paramName = StrFormat("p%d", paramIdx);
			}
			sig += typeName;
			sig += " ";
			sig += paramName;
		}

		if (funcType->mIsVarArg)
		{
			if (!funcType->mParams.IsEmpty())
				sig += ", ";
			sig += "...";
		}
		else if (funcType->mParams.IsEmpty())
		{
			sig += "void";
		}

		sig += ")";
		return sig;
	}

	void EmitFunctionPrototype(BeFunction* beFunc)
	{
		if (IsKnownCRuntimeFunction(beFunc->mName))
			return;
		String sig = BuildFunctionSignature(beFunc, true);
		sig += GetFunctionLinkNameSuffix(beFunc);
		mOut += sig;
		mOut += ";\n";
	}

	void EmitFunctionBody(BeFunction* beFunc)
	{
		if (beFunc->IsDecl())
			return;

		mModule->mActiveFunction = beFunc;
		mValueNames.clear();
		mBlockIds.clear();
		mAllocaStorageNames.clear();

		mOut += BuildFunctionSignature(beFunc, false);
		mOut += "\n";

		int blockId = 0;
		for (auto block : beFunc->mBlocks)
			mBlockIds[block] = blockId++;

		std::vector<BeInst*> valueInsts;
		for (auto block : beFunc->mBlocks)
		{
			for (auto inst : block->mInstructions)
			{
				auto instType = inst->GetType();
				if ((instType != NULL) && (instType->mTypeCode != BeTypeCode_None))
				{
					GetValueName(inst);
					valueInsts.push_back(inst);
				}
				if (auto allocaInst = BeValueDynCast<BeAllocaInst>(inst))
				{
					mAllocaStorageNames[allocaInst] = MakeUniqueName("alloca_mem");
				}
			}
		}

		mOut += "{\n";

		for (auto inst : valueInsts)
		{
			auto typeName = GetCppType(inst->GetType());
			mOut += StrFormat("\t%s %s{};\n", typeName.c_str(), GetValueName(inst).c_str());
		}

		for (auto& kv : mAllocaStorageNames)
		{
			auto allocaInst = kv.first;
			auto storageName = kv.second;
			if (allocaInst->mArraySize == NULL)
			{
				mOut += StrFormat("\talignas(%d) uint8_t %s[%d];\n",
					NormalizeAlign(allocaInst->mAlign), storageName.c_str(), NormalizeSize(allocaInst->mType->mSize));
			}
			else
			{
				mOut += StrFormat("\tvoid* %s = nullptr;\n", storageName.c_str());
			}
		}

		if (!beFunc->mBlocks.IsEmpty())
			mOut += "\tgoto bb_0;\n";

		for (auto block : beFunc->mBlocks)
		{
			mOut += StrFormat("bb_%d:\n", mBlockIds[block]);

			bool hadTerminator = false;
			for (auto inst : block->mInstructions)
			{
				if (BeValueDynCast<BePhiInst>(inst) != NULL)
					continue;

				if (auto nopInst = BeValueDynCast<BeNopInst>(inst))
				{
					(void)nopInst;
					continue;
				}
				if (auto dbgDecl = BeValueDynCast<BeDbgDeclareInst>(inst))
				{
					(void)dbgDecl;
					continue;
				}
				if (auto objCheck = BeValueDynCast<BeObjectAccessCheckInst>(inst))
				{
					(void)objCheck;
					continue;
				}
				if (auto lifeStart = BeValueDynCast<BeLifetimeStartInst>(inst))
				{
					(void)lifeStart;
					continue;
				}
				if (auto lifeEnd = BeValueDynCast<BeLifetimeEndInst>(inst))
				{
					(void)lifeEnd;
					continue;
				}
				if (auto lifeSoftEnd = BeValueDynCast<BeLifetimeSoftEndInst>(inst))
				{
					(void)lifeSoftEnd;
					continue;
				}
				if (auto lifeExtend = BeValueDynCast<BeLifetimeExtendInst>(inst))
				{
					(void)lifeExtend;
					continue;
				}
				if (auto lifeFence = BeValueDynCast<BeLifetimeFenceInst>(inst))
				{
					(void)lifeFence;
					continue;
				}
				if (auto valueScopeRetain = BeValueDynCast<BeValueScopeRetainInst>(inst))
				{
					(void)valueScopeRetain;
					continue;
				}
				if (auto valueScopeEnd = BeValueDynCast<BeValueScopeEndInst>(inst))
				{
					(void)valueScopeEnd;
					continue;
				}
				if (auto setCanMerge = BeValueDynCast<BeSetCanMergeInst>(inst))
				{
					(void)setCanMerge;
					continue;
				}
				if (auto fenceInst = BeValueDynCast<BeFenceInst>(inst))
				{
					(void)fenceInst;
					continue;
				}
				if (auto ensureInst = BeValueDynCast<BeEnsureInstructionAtInst>(inst))
				{
					(void)ensureInst;
					continue;
				}

				if (auto undefInst = BeValueDynCast<BeUndefValueInst>(inst))
				{
					if (IsPointerType(undefInst->mType))
						mOut += StrFormat("\t%s = nullptr;\n", GetValueName(undefInst).c_str());
					else
						mOut += StrFormat("\t%s = %s{};\n", GetValueName(undefInst).c_str(), GetCppType(undefInst->mType).c_str());
					continue;
				}
				if (auto numericCastInst = BeValueDynCast<BeNumericCastInst>(inst))
				{
					auto fromType = numericCastInst->mValue->GetType();
					auto toType = numericCastInst->mToType;
					String valExpr = GetValueExpr(numericCastInst->mValue);
					String castExpr;

					// Be IR keeps integer widths but signedness lives on numeric casts.
					// Preserve zero/sign extension semantics explicitly for C++ emission.
					if (IsIntegralType(fromType) && (!numericCastInst->mValSigned))
					{
						auto fromUnsignedType = GetUnsignedMathCastType(fromType);
						valExpr = StrFormat("((%s)(%s))", fromUnsignedType, valExpr.c_str());
					}

					if (IsIntegralType(toType) && (!numericCastInst->mToSigned))
					{
						auto toUnsignedType = GetUnsignedMathCastType(toType);
						auto toTypeName = GetCppType(toType);
						String unsignedExpr = StrFormat("((%s)(%s))", toUnsignedType, valExpr.c_str());
						if (toTypeName != toUnsignedType)
							castExpr = StrFormat("((%s)(%s))", toTypeName.c_str(), unsignedExpr.c_str());
						else
							castExpr = unsignedExpr;
					}
					else
						castExpr = CastExpr(toType, fromType, valExpr);

					mOut += StrFormat("\t%s = %s;\n", GetValueName(numericCastInst).c_str(), castExpr.c_str());
					continue;
				}
				if (auto bitCastInst = BeValueDynCast<BeBitCastInst>(inst))
				{
					auto dstType = bitCastInst->mToType;
					auto srcType = bitCastInst->mValue->GetType();
					String valExpr = GetValueExpr(bitCastInst->mValue);
					String castExpr;
					if (IsPointerType(dstType) || IsPointerType(srcType))
						castExpr = CastExpr(dstType, srcType, valExpr);
					else
						castExpr = StrFormat("bf::BitCast<%s>(%s)", GetCppType(dstType).c_str(), valExpr.c_str());
					mOut += StrFormat("\t%s = %s;\n", GetValueName(bitCastInst).c_str(), castExpr.c_str());
					continue;
				}
				if (auto negInst = BeValueDynCast<BeNegInst>(inst))
				{
					mOut += StrFormat("\t%s = -(%s);\n", GetValueName(negInst).c_str(), GetValueExpr(negInst->mValue).c_str());
					continue;
				}
				if (auto notInst = BeValueDynCast<BeNotInst>(inst))
				{
					String notExpr = GetValueExpr(notInst->mValue);
					if (IsBoolLikeType(notInst->mValue->GetType()))
						mOut += StrFormat("\t%s = !(%s);\n", GetValueName(notInst).c_str(), notExpr.c_str());
					else
						mOut += StrFormat("\t%s = ~(%s);\n", GetValueName(notInst).c_str(), notExpr.c_str());
					continue;
				}
				if (auto binaryOpInst = BeValueDynCast<BeBinaryOpInst>(inst))
				{
					mOut += StrFormat("\t%s = %s;\n", GetValueName(binaryOpInst).c_str(), GetBinaryOpExpr(binaryOpInst).c_str());
					continue;
				}
				if (auto cmpInst = BeValueDynCast<BeCmpInst>(inst))
				{
					mOut += StrFormat("\t%s = %s;\n", GetValueName(cmpInst).c_str(), GetCmpExpr(cmpInst).c_str());
					continue;
				}
				if (auto allocaInst = BeValueDynCast<BeAllocaInst>(inst))
				{
					auto storageName = mAllocaStorageNames[allocaInst];
					if (allocaInst->mArraySize == NULL)
					{
						mOut += StrFormat("\t%s = reinterpret_cast<%s>(%s);\n", GetValueName(allocaInst).c_str(),
							GetCppType(allocaInst->GetType()).c_str(), storageName.c_str());
					}
					else
					{
						mOut += StrFormat("\t%s = std::malloc((size_t)(%s) * (size_t)%d);\n", storageName.c_str(),
							GetValueExpr(allocaInst->mArraySize).c_str(), NormalizeSize(allocaInst->mType->mSize));
						mOut += StrFormat("\t%s = reinterpret_cast<%s>(%s);\n", GetValueName(allocaInst).c_str(),
							GetCppType(allocaInst->GetType()).c_str(), storageName.c_str());
					}
					continue;
				}
				if (auto aliasInst = BeValueDynCast<BeAliasValueInst>(inst))
				{
					mOut += StrFormat("\t%s = %s;\n", GetValueName(aliasInst).c_str(), GetValueExpr(aliasInst->mPtr).c_str());
					continue;
				}
				if (auto valueScopeStart = BeValueDynCast<BeValueScopeStartInst>(inst))
				{
					mOut += StrFormat("\t%s = 0;\n", GetValueName(valueScopeStart).c_str());
					continue;
				}
				if (auto loadInst = BeValueDynCast<BeLoadInst>(inst))
				{
					auto loadType = loadInst->GetType();
					auto loadTypeName = GetCppType(loadType);
					mOut += StrFormat("\t%s = *reinterpret_cast<%s*>(%s);\n", GetValueName(loadInst).c_str(),
						loadTypeName.c_str(), GetValueExpr(loadInst->mTarget).c_str());
					continue;
				}
				if (auto storeInst = BeValueDynCast<BeStoreInst>(inst))
				{
					auto valType = storeInst->mVal->GetType();
					if (auto constVal = BeValueDynCast<BeConstant>(storeInst->mVal))
					{
						if (valType->IsComposite())
						{
							String dstPtrExpr = GetValueExpr(storeInst->mPtr);
							mOut += StrFormat("\tstd::memset(%s, 0, (size_t)%d);\n", dstPtrExpr.c_str(), NormalizeSize(valType->mSize));
							EmitConstantStore(constVal, valType, dstPtrExpr, 0);
							continue;
						}
					}
					mOut += StrFormat("\t*reinterpret_cast<%s*>(%s) = %s;\n", GetCppType(valType).c_str(),
						GetValueExpr(storeInst->mPtr).c_str(), CastExpr(valType, storeInst->mVal->GetType(), GetValueExpr(storeInst->mVal)).c_str());
					continue;
				}
				if (auto memSetInst = BeValueDynCast<BeMemSetInst>(inst))
				{
					mOut += StrFormat("\tstd::memset(%s, (int)%s, (size_t)%s);\n",
						GetValueExpr(memSetInst->mAddr).c_str(), GetValueExpr(memSetInst->mVal).c_str(), GetValueExpr(memSetInst->mSize).c_str());
					continue;
				}
				if (auto stackSaveInst = BeValueDynCast<BeStackSaveInst>(inst))
				{
					mOut += StrFormat("\t%s = nullptr;\n", GetValueName(stackSaveInst).c_str());
					continue;
				}
				if (auto stackRestoreInst = BeValueDynCast<BeStackRestoreInst>(inst))
				{
					(void)stackRestoreInst;
					continue;
				}
				if (auto gepInst = BeValueDynCast<BeGEPInst>(inst))
				{
					mOut += StrFormat("\t%s = %s;\n", GetValueName(gepInst).c_str(), GetGEPExpr(gepInst).c_str());
					continue;
				}
					if (auto extractInst = BeValueDynCast<BeExtractValueInst>(inst))
					{
						auto extractType = extractInst->GetType();
						int byteOffset = GetAggregateElementByteOffset(extractInst->mAggVal->GetType(), extractInst->mIdx);
						String aggExpr = GetValueExpr(extractInst->mAggVal);
						String aggCopyName = MakeUniqueName("extract_agg");
						mOut += StrFormat("\t{\n\t\tauto %s = %s;\n", aggCopyName.c_str(), aggExpr.c_str());
						mOut += StrFormat("\t\t%s = *reinterpret_cast<%s*>(reinterpret_cast<uint8_t*>(&%s) + ((intptr_t)%d));\n",
							GetValueName(extractInst).c_str(), GetCppType(extractType).c_str(), aggCopyName.c_str(), byteOffset);
						mOut += "\t}\n";
						continue;
					}
					if (auto insertInst = BeValueDynCast<BeInsertValueInst>(inst))
					{
						auto aggType = insertInst->mAggVal->GetType();
						auto memberType = insertInst->mMemberVal->GetType();
						int byteOffset = GetAggregateElementByteOffset(aggType, insertInst->mIdx);
						mOut += StrFormat("\t%s = %s;\n", GetValueName(insertInst).c_str(), GetValueExpr(insertInst->mAggVal).c_str());
						mOut += StrFormat("\t*reinterpret_cast<%s*>(reinterpret_cast<uint8_t*>(&%s) + ((intptr_t)%d)) = %s;\n",
							GetCppType(memberType).c_str(), GetValueName(insertInst).c_str(), byteOffset,
							CastExpr(memberType, insertInst->mMemberVal->GetType(), GetValueExpr(insertInst->mMemberVal)).c_str());
						continue;
					}
				if (auto callInst = BeValueDynCast<BeCallInst>(inst))
				{
					bool hasRet = callInst->GetType() != NULL && callInst->GetType()->mTypeCode != BeTypeCode_None;
					if (auto intrinsic = BeValueDynCast<BeIntrinsic>(callInst->mFunc))
					{
						EmitIntrinsicCall(callInst, intrinsic, hasRet);
					}
					else
					{
						if (auto targetFunc = BeValueDynCast<BeFunction>(callInst->mFunc))
						{
							if ((!hasRet) && IsImplicitEmptyCtorDecl(targetFunc))
								continue;
							String callExpr = BuildCallExpr(callInst);
							if (hasRet)
								mOut += StrFormat("\t%s = %s;\n", GetValueName(callInst).c_str(), callExpr.c_str());
							else
								mOut += StrFormat("\t%s;\n", callExpr.c_str());
						}
						else
						{
							auto funcType = GetFunctionType(callInst->mFunc);
							if (funcType == NULL)
							{
								mOut += "\tstd::abort();\n";
								continue;
							}

							String funcTypeStr = BuildFunctionPointerType(funcType);
							String fnPtrExpr = StrFormat("reinterpret_cast<%s>(%s)", funcTypeStr.c_str(), GetValueExpr(callInst->mFunc).c_str());
							String argsExpr;
							for (int argIdx = 0; argIdx < (int)callInst->mArgs.size(); argIdx++)
							{
								if (argIdx != 0)
									argsExpr += ", ";
								argsExpr += GetValueExpr(callInst->mArgs[argIdx].mValue);
							}

								if (hasRet)
								{
									auto retType = callInst->GetType();
									String retTypeName = GetCppType(retType);
									String retDefaultExpr;
									if (IsPointerType(retType))
										retDefaultExpr = StrFormat("static_cast<%s>(nullptr)", retTypeName.c_str());
									else if (IsScalarType(retType))
										retDefaultExpr = StrFormat("static_cast<%s>(0)", retTypeName.c_str());
									else
										retDefaultExpr = StrFormat("%s{}", retTypeName.c_str());
									mOut += StrFormat("\tif (%s != nullptr)\n", fnPtrExpr.c_str());
									mOut += StrFormat("\t\t%s = %s(%s);\n", GetValueName(callInst).c_str(), fnPtrExpr.c_str(), argsExpr.c_str());
									mOut += "\telse\n";
									mOut += StrFormat("\t\t%s = %s;\n", GetValueName(callInst).c_str(), retDefaultExpr.c_str());
								}
							else
							{
								mOut += StrFormat("\tif (%s != nullptr)\n", fnPtrExpr.c_str());
								mOut += StrFormat("\t\t%s(%s);\n", fnPtrExpr.c_str(), argsExpr.c_str());
							}
						}
					}
					if (callInst->mNoReturn)
					{
						mOut += "\tstd::abort();\n";
						hadTerminator = true;
						break;
					}
					continue;
				}
				if (auto brInst = BeValueDynCast<BeBrInst>(inst))
				{
					EmitJump(block, brInst->mTargetBlock);
					hadTerminator = true;
					break;
				}
				if (auto condBrInst = BeValueDynCast<BeCondBrInst>(inst))
				{
					mOut += StrFormat("\tif (%s)\n\t{\n", GetValueExpr(condBrInst->mCond).c_str());
					EmitPhiAssignments(block, condBrInst->mTrueBlock);
					mOut += StrFormat("\t\tgoto bb_%d;\n\t}\n\telse\n\t{\n", mBlockIds[condBrInst->mTrueBlock]);
					EmitPhiAssignments(block, condBrInst->mFalseBlock);
					mOut += StrFormat("\t\tgoto bb_%d;\n\t}\n", mBlockIds[condBrInst->mFalseBlock]);
					hadTerminator = true;
					break;
				}
				if (auto switchInst = BeValueDynCast<BeSwitchInst>(inst))
				{
					String switchExpr = GetValueExpr(switchInst->mValue);
					bool emittedCase = false;
					for (auto& switchCase : switchInst->mCases)
					{
						String condExpr = GetConstantExpr(switchCase.mValue);
						if (!emittedCase)
							mOut += StrFormat("\tif ((%s) == (%s))\n\t{\n", switchExpr.c_str(), condExpr.c_str());
						else
							mOut += StrFormat("\telse if ((%s) == (%s))\n\t{\n", switchExpr.c_str(), condExpr.c_str());
						EmitPhiAssignments(block, switchCase.mBlock);
						mOut += StrFormat("\t\tgoto bb_%d;\n\t}\n", mBlockIds[switchCase.mBlock]);
						emittedCase = true;
					}
					if (!emittedCase)
						mOut += "\t{\n";
					else
						mOut += "\telse\n\t{\n";
					EmitPhiAssignments(block, switchInst->mDefaultBlock);
					mOut += StrFormat("\t\tgoto bb_%d;\n\t}\n", mBlockIds[switchInst->mDefaultBlock]);
					hadTerminator = true;
					break;
				}
				if (auto retInst = BeValueDynCast<BeRetInst>(inst))
				{
					if (retInst->mRetValue != NULL)
					{
						mOut += StrFormat("\treturn %s;\n", GetValueExpr(retInst->mRetValue).c_str());
					}
					else
					{
						mOut += "\treturn;\n";
					}
					hadTerminator = true;
					break;
				}
				if (auto unreachableInst = BeValueDynCast<BeUnreachableInst>(inst))
				{
					(void)unreachableInst;
					mOut += "\tstd::abort();\n";
					hadTerminator = true;
					break;
				}

				mOut += StrFormat("\t// Unsupported instruction kind id=%d\n", inst->GetTypeId());
				mOut += "\tstd::abort();\n";
				hadTerminator = true;
				break;
			}

			if (!hadTerminator)
				mOut += "\tstd::abort();\n";
		}

		mOut += "}\n\n";
	}

	void EmitPreamble()
	{
		mOut += "// Auto-generated by Beef C++ backend (experimental)\n";
		mOut += "#include <cstddef>\n";
		mOut += "#include <cstdint>\n";
		mOut += "#include <cstdlib>\n";
		mOut += "#include <cstring>\n";
		mOut += "#include <atomic>\n";
		mOut += "#include <cmath>\n\n";
		mOut += "#if defined(_WIN32)\n";
		mOut += "extern \"C\" int select(int, void*, void*, void*, void*);\n";
		mOut += "#endif\n\n";
		mOut += "#if defined(_WIN32) && (defined(__clang__) || defined(__GNUC__))\n";
		mOut += "#define BF_LINKNAME(sym) __asm__(sym)\n";
		mOut += "#else\n";
		mOut += "#define BF_LINKNAME(sym)\n";
		mOut += "#endif\n\n";

		// Bridge char8/int8_t interop to C runtime parsing APIs without requiring per-call casts.
		mOut += "static inline double strtod(int8_t* str, int8_t** endPtr)\n";
		mOut += "{\n";
		mOut += "\treturn std::strtod(reinterpret_cast<const char*>(str), reinterpret_cast<char**>(endPtr));\n";
		mOut += "}\n";
		mOut += "static inline float strtof(int8_t* str, int8_t** endPtr)\n";
		mOut += "{\n";
		mOut += "\treturn std::strtof(reinterpret_cast<const char*>(str), reinterpret_cast<char**>(endPtr));\n";
		mOut += "}\n";
		mOut += "static inline long double strtold(int8_t* str, int8_t** endPtr)\n";
		mOut += "{\n";
		mOut += "\treturn std::strtold(reinterpret_cast<const char*>(str), reinterpret_cast<char**>(endPtr));\n";
		mOut += "}\n";
		mOut += "static inline long strtol(int8_t* str, int8_t** endPtr, int32_t base)\n";
		mOut += "{\n";
		mOut += "\treturn std::strtol(reinterpret_cast<const char*>(str), reinterpret_cast<char**>(endPtr), base);\n";
		mOut += "}\n";
		mOut += "static inline long long strtoll(int8_t* str, int8_t** endPtr, int32_t base)\n";
		mOut += "{\n";
		mOut += "\treturn std::strtoll(reinterpret_cast<const char*>(str), reinterpret_cast<char**>(endPtr), base);\n";
		mOut += "}\n";
		mOut += "static inline unsigned long strtoul(int8_t* str, int8_t** endPtr, int32_t base)\n";
		mOut += "{\n";
		mOut += "\treturn std::strtoul(reinterpret_cast<const char*>(str), reinterpret_cast<char**>(endPtr), base);\n";
		mOut += "}\n";
		mOut += "static inline unsigned long long strtoull(int8_t* str, int8_t** endPtr, int32_t base)\n";
		mOut += "{\n";
		mOut += "\treturn std::strtoull(reinterpret_cast<const char*>(str), reinterpret_cast<char**>(endPtr), base);\n";
		mOut += "}\n\n";

		mOut += "namespace bf\n";
		mOut += "{\n";
		mOut += "\ttemplate <size_t TSize, size_t TAlign>\n";
		mOut += "\tstruct alignas(TAlign) OpaqueValue\n";
		mOut += "\t{\n";
		mOut += "\t\tuint8_t mData[TSize > 0 ? TSize : 1];\n";
		mOut += "\t};\n\n";
		mOut += "\ttemplate <typename TTo, typename TFrom>\n";
		mOut += "\tinline TTo BitCast(const TFrom& from)\n";
		mOut += "\t{\n";
		mOut += "\t\tstatic_assert(sizeof(TTo) == sizeof(TFrom), \"BitCast requires same size\");\n";
		mOut += "\t\tTTo to{};\n";
		mOut += "\t\tstd::memcpy(&to, &from, sizeof(TTo));\n";
		mOut += "\t\treturn to;\n";
		mOut += "\t}\n";
		mOut += "}\n\n";

		mOut += "namespace bf_module\n";
		mOut += "{\n";
		mOut += "\t// Module: ";
		mOut += mModule->mModuleName;
		mOut += "\n";
		mOut += "\t// Target: ";
		mOut += mModule->mTargetTriple;
		mOut += "\n";
		mOut += "\t// CPU: ";
		mOut += mModule->mTargetCPU;
		mOut += "\n";
		mOut += "}\n\n";
	}

		void EmitGlobals()
		{
			// Forward declarations allow initializers to reference globals declared later.
			for (int globalIdx = 0; globalIdx < (int)mModule->mGlobalVariables.size(); globalIdx++)
			{
				auto globalVar = mModule->mGlobalVariables[globalIdx];
				String varName = GetGlobalName(globalVar);
				auto varType = GetCppType(globalVar->mType);
				auto varLinkSuffix = GetGlobalLinkNameSuffix(globalVar);

				if (globalVar->mLinkageType == BfIRLinkageType_Internal)
					continue;

				mOut += "extern \"C\" ";
				if (globalVar->mIsTLS)
					mOut += "thread_local ";
				mOut += varType;
				mOut += " ";
				mOut += varName;
				mOut += varLinkSuffix;
				mOut += ";\n";
			}
			mOut += "\n";

			auto isEarlyInternalGlobal = [&](BeGlobalVariable* globalVar) -> bool
			{
				if (globalVar->mLinkageType != BfIRLinkageType_Internal)
					return false;
				String varName = GetGlobalName(globalVar);
				return varName.StartsWith("__constMem") ||
					varName.StartsWith("__bfStrObj") ||
					varName.StartsWith("__allocData");
			};

			for (int passIdx = 0; passIdx < 2; passIdx++)
			{
				bool wantEarlyInternal = passIdx == 0;
				for (int globalIdx = 0; globalIdx < (int)mModule->mGlobalVariables.size(); globalIdx++)
				{
					auto globalVar = mModule->mGlobalVariables[globalIdx];
					String varName = GetGlobalName(globalVar);
					auto varType = GetCppType(globalVar->mType);
					auto varLinkSuffix = GetGlobalLinkNameSuffix(globalVar);

					if (globalVar->mStorageKind == BfIRStorageKind_Import)
						continue;
					if ((globalVar->mInitializer == NULL) && (globalVar->mLinkageType != BfIRLinkageType_Internal))
						continue;

					bool isEarlyInternal = isEarlyInternalGlobal(globalVar);
					if (isEarlyInternal != wantEarlyInternal)
						continue;

					bool isInternal = (globalVar->mLinkageType == BfIRLinkageType_Internal);
					if (!isInternal)
						mOut += "extern \"C\" ";
					if (globalVar->mAlign > 0)
						mOut += StrFormat("alignas(%d) ", NormalizeAlign(globalVar->mAlign));
					if (isInternal)
						mOut += "static ";
					if (globalVar->mIsTLS)
						mOut += "thread_local ";
					mOut += varType;
					mOut += " ";
					mOut += varName;
					mOut += varLinkSuffix;

					if (globalVar->mInitializer != NULL)
					{
						if (auto strConst = BeValueDynCast<BeStringConstant>(globalVar->mInitializer))
						{
							mOut += " = ";
							if (varType.StartsWith("::bf::OpaqueValue<"))
							{
								int targetSize = NormalizeSize(globalVar->mType->mSize);
								mOut += "{{";
								for (int i = 0; i < targetSize; i++)
								{
									if (i != 0)
										mOut += ", ";
									uint8 c = 0;
									if (i < (int)strConst->mString.length())
										c = (uint8)strConst->mString[i];
									mOut += StrFormat("0x%02X", c);
								}
								mOut += "}}";
							}
							else
							{
								mOut += EscapeStringLiteral(strConst->mString);
							}
						}
						else
						{
							mOut += " = ";
							mOut += GetConstantExpr(globalVar->mInitializer);
						}
					}
					else
					{
						mOut += " {}";
					}
					mOut += ";\n";
				}
			}
			mOut += "\n";
		}

	void EmitRuntimeGlobalInitializers()
	{
		Array<BeGlobalVariable*> runtimeInitGlobals;
		for (auto globalVar : mModule->mGlobalVariables)
		{
			if (globalVar->mStorageKind == BfIRStorageKind_Import)
				continue;
			if (globalVar->mInitializer == NULL)
				continue;
			if (!RequiresRuntimeGlobalInit(globalVar->mInitializer))
				continue;
			runtimeInitGlobals.Add(globalVar);
		}

		if (runtimeInitGlobals.IsEmpty())
			return;

		String moduleTag = SanitizeIdentifier(mModule->mModuleName, "module");
		String initFuncName = MakeStableSymbolName(StrFormat("__bf_init_globals_%s", moduleTag.c_str()), "__bf_init_globals");
		String initTypeName = MakeStableSymbolName(StrFormat("__bf_global_init_%s", moduleTag.c_str()), "__bf_global_init");
		String initVarName = MakeStableSymbolName(StrFormat("g_%s", moduleTag.c_str()), "g_init");

		mOut += StrFormat("static void %s()\n", initFuncName.c_str());
		mOut += "{\n";
		mOut += "\tstatic bool sInited = false;\n";
		mOut += "\tif (sInited)\n";
		mOut += "\t\treturn;\n";
		mOut += "\tsInited = true;\n";
		for (auto globalVar : runtimeInitGlobals)
		{
			String varName = GetGlobalName(globalVar);
			mOut += StrFormat("\tstd::memset(&%s, 0, (size_t)%d);\n", varName.c_str(), NormalizeSize(globalVar->mType->mSize));
			String basePtrExpr = StrFormat("&%s", varName.c_str());
			EmitConstantStore(globalVar->mInitializer, globalVar->mType, basePtrExpr, 0);
		}
		mOut += "}\n\n";

		mOut += "namespace\n";
		mOut += "{\n";
		mOut += StrFormat("\tstruct %s\n", initTypeName.c_str());
		mOut += "\t{\n";
		mOut += StrFormat("\t\t%s() { %s(); }\n", initTypeName.c_str(), initFuncName.c_str());
		mOut += "\t};\n";
		mOut += StrFormat("\t%s %s;\n", initTypeName.c_str(), initVarName.c_str());
		mOut += "}\n\n";
	}

	void EmitFunctions()
	{
		for (auto beFunc : mModule->mFunctions)
			EmitFunctionPrototype(beFunc);
		mOut += "\n";

		for (auto beFunc : mModule->mFunctions)
			EmitFunctionBody(beFunc);
	}

	void EmitIRDump()
	{
		String irStr = mModule->ToString();
		mOut += "#if 0\n";
		mOut += "// Original Beef backend IR dump\n";
		AppendEscapedBlockComment(mOut, irStr);
		mOut += "#endif\n";
	}

		bool Generate(const StringImpl& outFileName, StringImpl& outError)
		{
			EmitPreamble();
			EmitGlobals();
			EmitFunctions();
			EmitRuntimeGlobalInitializers();
			EmitIRDump();

			String outDir = GetFileDir(outFileName);
			std::error_code fsErr;
			if (!outDir.IsEmpty())
				std::filesystem::create_directories(outDir.c_str(), fsErr);

			FileStream fs;
			if (!fs.Open(outFileName, "w"))
			{
				outError = StrFormat("Unable to open output file for writing (out='%s', dir='%s', dirExists=%d, mkdirErr='%s')",
					outFileName.c_str(), outDir.c_str(), (int)DirectoryExists(outDir), fsErr.message().c_str());
				return false;
			}
		fs.WriteSNZ(mOut);
		outError.clear();
		return true;
	}
};
} // namespace

bool BeCppCodeGen::Generate(BeModule* beModule, const StringImpl& outFileName, StringImpl& outError)
{
	CppEmitter emitter(beModule);
	return emitter.Generate(outFileName, outError);
}
