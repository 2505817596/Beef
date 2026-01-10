Func Syntax & Editor Fix Notes

Overview
- Add support for func-style method declarations alongside existing syntax.
- Keep compatibility by only treating "func:" as a keyword at the lexer level, while
  allowing "func" without a colon to be recognized as a method keyword in member context.
- Add "import" as a synonym for "using".
- Fix IDE squiggle persistence by clearing compiler flags before injecting new errors.

Key Changes
- Lexer: "func:" is recognized as BfToken_Function (whitespace allowed before ':').
- Lexer: "import" is accepted as an alias for "using" (same token).
- Reducer: "func:mod1:mod2" parses into method modifiers.
- Reducer: identifier "func" is treated as a function keyword when parsing type members,
  so "func void Test()" is accepted without editor errors.
- Autocomplete: add "func" token suggestions.
- Autocomplete: add "import" token suggestions.
- IDE: clear compiler error flags before applying the latest error list to avoid stale squiggles.

Files Touched
- IDEHelper/Compiler/BfParser.cpp
- IDEHelper/Compiler/BfParser.h
- IDEHelper/Compiler/BfReducer.cpp
- IDEHelper/Compiler/BfAutoComplete.cpp
- IDE/src/ui/SourceViewPanel.bf

Detailed Implementation Notes
1) Lexer rules
   - In BfParser::NextToken, map:
     - "func" to BfToken_Function only when the next non-whitespace char is ':'.
       This keeps "func" usable as an identifier in non-method contexts.
     - "import" to BfToken_Using, matching "using" behavior.

2) Reducer (method parsing)
   - Add a method-declaration branch for BfToken_Function when the token text is "func".
   - Parse optional "func:mod1:mod2" modifier chain:
     - Support standard method modifiers (public/private/protected/internal/static/virtual/override/abstract/concrete/extern/new/mut/readonly).
     - Reuse existing member modifier validation where applicable.
   - Continue with return type and method name parsing as usual.
   - Add a member-level fallback: if the current node is an identifier "func", replace it
     with a BfToken_Function and re-enter ReadTypeMember, enabling "func void Test()".

3) Autocomplete
   - Add "func" to token suggestions.
   - Add "import" to token suggestions (treated as "using").

4) IDE squiggle persistence
   - In SourceViewPanel.InjectErrors, clear compiler error flags on the target char data
     before applying the latest error list. This prevents transient edit errors from
     leaving permanent red squiggles after undo/redo.

Behavior Summary
- Supported:
  - func:private:static void Test() { }
  - func void Test() { }
  - import System;
  - using System;
- Compatibility:
  - "func" remains a valid identifier outside of member declarations.
  - "import" is a direct alias of "using" (same token in parser).

Rebuild Notes
- Rebuild IDEHelper then IDE for parser/autocomplete/editor changes to take effect.

Build Steps
1) bin\msbuild.bat IDEHelper\IDEHelper.vcxproj /p:Configuration=Release /p:Platform=x64 /p:SolutionDir=%cd%\\ /v:m
2) IDE\dist\BeefBuild.exe -proddir=IDE -config=Release -platform=Win64
