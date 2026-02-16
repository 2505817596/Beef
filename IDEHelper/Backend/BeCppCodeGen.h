#pragma once

#include "../Beef/BfCommon.h"
#include "BeModule.h"

NS_BF_BEGIN

class BeCppCodeGen
{
public:
	bool Generate(BeModule* beModule, const StringImpl& outFileName, StringImpl& outError);
};

NS_BF_END
