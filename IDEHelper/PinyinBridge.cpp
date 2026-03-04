#include "BeefySysLib/Common.h"
#include "Beef/BfCommon.h"

#include "third_party/cpp-pinyin-main/include/cpp-pinyin/G2pglobal.h"
#include "third_party/cpp-pinyin-main/include/cpp-pinyin/Pinyin.h"

#include <cctype>
#include <filesystem>
#include <memory>
#include <mutex>
#include <string>

USING_NS_BF;

namespace
{
	std::once_flag gPinyinInitOnce;
	std::unique_ptr<Pinyin::Pinyin> gPinyin;
	std::mutex gPinyinLock;
	bool gPinyinReady = false;

	bool IsHanziCodePoint(uint32 codePoint)
	{
		return ((codePoint >= 0x3400) && (codePoint <= 0x9FFF));
	}

	bool AppendCodePointUtf8(uint32 codePoint, std::string& outUtf8)
	{
		if (codePoint <= 0x7F)
		{
			outUtf8.push_back((char)codePoint);
			return true;
		}
		if (codePoint <= 0x7FF)
		{
			outUtf8.push_back((char)(0xC0 | (codePoint >> 6)));
			outUtf8.push_back((char)(0x80 | (codePoint & 0x3F)));
			return true;
		}
		if (codePoint <= 0xFFFF)
		{
			outUtf8.push_back((char)(0xE0 | (codePoint >> 12)));
			outUtf8.push_back((char)(0x80 | ((codePoint >> 6) & 0x3F)));
			outUtf8.push_back((char)(0x80 | (codePoint & 0x3F)));
			return true;
		}
		if (codePoint <= 0x10FFFF)
		{
			outUtf8.push_back((char)(0xF0 | (codePoint >> 18)));
			outUtf8.push_back((char)(0x80 | ((codePoint >> 12) & 0x3F)));
			outUtf8.push_back((char)(0x80 | ((codePoint >> 6) & 0x3F)));
			outUtf8.push_back((char)(0x80 | (codePoint & 0x3F)));
			return true;
		}
		return false;
	}

	std::filesystem::path GetModuleDir()
	{
#ifdef BF_PLATFORM_WINDOWS
		HMODULE moduleHandle = NULL;
		if (::GetModuleHandleExA(GET_MODULE_HANDLE_EX_FLAG_FROM_ADDRESS | GET_MODULE_HANDLE_EX_FLAG_UNCHANGED_REFCOUNT,
			(LPCSTR)&GetModuleDir, &moduleHandle) != 0)
		{
			char modulePath[MAX_PATH] = { 0 };
			uint32 modulePathLen = ::GetModuleFileNameA(moduleHandle, modulePath, MAX_PATH);
			if (modulePathLen > 0)
				return std::filesystem::path(std::string(modulePath, modulePathLen)).parent_path();
		}
#endif
		return std::filesystem::current_path();
	}

	std::filesystem::path FindDictionaryPath()
	{
		const std::filesystem::path moduleDictPath = GetModuleDir() / "dict";
		if (std::filesystem::exists(moduleDictPath / "mandarin" / "word.txt"))
			return moduleDictPath;

		const std::filesystem::path sourceDictPath = std::filesystem::path(__FILE__).parent_path() / "third_party" / "cpp-pinyin-main" / "res" / "dict";
		if (std::filesystem::exists(sourceDictPath / "mandarin" / "word.txt"))
			return sourceDictPath;

		const std::filesystem::path cwdDictPath = std::filesystem::current_path() / "IDEHelper" / "third_party" / "cpp-pinyin-main" / "res" / "dict";
		if (std::filesystem::exists(cwdDictPath / "mandarin" / "word.txt"))
			return cwdDictPath;

		return std::filesystem::path();
	}

	void InitPinyin()
	{
		const std::filesystem::path dictPath = FindDictionaryPath();
		if (dictPath.empty())
			return;

		Pinyin::setDictionaryPath(dictPath);

		auto pinyin = std::make_unique<Pinyin::Pinyin>();
		if (!pinyin->initialized())
			return;

		gPinyin = std::move(pinyin);
		gPinyinReady = true;
	}

	char GetInitialFromPinyin(const std::string& pinyin)
	{
		for (char c : pinyin)
		{
			if (std::isalpha((uint8)c) != 0)
				return (char)std::tolower((uint8)c);
		}
		return 0;
	}
}

BF_EXPORT char BF_CALLTYPE IDEHelper_GetPinyinInitial(int32 codePoint)
{
	if (!IsHanziCodePoint((uint32)codePoint))
		return 0;

	std::call_once(gPinyinInitOnce, InitPinyin);
	if ((!gPinyinReady) || (gPinyin == nullptr))
		return 0;

	std::string hanzi;
	hanzi.reserve(4);
	if (!AppendCodePointUtf8((uint32)codePoint, hanzi))
		return 0;

	std::lock_guard<std::mutex> lock(gPinyinLock);
	const auto pinyinList = gPinyin->getDefaultPinyin(hanzi, Pinyin::ManTone::Style::NORMAL, false, false);
	if (pinyinList.empty())
		return 0;

	return GetInitialFromPinyin(pinyinList[0]);
}
