using System;
using System.Collections;
using System.Text;
using System.Threading.Tasks;
using System.Diagnostics;
using System.IO;
using Beefy;
using Beefy.gfx;
using Beefy.events;
using Beefy.widgets;
using Beefy.theme.dark;
using Beefy.geom;
using Beefy.utils;
using IDE.Compiler;

namespace IDE.ui
{
	class DocumentationParser
	{
		public String mDocString = new String(256) ~ delete _;
		public String mBriefString ~ delete _;
		public String mAuthorString ~ delete _;
		public String mReturnString ~ delete _;
		public String mRemarksString ~ delete _;
		public String mNoteString ~ delete _;
		public String mTODOString ~ delete _;
		public String mSeeAlsoString ~ delete _;
		public String mVersionString ~ delete _;
		public Dictionary<String, String> mParamInfo ~ DeleteDictionaryAndKeysAndValues!(_);

		public String ShowDocString
		{
			get
			{
				return mBriefString ?? mDocString;
			}
		}

		public this(StringView info)
		{
			bool atLineStart = true;
			bool lineHadStar = false;
			int blockDepth = 0;
			bool queuedSpace = false;
			bool docStringDone = false;
			bool lineHadContent = false;
			String curDocStr = null;

			// Helper function to support adding various documentation strings without bloating code size
			[System.Inline]
			void AddPragma(ref String resultString, StringView pragma, StringSplitEnumerator splitEnum)
			{
				if (resultString == null)
					resultString = new String(pragma.Length);
				else if (resultString != null)
				{
					if (!resultString[resultString.Length - 1].IsWhiteSpace)
						resultString.Append(" ");
				}
				var briefStr = StringView(pragma, splitEnum.MatchPos + 1);
				briefStr.Trim();
				resultString.Append(briefStr);
				curDocStr = resultString;
				lineHadContent = true;
			}

			for (int idx = 0; idx < info.Length; idx++)
			{
				char8 c = info[idx];
				char8 nextC = 0;
				if (idx < info.Length - 1)
					nextC = info[idx + 1];

				if ((c == '/') && (nextC == '*'))
				{
					idx++;
					blockDepth++;

					if ((idx < info.Length - 1) && (info[idx + 1] == '*'))
					{
						idx++;
						if ((idx < info.Length - 1) && (info[idx + 1] == '<'))
							idx++;
					}

					continue;
				}

				if ((c == '*') && (nextC == '/'))
				{
					idx++;
					blockDepth--;
					continue;
				}

				if (c == '\x03') // \n
				{
					if (!lineHadContent)
					{
						if (curDocStr != null)
							curDocStr = null;
						else if (!mDocString.IsEmpty)
							docStringDone = true;
					}	
					queuedSpace = false;
					atLineStart = true;
					lineHadStar = false;
					lineHadContent = false;
					continue;
				}

				if ((c == '\x04') || (c == '\x05'))
				{
					queuedSpace = false;
					atLineStart = true;
					lineHadStar = false;
					lineHadContent = false;
					mDocString.Append('\n');
					if (c == '\x05')
						mDocString.Append("  ");
					continue;
				}

				if (atLineStart)
				{
					if ((c == '*') && (blockDepth > 0) && (!lineHadStar))
					{
						lineHadStar = false;
						continue;
					}

					if ((c == '/') && (!lineHadStar))
					{
						if ((nextC == '<') && (!queuedSpace))
						{
							idx++;
						}
						// Ignore any amount of '/' strings at a line start
						continue;
					}

					if ((c == '@') || (c == '\\'))
					{
						int pragmaEndPos = info.IndexOf('\x03', idx);
						if (pragmaEndPos == -1)
							pragmaEndPos = info.Length;
						StringView pragma = .(info, idx + 1, pragmaEndPos - idx - 1);
						var splitEnum = pragma.Split(' ');
						if (splitEnum.GetNext() case .Ok(var pragmaName))
						{
							if (pragmaName == "param")
							{
								if (splitEnum.GetNext() case .Ok(var paramName))
								{
									if (mParamInfo == null)
										mParamInfo = new .();
									curDocStr = new String(pragma, Math.Min(splitEnum.MatchPos + 1, pragma.Length));
									curDocStr.Trim();

									if (mParamInfo.TryAddAlt(paramName, var keyPtr, var valuePtr))
									{
										*keyPtr = new String(paramName);
										*valuePtr = curDocStr;
										lineHadContent = true;
									}
									else
									{
										defer:: delete curDocStr;
									}
								}
							}
							else if (pragmaName == "brief")
							{
								AddPragma(ref mBriefString, pragma, splitEnum);
							}
							else if (pragmaName == "author")
							{
								AddPragma(ref mAuthorString, pragma, splitEnum);
							}
							else if (pragmaName == "return" || pragmaName == "retVal")
							{
								AddPragma(ref mReturnString, pragma, splitEnum);
							}
							else if (pragmaName == "remarks")
							{
								AddPragma(ref mRemarksString, pragma, splitEnum);
							}
							else if (pragmaName == "note")
							{
								AddPragma(ref mNoteString, pragma, splitEnum);
							}
							else if (pragmaName == "todo" || pragmaName == "TODO")
							{
								AddPragma(ref mTODOString, pragma, splitEnum);
							}
							else if (pragmaName == "see")
							{
								AddPragma(ref mSeeAlsoString, pragma, splitEnum);
							}
							else if (pragmaName == "version")
							{
								AddPragma(ref mVersionString, pragma, splitEnum);
							}
						}

						idx = pragmaEndPos - 1;
						continue;
					}

					if (c.IsWhiteSpace)
					{
						continue;
					}
					else
					{
						queuedSpace = true;
						atLineStart = false;
					}
				}

				if (c.IsWhiteSpace)
				{
					queuedSpace = true;
					continue;
				}

				if ((curDocStr != null) && (docStringDone))
					continue;

				String docStr = curDocStr ?? mDocString;
				if (queuedSpace)
				{
					if (!docStr.IsEmpty)
					{
						char8 endC = docStr[docStr.Length - 1];
						if (!endC.IsWhiteSpace)
							docStr.Append(" ");
					}
					queuedSpace = false;
				}
				lineHadContent = true;
				docStr.Append(c);
			}
		}
	}

    public class AutoComplete
    {
		public const uint32 C_POPUP_BG = 0xFF252526;
		public const uint32 C_POPUP_BORDER = 0xFF454545;
		public const uint32 C_POPUP_SHADOW = 0x80000000;
		public const uint32 C_POPUP_ACCENT = 0xFF9E57A0;
		public const uint32 C_ROW_SELECTED_BG = 0xFF37373D;
		public const uint32 C_ROW_SELECTED_BORDER = 0xFF3F3F46;
		public const uint32 C_ENTRY_TEXT = 0xFFD4D4D4;
		public const uint32 C_ENTRY_MATCH = 0xFF1FA8FF;
		public const uint32 C_ENTRY_KIND = 0xFF8E96A6;
		public const uint32 C_ICON_METHOD = 0xFFC586C0;
		public const uint32 C_ICON_FIELD = 0xFF75BEFF;
		public const uint32 C_ICON_TYPE = 0xFFEE9D28;
		public const uint32 C_ICON_NAMESPACE = 0xFF4EC9B0;
		public const uint32 C_ICON_ENUM = 0xFFDCDCAA;

		static Font sCodiconFont;
		static bool sTriedLoadCodiconFont;
		public static bool sTraceEnabled = false;

		public static void Trace(StringView msg)
		{
			if (!sTraceEnabled)
				return;

			String logPath = scope .();
			logPath.Append(BFApp.sApp.mInstallDir, "autocomplete_trace.log");
			String line = scope .();
			line.Append(msg);
			line.Append('\n');
			File.WriteAllText(logPath, line, true);
		}

		public static Font GetCodiconFont()
		{
			if (sTriedLoadCodiconFont)
				return sCodiconFont;
			sTriedLoadCodiconFont = true;

			String codiconPath = scope .();
			codiconPath.Append(BFApp.sApp.mInstallDir, "fonts/codicon.ttf");
			if (!File.Exists(codiconPath))
				return null;

			Font codiconFont = new Font();
			if (!codiconFont.Load(codiconPath, 15.0f * DarkTheme.sScale))
			{
				delete codiconFont;
				return null;
			}

			sCodiconFont = codiconFont;
			return sCodiconFont;
		}

		public static bool TryGetCodiconForEntryType(StringView entryType, out char32 iconGlyph, out uint32 iconColor)
		{
			iconGlyph = '\0';
			iconColor = C_ENTRY_KIND;
			if (entryType.IsEmpty)
				return false;

			switch (entryType)
			{
			case "method":
				iconGlyph = (char32)0xEA8C; // symbol-method
				iconColor = C_ICON_METHOD;
				return true;
			case "extmethod":
				iconGlyph = (char32)0xEC41; // symbol-method-arrow
				iconColor = C_ICON_METHOD;
				return true;
			case "field":
				iconGlyph = (char32)0xEB5F; // symbol-field
				iconColor = C_ICON_FIELD;
				return true;
			case "property":
				iconGlyph = (char32)0xEB65; // symbol-property
				iconColor = C_ICON_FIELD;
				return true;
			case "namespace":
				iconGlyph = (char32)0xEA8B; // symbol-namespace
				iconColor = C_ICON_NAMESPACE;
				return true;
			case "class":
				iconGlyph = (char32)0xEB5B; // symbol-class
				iconColor = C_ICON_TYPE;
				return true;
			case "interface":
				iconGlyph = (char32)0xEB61; // symbol-interface
				iconColor = C_ICON_TYPE;
				return true;
			case "valuetype":
				iconGlyph = (char32)0xEA91; // symbol-struct
				iconColor = C_ICON_TYPE;
				return true;
			case "payloadEnum":
				iconGlyph = (char32)0xEA95; // symbol-enum
				iconColor = C_ICON_ENUM;
				return true;
			case "constant":
				iconGlyph = (char32)0xEB5D; // symbol-constant
				iconColor = C_ICON_ENUM;
				return true;
			case "parameter":
				iconGlyph = (char32)0xEA92; // symbol-parameter
				iconColor = C_ICON_FIELD;
				return true;
			case "variable", "value":
				iconGlyph = (char32)0xEA88; // symbol-variable
				iconColor = C_ICON_FIELD;
				return true;
			case "object", "generic":
				iconGlyph = (char32)0xEA8B; // symbol-object
				iconColor = C_ICON_TYPE;
				return true;
			case "folder":
				iconGlyph = (char32)0xEA83; // symbol-folder
				iconColor = C_ICON_NAMESPACE;
				return true;
			case "file":
				iconGlyph = (char32)0xEB60; // symbol-file
				iconColor = C_ENTRY_KIND;
				return true;
			default:
			}
			return false;
		}

		public struct TokenRange
		{
			public int32 mStart;
			public int32 mEnd;
		}

		public static bool IsIdentifierStartChar(char8 c)
		{
			return (c == '_') || (c.IsLetter) || ((uint8)c >= 0x80);
		}

		public static bool IsIdentifierStartChar(char32 c)
		{
			if (c == '_')
				return true;
			if (c <= (char32)0x7F)
				return IsIdentifierStartChar((char8)c);
			return c.IsLetter;
		}

		public static bool IsIdentifierChar(char8 c)
		{
			return (c == '_') || (c.IsLetterOrDigit) || ((uint8)c >= 0x80);
		}

		public static bool IsIdentifierChar(char32 c)
		{
			if (c == '_')
				return true;
			if (c <= (char32)0x7F)
				return IsIdentifierChar((char8)c);
			return c.IsLetterOrDigit;
		}

		public static bool IsKeywordToken(StringView token)
		{
			switch (token)
			{
			case "ref", "out", "in", "params", "mut", "readonly", "const", "public", "private", "protected", "internal",
				"static", "virtual", "override", "abstract", "sealed", "extern", "operator", "this", "where", "new":
				return true;
			default:
				return false;
			}
		}

		public static bool IsPrimitiveTypeToken(StringView token)
		{
			switch (token)
			{
			case "void", "bool", "char8", "char16", "char32", "int8", "int16", "int32", "int64", "int",
				"uint8", "uint16", "uint32", "uint64", "uint", "float", "double", "String", "var":
				return true;
			default:
				return false;
			}
		}

		public static bool IsTokenInRanges(int32 tokenStart, int32 tokenEnd, List<TokenRange> ranges)
		{
			for (let range in ranges)
			{
				if ((tokenStart >= range.mStart) && (tokenEnd <= range.mEnd))
					return true;
			}
			return false;
		}

		public static void GetMethodNameRange(StringView titleStr, out int32 methodStart, out int32 methodEnd)
		{
			methodStart = -1;
			methodEnd = -1;

			int32 parenIdx = (.)titleStr.IndexOf('(');
			if (parenIdx <= 0)
				return;

			int32 idx = parenIdx - 1;
			while ((idx >= 0) && (titleStr[idx].IsWhiteSpace))
				idx--;
			if (idx < 0)
				return;

			if (titleStr[idx] == '>')
			{
				int32 angleDepth = 1;
				idx--;
				while ((idx >= 0) && (angleDepth > 0))
				{
					char8 c = titleStr[idx];
					if (c == '>')
						angleDepth++;
					else if (c == '<')
						angleDepth--;
					idx--;
				}
				while ((idx >= 0) && (titleStr[idx].IsWhiteSpace))
					idx--;
			}

			methodEnd = idx + 1;
			while ((idx >= 0) && IsIdentifierChar(titleStr[idx]))
				idx--;
			methodStart = idx + 1;

			if (methodStart >= methodEnd)
			{
				methodStart = -1;
				methodEnd = -1;
			}
		}

		public static void TryAddParamNameRange(StringView titleStr, int32 identCountInSegment, int32 tokenStart, int32 tokenEnd, List<TokenRange> outRanges)
		{
			if ((identCountInSegment < 2) || (tokenStart < 0) || (tokenEnd <= tokenStart))
				return;

			StringView token = .(titleStr, tokenStart, tokenEnd - tokenStart);
			if (IsKeywordToken(token) || IsPrimitiveTypeToken(token))
				return;

			TokenRange tokenRange = .();
			tokenRange.mStart = tokenStart;
			tokenRange.mEnd = tokenEnd;
			outRanges.Add(tokenRange);
		}

		public static void CollectParamNameRanges(StringView titleStr, List<TokenRange> outRanges)
		{
			int32 parenStart = (.)titleStr.IndexOf('(');
			if (parenStart == -1)
				return;

			int32 lastIdentStart = -1;
			int32 lastIdentEnd = -1;
			int32 identCountInSegment = 0;
			int32 parenDepth = 0;
			int32 angleDepth = 0;

			for (int32 idx = parenStart + 1; idx < titleStr.Length; idx++)
			{
				char8 c = titleStr[idx];
				if (IsIdentifierStartChar(c))
				{
					lastIdentStart = idx;
					idx++;
					while ((idx < titleStr.Length) && IsIdentifierChar(titleStr[idx]))
						idx++;
					lastIdentEnd = idx;
					identCountInSegment++;
					idx--;
					continue;
				}

				if (c == '<')
				{
					angleDepth++;
					continue;
				}
				if ((c == '>') && (angleDepth > 0))
				{
					angleDepth--;
					continue;
				}
				if (c == '(')
				{
					parenDepth++;
					continue;
				}
				if (c == ')')
				{
					if (parenDepth > 0)
					{
						parenDepth--;
						continue;
					}

					TryAddParamNameRange(titleStr, identCountInSegment, lastIdentStart, lastIdentEnd, outRanges);
					break;
				}

				if ((c == ',') && (parenDepth == 0) && (angleDepth == 0))
				{
					TryAddParamNameRange(titleStr, identCountInSegment, lastIdentStart, lastIdentEnd, outRanges);
					lastIdentStart = -1;
					lastIdentEnd = -1;
					identCountInSegment = 0;
				}
			}
		}

		public static void DrawDocTitle(Graphics g, StringView titleStr, float x, float y, float maxWidth, int32 highlightStart = -1, int32 highlightEnd = -1)
		{
			let colors = gApp.mSettings.mUISettings.mColors;
			uint32 defaultColor = colors.mAutoCompleteDocText;

			if ((g != null) && (highlightStart != -1) && (highlightEnd > highlightStart))
			{
				float hX = x + g.mFont.GetWidth(titleStr.Substring(0, highlightStart));
				float hW = g.mFont.GetWidth(titleStr.Substring(highlightStart, highlightEnd - highlightStart));
				using (g.PushColor(0x25000000 | (AutoComplete.C_POPUP_ACCENT & 0x00FFFFFF)))
					g.FillRect(hX, y - GS!(1), hW, g.mFont.GetLineSpacing() + GS!(2));
			}

			GetMethodNameRange(titleStr, var methodStart, var methodEnd);
			List<TokenRange> paramNameRanges = scope .();
			CollectParamNameRanges(titleStr, paramNameRanges);

			float curX = x;
			int32 angleDepth = 0;
			int32 methodOwnerStart = -1;
			int32 methodOwnerLastStart = -1;
			int32 methodOwnerLastEnd = -1;
			if (methodStart != -1)
			{
				int32 sepIdx = methodStart - 1;
				while ((sepIdx >= 0) && (titleStr[sepIdx].IsWhiteSpace))
					sepIdx--;
				if ((sepIdx >= 0) && ((titleStr[sepIdx] == '.') || (titleStr[sepIdx] == ':')))
				{
					int32 idx = sepIdx - 1;
					while ((idx >= 0) && (titleStr[idx].IsWhiteSpace))
						idx--;
					methodOwnerLastEnd = idx + 1;
					while ((idx >= 0) && IsIdentifierChar(titleStr[idx]))
						idx--;
					methodOwnerLastStart = idx + 1;

					int32 ownerStart = methodOwnerLastStart - 1;
					while (ownerStart >= 0)
					{
						char8 c = titleStr[ownerStart];
						if (IsIdentifierChar(c) || (c == '.') || (c == ':'))
							ownerStart--;
						else
							break;
					}
					methodOwnerStart = ownerStart + 1;
				}
			}

			int32 fieldMemberStart = -1;
			int32 fieldMemberEnd = -1;
			int32 fieldOwnerStart = -1;
			int32 fieldOwnerLastStart = -1;
			int32 fieldOwnerLastEnd = -1;
			if (methodStart == -1)
			{
				int32 sepIdx = (.)titleStr.LastIndexOf('.');
				if (sepIdx == -1)
					sepIdx = (.)titleStr.LastIndexOf(':');
				if (sepIdx != -1)
				{
					int32 idx = sepIdx + 1;
					while ((idx < titleStr.Length) && (titleStr[idx].IsWhiteSpace))
						idx++;
					fieldMemberStart = idx;
					while ((idx < titleStr.Length) && IsIdentifierChar(titleStr[idx]))
						idx++;
					fieldMemberEnd = idx;

					idx = sepIdx - 1;
					while ((idx >= 0) && (titleStr[idx].IsWhiteSpace))
						idx--;
					fieldOwnerLastEnd = idx + 1;
					while ((idx >= 0) && IsIdentifierChar(titleStr[idx]))
						idx--;
					fieldOwnerLastStart = idx + 1;

					int32 ownerStart = fieldOwnerLastStart - 1;
					while (ownerStart >= 0)
					{
						char8 c = titleStr[ownerStart];
						if (IsIdentifierChar(c) || (c == '.') || (c == ':'))
							ownerStart--;
						else
							break;
					}
					fieldOwnerStart = ownerStart + 1;
				}
			}

			int32 idx = 0;
			while (idx < titleStr.Length)
			{
				int32 tokenStart = idx;
				if (IsIdentifierStartChar(titleStr[idx]))
				{
					idx++;
					while ((idx < titleStr.Length) && IsIdentifierChar(titleStr[idx]))
						idx++;

					int32 tokenEnd = idx;
					StringView token = .(titleStr, tokenStart, tokenEnd - tokenStart);
					uint32 tokenColor = defaultColor;

					int32 prevIdx = tokenStart - 1;
					while ((prevIdx >= 0) && (titleStr[prevIdx].IsWhiteSpace))
						prevIdx--;
					int32 nextIdx = tokenEnd;
					while ((nextIdx < titleStr.Length) && (titleStr[nextIdx].IsWhiteSpace))
						nextIdx++;
					bool hasDotPrev = (prevIdx >= 0) && ((titleStr[prevIdx] == '.') || (titleStr[prevIdx] == ':'));
					bool hasDotNext = (nextIdx < titleStr.Length) && (titleStr[nextIdx] == '.');
					bool isQualified = hasDotPrev || hasDotNext;
					bool isFieldLikeMember = (methodStart == -1) && hasDotPrev && (!hasDotNext);
					bool isMethodOwnerToken = (methodOwnerStart != -1) && (tokenStart >= methodOwnerStart) && (tokenEnd <= methodOwnerLastEnd);
					bool isMethodOwnerTypeToken = (tokenStart == methodOwnerLastStart) && (tokenEnd == methodOwnerLastEnd);
					bool isFieldOwnerToken = (fieldOwnerStart != -1) && (tokenStart >= fieldOwnerStart) && (tokenEnd <= fieldOwnerLastEnd);
					bool isFieldOwnerTypeToken = (tokenStart == fieldOwnerLastStart) && (tokenEnd == fieldOwnerLastEnd);
					bool isResolvedFieldMemberToken = (fieldMemberStart != -1) && (tokenStart == fieldMemberStart) && (tokenEnd == fieldMemberEnd);
					bool isImmediateTypeOwnerForMethod = false;
					if ((methodStart != -1) && hasDotNext)
					{
						int32 probeIdx = nextIdx + 1;
						while ((probeIdx < titleStr.Length) && (titleStr[probeIdx].IsWhiteSpace))
							probeIdx++;
						int32 nextIdentStart = probeIdx;
						while ((probeIdx < titleStr.Length) && IsIdentifierChar(titleStr[probeIdx]))
							probeIdx++;
						int32 nextIdentEnd = probeIdx;
						while ((probeIdx < titleStr.Length) && (titleStr[probeIdx].IsWhiteSpace))
							probeIdx++;
						isImmediateTypeOwnerForMethod = (nextIdentStart == methodStart) && (nextIdentEnd <= methodEnd) && (probeIdx < titleStr.Length) && (titleStr[probeIdx] == '(');
					}

					if ((methodStart != -1) && (tokenStart >= methodStart) && (tokenEnd <= methodEnd))
					{
						tokenColor = colors.mMethod;
					}
					else if (isResolvedFieldMemberToken || isFieldLikeMember)
					{
						tokenColor = colors.mMember;
					}
					else if (IsTokenInRanges(tokenStart, tokenEnd, paramNameRanges))
					{
						tokenColor = ((tokenStart >= highlightStart) && (tokenEnd <= highlightEnd)) ? AutoComplete.C_POPUP_ACCENT : colors.mParameter;
					}
					else if (IsKeywordToken(token))
					{
						tokenColor = colors.mKeyword;
					}
					else if (IsPrimitiveTypeToken(token))
					{
						tokenColor = colors.mPrimitiveType;
					}
					else if (angleDepth > 0)
					{
						tokenColor = colors.mGenericParam;
					}
					else if (isMethodOwnerToken || isImmediateTypeOwnerForMethod)
					{
						tokenColor = (isMethodOwnerTypeToken || isImmediateTypeOwnerForMethod) ? colors.mRefType : colors.mNamespace;
					}
					else if (isFieldOwnerToken)
					{
						tokenColor = isFieldOwnerTypeToken ? colors.mRefType : colors.mNamespace;
					}
					else if (isQualified)
					{
						tokenColor = hasDotNext ? colors.mNamespace : colors.mRefType;
					}
					else
					{
						if (token[0].IsUpper)
						{
							tokenColor = colors.mRefType;
						}
					}

					float availWidth = maxWidth - (curX - x);
					if (availWidth <= 0)
						break;

					using (g.PushColor(tokenColor))
						g.DrawString(token, curX, y, .Left, availWidth, .Ellipsis);

					curX += g.mFont.GetWidth(token);
					if (curX - x >= maxWidth)
						break;
					continue;
				}

				char8 c = titleStr[idx];
				idx++;

				if (c == '<')
					angleDepth++;
				else if ((c == '>') && (angleDepth > 0))
					angleDepth--;

				float availWidth = maxWidth - (curX - x);
				if (availWidth <= 0)
					break;

				StringView str = .(titleStr, tokenStart, 1);
				using (g.PushColor(defaultColor))
					g.DrawString(str, curX, y, .Left, availWidth, .Ellipsis);
				curX += g.mFont.GetWidth(str);
				if (curX - x >= maxWidth)
					break;
			}
		}

        public class AutoCompleteContent : ScrollableWidget
        {
            public AutoComplete mAutoComplete;
            public bool mIsInitted;
			public bool mOwnsWindow;
			public float mRightBoxAdjust;
			public float mWantHeight;

            public this(AutoComplete autoComplete)
            {
                mAutoComplete = autoComplete;
            }

			public ~this()
			{
				//Debug.WriteLine("~this {} {}", this, mIsInitted);

			    if (mIsInitted)
			        Cleanup();
			}

            void LostFocusHandler(BFWindow window, BFWindow newFocus)
            {
				if (gApp.mRunningTestScript)
					return;

                if ((newFocus != mWidgetWindow) && (newFocus != mAutoComplete.mTargetEditWidget.mWidgetWindow))
                    mAutoComplete.Close();
            }

            void HandleWindowMoved(BFWindow window)
            {
				if (gApp.mRunningTestScript)
					return;

				if ((mWidgetWindow == null) || (mWidgetWindow.mRootWidget != this))
					return; // We're being replaced as root

				if (let widgetWindow = window as WidgetWindow)
				{
					if (widgetWindow.mRootWidget is DarkTooltipContainer)
						return;
				}

                if ((mAutoComplete.mIgnoreMove == 0) && (mWidgetWindow != null) && (!mWidgetWindow.mHasClosed))
                    mAutoComplete.Close();
            }

            public void Init()
            {
                Debug.Assert(!mIsInitted);
                mIsInitted = true;

                //Console.WriteLine("AutoCompleteContent Init");

				//Debug.WriteLine("Init {} {} {} {}", this, mIsInitted, mOwnsWindow, mAutoComplete);

				if (mOwnsWindow)
				{
	                WidgetWindow.sOnWindowLostFocus.Add(new => LostFocusHandler);
	                WidgetWindow.sOnMouseDown.Add(new => HandleMouseDown);
	                WidgetWindow.sOnMouseWheel.Add(new => HandleMouseWheel);
	                WidgetWindow.sOnWindowMoved.Add(new => HandleWindowMoved);
	                WidgetWindow.sOnMenuItemSelected.Add(new => HandleSysMenuItemSelected);
				}
            }

            void HandleMouseWheel(MouseEvent evt)
            {
				if (gApp.mRunningTestScript)
					return;
				if (mWidgetWindow == null)
					return;

                WidgetWindow widgetWindow = (WidgetWindow)evt.mSender;
                if (!(widgetWindow.mRootWidget is AutoCompleteContent))
                {
                    float mouseScreenX = widgetWindow.mClientX + evt.mX;
                    float mouseScreenY = widgetWindow.mClientY + evt.mY;
                    let windowRect = Rect(mWidgetWindow.mX, mWidgetWindow.mY, mWidgetWindow.mWindowWidth, mWidgetWindow.mWindowHeight);
                    if (windowRect.Contains(mouseScreenX, mouseScreenY))
                    {
                        MouseWheel(evt.mX - mWidgetWindow.mX, evt.mY - mWidgetWindow.mY, evt.mWheelDeltaX, evt.mWheelDeltaY);
                        evt.mHandled = true;
                    }
                    else
                        mAutoComplete.Close();                    
                }
            }

            void HandleMouseDown(MouseEvent evt)
            {
                WidgetWindow widgetWindow = (WidgetWindow)evt.mSender;
                if (!(widgetWindow.mRootWidget is AutoCompleteContent))
                    mAutoComplete.Close();
            }

            void HandleSysMenuItemSelected(IMenu sysMenu)
            {
                mAutoComplete.Close();
            }

            public void Cleanup()
            {
				//Debug.WriteLine("Cleanup {} {}", this, mIsInitted);

				if (!mIsInitted)
					return;

                //Console.WriteLine("AutoCompleteContent Dispose");
				if (mOwnsWindow)
				{
	                WidgetWindow.sOnWindowLostFocus.Remove(scope => LostFocusHandler, true);
	                WidgetWindow.sOnMouseDown.Remove(scope => HandleMouseDown, true);
	                WidgetWindow.sOnMouseWheel.Remove(scope => HandleMouseWheel, true);
	                WidgetWindow.sOnWindowMoved.Remove(scope => HandleWindowMoved, true);
	                WidgetWindow.sOnMenuItemSelected.Remove(scope => HandleSysMenuItemSelected, true);
	                mIsInitted = false;
				}
            }

            public override void Draw(Graphics g)
            {
                base.Draw(g);

				float drawHeight = (mWantHeight != 0) ? mWantHeight : mHeight;
				float boxWidth = mWidth - GS!(2) - mRightBoxAdjust;
				
				if (mOwnsWindow)
				{
					float panelWidth = boxWidth - GS!(6);
					float panelHeight = drawHeight - GS!(8);

					if ((panelWidth > 0) && (panelHeight > 0))
					{
						g.DrawBox(DarkTheme.sDarkTheme.GetImage(.DropShadow), GS!(2), GS!(2), panelWidth, panelHeight);
						using (g.PushColor(AutoComplete.C_POPUP_BG))
							g.FillRect(0, 0, panelWidth, panelHeight);
						using (g.PushColor(AutoComplete.C_POPUP_BORDER))
							g.OutlineRect(0, 0, panelWidth, panelHeight);
					}
				}

                g.SetFont(IDEApp.sApp.mCodeFont);

				/*using (g.PushColor(0x80FF0000))
					g.FillRect(0, 0, mWidth, mHeight);*/
            }

			public override void Resize(float x, float y, float width, float height)
			{
				base.Resize(x, y, width, height);
			}

			public override void Update()
			{
				base.Update();
			}
        }

        public class AutoCompleteListWidget : AutoCompleteContent
        {
			BumpAllocator mAlloc = new BumpAllocator(.Ignore) ~ delete _;
			public List<EntryWidget> mFullEntryList = new List<EntryWidget>() ~ delete _;
			public List<EntryWidget> mEntryList = mFullEntryList;
			public float mItemSpacing = GS!(22);
			public int32 mSelectIdx = -1;
			public float mMaxWidth;
			public float mDocWidth;
			public float mDocHeight;
			public int mDocumentationDelay = -1;

			public ~this()
			{
				Debug.Assert(mParent == null);
				if (mEntryList != mFullEntryList)
					delete mEntryList;
			}

            public override void MouseEnter()
            {
                base.MouseEnter();
            }

            public class EntryWidget
            {
				public int32 mShowIdx;
                public AutoCompleteListWidget mAutoCompleteListWidget;
                public String mEntryType;
                public String mEntryDisplay;
                public String mEntryInsert;
				public String mDocumentation;
                public Image mIcon;
				public List<uint8> mMatchIndices;
				public int32 mScore;
				public int32 mMatchTier;
				public int32 mTypePriority;
				public int32 mMRUPriority;

				public float Y
				{
					get
					{
						return GS!(6) + mShowIdx * mAutoCompleteListWidget.mItemSpacing;
					}
				}

				public ~this()
				{
				}

                public void Draw(Graphics g, float width)
                {
					var font = IDEApp.sApp.mCodeFont;
                    g.SetFont(font);

					bool hasCodicon = false;
					char32 codiconGlyph;
					uint32 codiconColor;
					if (AutoComplete.TryGetCodiconForEntryType(mEntryType, out codiconGlyph, out codiconColor))
					{
						let codiconFont = AutoComplete.GetCodiconFont();
						if (codiconFont != null)
						{
							hasCodicon = true;
							String codiconText = scope .();
							codiconText.Append(codiconGlyph);
							g.SetFont(codiconFont);
							using (g.PushColor(codiconColor))
								g.DrawString(codiconText, GS!(4), GS!(1));
							g.SetFont(font);
						}
					}

					if ((!hasCodicon) && (mIcon != null))
						g.Draw(mIcon, GS!(4), GS!(1));

					if (mScore > 100) // Simulate IntelliCode with stars
					{
						using (g.PushColor(AutoComplete.C_POPUP_ACCENT))
							g.DrawString("★", GS!(22), GS!(1));
					}

					float rightPadding = GS!(8);
					float offset = (mScore > 100) ? GS!(40) : GS!(28);
					float drawLimit = width - rightPadding;
					float typeWidth = 0;
					bool hasEntryType = (mEntryType != null) && (!mEntryType.IsEmpty);
					if (hasEntryType)
					{
						typeWidth = font.GetWidth(mEntryType);
						drawLimit -= typeWidth + GS!(12);
					}

					int index = 0;
					for(char32 c in mEntryDisplay.DecodedChars)
					{
						let str = StringView(mEntryDisplay, index, @c.NextIndex - index);
						float strWidth = font.GetWidth(str);
						if (offset + strWidth > drawLimit)
							break;

						if (mMatchIndices?.Contains((uint8)index) == true)
						{
							using (g.PushColor(AutoComplete.C_ENTRY_MATCH))
								g.DrawString(str, offset, 0);
						}
						else
						{
							using (g.PushColor(AutoComplete.C_ENTRY_TEXT))
								g.DrawString(str, offset, 0);
						}

						offset += strWidth;
						index = @c.NextIndex;
					}

					if ((hasEntryType) && (typeWidth < width - GS!(12)))
					{
						using (g.PushColor(0xFF808080)) // More subtle kind text
							g.DrawString(mEntryType, width - typeWidth - rightPadding, 0);
					}
                } 

				public void SetMatches(Span<uint8> matchIndices)
				{
					mMatchIndices?.Clear();
	
					if (!matchIndices.IsEmpty)
					{
						if(mMatchIndices == null)
							mMatchIndices = new:(mAutoCompleteListWidget.mAlloc) List<uint8>(matchIndices.Length);
						
						mMatchIndices.AddRange(matchIndices);
					}
				}               
            }

            class Content : Widget
            {
                AutoCompleteListWidget mAutoCompleteListWidget;

                public this(AutoCompleteListWidget autoCompleteListWidget)
                {
                    mAutoCompleteListWidget = autoCompleteListWidget;
                }

                public override void Draw(Graphics g)
                {
                    base.Draw(g);

					float absX;
					float absY;
					mParent.SelfToRootTranslate(0, 0, out absX, out absY);

					float scrollPos = -g.mMatrix.ty + absY;
					int32 startIdx = (int32)(scrollPos / mAutoCompleteListWidget.mItemSpacing);
					int32 endIdx = Math.Min((int32)((scrollPos + mAutoCompleteListWidget.mHeight)/ mAutoCompleteListWidget.mItemSpacing) + 1, (int32)mAutoCompleteListWidget.mEntryList.Count);
					float rowWidth = mWidth - GS!(4) - mAutoCompleteListWidget.mRightBoxAdjust;
					if (mAutoCompleteListWidget.mVertScrollbar != null)
						rowWidth -= GS!(18);
					rowWidth = Math.Max(rowWidth, GS!(40));

					if (mAutoCompleteListWidget.mSelectIdx != -1)
					{
						var selectedEntry = mAutoCompleteListWidget.mEntryList[mAutoCompleteListWidget.mSelectIdx];
						float selX = GS!(1);
						float selY = selectedEntry.Y - GS!(1);
						float selHeight = mAutoCompleteListWidget.mItemSpacing;
						using (g.PushColor(AutoComplete.C_ROW_SELECTED_BG))
							g.FillRect(selX, selY, rowWidth, selHeight);
						/*using (g.PushColor(AutoComplete.C_ROW_SELECTED_BORDER))
							g.OutlineRect(selX, selY, rowWidth, selHeight);*/
						using (g.PushColor(AutoComplete.C_POPUP_ACCENT))
							g.FillRect(selX, selY, GS!(3), selHeight);
					}

                    for (int32 itemIdx = startIdx; itemIdx < endIdx; itemIdx++)
                    {
                        var entry = (EntryWidget)mAutoCompleteListWidget.mEntryList[itemIdx];

						float curY = entry.Y;
                        using (g.PushTranslate(GS!(8), curY))
							entry.Draw(g, rowWidth - GS!(12));
                    }
                }

				public override void MouseDown(float x, float y, int32 btn, int32 btnCount)
				{
					base.MouseDown(x, y, btn, btnCount);

					int32 idx = (int32)((y - GS!(4.0f)) / mAutoCompleteListWidget.mItemSpacing);
					if ((idx >= 0) && (idx < mAutoCompleteListWidget.mEntryList.Count))
					{
						mAutoCompleteListWidget.Select(idx);
						if (!mAutoCompleteListWidget.mOwnsWindow)
							mAutoCompleteListWidget.SetFocus();
						if (btnCount > 1)
						{
						    mAutoCompleteListWidget.mAutoComplete.InsertSelection((char8)0);
						    mAutoCompleteListWidget.mAutoComplete.Close();
						}
					}
				}
            }

            public this(AutoComplete autoComplete) : base(autoComplete)
            {
                mScrollContent = new Content(this);
                mScrollContentContainer.AddWidget(mScrollContent);                
            }

			public void UpdateWidth()
			{
				int firstEntry = (int)(-(int)mScrollContent.mY / mItemSpacing);
				int lastEntry = (int)((-(int)mScrollContent.mY + mScrollContentContainer.mHeight) / mItemSpacing);

				if (mScrollContentContainer.mHeight == 0)
				{
					firstEntry = Math.Max(mSelectIdx - 3, 0);
					lastEntry = mSelectIdx + 7;
				}

				firstEntry = Math.Max(firstEntry, 0);
				lastEntry = Math.Max(lastEntry, 0);
				int entryCount = mEntryList.Count;
				if (entryCount <= 0)
					return;
				if (firstEntry >= entryCount)
					return;
				lastEntry = Math.Min(lastEntry, entryCount);

				float prevMaxWidth = mMaxWidth;
				var font = IDEApp.sApp.mCodeFont;

				for (int i = firstEntry; i < lastEntry; i++)
				{
					if ((i < 0) || (i >= mEntryList.Count))
						break;
					var entry = mEntryList[i];
					if (entry == null)
						continue;
					float entryWidth = font.GetWidth(entry.mEntryDisplay) + GS!(40);
					if ((entry.mEntryType != null) && (!entry.mEntryType.IsEmpty))
						entryWidth += font.GetWidth(entry.mEntryType) + GS!(24);
					mMaxWidth = Math.Max(mMaxWidth, entryWidth);
				}

				if (mWidgetWindow == null)
					return;

				float docWidth = 0.0f;
				float docHeight = 0;
				if ((mSelectIdx != -1) && (mSelectIdx < mEntryList.Count))
				{
					let selectedEntry = mEntryList[mSelectIdx];
					if (selectedEntry.mDocumentation != null)
					{
						DocumentationParser docParser = scope DocumentationParser(selectedEntry.mDocumentation);
						var showDocString = docParser.ShowDocString;

						int lineCount = 0;
						docWidth = 0;
						for (var line in showDocString.Split('\n'))
						{
							docWidth = Math.Max(docWidth, font.GetWidth(line) + GS!(24));
							lineCount++;
						}

						int drawScreenX = (.)(mWidgetWindow.mX + mWidth - mDocWidth);
						gApp.GetWorkspaceRectFrom(drawScreenX, mWidgetWindow.mY, 0, 0, var workspaceX, var workspaceY, var workspaceWidth, var workspaceHeight);
						float maxWidth = workspaceWidth - (drawScreenX - workspaceX) - GS!(8);
						float newDocWidth = Math.Min(docWidth, workspaceWidth - (drawScreenX - workspaceX) - GS!(8));
						newDocWidth = Math.Max(newDocWidth, GS!(80));
						if ((docWidth > maxWidth) || (lineCount > 1))
						{
							docWidth = newDocWidth;
							docHeight = font.GetWrapHeight(showDocString, docWidth - GS!(20)) + GS!(17);
						}
						else
							docHeight = GS!(32);
					}
				}

				if ((mOwnsWindow) && ((prevMaxWidth != mMaxWidth) || (docWidth != mDocWidth) || (docHeight != mDocHeight)) && (mWidgetWindow != null))
				{
					if (mWantHeight == 0)
						mWantHeight = mHeight;

					mDocWidth = docWidth;
					mDocHeight = docHeight;
					mRightBoxAdjust = docWidth + GS!(16);
					int32 windowWidth = (int32)mMaxWidth;
					windowWidth += (.)mDocWidth;
					windowWidth += GS!(32);

					if (mVertScrollbar != null)
					{
						windowWidth += GS!(12);
					}

					int windowHeight = (int)(mWantHeight + Math.Max(0, mDocHeight - GS!(32)));

					mAutoComplete.mIgnoreMove++;
					mWidgetWindow.Resize(mWidgetWindow.mNormX, mWidgetWindow.mNormY, windowWidth, windowHeight);
					mScrollContent.mWidth = mWidth;
					//Resize(0, 0, mWidgetWindow.mClientWidth, mWidgetWindow.mClientHeight);
					mAutoComplete.mIgnoreMove--;
					ResizeContent(-1, -1, mVertScrollbar != null);
				}
			}

			/*public override void Resize(float x, float y, float width, float height)
			{
				if (mWantHeight != 0)
				{
					mScrollContentInsets.mBottom = mHeight - mWantHeight;
					mScrollbarInsets.mBottom = mHeight - mWantHeight + 10;
				}
				else
				{
					mScrollContentInsets.mBottom = 0;
					mScrollbarInsets.mBottom = 10;
				}

				base.Resize(x, y, width, height);
			}*/

            public void UpdateEntry(EntryWidget entry, int showIdx)
            {
                if (showIdx == -1)
                {
                    //entry.mVisible = false;
					entry.mShowIdx = (int32)showIdx;
                    return;
                }

                //entry.mVisible = true;
                //entry.Resize(GS!(4), GS!(6) + showIdx * mItemSpacing, int32.MaxValue, mItemSpacing);
				entry.mShowIdx = (int32)showIdx;

				/*if (showIdx < 10)
				{
	                var font = IDEApp.sApp.mCodeFont;
	                float entryWidth = font.GetWidth(entry.mEntryDisplay) + GS!(32);
	                mMaxWidth = Math.Max(mMaxWidth, entryWidth);
				}*/
            }
			
			public void AddEntry(StringView entryType, StringView entryDisplay, Image icon, StringView entryInsert = default, StringView documentation = default, List<uint8> matchIndices = null)
            {                
                var entryWidget = new:mAlloc EntryWidget();
                entryWidget.mAutoCompleteListWidget = this;
                entryWidget.mEntryType = new:mAlloc String(entryType);
                entryWidget.mEntryDisplay = new:mAlloc String(entryDisplay);
				if (!entryInsert.IsEmpty)
                	entryWidget.mEntryInsert = new:mAlloc String(entryInsert);
				if (!documentation.IsEmpty)
					entryWidget.mDocumentation = new:mAlloc String(documentation);
                entryWidget.mIcon = icon;

				entryWidget.SetMatches(matchIndices ?? scope .());

                UpdateEntry(entryWidget, mEntryList.Count);
                mEntryList.Add(entryWidget);
                //mScrollContent.AddWidget(entryWidget);
            }

            public void EnsureSelectionVisible()
            {
                if (mVertScrollbar != null)
				{
					float extraSpacing = mOwnsWindow ? 0 : GS!(4);

					//int numItemsVisible = (int)((mVertScrollbar.mPageSize - GS!(6)) / mItemSpacing);
					//float usableHeight = numItemsVisible * mItemSpacing;
					float usableHeight = (float)mVertScrollbar.mPageSize;

					float height = mItemSpacing;
	                var selectItem = mEntryList[mSelectIdx];
	                if (selectItem.Y - extraSpacing < mVertScrollbar.mContentPos)
	                    mVertScrollbar.ScrollTo(selectItem.Y - extraSpacing);
	                if (selectItem.Y + height > mVertScrollbar.mContentPos + usableHeight)
	                    mVertScrollbar.ScrollTo(selectItem.Y + height - usableHeight);
				}
				UpdateWidth();
            }

            public void CenterSelection()
            {
				if (mSelectIdx == -1)
					return;
                if (mVertScrollbar == null)
                    return;

                var selectItem = mEntryList[mSelectIdx];
                VertScrollTo(selectItem.Y + mItemSpacing - mVertScrollbar.mPageSize / 2, true);
				UpdateWidth();
            }

            public void Select(int32 idx)
            {
				if (mSelectIdx == idx)
					return;

				MarkDirty();
                mSelectIdx = idx;
				if ((gApp.mSettings.mEditorSettings.mAutoCompleteShowDocumentation) && (!mAutoComplete.mIsDocumentationPass))
				{
					// Show faster when we have a panel to show within
					mDocumentationDelay = mOwnsWindow ? 40 : 20;
				}
                EnsureSelectionVisible();
            }

            public void SelectDirection(int32 dir)
            {
				mAutoComplete.HasInteracted = true;

				if (mEntryList.IsEmpty)
					return;
                int32 newSelection = mSelectIdx + dir;
				if (newSelection < 0)
				{
					if (dir == -1)
						newSelection = (.)mEntryList.Count - 1;
					else
						newSelection = 0;
				}
				else if (newSelection >= mEntryList.Count)
				{
					if (dir == 1)
						newSelection = 0;
					else
						newSelection = (.)mEntryList.Count - 1;
				}
                
                if (mEntryList[newSelection].mShowIdx != -1)
                    Select(newSelection);
            }

            public override void ScrollPositionChanged()
            {
                if (mVertScrollbar != null)
                {
                    //mVertScrollbar.mContentPos = (float)Math.Round(mVertScrollbar.mContentPos / mItemSpacing) * mItemSpacing;
                    
                }

                base.ScrollPositionChanged();
            }

			public override void Draw(Graphics g)
			{
				base.Draw(g);
				if (mSelectIdx != -1)
				{
					let selectedEntry = mEntryList[mSelectIdx];
					if ((selectedEntry.mDocumentation != null) && (mDocumentationDelay <= 0))
					{
						DocumentationParser docParser = scope .(selectedEntry.mDocumentation);
						if (mOwnsWindow)
						{
							if (mDocWidth > 0)
							{
								float drawX = mWidth - mDocWidth - GS!(22);

								//float drawX = mRightBoxAdjust + GS!(42);
								float drawY = GS!(4);
								//float drawHeight = GS!(32);
								float drawHeight = mDocHeight;
								float drawWidth = mRightBoxAdjust - GS!(8);

								if ((drawWidth > 0) && (drawHeight > 0))
								{
									g.DrawBox(DarkTheme.sDarkTheme.GetImage(.DropShadow), drawX + GS!(2), drawY + GS!(2), drawWidth, drawHeight);
									using (g.PushColor(AutoComplete.C_POPUP_BG))
										g.FillRect(drawX, drawY, drawWidth, drawHeight);
									using (g.PushColor(AutoComplete.C_POPUP_BORDER))
										g.OutlineRect(drawX, drawY, drawWidth, drawHeight);

									float textX = drawX + GS!(8);
									float textY = drawY + GS!(6);
									float textWidth = drawWidth - GS!(16);

									StringView showDocString = .(docParser.ShowDocString);
									StringView titleStr = showDocString;
									StringView bodyStr = default;
									int splitIdx = showDocString.IndexOf('\n');
									if (splitIdx != -1)
									{
										titleStr = .(showDocString, 0, splitIdx);
										bodyStr = .(showDocString, splitIdx + 1);
									}

									if (!titleStr.IsEmpty)
									{
										AutoComplete.DrawDocTitle(g, titleStr, textX, textY, textWidth);
										textY += g.mFont.GetLineSpacing() + GS!(3);
									}

									if (!bodyStr.IsEmpty)
									{
										using (g.PushColor(gApp.mSettings.mUISettings.mColors.mAutoCompleteDocText))
											g.DrawString(bodyStr, textX, textY, .Left, textWidth, .Wrap);
									}
								}
							}
						}
						else
						{
							/*float drawX = GS!(8);
							float drawY = mHeight + GS!(2);
							using (g.PushColor(0xFFC0C0C0))
								g.DrawString(docParser.ShowDocString, drawX, drawY, .Left, mWidth - drawX, .Wrap);*/
						}
					}
				}
			}

			public override void DrawAll(Graphics g)
			{
				base.DrawAll(g);
				/*using (g.PushColor(0x20FF0000))
					g.FillRect(0, 0, mWidth, mHeight);*/
			}

			public override void Update()
			{
				base.Update();
				if (mDocumentationDelay > 0)
					--mDocumentationDelay;
			}

            public void ResizeContent(int32 width, int32 height, bool wantScrollbar)
            {
                InitScrollbars(false, wantScrollbar);
                if ((wantScrollbar) && (mOwnsWindow))
                {
                    mVertScrollbar.mScrollIncrement = mItemSpacing;
                    mVertScrollbar.mAlignItems = true;
                }
				if (mOwnsWindow)
				{
	                mScrollbarInsets.mTop = GS!(2);
	                mScrollbarInsets.mBottom = GS!(10);
	                mScrollbarInsets.mRight = GS!(10) + mRightBoxAdjust;
					mScrollContentInsets.mBottom = 0;

					if (mWantHeight != 0)
					{
						mScrollbarInsets.mBottom += mHeight - mWantHeight;
					}

				}
				else
				{
					mScrollbarInsets.mTop = GS!(2);
					mScrollbarInsets.mBottom = GS!(2);
					mScrollbarInsets.mRight = GS!(2);
				}

				if (width != -1)
				{
	                mScrollContent.mWidth = width /*- mRightBoxAdjust*/;
	                mScrollContent.mHeight = height;
				}
                UpdateScrollbars();
            }

			public override void RehupScale(float oldScale, float newScale)
			{
				base.RehupScale(oldScale, newScale);
				mAutoComplete.Close();
			}

			public override void KeyDown(KeyCode keyCode, bool isRepeat)
			{
				base.KeyDown(keyCode, isRepeat);

				switch (keyCode)
				{
				case .Up:
					SelectDirection(-1);
				case .Down:
					SelectDirection(1);
				default:
				}
			}
        }

        public class InvokeWidget : AutoCompleteContent
        {
            public class Entry
            {
                public String mText ~ delete _;
				public String mDocumentation ~ delete _;
				public int32 mArgMatchCount;

				public int GetParamCount()
				{
					int  splitCount = 0;
					for (int32 i = 0; i < mText.Length; i++)
					{
						char8 c = mText[i];
					    if (c == '\x01')
						{
					        splitCount++;
							i++;
						}
					}
					return splitCount - 1;
				}

				public bool HasParamsParam()
				{
					int lastSplit = mText.LastIndexOf('\x01');
					if (lastSplit == -1)
						return false;
					lastSplit = mText.LastIndexOf('\x01', lastSplit - 1);
					if (lastSplit == -1)
						return false;
					
					StringView sv = .(mText, lastSplit);
					return sv.StartsWith("\x01params ") || sv.StartsWith("\x01 params ");
				}
            }

            public List<Entry> mEntryList = new List<Entry>() ~ DeleteContainerAndItems!(_);
            public int32 mSelectIdx;
            public float mMaxWidth;
            public int32 mLeftParenIdx;
            public bool mIsAboveText;

            public this(AutoComplete autoComplete)
                : base(autoComplete)
            {
            }

			public ~this()
			{
			}

            public void AddEntry(Entry entry)
            {
                mEntryList.Add(entry);

                var font = IDEApp.sApp.mCodeFont;
				String checkString = scope String(entry.mText);
				checkString.Replace("\x01", "");
                float entryWidth = font.GetWidth(checkString) + GS!(32);
                mMaxWidth = Math.Max(mMaxWidth, entryWidth);
            }

			public void ResizeContent(bool resizeWindow)
			{
				if (mOwnsWindow)
				{
					int workspaceX;
					int workspaceY;
					int workspaceWidth;
					int workspaceHeight;
					BFApp.sApp.GetWorkspaceRect(out workspaceX, out workspaceY, out workspaceWidth, out workspaceHeight);
					mWidth = workspaceWidth;
				}
				else
					mWidth = gApp.mAutoCompletePanel.mWidth;

				float extWidth;
				float extHeight;
				DrawInfo(null, out extWidth, out extHeight);

				mWidth = extWidth + GS!(16);
				mHeight = extHeight + GS!(12);

				if ((mWidth <= 0) || (mHeight <= 0))
					return;

				if (resizeWindow)
				{
					if (mOwnsWindow)
					{
						mAutoComplete.mIgnoreMove++;
						mAutoComplete.UpdateWindow(ref mWidgetWindow, this, mAutoComplete.mInvokeSrcPositions[0], (int32)mWidth, (int32)mHeight);
						mAutoComplete.mIgnoreMove--;
					}
					else
					{
						gApp.mAutoCompletePanel.ResizeComponents();
					}
				}
			}

            public void Select(int32 idx)
            {
                mSelectIdx = idx;
				ResizeContent(mWidgetWindow != null);
            }

            public new void Init()
            {
                base.Init();

                if (mSelectIdx >= mEntryList.Count)
                    mSelectIdx = 0;
            }

            public bool SelectDirection(int32 dir)
            {
                int32 newSelection = mSelectIdx + dir;
                if ((newSelection >= 0) && (newSelection < mEntryList.Count))
				{
                    Select(newSelection);
					return true;
				}
				return false;
            }

            public override void Update()
            {
                base.Update();

            }

			public void GetState(out int cursorSection)
			{
				cursorSection = -1;

				var selectedEntry = mEntryList[mSelectIdx];

				List<StringView> textSections = scope List<StringView>(selectedEntry.mText.Split('\x01'));

				int cursorPos = mAutoComplete.mTargetEditWidget.Content.mTextCursors.Front.mCursorTextPos;
				for (int sectionIdx = 0; sectionIdx < mAutoComplete.mInvokeSrcPositions.Count - 1; sectionIdx++)
				{
				    if (cursorPos > mAutoComplete.mInvokeSrcPositions[sectionIdx])
				        cursorSection = sectionIdx + 1;
				}

				// Just show last section hilighted even if we have too many params.
				//  This accounts for variadic cases
				if (cursorSection >= textSections.Count - 1)
				    cursorSection = textSections.Count - 2;

				if ((cursorSection >= 0) && (cursorSection < mAutoComplete.mInvokeSrcPositions.Count))
				{
					var argText = mAutoComplete.mTargetEditWidget.mEditWidgetContent.ExtractString(mAutoComplete.mInvokeSrcPositions[cursorSection - 1],
						mAutoComplete.mInvokeSrcPositions[cursorSection] - mAutoComplete.mInvokeSrcPositions[cursorSection - 1], .. scope .());

					int colonPos = argText.IndexOf(':');
					
					if (colonPos != -1)
					{
						do
						{
							bool foundSep = false;
							int nameStart = -1;
							for (int i = colonPos - 1; i >= 0; i--)
							{
								char8 c = argText[i];
								if (nameStart == -1)
								{
									if ((c != '_') && (!c.IsLetterOrDigit))
										nameStart = i + 1;
								}
								else
								{
									if (!c.IsWhiteSpace)
									{
										if ((!foundSep) &&
											((c == ',') || (c == '(')))
											foundSep = true;
										else
											break;
									}
								}
							}

							if (nameStart == -1)
								break;

							var argParamName = argText.Substring(nameStart, colonPos - nameStart);
							for (int checkSectionIdx = 1; checkSectionIdx < textSections.Count; checkSectionIdx++)
							{
								var sectionStr = textSections[checkSectionIdx];

								var checkParamName = sectionStr;
								if (checkParamName.EndsWith(','))
									checkParamName.RemoveFromEnd(1);

								for (int checkIdx = checkParamName.Length - 1; checkIdx >= 0; checkIdx--)
								{
									char8 c = checkParamName[checkIdx];
									if (c.IsWhiteSpace)
									{
										checkParamName.RemoveFromStart(checkIdx + 1);
										break;
									}
								}

								if (checkParamName == argParamName)
								{
									cursorSection = checkSectionIdx;
									break;
								}
							}
						}
					}
				}
			}

			void DrawInfo(Graphics g, out float extWidth, out float extHeight)
			{
				var font = IDEApp.sApp.mCodeFont;

				extHeight = 0;
				extWidth = 0;

				if (mSelectIdx < 0)
					return;

				float curX = GS!(8);
				float curY = GS!(6);

				if (mEntryList.Count > 1)
				{
					String numStr = scope String();
					numStr.AppendF("{0}/{1}", mSelectIdx + 1, mEntryList.Count);
					if (g != null)
					{
					    using (g.PushColor(AutoComplete.C_ENTRY_KIND))
					        g.DrawString(numStr, curX, curY);
					}
					curX += font.GetWidth(numStr) + GS!(8);
				}

				var selectedEntry = mEntryList[mSelectIdx];
				
				float maxWidth = mWidth;

				StringView paramName = .();
				List<StringView> textSections = scope List<StringView>(selectedEntry.mText.Split('\x01'));

				GetState(var cursorSection);

				String fullSignature = scope String();
				int32 highlightStart = -1;
				int32 highlightEnd = -1;
				for (int sectionIdx = 0; sectionIdx < textSections.Count; sectionIdx++)
				{
					if (sectionIdx == cursorSection)
						highlightStart = (.)fullSignature.Length;
					fullSignature.Append(textSections[sectionIdx]);
					if (sectionIdx == cursorSection)
						highlightEnd = (.)fullSignature.Length;
				}

				if (g != null)
				{
					AutoComplete.DrawDocTitle(g, fullSignature, curX, curY, maxWidth - curX, highlightStart, highlightEnd);
				}
				extWidth = Math.Max(extWidth, curX + font.GetWidth(fullSignature));
				curX += font.GetWidth(fullSignature);

				extWidth += GS!(16);
				extHeight = curY + font.GetLineSpacing() + GS!(12);

				if ((selectedEntry.mDocumentation != null) && (gApp.mSettings.mEditorSettings.mAutoCompleteShowDocumentation))
				{
					DocumentationParser docParser = scope .(selectedEntry.mDocumentation);
					var docString = docParser.mBriefString ?? docParser.mDocString;

					curX = GS!(32);

					float docHeight = 0;
					if (mWidgetWindow == null)
					{
						docHeight = font.GetHeight();
					}
					else
					{
						int drawScreenX = (.)(mWidgetWindow.mX + curX);
						gApp.GetWorkspaceRectFrom(drawScreenX, mWidgetWindow.mY, 0, 0, var workspaceX, var workspaceY, var workspaceWidth, var workspaceHeight);
						float maxDocWidth = workspaceWidth - drawScreenX - GS!(8);
						maxDocWidth = Math.Min(maxDocWidth, workspaceWidth - drawScreenX - GS!(8));
						maxDocWidth = Math.Max(maxDocWidth, GS!(80));

						if (!docString.IsWhiteSpace)
						{
							
							if (g != null)
							{
								let docY = curY + font.GetLineSpacing() + GS!(4);

								using (g.PushColor(gApp.mSettings.mUISettings.mColors.mAutoCompleteDocText))
									docHeight = g.DrawString(docString, curX, docY, .Left, maxDocWidth, .Wrap);
							}
							else
								docHeight = font.GetWrapHeight(docString, maxDocWidth);

							curY += docHeight;
						}

						extWidth = Math.Max(extWidth, Math.Min(font.GetWidth(docString), maxDocWidth) + GS!(48));
					}
					extHeight += docHeight + GS!(4);

					/*if (docWidth > maxDocWidth)
					{
						docWidth = newDocWidth;
						docHeight = font.GetWrapHeight(showDocString, docWidth - GS!(20)) + GS!(17);
					}
					else
						docHeight = GS!(32);*/


					/*curY += font.GetLineSpacing() + GS!(4);
					if (g != null)
					{
						using (g.PushColor(0xFFC0C0C0))
							g.DrawString(docString, curX, curY, .Left, mWidth, .Ellipsis);
					}
					extWidth = Math.Max(extWidth, font.GetWidth(docString) + GS!(48));
					extHeight += font.GetLineSpacing() + GS!(4);*/


					if (docParser.mParamInfo != null)
					{
						if (docParser.mParamInfo.TryGetValue(scope String(paramName), var paramDoc) || paramName.IsEmpty)
						{
							curY += font.GetLineSpacing() + GS!(4);
							if (g != null)
							{
								using (g.PushColor(gApp.mSettings.mUISettings.mColors.mText))
								{
									g.DrawString(scope String(paramName.Length + 1)..AppendF("{0}:", paramName), curX, curY, .Left, mWidth, .Ellipsis);
								}

								using (g.PushColor(gApp.mSettings.mUISettings.mColors.mAutoCompleteDocText))
								{
									g.DrawString(paramDoc, curX + font.GetWidth(paramName) + font.GetWidth(": "), curY, .Left, mWidth, .Ellipsis);
								}
							}
						}

						for (var paramDocKV in docParser.mParamInfo)
						{
							extWidth = Math.Max(extWidth, font.GetWidth(paramDocKV.key) + font.GetWidth(": ") + font.GetWidth(paramDocKV.value) + GS!(48));
						}
						extHeight += font.GetLineSpacing() + GS!(4);
					}
				}
			}

            public override void Draw(Beefy.gfx.Graphics g)
            {
                base.Draw(g);
                
				float extWidth;
				float extHeight;
				DrawInfo(g, out extWidth, out extHeight);
            }

			public override void RehupScale(float oldScale, float newScale)
			{
				base.RehupScale(oldScale, newScale);
				mAutoComplete.Close();
			}
        }

		public class TextPos
		{
			public AutoComplete mAutoComplete;
			public PersistentTextPosition mPersistentTextPosition ~ delete _;
			public int32 mTextPos;

			public this(AutoComplete autoComplete, int textPos)
			{
				mAutoComplete = autoComplete;
				mTextPos = (.)textPos;

				if (var ewc = mAutoComplete.mTargetEditWidget.Content as SourceEditWidgetContent)
				{
					if (ewc.HasTextCursorBefore(textPos))
					{
						mPersistentTextPosition = new PersistentTextPosition(mTextPos);
						ewc.PersistentTextPositions.Add(mPersistentTextPosition);
					}
				}
			}

			public ~this()
			{
				if (mPersistentTextPosition != null)
				{
					if (var ewc = mAutoComplete.mTargetEditWidget.Content as SourceEditWidgetContent)
					{
						ewc.PersistentTextPositions.Remove(mPersistentTextPosition);
					}
				}
			}

			public int32 Value
			{
				get
				{
					if (mPersistentTextPosition != null)
					{
						int32 textPos = mPersistentTextPosition.mIndex;
						if (textPos != mTextPos)
						{
							NOP!();
						}
						return textPos;
					}
					return mTextPos;
				}
			}

			public static Self operator++(Self self)
			{
				self.mTextPos++;
				if (self.mPersistentTextPosition != null)
					self.mPersistentTextPosition.mIndex++;
				return self;
			}
		}

		public Stopwatch mStopwatch ~ delete _;
        public EditWidget mTargetEditWidget;
        public Event<Action> mOnAutoCompleteInserted ~ _.Dispose();
        public Event<Action> mOnClosed ~ _.Dispose();
        public WidgetWindow mListWindow;
        public AutoCompleteListWidget mAutoCompleteListWidget;
        public WidgetWindow mInvokeWindow;
        public InvokeWidget mInvokeWidget;
        public List<InvokeWidget> mInvokeStack = new List<InvokeWidget>() ~ delete _; // Previous invokes (from async)
        public TextPos mInsertStartIdx ~ delete _;
        public int32 mInsertEndIdx = -1;
		public String mInfoFilter ~ delete _;
        public List<int32> mInvokeSrcPositions ~ delete _;
        public static int32 sAutoCompleteIdx = 1;
        public static Dictionary<String, int32> sAutoCompleteMRU = new Dictionary<String, int32>() {
			(new String("return"), (int32)1)
			} ~ delete _;
		public static Dictionary<char32, char8> sPinyinInitialCache = new .() ~ delete _;
        public bool mIsAsync = true;
        public bool mIsMember;        
		public bool mIsFixit;
		public bool mInvokeOnly;
		public bool mUncertain;
		public bool mIsDocumentationPass;
		public bool mIsUserRequested;

		public int mIgnoreMove;
		bool mClosed;
		bool mPopulating;
		float mWantX;
		float mWantY;

		public bool HasInteracted;

		public int32 InsertStartIdx => (mInsertStartIdx != null) ? mInsertStartIdx.Value : -1;

        public this(EditWidget targetEditWidget)
        {
            mTargetEditWidget = targetEditWidget;
        }

		public ~this()
		{
			Close(false);
		}

		static ~this()
		{
			for (var key in sAutoCompleteMRU.Keys)
				delete key;
		}

        public void UpdateWindow(ref WidgetWindow widgetWindow, Widget rootWidget, int textIdx, int width, int height)
        {
			var textIdx;

			// This makes typing '..' NOT move the window after pressing the second '.'
			 if (mTargetEditWidget.Content.SafeGetChar(textIdx - 2) == '.')
			{
				textIdx--;
			}

            Debug.Assert(textIdx >= 0);
            int line = 0;
            int column = 0;
            if (textIdx >= 0)
                mTargetEditWidget.Content.GetLineCharAtIdx(textIdx, out line, out column);

            float x;
            float y;
            mTargetEditWidget.Content.GetTextCoordAtLineChar(line, column, out x, out y);

			//Debug.WriteLine($"UpdateWindow GetTextCoordAtLineChar TextIdx:{textIdx} {x},{y}");

			mTargetEditWidget.Content.GetTextCoordAtCursor(var cursorX, var cursorY);

			if (mInvokeWidget?.mIsAboveText != true)
				y = Math.Max(y, cursorY + gApp.mCodeFont.GetHeight() * 0.0f);

			/*if (cursorY > y + gApp.mCodeFont.GetHeight() * 2.5f)
				y = cursorY;*/

            float screenX;
            float screenY;
            mTargetEditWidget.Content.SelfToRootTranslate(x, y, out screenX, out screenY);
			
            /// 

            /*if ((mInvokeSrcPositions != null) && (mInvokeSrcPositions.Count > 0))
            {
                textIdx = mInvokeSrcPositions[mInvokeSrcPositions.Count - 1];
                mTargetEditWidget.Content.GetLineCharAtIdx(textIdx, out line, out column);                
                mTargetEditWidget.Content.GetTextCoordAtLineChar(line, column, out x, out y);

                float endScreenX;
                float endScreenY;
                mTargetEditWidget.Content.SelfToRootTranslate(x, y, out endScreenX, out endScreenY);

                screenY = endScreenY;
            }*/

            ///

			int screenWidth = width;
			int screenHeight = height;

            screenX += mTargetEditWidget.mWidgetWindow.mClientX;
            screenY += mTargetEditWidget.mWidgetWindow.mClientY;
            screenX -= GS!(24);
            screenY += GS!(20);

			float startScreenY = screenY;
            if (rootWidget == mInvokeWidget)
            {
                if (mInvokeWidget.mIsAboveText)
                    screenY -= height + GS!(16);
            }

            //TODO: Do better positioning
            if ((mInvokeWindow != null) && (widgetWindow == mListWindow))
            {
                if (!mInvokeWidget.mIsAboveText)
                    screenY += mInvokeWindow.mWindowHeight - 6;
            }

			mWantX = screenX;
			mWantY = screenY;

			int workspaceX;
			int workspaceY;
			int workspaceWidth;
			int workspaceHeight;
			BFApp.sApp.GetWorkspaceRect(out workspaceX, out workspaceY, out workspaceWidth, out workspaceHeight);
			if (screenX + width > workspaceWidth)
				screenX = workspaceWidth - width;
			if (screenX < workspaceX)
				screenX = workspaceX;

			if (rootWidget == mAutoCompleteListWidget)
			{
				// May clip of bottom?
				if (screenY + GetMaxWindowHeight() >= workspaceHeight)
				{
					screenY = startScreenY - (height + GS!(16));
				}
			}

			/*if (width > workspaceWidth)
			{
				screenWidth = workspaceWidth;
				var font = IDEApp.sApp.mCodeFont;
				//font.GetWrapHeight()
			}*/

            if (widgetWindow == null)
            {
				//Debug.WriteLine($"UpdateWindow Create {screenX},{screenY}");

                BFWindow.Flags windowFlags = BFWindow.Flags.ClientSized | BFWindow.Flags.PopupPosition | BFWindow.Flags.NoActivate | BFWindow.Flags.NoMouseActivate | BFWindow.Flags.DestAlpha;
                widgetWindow = new WidgetWindow(mTargetEditWidget.mWidgetWindow,
                    "Autocomplete",
                    (int32)screenX, (int32)screenY,
                    screenWidth, screenHeight,
                    windowFlags,
                    rootWidget);
            }
            else 
            {
				//Debug.WriteLine($"UpdateWindow Update {screenX},{screenY}");

                if (widgetWindow.mRootWidget != rootWidget)
				{
					var prevRoot = widgetWindow.mRootWidget;
					//Debug.WriteLine("Setting window {0} to root {1} from root {2}", widgetWindow, rootWidget, prevRoot);
                    widgetWindow.SetRootWidget(rootWidget);
					delete prevRoot;
				}
                widgetWindow.Resize((int)screenX, (int)screenY, width, height);
            }
        }        

        public void UpdateAsyncInfo()
        {
            GetAsyncTextPos();
            UpdateData(null, true);
        }

        public void Update()
        {
			Debug.Assert((mIgnoreMove >= 0) && (mIgnoreMove <= 4));

            if ((mInvokeWindow != null) && (!mInvokeWidget.mIsAboveText))
            {
                int textIdx = mTargetEditWidget.Content.mTextCursors.Front.mCursorTextPos;
                int line = 0;
                int column = 0;
                if (textIdx >= 0)
                    mTargetEditWidget.Content.GetLineCharAtIdx(textIdx, out line, out column);
                float x;
                float y;
                mTargetEditWidget.Content.GetTextCoordAtLineChar(line, column, out x, out y);

                float screenX;
                float screenY;
                mTargetEditWidget.Content.SelfToRootTranslate(x, y, out screenX, out screenY);

                screenX += mTargetEditWidget.mWidgetWindow.mClientX;
                screenY += mTargetEditWidget.mWidgetWindow.mClientY;

                //if (screenY >= mInvokeWindow.mY - 8)

				int invokeLine = 0;
				int invokeColumn = 0;
				if (mInvokeSrcPositions != null)
					mTargetEditWidget.Content.GetLineCharAtIdx(mInvokeSrcPositions[0], out invokeLine, out invokeColumn);

				int insertLine = line;
				if ((insertLine != invokeLine) && ((insertLine - invokeLine) * gApp.mCodeFont.GetHeight() < GS!(40)))
                {
                    mIgnoreMove++;
                    mInvokeWidget.mIsAboveText = true;
					mInvokeWidget.ResizeContent(false);
                    UpdateWindow(ref mInvokeWindow, mInvokeWidget, mInvokeSrcPositions[0], (int32)mInvokeWidget.mWidth, (int32)mInvokeWidget.mHeight);                    
                    if (mListWindow != null)
                        UpdateWindow(ref mListWindow, mAutoCompleteListWidget, mInsertStartIdx.Value, mListWindow.mWindowWidth, mListWindow.mWindowHeight);
                    mIgnoreMove--;
                }
            }

			if (mAutoCompleteListWidget != null)
				mAutoCompleteListWidget.UpdateWidth();

			if ((IsShowing()) && (!IsInPanel()))
			{
				bool hasFocus = false;
				if ((mListWindow != null) && (mListWindow.mHasFocus))
					hasFocus = true;
				if (mTargetEditWidget.mHasFocus)
					hasFocus = true;
				if (!hasFocus)
				{
					Close();
				}
			}

			/*if (mInvokeWidget != null)
			{
				var invokeEntry = mInvokeWidget.mEntryList[mInvokeWidget.mSelectIdx];

				mInvokeWidget.GetState(var cursorSection);

				if (mAutoCompleteListWidget != null)
				{

				}
				else
				{
					if (cursorSection > 0)
					{
						int sectionStartIdx = -1;
						int sectionEndIdx = -1;

						int foundSectionIdx = 0;
						for (var c in invokeEntry.mText.RawChars)
						{
							if (c == '\x01')
							{
								foundSectionIdx++;
								if (foundSectionIdx == cursorSection)
									sectionStartIdx = @c.Index;
								else if (foundSectionIdx == cursorSection + 1)
									sectionEndIdx = @c.Index;
							}
						}

						if (sectionEndIdx != -1)
						{
							StringView argText = invokeEntry.mText.Substring(sectionStartIdx + 1, sectionEndIdx - sectionStartIdx - 1);
							argText.Trim();
							while (!argText.IsEmpty)
							{
								char8 c = argText[argText.Length - 1];
								if ((c.IsLetterOrDigit) || (c == '_'))
									break;
								argText.RemoveFromEnd(1);
							}

							if (argText.StartsWith("tag "))
							{
								int spacePos = argText.IndexOf(' ', 4);
								if (spacePos == -1)
									spacePos = argText.Length;
								StringView tagName = argText.Substring(4, spacePos - 4);

								mInsertStartIdx = mInvokeSrcPositions[cursorSection - 1];
								mInsertEndIdx = mInsertStartIdx;
								mAutoCompleteListWidget = new AutoCompleteListWidget(this);
								mAutoCompleteListWidget.AddEntry("value", scope $".{tagName}", DarkTheme.sDarkTheme.GetImage(.IconValue));
								HandleAutoCompleteListWidget(1);
								mAutoCompleteListWidget.mSelectIdx = 0;
							}
						}
					}
				}
			}*/
        }

		public void GetFilter(String outFilter)
		{
			if ((mInsertEndIdx != -1) && (mInsertStartIdx != null))
			{
				var length = Math.Abs(mInsertEndIdx - mInsertStartIdx.Value);
				if (length == 0)
					return;
				var start = Math.Min(mInsertStartIdx.Value, mInsertEndIdx);
				mTargetEditWidget.Content.ExtractString(start, length, outFilter);
			}
		}

		void GetIdentifierFilterAtCursor(String outFilter)
		{
			var data = mTargetEditWidget.Content.mData;
			int32 cursorPos = (int32)mTargetEditWidget.Content.CursorTextPos;
			cursorPos = Math.Min(cursorPos, data.mTextLength);
			int32 startPos = cursorPos;
			while (startPos > 0)
			{
				char32 c = data.mText[startPos - 1].mChar;
				if (!AutoComplete.IsIdentifierChar(c))
					break;
				startPos--;
			}

			if (cursorPos > startPos)
				mTargetEditWidget.Content.ExtractString(startPos, cursorPos - startPos, outFilter);
		}

		public void GetAsyncTextPos()
		{
			if (mInsertStartIdx == null)
			{
				var data = mTargetEditWidget.Content.mData;
				int32 cursorPos = (int32)mTargetEditWidget.Content.CursorTextPos;
				cursorPos = Math.Min(cursorPos, data.mTextLength);
				int32 startPos = cursorPos;
				while (startPos > 0)
				{
					char32 c = data.mText[startPos - 1].mChar;
					if (!AutoComplete.IsIdentifierChar(c))
						break;
					startPos--;
				}

				// Fallback for backends that don't provide insertRange on incremental updates.
				mInsertStartIdx = new .(this, startPos);
			}

            mInsertEndIdx = (int32)mTargetEditWidget.Content.CursorTextPos;
			while ((mInsertStartIdx != null) && (mInsertStartIdx.Value < mInsertEndIdx))
			{
				char8 c = (char8)mTargetEditWidget.Content.mData.mText[mInsertStartIdx.Value].mChar;
				//Debug.WriteLine("StartIdx: {}, EndIdx: {}, mData.mText[startIdx]: '{}'", mInsertStartIdx, mInsertEndIdx, c);
				if ((c != ' ') && (c != ',') && (c != '('))
				    break;
				mInsertStartIdx++;
			}

            if ((mInvokeWidget != null) && (mInvokeSrcPositions != null) && (mInvokeWidget.mEntryList.Count > 0))
            {
				var data = mTargetEditWidget.Content.mData;

				int32 startIdx = mInvokeSrcPositions[0];
				if ((startIdx < data.mTextLength) && (data.mText[startIdx].mChar == '('))
				{
	                mInvokeSrcPositions.Clear();
	                int32 openDepth = 0;
					int32 braceDepth = 0;
	                int32 checkIdx = startIdx;
	                mInvokeSrcPositions.Add(startIdx);
	                int32 argCount = 0;

					bool inInterpolatedString = false;
					bool inInterpolatedExpr = false;

					void HadContent()
					{
						if (argCount == 0)
							argCount++;
					}

					bool failed = false;
	                while (checkIdx < data.mText.Count)
	                {
	                    var charData = data.mText[checkIdx];
						if (inInterpolatedExpr)
						{
							if ((SourceElementType)charData.mDisplayTypeId == .Normal)
							{
								if (charData.mChar == '{')
								{
									braceDepth++;
								}
								else if (charData.mChar == '}')
								{
									braceDepth--;
									if (braceDepth == 0)
										inInterpolatedExpr = false;
								}
							}

						}
	                    else if ((SourceElementType)charData.mDisplayTypeId == .Normal)
	                    {
							if (charData.mChar == '{')
							{
								braceDepth++;
								if (inInterpolatedString)
								{
									inInterpolatedExpr = true;
								}
								else
								{
									failed = true;
									break;
								}
							}
							else if (charData.mChar == '}')
								braceDepth--;
	                        else if (charData.mChar == '(')
	                            openDepth++;
	                        else if (charData.mChar == ')')
	                        {
								openDepth--;
	                        }
	                        else if ((charData.mChar == ',') && (openDepth == 1))
	                        {
	                            mInvokeSrcPositions.Add(checkIdx);
	                            argCount++;
	                        }
	                        else if (!((char8)charData.mChar).IsWhiteSpace)
	                            HadContent();

							if (openDepth == 0)
							{
							    mInvokeSrcPositions.Add(checkIdx);
								break;
							}
	                    }
						else if ((SourceElementType)charData.mDisplayPassId != .Comment)
						{
							if ((SourceElementType)charData.mDisplayTypeId == .Literal)
							{
								if ((charData.mChar == '"') &&
									(checkIdx > 1) && (data.mText[checkIdx - 1].mChar == '$') &&
									((SourceElementType)data.mText[checkIdx - 1].mDisplayTypeId == .Literal))
								{
									inInterpolatedString = true;
								}
								else if ((inInterpolatedString) &&
									(charData.mChar == '"') &&
									(checkIdx > 1) && (data.mText[checkIdx - 1].mChar != '\\'))
								{
									inInterpolatedString = false;
								}
							}

							HadContent();
						}
	                    checkIdx++;
	                }

					bool hasTooFewParams = false;
					if (!failed)
					{
						if (mInvokeWidget.mSelectIdx != -1)
						{
							let entry = mInvokeWidget.mEntryList[mInvokeWidget.mSelectIdx];
							if (!entry.HasParamsParam())
								hasTooFewParams = entry.GetParamCount() < argCount;
						}
					}

					if (hasTooFewParams)
					{
		                // Make sure the current method has enough params to support the args coming in
		                for (int checkOffset = 0; checkOffset < mInvokeWidget.mEntryList.Count; checkOffset++)
		                {
		                    int checkEntryIdx = (mInvokeWidget.mSelectIdx + checkOffset) % mInvokeWidget.mEntryList.Count;

		                    let entry = mInvokeWidget.mEntryList[checkEntryIdx];
							bool matches = false;
							int paramCount = entry.GetParamCount();
							if (argCount <= paramCount)
							{
								matches = true;
							}
							if (entry.HasParamsParam())
							{
								matches = true;
							}

							if ((matches) && (mInvokeWidget.mSelectIdx != -1))
							{
								let prevEntry = mInvokeWidget.mEntryList[mInvokeWidget.mSelectIdx];
								int prevMatchDiff = prevEntry.GetParamCount() - argCount;
								int newMatchDiff = entry.GetParamCount() - argCount;
								if ((prevMatchDiff >= 0) && (prevMatchDiff < newMatchDiff))
									matches = false;
							}

		                    if (matches)
		                    {
		                        mInvokeWidget.mSelectIdx = (int32)checkEntryIdx;
		                    }
		                }
					}
				}
            }

			//Debug.WriteLine("GetAsyncTextPos end {0} {1}", mInsertStartIdx, mInsertEndIdx);
        }

        bool SelectEntry(String curString)
        {
            if (mAutoCompleteListWidget == null)
                return false;

            int32 caseMatchMRUPriority = -1;
            int32 caseNotMatchMRUPriority = -1;            

			int32 selectIdx = mAutoCompleteListWidget.mSelectIdx;

            bool hadMatch = false;
            for (int32 i = 0; i < mAutoCompleteListWidget.mEntryList.Count; i++)
            {
                var entry = mAutoCompleteListWidget.mEntryList[i];
                if (entry.mEntryDisplay == curString)
                {
                    hadMatch = true;
                    selectIdx = i;
                    break;
                }

                if (curString.Length > entry.mEntryDisplay.Length)
                    continue;

                if (String.Compare(curString, 0, entry.mEntryDisplay, 0, curString.Length, false) == 0)
                {
                    hadMatch = true;
                    int32 priority = -1;
                    sAutoCompleteMRU.TryGetValue(entry.mEntryDisplay, out priority);
                    if (priority > caseMatchMRUPriority)
                    {
						selectIdx = i;
                        caseMatchMRUPriority = priority;
                    }
                }
                else if ((caseMatchMRUPriority == -1) && (String.Compare(curString, 0, entry.mEntryDisplay, 0, curString.Length, true) == 0))
                {
                    hadMatch = true;
                    int32 priority = -1;
                    sAutoCompleteMRU.TryGetValue(entry.mEntryDisplay, out priority);
                    if (priority > caseNotMatchMRUPriority)
                    {
                        selectIdx = i;
                        caseNotMatchMRUPriority = priority;
                    }
                }
            }

			if (selectIdx == -1)
				selectIdx = 0;

			if (!mAutoCompleteListWidget.mEntryList.IsEmpty)
				mAutoCompleteListWidget.Select(selectIdx);

            return hadMatch;
        }

		public void SetIgnoreMove(bool ignoreMove)
		{
			mIgnoreMove += ignoreMove ? 1 : -1;
		}

		// IDEHelper/third_party/FtsFuzzyMatch.h 
		[CallingConvention(.Stdcall), CLink]
		static extern bool fts_fuzzy_match(char8* pattern, char8* str, ref int32 outScore, uint8* matches, int maxMatches);

#if BF_PLATFORM_WINDOWS
		[CallingConvention(.Stdcall), CLink]
		static extern char8 IDEHelper_GetPinyinInitial(char32 c32);
#endif

		const int32 MATCH_TIER_EXACT_CASE = 0;
		const int32 MATCH_TIER_EXACT_NOCASE = 1;
		const int32 MATCH_TIER_PREFIX_CASE = 2;
		const int32 MATCH_TIER_PREFIX_NOCASE = 3;
		const int32 MATCH_TIER_WORD_PREFIX_CASE = 4;
		const int32 MATCH_TIER_WORD_PREFIX_NOCASE = 5;
		const int32 MATCH_TIER_SUBSTRING_CASE = 6;
		const int32 MATCH_TIER_SUBSTRING_NOCASE = 7;
		const int32 MATCH_TIER_INITIALS_CASE = 8;
		const int32 MATCH_TIER_INITIALS_NOCASE = 9;
		const int32 MATCH_TIER_FUZZY = 10;
		const int32 MATCH_TIER_OTHER = 11;

		bool TryGetPinyinInitial(char32 c32, out char8 initial)
		{
			initial = 0;

#if BF_PLATFORM_WINDOWS
			if (sPinyinInitialCache.TryGetValue(c32, out initial))
				return initial != 0;

			if ((c32 < (char32)0x3400) || (c32 > (char32)0x9FFF) || (c32 > (char32)0xFFFF))
			{
				sPinyinInitialCache[c32] = 0;
				return false;
			}

			initial = IDEHelper_GetPinyinInitial(c32);
			if ((initial >= 'A') && (initial <= 'Z'))
				initial = (char8)(initial - 'A' + 'a');
			sPinyinInitialCache[c32] = initial;
			return initial != 0;
#else
			return false;
#endif
		}

		int BuildInitialsAndPositions(String entry, char8* initials, uint8* initialPos, int maxCount, out bool hasPinyinInitial)
		{
			hasPinyinInitial = false;
			int initialCount = 0;
			bool prevWasUnderscore = false;
			int entryIdx = 0;
			for (char32 entryC in entry.DecodedChars)
			{
				int nextEntryIdx = @entryC.NextIndex;
				if (entryC == '_')
				{
					prevWasUnderscore = true;
					entryIdx = nextEntryIdx;
					continue;
				}

				bool appendInitial = false;
				char8 initialC = 0;
				if ((entryIdx == 0) || (prevWasUnderscore) || (entryC.IsUpper) || ((entryC >= '0') && (entryC <= '9')))
				{
					if (entryC <= (char32)0x7F)
					{
						char8 entryC8 = (char8)entryC;
						if (entryC8.IsLetterOrDigit)
						{
							initialC = entryC8;
							appendInitial = true;
						}
					}
				}

				if (!appendInitial && TryGetPinyinInitial(entryC, out initialC))
				{
					appendInitial = true;
					hasPinyinInitial = true;
				}

				if (appendInitial && (initialCount < maxCount) && (entryIdx <= uint8.MaxValue))
				{
					initials[initialCount] = initialC;
					initialPos[initialCount] = (uint8)entryIdx;
					initialCount++;
				}

				prevWasUnderscore = false;
				entryIdx = nextEntryIdx;
			}

			return initialCount;
		}

		bool IsWordBoundaryPrefixMatch(String entry, String filter, bool ignoreCase)
		{
			int filterLen = filter.Length;
			int entryLen = entry.Length;
			if ((filterLen == 0) || (filterLen > entryLen))
				return false;

			char8* entryPtr = entry.Ptr;
			char8* filterPtr = filter.Ptr;
			bool prevWasUnderscore = false;
			for (int entryIdx = 0; entryIdx < entryLen; entryIdx++)
			{
				char8 entryC = entryPtr[entryIdx];

				if (entryC == '_')
				{
					prevWasUnderscore = true;
					continue;
				}

				if ((entryIdx == 0) || (prevWasUnderscore) || (entryC.IsUpper) || (entryC.IsDigit))
				{
					if ((entryLen - entryIdx >= filterLen) && (String.Compare(entryPtr + entryIdx, filterLen, filterPtr, filterLen, ignoreCase) == 0))
						return true;
				}

				prevWasUnderscore = false;
			}

			return false;
		}

		bool IsInitialsMatch(String entry, String filter, bool ignoreCase)
		{
			int filterLen = filter.Length;
			int entryLen = entry.Length;
			if ((filterLen <= 0) || (filterLen > entryLen))
				return false;

			char8* filterPtr = filter.Ptr;
			char8[256] initialStr = ?;
			uint8[256] initialPos;
			char8* initialStrPtr = &initialStr;
			bool hasPinyinInitial = false;
			int initialLen = BuildInitialsAndPositions(entry, &initialStr, &initialPos, initialStr.Count, out hasPinyinInitial);
			if ((filterLen == 1) && (!hasPinyinInitial))
				return false;
			if (hasPinyinInitial)
			{
				for (int startIdx = 0; startIdx <= initialLen - filterLen; startIdx++)
				{
					if (String.Compare(initialStrPtr + startIdx, filterLen, filterPtr, filterLen, ignoreCase) == 0)
						return true;
				}
				return false;
			}
			return (initialLen >= filterLen) && (String.Compare(&initialStr, filterLen, filterPtr, filterLen, ignoreCase) == 0);
		}

		bool IsSubstringMatch(String entry, String filter, bool ignoreCase)
		{
			int filterLen = filter.Length;
			int entryLen = entry.Length;
			if ((filterLen == 0) || (filterLen > entryLen))
				return false;

			char8* entryPtr = entry.Ptr;
			char8* filterPtr = filter.Ptr;
			for (int entryIdx = 0; entryIdx <= entryLen - filterLen; entryIdx++)
			{
				if (String.Compare(entryPtr + entryIdx, filterLen, filterPtr, filterLen, ignoreCase) == 0)
					return true;
			}

			return false;
		}

		int32 GetEntryMatchTier(AutoCompleteListWidget.EntryWidget entry, String filter, bool doFuzzyAutoComplete)
		{
			if (filter.Length == 0)
				return MATCH_TIER_OTHER;

			String display = entry.mEntryDisplay;
			if (display == filter)
				return MATCH_TIER_EXACT_CASE;

			if ((display.Length == filter.Length) && (String.Compare(filter, 0, display, 0, filter.Length, true) == 0))
				return MATCH_TIER_EXACT_NOCASE;

			if ((filter.Length <= display.Length) && (String.Compare(filter, 0, display, 0, filter.Length, false) == 0))
				return MATCH_TIER_PREFIX_CASE;

			if ((filter.Length <= display.Length) && (String.Compare(filter, 0, display, 0, filter.Length, true) == 0))
				return MATCH_TIER_PREFIX_NOCASE;

			if (IsWordBoundaryPrefixMatch(display, filter, false))
				return MATCH_TIER_WORD_PREFIX_CASE;

			if (IsWordBoundaryPrefixMatch(display, filter, true))
				return MATCH_TIER_WORD_PREFIX_NOCASE;

			if (IsSubstringMatch(display, filter, false))
				return MATCH_TIER_SUBSTRING_CASE;

			if (IsSubstringMatch(display, filter, true))
				return MATCH_TIER_SUBSTRING_NOCASE;

			if (IsInitialsMatch(display, filter, false))
				return MATCH_TIER_INITIALS_CASE;

			if (IsInitialsMatch(display, filter, true))
				return MATCH_TIER_INITIALS_NOCASE;

			if (doFuzzyAutoComplete)
				return MATCH_TIER_FUZZY;

			return MATCH_TIER_OTHER;
		}

		int32 GetEntryTypePriority(StringView entryType, String filter, bool isMember)
		{
			bool isTypeLike = false;
			bool isMemberLike = false;
			bool isNamespaceLike = false;
			switch (entryType)
			{
			case "class", "interface", "valuetype", "payloadEnum", "generic", "object":
				isTypeLike = true;
			case "method", "extmethod", "property", "field", "variable", "value", "parameter":
				isMemberLike = true;
			case "namespace", "folder":
				isNamespaceLike = true;
			default:
			}

			bool prefersTypeLike = false;
			bool prefersMemberLike = false;
			if (!filter.IsEmpty)
			{
				char8 firstC = filter[0];
				if (firstC.IsUpper)
					prefersTypeLike = true;
				else if (firstC.IsLower)
					prefersMemberLike = true;
			}

			if (isMember)
			{
				if (isMemberLike)
					return 0;
				if (isTypeLike)
					return 1;
				if (isNamespaceLike)
					return 2;
				return 3;
			}

			if (prefersTypeLike)
			{
				if (isTypeLike)
					return 0;
				if (isNamespaceLike)
					return 1;
				if (isMemberLike)
					return 2;
				return 3;
			}

			if (prefersMemberLike)
			{
				if (isMemberLike)
					return 0;
				if (isTypeLike)
					return 1;
				if (isNamespaceLike)
					return 2;
				return 3;
			}

			if (isTypeLike || isMemberLike)
				return 1;
			if (isNamespaceLike)
				return 2;
			return 3;
		}

		int CompareEntries(AutoCompleteListWidget.EntryWidget left, AutoCompleteListWidget.EntryWidget right)
		{
			if (left.mMatchTier < right.mMatchTier)
				return -1;
			if (left.mMatchTier > right.mMatchTier)
				return 1;

			if ((left.mMatchTier >= MATCH_TIER_FUZZY) || (right.mMatchTier >= MATCH_TIER_FUZZY))
			{
				if (left.mScore > right.mScore)
					return -1;
				if (left.mScore < right.mScore)
					return 1;
			}

			if (left.mTypePriority < right.mTypePriority)
				return -1;
			if (left.mTypePriority > right.mTypePriority)
				return 1;

			if (left.mMRUPriority > right.mMRUPriority)
				return -1;
			if (left.mMRUPriority < right.mMRUPriority)
				return 1;

			int nameLenCmp = left.mEntryDisplay.Length - right.mEntryDisplay.Length;
			if (nameLenCmp != 0)
				return nameLenCmp;

			return String.Compare(left.mEntryDisplay, right.mEntryDisplay, true);
		}

		/// Checks whether the given entry matches the filter and updates its score and match indices accordingly.
		bool DoesFilterMatchFuzzy(AutoCompleteListWidget.EntryWidget entry, String filter)
		{
			if (filter.Length == 0)
				return true;

			if (filter.Length > entry.mEntryDisplay.Length)
				return false;

			int32 score = 0;
			uint8[256] matches = ?;

			if (!fts_fuzzy_match(filter.CStr(), entry.mEntryDisplay.CStr(), ref score, &matches, matches.Count))
			{
				entry.SetMatches(Span<uint8>((uint8*)null, 0));
				entry.mScore = score;
				return false;
			}
			
			// Should be the amount of Unicode-codepoints in filter though it' probably faster to do it this way
			int matchesLength = 0;

			for (uint8 i = 0;; i++)
			{
				uint8 matchIndex = matches[i];
				
				if ((matchIndex == 0 && i != 0) || i == uint8.MaxValue)
				{
					matchesLength = i;
					break;
				}
			}

			entry.SetMatches(Span<uint8>(&matches, matchesLength));
			entry.mScore = score;

			return true;
		}

		bool DoesFilterMatch(String entry, String filter)
		{	
			if (filter.Length == 0)
				return true;

			char8* entryPtr = entry.Ptr;
			char8* filterPtr = filter.Ptr;

			int filterLen = (int)filter.Length;
			int entryLen = (int)entry.Length;
			bool entryHasNonAscii = false;
			for (int i = 0; i < entryLen; i++)
			{
				if ((uint8)entryPtr[i] >= 0x80)
				{
					entryHasNonAscii = true;
					break;
				}
			}

			bool hasUnderscore = false;
			bool checkInitials = filterLen > 1;
			if ((entryHasNonAscii) && (filterLen > 0))
				checkInitials = true;
			for (int i = 0; i < (int)filterLen; i++)
			{
				char8 c = filterPtr[i];
				if (c == '_')
					hasUnderscore = true;
				else if ((filterPtr[i].IsLower) && (!entryHasNonAscii))
					checkInitials = false;
			}

			if (hasUnderscore)
				return (entryLen >= filterLen) && (String.Compare(entryPtr, filterLen, filterPtr, filterLen, true) == 0);

			char8[256] initialStr = ?;
			uint8[256] initialPos;
			char8* initialStrPtr = &initialStr;
			bool hasPinyinInitial = false;
			int initialLen = BuildInitialsAndPositions(entry, &initialStr, &initialPos, initialStr.Count, out hasPinyinInitial);

			bool prevWasUnderscore = false;
			for (int entryIdx = 0; entryIdx < entryLen; entryIdx++)
			{
				char8 entryC = entryPtr[entryIdx];

				if (entryC == '_')
				{
					prevWasUnderscore = true;
					continue;
				}

				if ((entryIdx == 0) || (prevWasUnderscore) || (entryC.IsUpper) || (entryC.IsDigit))
				{
					if ((entryLen - entryIdx >= filterLen) && (String.Compare(entryPtr + entryIdx, filterLen, filterPtr, filterLen, true) == 0))
						return true;
				}
				prevWasUnderscore = false;

				if (filterLen == 1)
					break; // Don't check inners for single-character case
			}	

			if (!checkInitials)
				return IsSubstringMatch(entry, filter, true);
			if ((filterLen == 1) && (!hasPinyinInitial))
				return IsSubstringMatch(entry, filter, true);
			if (hasPinyinInitial)
			{
				for (int startIdx = 0; startIdx <= initialLen - filterLen; startIdx++)
				{
					if (String.Compare(initialStrPtr + startIdx, filterLen, filterPtr, filterLen, true) == 0)
						return true;
				}
			}
			else if ((initialLen >= filterLen) && (String.Compare(&initialStr, filterLen, filterPtr, filterLen, true) == 0))
				return true;

			// Rider-like fallback: allow infix match, e.g. "e"/"es" -> "Test".
			return IsSubstringMatch(entry, filter, true);
		}

		int FindSubstringStart(String entry, String filter, bool ignoreCase)
		{
			int filterLen = filter.Length;
			int entryLen = entry.Length;
			if (filterLen == 0)
				return 0;
			if (filterLen > entryLen)
				return -1;

			char8* entryPtr = entry.Ptr;
			char8* filterPtr = filter.Ptr;
			for (int entryIdx = 0; entryIdx <= entryLen - filterLen; entryIdx++)
			{
				if (String.Compare(entryPtr + entryIdx, filterLen, filterPtr, filterLen, ignoreCase) == 0)
					return entryIdx;
			}
			return -1;
		}

		int FindWordBoundaryPrefixStart(String entry, String filter, bool ignoreCase)
		{
			int filterLen = filter.Length;
			int entryLen = entry.Length;
			if ((filterLen == 0) || (filterLen > entryLen))
				return -1;

			char8* entryPtr = entry.Ptr;
			char8* filterPtr = filter.Ptr;
			bool prevWasUnderscore = false;
			for (int entryIdx = 0; entryIdx < entryLen; entryIdx++)
			{
				char8 entryC = entryPtr[entryIdx];
				if (entryC == '_')
				{
					prevWasUnderscore = true;
					continue;
				}

				if ((entryIdx == 0) || (prevWasUnderscore) || (entryC.IsUpper) || (entryC.IsDigit))
				{
					if ((entryLen - entryIdx >= filterLen) && (String.Compare(entryPtr + entryIdx, filterLen, filterPtr, filterLen, ignoreCase) == 0))
						return entryIdx;
				}
				prevWasUnderscore = false;
			}
			return -1;
		}

		void SetEntryMatchRange(AutoCompleteListWidget.EntryWidget entry, int start, int length)
		{
			if ((start < 0) || (length <= 0))
			{
				entry.SetMatches(Span<uint8>((uint8*)null, 0));
				return;
			}

			uint8[256] matches = ?;
			int count = 0;
			int end = Math.Min(start + length, entry.mEntryDisplay.Length);
			for (int i = start; i < end; i++)
			{
				if ((i > uint8.MaxValue) || (count >= matches.Count))
					break;
				matches[count++] = (uint8)i;
			}

			if (count == 0)
				entry.SetMatches(Span<uint8>((uint8*)null, 0));
			else
				entry.SetMatches(Span<uint8>(&matches, count));
		}

		void SetEntryInitialMatches(AutoCompleteListWidget.EntryWidget entry, String filter, bool ignoreCase)
		{
			int filterLen = filter.Length;
			if (filterLen <= 0)
			{
				entry.SetMatches(Span<uint8>((uint8*)null, 0));
				return;
			}

			String display = entry.mEntryDisplay;
			char8* filterPtr = filter.Ptr;

			char8[256] initials = ?;
			uint8[256] initialPos = ?;
			char8* initialsPtr = &initials;
			uint8* initialPosPtr = &initialPos;
			bool hasPinyinInitial = false;
			int initialCount = BuildInitialsAndPositions(display, &initials, &initialPos, initials.Count, out hasPinyinInitial);
			if ((filterLen == 1) && (!hasPinyinInitial))
			{
				entry.SetMatches(Span<uint8>((uint8*)null, 0));
				return;
			}

			if (hasPinyinInitial)
			{
				for (int startIdx = 0; startIdx <= initialCount - filterLen; startIdx++)
				{
					if (String.Compare(initialsPtr + startIdx, filterLen, filterPtr, filterLen, ignoreCase) == 0)
					{
						entry.SetMatches(Span<uint8>(initialPosPtr + startIdx, filterLen));
						return;
					}
				}
				entry.SetMatches(Span<uint8>((uint8*)null, 0));
				return;
			}

			if ((initialCount >= filterLen) && (String.Compare(&initials, filterLen, filterPtr, filterLen, ignoreCase) == 0))
				entry.SetMatches(Span<uint8>(&initialPos, filterLen));
			else
				entry.SetMatches(Span<uint8>((uint8*)null, 0));
		}

		void UpdateNonFuzzyMatches(AutoCompleteListWidget.EntryWidget entry, String filter)
		{
			if (filter.IsEmpty)
			{
				entry.SetMatches(Span<uint8>((uint8*)null, 0));
				return;
			}

			switch (entry.mMatchTier)
			{
			case MATCH_TIER_EXACT_CASE, MATCH_TIER_EXACT_NOCASE, MATCH_TIER_PREFIX_CASE, MATCH_TIER_PREFIX_NOCASE:
				SetEntryMatchRange(entry, 0, filter.Length);
			case MATCH_TIER_WORD_PREFIX_CASE:
				SetEntryMatchRange(entry, FindWordBoundaryPrefixStart(entry.mEntryDisplay, filter, false), filter.Length);
			case MATCH_TIER_WORD_PREFIX_NOCASE:
				SetEntryMatchRange(entry, FindWordBoundaryPrefixStart(entry.mEntryDisplay, filter, true), filter.Length);
			case MATCH_TIER_SUBSTRING_CASE:
				SetEntryMatchRange(entry, FindSubstringStart(entry.mEntryDisplay, filter, false), filter.Length);
			case MATCH_TIER_SUBSTRING_NOCASE:
				SetEntryMatchRange(entry, FindSubstringStart(entry.mEntryDisplay, filter, true), filter.Length);
			case MATCH_TIER_INITIALS_CASE:
				SetEntryInitialMatches(entry, filter, false);
			case MATCH_TIER_INITIALS_NOCASE:
				SetEntryInitialMatches(entry, filter, true);
			default:
				SetEntryMatchRange(entry, FindSubstringStart(entry.mEntryDisplay, filter, true), filter.Length);
			}
		}

        void UpdateData(String selectString, bool changedAfterInfo)
        {
			int32 insertStartIdx = InsertStartIdx;

			if ((mInsertEndIdx != -1) && (mInsertEndIdx < insertStartIdx))
			{
				mPopulating = false;
				Close();
				return;
			}

            int visibleCount = 0;
            if (mAutoCompleteListWidget != null)
                visibleCount = mAutoCompleteListWidget.mEntryList.Count;
            if ((mAutoCompleteListWidget != null) && ((mInsertEndIdx != -1) || (selectString != null)))
            {
                String curString;
                if (selectString != null)
                    curString = selectString;
                else
				{
					curString = scope:: String();
					String identifierFilter = scope:: String();
					GetIdentifierFilterAtCursor(identifierFilter);
					if ((mIsMember) && (!identifierFilter.IsEmpty))
					{
						curString.Append(identifierFilter);
					}
					else
					{
                    	mTargetEditWidget.Content.ExtractString(insertStartIdx, mInsertEndIdx - insertStartIdx, curString);
						// Some parser insert ranges may skip a leading digit in mixed token input (eg "1s").
						// Prefer the full identifier-at-cursor when it provides a longer filter.
						if ((!identifierFilter.IsEmpty) && (identifierFilter.Length > curString.Length))
						{
							curString.Clear();
							curString.Append(identifierFilter);
						}
					}
				}
                
				// Re-rank when text changed OR we have a non-empty filter string.
				// This keeps server-refresh path (changedAfterInfo=false) aligned with local VS-like ordering.
				bool shouldRefilterAndSort = changedAfterInfo || (curString.Length > 0);
				if (shouldRefilterAndSort)
                {
					mAutoCompleteListWidget.mSelectIdx = -1;

                    if ((curString.Length == 0) && (!mIsMember) && (mInvokeSrcPositions == null))
                    {
						mPopulating = false;
                        Close();
                        return;
                    }
                
                    // Only show applicable entries                    
                    mAutoCompleteListWidget.mMaxWidth = 0;
					mAutoCompleteListWidget.mDocWidth = 0;
					mAutoCompleteListWidget.mRightBoxAdjust = 0;
                    visibleCount = 0;
					if (mAutoCompleteListWidget.mEntryList == mAutoCompleteListWidget.mFullEntryList)
						mAutoCompleteListWidget.mEntryList = new List<AutoCompleteListWidget.EntryWidget>();
					mAutoCompleteListWidget.mEntryList.Clear();

					int spaceIdx = curString.LastIndexOf(' ');
					if (spaceIdx != -1)
						curString.Remove(0, spaceIdx + 1);

					curString.Trim();
					if (curString == ".")
						curString.Clear();

					// For member access expressions like "p.es" / "ptr->es", only filter by the tail segment.
					// This matches Rider/VS behavior and avoids filtering against the full expression text.
					int splitIdx = curString.LastIndexOf('.');
					int lastColon = curString.LastIndexOf(':');
					if (lastColon > splitIdx)
						splitIdx = lastColon;
					for (int i = 1; i < curString.Length; i++)
					{
						if ((curString[i - 1] == '-') && (curString[i] == '>'))
							splitIdx = Math.Max(splitIdx, i);
					}

					if (splitIdx != -1)
					{
						if (splitIdx + 1 >= curString.Length)
							curString.Clear();
						else
							curString.Remove(0, splitIdx + 1);
					}

					bool doFuzzyAutoComplete = gApp.mSettings.mEditorSettings.mFuzzyAutoComplete;

                    for (int i < mAutoCompleteListWidget.mFullEntryList.Count)
                    {
                        var entry = mAutoCompleteListWidget.mFullEntryList[i];

						bool fuzzyMatched = false;
						if (doFuzzyAutoComplete)
							fuzzyMatched = DoesFilterMatchFuzzy(entry, curString);
						bool nonFuzzyMatched = DoesFilterMatch(entry.mEntryDisplay, curString);

						if (fuzzyMatched || nonFuzzyMatched)
						{
							if (!fuzzyMatched)
								entry.mScore = 0;
							entry.mMatchTier = GetEntryMatchTier(entry, curString, doFuzzyAutoComplete);
							entry.mTypePriority = GetEntryTypePriority(entry.mEntryType, curString, mIsMember);
							if (nonFuzzyMatched)
								UpdateNonFuzzyMatches(entry, curString);
							sAutoCompleteMRU.TryGetValue(entry.mEntryDisplay, out entry.mMRUPriority);
							mAutoCompleteListWidget.mEntryList.Add(entry);
							if (!doFuzzyAutoComplete)
								mAutoCompleteListWidget.UpdateEntry(entry, visibleCount);
                            visibleCount++;
						}
						else
						{
							entry.mScore = 0;
							entry.mMatchTier = MATCH_TIER_OTHER;
							entry.mTypePriority = 3;
							entry.mMRUPriority = -1;
                            mAutoCompleteListWidget.UpdateEntry(entry, -1);
						}
                    }

					{
						String log = scope .();
						log.AppendF("AC.UpdateData filter='{0}' changed={1} member={2} fuzzy={3} full={4} visible={5}",
							curString, changedAfterInfo, mIsMember, doFuzzyAutoComplete, mAutoCompleteListWidget.mFullEntryList.Count, visibleCount);
						Trace(log);
					}

					if ((doFuzzyAutoComplete) || (curString.Length > 0))
					{
						// VS-like ordering: exact/prefix/camelCase-first, then fuzzy, then MRU/name.
						mAutoCompleteListWidget.mEntryList.Sort(scope (left, right) =>
							{
								return CompareEntries(left, right);
							});
	
						for (int i < mAutoCompleteListWidget.mEntryList.Count)
						{
							mAutoCompleteListWidget.UpdateEntry(mAutoCompleteListWidget.mEntryList[i], i);
						}
					}

                    if ((visibleCount == 0) && (mInvokeSrcPositions == null))
                    {
						if ((mIsMember) && (mAutoCompleteListWidget != null) && (mAutoCompleteListWidget.mFullEntryList.Count > 0))
						{
							// Over-filtered member completion: hide popup safely but keep cached full list.
							// Use Close() (not Dispose()) and detach root to avoid dangling widget/window references.
							if (mListWindow != null)
							{
								if (mListWindow.mRootWidget == mAutoCompleteListWidget)
									mListWindow.mRootWidget = null;
								mListWindow.Close();
								mListWindow = null;
							}
							if ((IsInPanel()) && (mAutoCompleteListWidget.mParent != null))
								mAutoCompleteListWidget.RemoveSelf();
							if (mAutoCompleteListWidget != null)
							{
								mAutoCompleteListWidget.mOwnsWindow = false;
								mAutoCompleteListWidget.mWidgetWindow = null;
							}
							Trace("AC.UpdateData HIDE visible=0 member keepCache");
							mPopulating = false;
							return;
						}

						Trace("AC.UpdateData CLOSE visible=0 invoke=null");
						mPopulating = false;
                        Close();
                        return;
                    }
                }

				// Only take last part, useful for "overide <methodName>" autocompletes
				for (int32 i = 0; i < curString.Length; i++)
				{
					char8 c = curString[i];
					if ((c == '<') || (c == '('))
						break;
					if (c.IsWhiteSpace)
					{
						curString.Remove(0, i + 1);
						i = 0;
					}
				}

                if ((!SelectEntry(curString)) && (curString.Length > 0))
                {
                    // If we can't find any matches, at least select a string that starts with the right character
                    curString.RemoveToEnd(1);
                    SelectEntry(curString);
                }

				if (mAutoCompleteListWidget != null)
				{
					mAutoCompleteListWidget.UpdateWidth();
				}
            }
            else if (selectString == null)
            {
                SelectEntry("");
            }

            SetIgnoreMove(true);

			gApp.mAutoCompletePanel.StartBind(this);

			int32 prevInvokeSelect = 0;
            if (mInvokeWidget != null)
            {
				prevInvokeSelect = mInvokeWidget.mSelectIdx;
                if ((mInvokeWidget.mEntryList.Count > 0) && (mInvokeSrcPositions != null) && (!mInvokeSrcPositions.IsEmpty) && (mInvokeWidget.mSelectIdx >= 0))
                {
					if (IsInPanel())
					{
						mInvokeWidget.mOwnsWindow = false;
					}
					else
					{
						mInvokeWidget.mOwnsWindow = true;
						mInvokeWidget.ResizeContent(false);
						if ((mInvokeWidget.mWidth > 0) && (mInvokeWidget.mHeight > 0))
						{
		                    UpdateWindow(ref mInvokeWindow, mInvokeWidget, mInvokeSrcPositions[0], (int32)mInvokeWidget.mWidth, (int32)mInvokeWidget.mHeight);
							mInvokeWidget.ResizeContent(true);
						}
					}
                }
                else
                {
					if ((mInvokeWindow == null) || (mInvokeWindow.mRootWidget != mInvokeWidget))
						delete mInvokeWidget;
                    if (mInvokeWindow != null)
                    {
                        mInvokeWindow.Close();
                        mInvokeWindow = null;
                    }
                    mInvokeWidget = null;
                }
            }

            if (mAutoCompleteListWidget != null)
            {
				HandleAutoCompleteListWidget(visibleCount);
            }
			gApp.mAutoCompletePanel.FinishBind();
            SetIgnoreMove(false);

            if ((mAutoCompleteListWidget != null) && (!mAutoCompleteListWidget.mIsInitted))
                mAutoCompleteListWidget.Init();
            if ((mInvokeWidget != null) && (!mInvokeWidget.mIsInitted))
			{
				mInvokeWidget.mSelectIdx = prevInvokeSelect;
                mInvokeWidget.Init();
			}
        }

		public void UpdateInfo(String info)
		{
			List<uint8> matchIndices = new:ScopedAlloc! .(256);
			for (var entryView in info.Split('\n'))
			{
				StringView entryType = StringView(entryView);
				int tabPos = entryType.IndexOf('\t');
				StringView entryDisplay = default;
				if (tabPos != -1)
				{
					entryDisplay = StringView(entryView, tabPos + 1);
					entryType = StringView(entryType, 0, tabPos);
				}
				
				StringView matches = default;
				StringView documentation = default;
				int matchesPos = entryDisplay.IndexOf('\x02');
				matchIndices.Clear();
				if (matchesPos != -1)
				{
					matches = StringView(entryDisplay, matchesPos + 1);
					entryDisplay = StringView(entryDisplay, 0, matchesPos);

					for(var sub in matches.Split(','))
					{
						if(sub.StartsWith('X'))
							break;

						var result = int64.Parse(sub, .HexNumber);

						Debug.Assert((result case .Ok(let value)) && value <= uint8.MaxValue);

						// TODO(FUZZY): we could save start and length instead of single chars
						matchIndices.Add((uint8)result.Value);
					}

					int docPos = matches.IndexOf('\x03');
					if (docPos != -1)
					{
						documentation = StringView(matches, docPos + 1);
						matches = StringView(matches, 0, docPos);
					}
				}
				else
				{
					int docPos = entryDisplay.IndexOf('\x03');
					if (docPos != -1)
					{
						documentation = StringView(entryDisplay, docPos + 1);
						entryDisplay = StringView(entryDisplay, 0, docPos);
					}
				}
				
				StringView entryInsert = default;
				tabPos = entryDisplay.IndexOf('\t');
				if (tabPos != -1)
				{
					entryInsert = StringView(entryDisplay, tabPos + 1);
					entryDisplay = StringView(entryDisplay, 0, tabPos);
				}

				int entryIdx = 0;
				switch (entryType)
				{
				case "insertRange":
				case "invoke":
				case "invoke_cur":
				case "isMember":
				case "invokeInfo":
				case "invokeLeftParen":
				case "select":
				default:
				    {
						if (((!documentation.IsEmpty) || (!matchIndices.IsEmpty)) && (mAutoCompleteListWidget != null))
						{
							while (entryIdx < mAutoCompleteListWidget.mEntryList.Count)
							{
								let entry = mAutoCompleteListWidget.mEntryList[entryIdx];
								if ((entry.mEntryDisplay == entryDisplay) && (entry.mEntryType == entryType))
								{
									if (!matchIndices.IsEmpty)
									{
										if (entry.mMatchIndices == null)
											entry.mMatchIndices = new:(mAutoCompleteListWidget.[Friend]mAlloc) List<uint8>(matchIndices.GetEnumerator());
										else
										{
											entry.mMatchIndices.Clear();
											entry.mMatchIndices.AddRange(matchIndices);
										}
									}

									if ((!documentation.IsEmpty) && entry.mDocumentation == null)
										entry.mDocumentation = new:(mAutoCompleteListWidget.[Friend]mAlloc) String(documentation);

									break;
								}
								entryIdx++;
							}
						}
				    }                        
				}

				if (mAutoCompleteListWidget != null)
					mAutoCompleteListWidget.UpdateWidth();
			}
			MarkDirty();

			//Debug.WriteLine("UpdateInfo {0} {1}", mInsertStartIdx, mInsertEndIdx);
		}

		public void HandleAutoCompleteListWidget(int visibleCount)
		{
			if (mAutoCompleteListWidget.mEntryList.Count > 0)
			{
				mAutoCompleteListWidget.mOwnsWindow = !IsInPanel();
				mAutoCompleteListWidget.mAutoFocus = IsInPanel();
				int32 windowWidth = (int32)mAutoCompleteListWidget.mMaxWidth;
				if (mAutoCompleteListWidget.mRightBoxAdjust != 0)
					windowWidth += (int32)mAutoCompleteListWidget.mRightBoxAdjust; // - GS!(16);
				//windowWidth += (int32)mAutoCompleteListWidget.mDocWidth;
				windowWidth += GS!(16);

				int32 contentHeight = (int32)(visibleCount * mAutoCompleteListWidget.mItemSpacing);
				int32 windowHeight = contentHeight + GS!(20);
				int32 maxWindowHeight = GetMaxWindowHeight();
				bool wantScrollbar = false;
				if (windowHeight > maxWindowHeight)
				{
				    windowHeight = maxWindowHeight;
				    wantScrollbar = true;
				    windowWidth += GS!(12);
				}
				contentHeight += GS!(8);
				mAutoCompleteListWidget.ResizeContent(windowWidth, contentHeight, wantScrollbar);
				//mAutoCompleteListWidget.UpdateWidth();
				if ((mInsertStartIdx != null) && (!IsInPanel()))
				{
					//Debug.WriteLine($"HandleAutoCompleteListWidget mInsertStartIdx:{mInsertStartIdx}");

					UpdateWindow(ref mListWindow, mAutoCompleteListWidget, mInsertStartIdx.Value, windowWidth, windowHeight);
					mAutoCompleteListWidget.mWantHeight = windowHeight;
				}
				mAutoCompleteListWidget.UpdateScrollbars();
				mAutoCompleteListWidget.CenterSelection();
				mAutoCompleteListWidget.UpdateWidth();
			}
			else
			{
				if ((mListWindow == null) || (mListWindow.mRootWidget != mAutoCompleteListWidget))
			    {
					if (IsInPanel())
					{
						gApp.mAutoCompletePanel.Unbind(this);
						if (mInvokeWidget != null)
						{
							if (mInvokeWidget.mParent != null)
								mInvokeWidget.RemoveSelf();
							delete mInvokeWidget;
							mInvokeWidget = null;
						}
					}
					delete mAutoCompleteListWidget;
				}
			    if (mListWindow != null)
			    {
			        mListWindow.Close();
			        mListWindow = null;
			    }
			    mAutoCompleteListWidget = null;
			}
		}

		void AddCurrentFileTypeEntries()
		{
			if ((mAutoCompleteListWidget == null) || (mInvokeOnly))
				return;
			if (mIsMember)
				return;

			int32 checkPos = (mInsertStartIdx != null) ? mInsertStartIdx.Value : (int32)mTargetEditWidget.Content.CursorTextPos;
			int32 left = checkPos - 1;
			while ((left >= 0) && (mTargetEditWidget.Content.mData.mText[left].mChar.IsWhiteSpace))
				left--;
			if (left >= 0)
			{
				char32 c = mTargetEditWidget.Content.mData.mText[left].mChar;
				if (c == '.')
					return;
				if ((c == ':') && (left > 0) && (mTargetEditWidget.Content.mData.mText[left - 1].mChar == ':'))
					return;
				if ((c == '>') && (left > 0) && (mTargetEditWidget.Content.mData.mText[left - 1].mChar == '-'))
					return;
			}

			var sewc = mTargetEditWidget.Content as SourceEditWidgetContent;
			if (sewc == null)
				return;

			var data = sewc.PreparedData;
			if (data == null)
				return;

			bool HasEntryDisplay(StringView entryDisplay)
			{
				for (var entry in mAutoCompleteListWidget.mFullEntryList)
				{
					if (entry.mEntryDisplay == entryDisplay)
						return true;
				}
				return false;
			}

			void AddTypeNameIfNeeded(StringView typeName, Image classIcon)
			{
				if (typeName.IsEmpty)
					return;
				if (HasEntryDisplay(typeName))
					return;
				mAutoCompleteListWidget.AddEntry("class", typeName, classIcon);
			}

			let classIcon = DarkTheme.sDarkTheme.GetImage(.Type_Class);
			for (var typeName in data.mTypeNames)
			{
				if (typeName != null)
					AddTypeNameIfNeeded(typeName, classIcon);
			}

			// Fallback: parse current source text directly so newly-typed local types
			// (including Chinese names) are available even if backend list is filtered.
			String sourceText = scope:: String();
			var content = mTargetEditWidget.Content;
			content.ExtractString(0, content.mData.mTextLength, sourceText);

			bool IsTypeDeclKeyword(StringView token)
			{
				switch (token)
				{
				case "class", "struct", "interface", "enum":
					return true;
				default:
					return false;
				}
			}

			int idx = 0;
			while (idx < sourceText.Length)
			{
				char8 c = sourceText[idx];
				if (!AutoComplete.IsIdentifierStartChar(c))
				{
					idx++;
					continue;
				}

				int tokenStart = idx;
				idx++;
				while ((idx < sourceText.Length) && AutoComplete.IsIdentifierChar(sourceText[idx]))
					idx++;
				StringView token = StringView(sourceText, tokenStart, idx - tokenStart);
				if (!IsTypeDeclKeyword(token))
					continue;

				while ((idx < sourceText.Length) && sourceText[idx].IsWhiteSpace)
					idx++;

				if ((idx < sourceText.Length) && (sourceText[idx] == '@'))
					idx++;

				if ((idx >= sourceText.Length) || (!AutoComplete.IsIdentifierStartChar(sourceText[idx])))
					continue;

				int typeStart = idx;
				idx++;
				while ((idx < sourceText.Length) && AutoComplete.IsIdentifierChar(sourceText[idx]))
					idx++;
				StringView typeName = StringView(sourceText, typeStart, idx - typeStart);
				AddTypeNameIfNeeded(typeName, classIcon);
			}
		}

        public void SetInfo(String info, bool clearList = true, int32 textOffset = 0, bool changedAfterInfo = false)
        {
			//Debug.WriteLine($"AutoComplete TextOffset:{textOffset} SetInfo:{info}");

			scope AutoBeefPerf("AutoComplete.SetInfo");

			bool hadPreviousInsertRange = mInsertStartIdx != null;
			int32 previousInsertStart = hadPreviousInsertRange ? mInsertStartIdx.Value : -1;
			int32 previousInsertEnd = mInsertEndIdx;
			DeleteAndNullify!(mInfoFilter);

			mPopulating = true;
			//defer { mPopulating = false; };

			Debug.Assert(!mClosed);

			mIsFixit = false;
			DeleteAndNullify!(mInsertStartIdx);
            mInsertEndIdx = -1;
			delete mInvokeSrcPositions;
            mInvokeSrcPositions = null;
			mUncertain = false;
			bool doClearList = clearList;

			// Some backends return only control records for intermediate member filters.
			// If there are no actual completion entries, keep the current list and re-filter locally.
			bool hasCompletionEntries = false;
			bool responseIsMember = false;
			bool hasIsMemberToken = false;
			for (var entryView in info.Split('\n'))
			{
				if (entryView.IsEmpty)
					continue;

				StringView entryType = StringView(entryView);
				int tabPos = entryType.IndexOf('\t');
				StringView entryDisplay = default;
				if (tabPos != -1)
				{
					entryDisplay = StringView(entryView, tabPos + 1);
					entryType = StringView(entryType, 0, tabPos);
				}

				if (entryType == "isMember")
				{
					responseIsMember = true;
					hasIsMemberToken = true;
				}

				bool isControlEntry =
					(entryType == "insertRange") ||
					(entryType == "invoke") ||
					(entryType == "invoke_cur") ||
					(entryType == "isMember") ||
					(entryType == "invokeInfo") ||
					(entryType == "invokeLeftParen") ||
					(entryType == "select") ||
					(entryType == "uncertain");
				if ((!isControlEntry) && (entryDisplay.Ptr != null))
					hasCompletionEntries = true;

				if (hasCompletionEntries)
					break;
			}

			bool reuseExistingMemberEntries = false;
			bool hasPrevFullList = (mAutoCompleteListWidget != null) && (!mAutoCompleteListWidget.mFullEntryList.IsEmpty);
			bool IsMemberAccessBefore(int32 pos)
			{
				if (pos <= 0)
					return false;

				int32 left = pos - 1;
				while ((left >= 0) && (mTargetEditWidget.Content.mData.mText[left].mChar.IsWhiteSpace))
					left--;

				if (left < 0)
					return false;

				char32 c = mTargetEditWidget.Content.mData.mText[left].mChar;
				if (c == '.')
					return true;
				if ((c == ':') && (left > 0) && (mTargetEditWidget.Content.mData.mText[left - 1].mChar == ':'))
					return true;
				if ((c == '>') && (left > 0) && (mTargetEditWidget.Content.mData.mText[left - 1].mChar == '-'))
					return true;
				return false;
			}

			bool isMemberContextByText = false;
			int32 checkStartPos = previousInsertStart;
			if (!hadPreviousInsertRange)
			{
				var data = mTargetEditWidget.Content.mData;
				int32 cursorPos = (int32)mTargetEditWidget.Content.CursorTextPos;
				cursorPos = Math.Min(cursorPos, data.mTextLength);
				int32 startPos = cursorPos;
				while (startPos > 0)
				{
					char32 c = data.mText[startPos - 1].mChar;
					if (!AutoComplete.IsIdentifierChar(c))
						break;
					startPos--;
				}
				checkStartPos = startPos;
			}
			isMemberContextByText = IsMemberAccessBefore(checkStartPos);
			if ((!hasIsMemberToken) && (isMemberContextByText))
				responseIsMember = true;

			bool shouldKeepExistingOnIncrement =
				hasPrevFullList &&
				clearList &&
				(!changedAfterInfo) &&
				(hasIsMemberToken || mIsMember || isMemberContextByText);
			if (shouldKeepExistingOnIncrement)
			{
				// Preserve the first full list for the current completion session and do local filtering only.
				// This keeps items like "GetType" available for infix filters like "t"/"et".
				doClearList = false;
				reuseExistingMemberEntries = true;
				if (!hasIsMemberToken)
					responseIsMember = mIsMember || isMemberContextByText;
			}

			mIsMember = responseIsMember;

			{
				int32 prevFullCount = (mAutoCompleteListWidget != null) ? (.)mAutoCompleteListWidget.mFullEntryList.Count : -1;
				String log = scope .();
				log.AppendF("AC.SetInfo len={0} clear={1} doClear={2} changed={3} hasEntries={4} memberCtx={5} reuse={6} prevFull={7} hadInsert={8}",
					info.Length, clearList, doClearList, changedAfterInfo, hasCompletionEntries, responseIsMember, reuseExistingMemberEntries, prevFullCount, hadPreviousInsertRange);
				Trace(log);
			}

            if (doClearList)
            {
                if (mAutoCompleteListWidget != null)
                {
					mIgnoreMove++;
					if (IsInPanel())
					{
						mAutoCompleteListWidget.RemoveSelf();
						delete mAutoCompleteListWidget;
					}
					else if (mListWindow != null)
					{
						// Will get deleted later...
						Debug.Assert(mListWindow.mRootWidget == mAutoCompleteListWidget);
					}
					else
						delete mAutoCompleteListWidget;
                    mAutoCompleteListWidget = null;
					mIgnoreMove--;
                }
            }
            if (mAutoCompleteListWidget == null)
			{
                mAutoCompleteListWidget = new AutoCompleteListWidget(this);
				//Debug.WriteLine("Created mAutoCompleteListWidget {} in {}", mAutoCompleteListWidget, this);
			}
            
			bool queueClearInvoke = false;
			bool hasInsertRangeEntry = false;
            if (queueClearInvoke)
            {
                mInvokeSrcPositions = null;
            }
            else
            {
				if (IsInPanel())
				{
					if (mInvokeWidget != null)
					{
						mInvokeWidget.RemoveSelf();
						delete mInvokeWidget;
					}
				}

                mInvokeWidget = new InvokeWidget(this);
            }

            InvokeWidget oldInvokeWidget = null;
            String selectString = null;
			List<uint8> matchIndices = new:ScopedAlloc! .(256);
			for (var entryView in info.Split('\n'))
            {
				Image entryIcon = null;
				StringView entryType = StringView(entryView);
				int tabPos = entryType.IndexOf('\t');
				StringView entryDisplay = default;
				if (tabPos != -1)
				{
					entryDisplay = StringView(entryView, tabPos + 1);
					entryType = StringView(entryType, 0, tabPos);
				}

				StringView matches = default;
				StringView documentation = default;
				int matchesPos = entryDisplay.IndexOf('\x02');
				matchIndices.Clear();
				if (matchesPos != -1)
				{
					matches = StringView(entryDisplay, matchesPos + 1);
					entryDisplay = StringView(entryDisplay, 0, matchesPos);

					for(var sub in matches.Split(','))
					{
						if(sub.StartsWith('X'))
							break;

						var result = int64.Parse(sub, .HexNumber);

						Debug.Assert((result case .Ok(let value)) && value <= uint8.MaxValue);

						// TODO(FUZZY): we could save start and length instead of single chars
						matchIndices.Add((uint8)result.Value);
					}

					int docPos = matches.IndexOf('\x03');
					if (docPos != -1)
					{
						documentation = StringView(matches, docPos + 1);
						matches = StringView(matches, 0, docPos);
					}
				}
				else
				{
					int docPos = entryDisplay.IndexOf('\x03');
					if (docPos != -1)
					{
						documentation = StringView(entryDisplay, docPos + 1);
						entryDisplay = StringView(entryDisplay, 0, docPos);
					}
				}
				

				StringView entryInsert = default;
				tabPos = entryDisplay.IndexOf('\t');
				if (tabPos != -1)
				{
					entryInsert = StringView(entryDisplay, tabPos + 1);
					entryDisplay = StringView(entryDisplay, 0, tabPos);
				}

				if (entryDisplay.Ptr == null)
				{
					if (entryView == "uncertain")
					{
						mUncertain = true;
					}
					continue;
				}

                switch (entryType)
                {
                case "method":
                    entryIcon = DarkTheme.sDarkTheme.GetImage(.Method);
				case "extmethod":
					entryIcon = DarkTheme.sDarkTheme.GetImage(.ExtMethod);
                case "field":
                    entryIcon = DarkTheme.sDarkTheme.GetImage(.Field);
                case "property":
                    entryIcon = DarkTheme.sDarkTheme.GetImage(.Property);
                case "namespace":
                    entryIcon = DarkTheme.sDarkTheme.GetImage(.Namespace);
                case "class":
                    entryIcon = DarkTheme.sDarkTheme.GetImage(.Type_Class);
                case "interface":
                    entryIcon = DarkTheme.sDarkTheme.GetImage(.Interface);
                case "valuetype":
                    entryIcon = DarkTheme.sDarkTheme.GetImage(.Type_ValueType);
                case "object":
                    entryIcon = DarkTheme.sDarkTheme.GetImage(.IconObject);
                case "pointer":
                    entryIcon = DarkTheme.sDarkTheme.GetImage(.IconPointer);
                case "value":
                    entryIcon = DarkTheme.sDarkTheme.GetImage(.IconValue);
                case "payloadEnum":
					entryIcon = DarkTheme.sDarkTheme.GetImage(.IconPayloadEnum);
                case "generic": //TODO: make icon
                    entryIcon = DarkTheme.sDarkTheme.GetImage(.IconValue);
				case "folder":
					entryIcon = DarkTheme.sDarkTheme.GetImage(.ProjectFolder);
				case "file":
					entryIcon = DarkTheme.sDarkTheme.GetImage(.Document);
                }

				bool isInvoke = false;
                switch (entryType)
                {
                case "insertRange":
                    {
						hasInsertRangeEntry = true;
                        //var infoSections = scope List<StringView>(entryDisplay.Split(' '));
						int spacePos = entryDisplay.IndexOf(' ');
						if (spacePos != -1)
						{
							String str = scope String();
							//infoSections[0].ToString(str);
							str.Append(StringView(entryDisplay, 0, spacePos));
	                        mInsertStartIdx = new .(this, int32.Parse(str).Get() + textOffset);
							str.Clear();
							str.Append(StringView(entryDisplay, spacePos + 1));
							//infoSections[1].ToString(str);
	                        mInsertEndIdx = int32.Parse(str).Get();
							if (mInsertEndIdx != -1)
								mInsertEndIdx += textOffset;
						}
                    }
                case "invoke":
                    {
						isInvoke = true;
                    }
                case "invoke_cur":
					{
						// Only use the "invoke_cur" if we don't already have an invoke widget
	                    if ((mInvokeWidget == null) || (mInvokeWidget.mEntryList.Count <= 1))
	                    {
	                        isInvoke = true;
	                    }
	                    else
	                    {
	                        for (int32 invokeIdx = 0; invokeIdx < mInvokeWidget.mEntryList.Count; invokeIdx++)
	                        {
	                            var invokeEntry = mInvokeWidget.mEntryList[invokeIdx];                                
	                            if (invokeEntry.mText == entryDisplay)
	                            {
	                                mInvokeWidget.mSelectIdx = invokeIdx;
	                            }                                
	                        }
	                    }
	                    break;
					}
                case "isMember":
                    mIsMember = true;
                case "invokeInfo":
                    {
						String invokeStr = scope String(entryDisplay);

                        var infoSections = scope List<StringView>(invokeStr.Split(' '));
						var str = scope String();
						infoSections[0].ToString(str);
                        mInvokeWidget.mSelectIdx = int32.Parse(str);

                        mInvokeSrcPositions = new List<int32>();
                        for (int32 i = 1; i < infoSections.Count; i++)
						{
							str.Clear();
							infoSections[i].ToString(str);
                            mInvokeSrcPositions.Add(int32.Parse(str));
						}
                    }
                case "invokeLeftParen":
                    {
                        mInvokeWidget.mLeftParenIdx = int32.Parse(entryDisplay);
                    }
                case "select":
                    {
                        selectString = scope:: String(entryDisplay);
                    }
                default:
                    {
						if (!mInvokeOnly)
						{
							mIsFixit |= entryType == "fixit";
							if (!reuseExistingMemberEntries)
	                            mAutoCompleteListWidget.AddEntry(entryType, entryDisplay, entryIcon, entryInsert, documentation, matchIndices);
						}
                    }                        
                }

                if (isInvoke)
				{
					if (queueClearInvoke)
					{
					    oldInvokeWidget = mInvokeWidget;                                    
					    mInvokeWidget = new InvokeWidget(this);
					    queueClearInvoke = false;
					}

					var invokeEntry = new InvokeWidget.Entry();
					invokeEntry.mText = new String(entryDisplay);
					invokeEntry.mArgMatchCount = int32.Parse(entryInsert).GetValueOrDefault();
					if (!documentation.IsEmpty)
						invokeEntry.mDocumentation = new String(documentation);
                    mInvokeWidget.AddEntry(invokeEntry);                            
				}
            }

			if ((!hasInsertRangeEntry) && (hadPreviousInsertRange) && (reuseExistingMemberEntries))
			{
				mInsertStartIdx = new .(this, previousInsertStart);
				mInsertEndIdx = previousInsertEnd;
			}

			AddCurrentFileTypeEntries();

            if (oldInvokeWidget != null)
            {
                /*if ((!mIsAsync) || (oldInvokeWidget.mLeftParenIdx == mInvokeWidget.mLeftParenIdx))
                {
                    // If it's not another embedded invoke then just get rid of it
                    delete oldInvokeWidget;
                }
                else
                {
                    mInvokeStack.Add(oldInvokeWidget);
                    oldInvokeWidget.Cleanup();
                }*/
            }

			/*for (int i in mInsertStartIdx.Value..<mInsertEndIdx)
			{
				var data = mTargetEditWidget.Content.mData.mText[i];
				var char = data.mChar;
				if (char.IsWhiteSpace)
					mInsertSpanSpaceCount++;
			}
			Debug.WriteLine($"AutoComplete SetInfo mInsertSpanSpaceCount:{mInsertSpanSpaceCount}");*/

            if ((changedAfterInfo) || (mTargetEditWidget.Content.mTextCursors.Count > 1) || (reuseExistingMemberEntries) || (mInsertStartIdx == null))
            {
                GetAsyncTextPos();                
            }

            if ((mInvokeWidget != null) && (mInvokeSrcPositions != null))
            {
                int invokeLine = 0;
                int invokeColumn = 0;                
                mTargetEditWidget.Content.GetLineCharAtIdx(mInvokeSrcPositions[0], out invokeLine, out invokeColumn);
                int insertLine = 0;
                int insertColumn = 0;
                mTargetEditWidget.Content.GetLineCharAtIdx(mTargetEditWidget.Content.mTextCursors.Front.mCursorTextPos, out insertLine, out insertColumn);

                if ((insertLine != invokeLine) && ((insertLine - invokeLine) * gApp.mCodeFont.GetHeight() < GS!(40)))
                    mInvokeWidget.mIsAboveText = true;
            }

			mInfoFilter = new String();
			GetFilter(mInfoFilter);
			UpdateData(selectString, changedAfterInfo);
			mPopulating = false;

			/*if ((mInsertStartIdx != null) && (mInsertEndIdx != -1))
			{
				var insertSpanStr = mTargetEditWidget.Content.ExtractString(mInsertStartIdx.Value, mInsertEndIdx - mInsertStartIdx.Value, .. scope .());
				Debug.WriteLine("SetInfo {0}-{1} '{2}'", mInsertStartIdx.Value, mInsertEndIdx, insertSpanStr);
			}*/
        }

        public bool HasSelection()
        {
            return mAutoCompleteListWidget != null;
        }

        public bool IsShowing()
        {
            return (mInvokeWidget != null) || (mAutoCompleteListWidget != null);
        }

		public bool IsInPanel()
		{
			return (gApp.mAutoCompletePanel != null) && (this == gApp.mAutoCompletePanel.mAutoComplete);
		}

        public void Close(bool deleteSelf = true)
        {
			Debug.Assert(!mPopulating);

			if (!mClosed)
			{
				if ((DarkTooltipManager.sTooltip != null) && (DarkTooltipManager.sTooltip.mAllowMouseOutside))
					DarkTooltipManager.CloseTooltip();

				if (IsInPanel())
				{
					gApp.mAutoCompletePanel.Unbind(this);
					if (mTargetEditWidget.mWidgetWindow != null)
						mTargetEditWidget.SetFocus();
				}

				if (deleteSelf)
				{
					BFApp.sApp.DeferDelete(this);
				}
				mClosed = true;

				if (mInvokeStack != null)
				{
				    for (var oldInvoke in mInvokeStack)
				        delete oldInvoke;
				}

				if (mOnClosed.HasListeners)
				    mOnClosed();

				if ((mAutoCompleteListWidget != null) && (mAutoCompleteListWidget.mWidgetWindow == null))
				{
					mAutoCompleteListWidget.Cleanup();
					if (mListWindow?.mRootWidget == mAutoCompleteListWidget)
						mListWindow.mRootWidget = null;
					if (IsInPanel())
						gApp.mAutoCompletePanel.Unbind(this);
					delete mAutoCompleteListWidget;
				}
				
				if (mListWindow != null)
				{
				    mListWindow.Dispose();
				    mListWindow = null;
				}

				if ((mInvokeWidget != null) && (mInvokeWidget.mWidgetWindow == null))
				{
					mInvokeWidget.Cleanup();
					if (mInvokeWindow?.mRootWidget == mInvokeWidget)
						mInvokeWindow.mRootWidget = null;
					delete mInvokeWidget;
					mInvokeWidget = null;
				}

				if (mInvokeWindow != null)
				{
				    mInvokeWindow.Dispose();
				    mInvokeWindow = null;
				}
			}
        }

        public void CloseListWindow()
        {
            if (mInvokeSrcPositions == null)
            {
                Close();
                return;
            }

			if (IsInPanel())
			{
				if (mAutoCompleteListWidget != null)
				{
					mAutoCompleteListWidget.RemoveSelf();
					delete mAutoCompleteListWidget;
					mAutoCompleteListWidget = null;
				}
			}
            else if (mListWindow != null)
            {
                mListWindow.Dispose();
                mListWindow = null;
                mAutoCompleteListWidget = null;
            }
        }

        public void ClearAsyncEdit()
        {
            CloseListWindow();
            if (mInvokeSrcPositions != null)
                UpdateAsyncInfo();            
        }

        public void CloseInvoke()
        {
            if (mInvokeStack.Count > 0)
            {
                delete mInvokeWidget;
                mInvokeWidget = mInvokeStack[mInvokeStack.Count - 1];
                mInvokeStack.RemoveAt(mInvokeStack.Count - 1);

                UpdateAsyncInfo();
                return;
            }

            Close();
        }

        public bool IsInsertEmpty()
        {
			if (mInsertStartIdx == null)
				return true;

            return mInsertStartIdx.Value == mInsertEndIdx;
        }

		bool TryApplyUsingFixit(SourceEditWidgetContent sewc, AutoCompleteListWidget.EntryWidget entry)
		{
			if ((sewc == null) || (mIsMember) || (mIsFixit) || (mInvokeOnly))
				return false;

			var sourceViewPanel = sewc.mSourceViewPanel;
			if ((sourceViewPanel == null) || (!sourceViewPanel.mIsBeefSource) || (sourceViewPanel.FilteredProjectSource == null))
				return false;

			if ((gApp.mSymbolReferenceHelper?.IsLocked == true) || (sewc.mTextCursors.Count != 1))
				return false;

			switch (entry.mEntryType)
			{
			case "class":
			case "interface":
			case "valuetype":
				break;
			default:
				return false;
			}

			ResolveParams resolveParams = scope .();
			resolveParams.mOverrideCursorPos = (.)sewc.CursorTextPos;
			resolveParams.mIsUserRequested = true;
			sourceViewPanel.DoClassify(ResolveType.GetFixits, resolveParams, true);

			if ((resolveParams.mCancelled) || (resolveParams.mNavigationData == null) || (resolveParams.mNavigationData.IsEmpty))
				return false;

			String wantNamespace = scope .();
			bool hasWantNamespace = TryGetEntryNamespace(entry, wantNamespace);

			int usingFixitCount = 0;
			String usingFixit = null;
			for (var entryView in resolveParams.mNavigationData.Split('\n'))
			{
				if (entryView.IsEmpty)
					continue;

				int tabPos = entryView.IndexOf('\t');
				if (tabPos == -1)
					continue;

				StringView entryType = StringView(entryView, 0, tabPos);
				if (entryType != "fixit")
					continue;

				StringView entryDisplay = StringView(entryView, tabPos + 1);
				int insertTabPos = entryDisplay.IndexOf('\t');
				if (insertTabPos == -1)
					continue;

				StringView entryInsert = StringView(entryDisplay, insertTabPos + 1);
				if (!entryInsert.StartsWith(".using|"))
					continue;

				usingFixitCount++;

				String fixitNamespace = scope .();
				bool hasFixitNamespace = TryGetUsingNamespace(entryInsert, fixitNamespace);
				if (!hasWantNamespace)
				{
					if (usingFixitCount == 1)
						usingFixit = new String(entryInsert);
					else if (usingFixitCount > 1)
						usingFixitCount = 2;
				}
				else if ((hasFixitNamespace) && (fixitNamespace == wantNamespace))
				{
					delete usingFixit;
					usingFixit = new String(entryInsert);
					break;
				}
			}

			bool hasExistingUsing = false;
			String usingNamespace = scope .();
			if ((usingFixit != null) && (TryGetUsingNamespace(usingFixit, usingNamespace)))
				hasExistingUsing = HasUsingDirective(sewc, usingNamespace);

			bool hasSelectedUsing = (!wantNamespace.IsEmpty) && (usingFixit != null);
			if (hasSelectedUsing || ((usingFixitCount == 1) && (usingFixit != null)))
			{
				if (!hasExistingUsing)
					ApplyFixit(usingFixit);
				delete usingFixit;
				return true;
			}

			if (usingFixit != null)
				delete usingFixit;

			return false;
		}

		bool TryGetUsingNamespace(StringView fixitData, String outNamespace)
		{
			if (fixitData.IsEmpty)
				return false;

			StringView insertStr = default;
			for (var part in fixitData.Split('|'))
			{
				insertStr = part;
			}

			insertStr.Trim();
			if (insertStr.IsEmpty)
				return false;

			if (insertStr.StartsWith("using static "))
				insertStr = insertStr.Substring("using static ".Length);
			else if (insertStr.StartsWith("using "))
				insertStr = insertStr.Substring("using ".Length);
			else
				return false;

			insertStr.Trim();
			int semiPos = insertStr.IndexOf(';');
			if (semiPos != -1)
				insertStr.RemoveToEnd(semiPos);

			insertStr.Trim();
			if (insertStr.IsEmpty)
				return false;

			int eqPos = insertStr.IndexOf('=');
			if (eqPos != -1)
			{
				insertStr = insertStr.Substring(eqPos + 1);
				insertStr.Trim();
			}

			if (insertStr.IsEmpty)
				return false;

			outNamespace.Append(insertStr);
			return true;
		}

		bool TryGetEntryNamespace(AutoCompleteListWidget.EntryWidget entry, String outNamespace)
		{
			if ((entry == null) || (entry.mEntryDisplay == null))
				return false;

			StringView display = entry.mEntryDisplay;
			if (!display.EndsWith(")"))
				return false;

			int openIdx = display.LastIndexOf('(');
			if (openIdx == -1)
				return false;
			if ((openIdx == 0) || (display[openIdx - 1] != ' '))
				return false;

			int nsStart = openIdx + 1;
			int nsLen = display.Length - openIdx - 2;
			if (nsLen <= 0)
				return false;

			StringView nsView = display.Substring(nsStart, nsLen);
			nsView.Trim();
			if (nsView.IsEmpty)
				return false;

			outNamespace.Append(nsView);
			return true;
		}

		bool HasUsingDirective(SourceEditWidgetContent sewc, StringView namespaceName)
		{
			if (namespaceName.IsEmpty)
				return false;

			int lineCount = sewc.GetLineCount();
			for (int line < lineCount)
			{
				String lineText = scope .();
				sewc.GetLineText(line, lineText);
				lineText.Trim();

				if (lineText.IsEmpty)
					continue;
				if (lineText.StartsWith("//"))
					continue;

				StringView check = lineText;
				if (check.StartsWith("using static "))
					check = check.Substring("using static ".Length);
				else if (check.StartsWith("using "))
					check = check.Substring("using ".Length);
				else
					continue;

				check.Trim();
				int semiPos = check.IndexOf(';');
				if (semiPos != -1)
					check.RemoveToEnd(semiPos);

				check.Trim();
				if (check.IsEmpty)
					continue;

				int eqPos = check.IndexOf('=');
				if (eqPos != -1)
				{
					check = check.Substring(eqPos + 1);
					check.Trim();
				}

				if (check == namespaceName)
					return true;
			}

			return false;
		}

		void ApplyFixit(String data)
		{
			int splitIdx = data.IndexOf('\x01');
			if (splitIdx != -1)
			{
				String lhs = scope String(data, 0, splitIdx);
				String rhs = scope String(data, splitIdx + 1);
				ApplyFixit(lhs);
				ApplyFixit(rhs);
				return;
			}

			var targetSourceEditWidgetContent = mTargetEditWidget.Content as SourceEditWidgetContent;
			var sourceEditWidgetContent = targetSourceEditWidgetContent;
			var prevCursorPosition = sourceEditWidgetContent.CursorTextPos;
			var prevScrollPos = mTargetEditWidget.mVertPos.mDest;

			UndoBatchStart undoBatchStart = null;

			var parts = String.StackSplit!(data, '|');
			String fixitKind = parts[0];
			String fixitFileName = parts[1];
			var (sourceViewPanel, tabButton) = IDEApp.sApp.ShowSourceFile(fixitFileName);
			bool focusChange = !fixitKind.StartsWith(".");

			var historyEntry = targetSourceEditWidgetContent.RecordHistoryLocation();
			historyEntry.mNoMerge = true;

			if (sourceEditWidgetContent.mSourceViewPanel != sourceViewPanel)
			{
				sourceEditWidgetContent = (SourceEditWidgetContent)sourceViewPanel.GetActivePanel().EditWidget.mEditWidgetContent;
				undoBatchStart = new UndoBatchStart("autocomplete");
				sourceEditWidgetContent.mData.mUndoManager.Add(undoBatchStart);
			}

			if (!focusChange)
			{
				if (prevScrollPos != 0)
					sourceEditWidgetContent.CheckRecordScrollTop(true);
			}

			int32 fixitIdx = 0;
			int32 fixitLen = 0;
			StringView fixitLocStr = parts[2];
			int dashPos = fixitLocStr.IndexOf('-');
			if (dashPos != -1)
			{
				fixitLen = int32.Parse(fixitLocStr.Substring(dashPos + 1));
				fixitLocStr.RemoveToEnd(dashPos);
			}

			if (fixitLocStr.Contains(':'))
			{
				var splitItr = fixitLocStr.Split(':');
				int32 line = int32.Parse(splitItr.GetNext().Value).Value;
				int32 col = int32.Parse(splitItr.GetNext().Value).Value;
				fixitIdx = (.)sourceEditWidgetContent.GetTextIdx(line, col);
			}
			else
				fixitIdx = int32.Parse(fixitLocStr).GetValueOrDefault();

			int prevTextLength = sourceEditWidgetContent.mData.mTextLength;

			int insertCount = 0;
			int dataIdx = 3;

			while (dataIdx < parts.Count)
			{
				int32 lenAdd = 0;

				String fixitInsert = scope String(parts[dataIdx++]);
				while (dataIdx < parts.Count)
				{
					var insertStr = parts[dataIdx++];
					if (insertStr.StartsWith("`"))
					{
						lenAdd = int32.Parse(StringView(insertStr, 1));
						break;
					}

					fixitInsert.Append('\n');
					fixitInsert.Append(insertStr);
				}

#unwarn
				bool hasMore = dataIdx < parts.Count;

				if (sourceViewPanel != null)
				{
					if (sourceViewPanel.IsReadOnly)
					{
						gApp.Fail(scope String()..AppendF("The selected fixit cannot be applied to locked file '{}'", sourceViewPanel.mFilePath));
						return;
					}
	
					sourceEditWidgetContent.CursorTextPos = fixitIdx;
					if (focusChange)
						sourceEditWidgetContent.EnsureCursorVisible(true, true);

					sourceEditWidgetContent.CurSelection = null;
					if (fixitLen > 0)
					{
						sourceEditWidgetContent.CurSelection = EditSelection(fixitIdx, fixitIdx + fixitLen);
						sourceEditWidgetContent.DeleteSelection();
						fixitLen = 0;
					}

					if (fixitInsert.StartsWith('\n'))
						sourceEditWidgetContent.PasteText(fixitInsert, fixitInsert.StartsWith("\n"));
					else
						InsertImplText(sourceEditWidgetContent, fixitInsert);

					fixitIdx = (.)sourceEditWidgetContent.CursorTextPos;
					insertCount++;
				}
			}

			if (!focusChange)
			{
				mTargetEditWidget.VertScrollTo(prevScrollPos, true);
				sourceEditWidgetContent.CursorTextPos = prevCursorPosition;
				int addedSize = sourceEditWidgetContent.mData.mTextLength - prevTextLength;
				sourceEditWidgetContent.[Friend]AdjustCursorsAfterExternalEdit(fixitIdx, addedSize, 0);
				sourceEditWidgetContent.CurCursorTextPos += (int32)addedSize;
			}

			if (historyEntry != null)
			{
				// Make sure when we go back that we'll go back to the insert position
				int idx = gApp.mHistoryManager.mHistoryList.LastIndexOf(historyEntry);
				if (idx != -1)
					gApp.mHistoryManager.mHistoryIdx = (.)idx;
			}

			if (undoBatchStart != null)
				sourceEditWidgetContent.mData.mUndoManager.Add(undoBatchStart.mBatchEnd);
		}

		void InsertImplText(SourceEditWidgetContent sourceEditWidgetContent, String implText)
		{
			String implSect = scope .();
			
			int startIdx = 0;
			for (int i < implText.Length)
			{
				char8 c = implText[i];
				if ((c == '\a') || (c == '\t') || (c == '\b') || (c == '\r') || (c == '\f'))
				{
					implSect.Clear();
					implSect.Append(implText, startIdx, i - startIdx);
					if (!implSect.IsEmpty)
					{
						sourceEditWidgetContent.InsertAtCursor(implSect);
					}

					if (c == '\a') // Ensure we have spacing or an open brace on the previous line
					{
						int lineNum = sourceEditWidgetContent.CursorLineAndColumn.mLine;
						if (lineNum > 0)
						{
							sourceEditWidgetContent.GetLinePosition(lineNum - 1, var lineStart, var lineEnd);
							for (int idx = lineEnd; idx >= lineStart; idx--)
							{
								let charData = sourceEditWidgetContent.mData.mText[idx];
								if (charData.mDisplayTypeId == (.)SourceElementType.Comment)
									continue;
								if (charData.mChar.IsWhiteSpace)
									continue;
								if (charData.mChar == '{')
									break;

								// Add new line
								sourceEditWidgetContent.InsertAtCursor("\n");
								sourceEditWidgetContent.CursorToLineEnd();
								break;
							}
						}
					}
					else if (c == '\f') // Make sure we're on an empty line
					{
						if (!sourceEditWidgetContent.IsLineWhiteSpace(sourceEditWidgetContent.CursorLineAndColumn.mLine))
						{
							sourceEditWidgetContent.InsertAtCursor("\n");
						}
						if (!sourceEditWidgetContent.IsLineWhiteSpace(sourceEditWidgetContent.CursorLineAndColumn.mLine))
						{
							int prevPos = sourceEditWidgetContent.mTextCursors.Front.mCursorTextPos;
							sourceEditWidgetContent.InsertAtCursor("\n");
							sourceEditWidgetContent.mTextCursors.Front.mCursorTextPos = (int32)prevPos;
						}
						sourceEditWidgetContent.CursorToLineEnd();
					}
					else if (c == '\t') // Open block
					{
						sourceEditWidgetContent.InsertAtCursor("\n");
						sourceEditWidgetContent.CursorToLineEnd();
						sourceEditWidgetContent.OpenCodeBlock();
					}
					else if (c == '\r') // Newline
					{
						sourceEditWidgetContent.InsertAtCursor("\n");
						sourceEditWidgetContent.CursorToLineEnd();
					}
					else if (c == '\b') // Close block
					{
						int cursorPos = sourceEditWidgetContent.mTextCursors.Front.mCursorTextPos;
						while (cursorPos < sourceEditWidgetContent.mData.mTextLength)
						{
							char8 checkC = sourceEditWidgetContent.mData.mText[cursorPos].mChar;
							cursorPos++;
							if (checkC == '}')
								break;
						}
						sourceEditWidgetContent.mTextCursors.Front.mCursorTextPos = (int32)cursorPos;
					}
					else
					{
						let lc = sourceEditWidgetContent.CursorLineAndColumn;
						sourceEditWidgetContent.CursorLineAndColumn = .(lc.mLine + 1, 0);
						sourceEditWidgetContent.CursorToLineEnd();
						sourceEditWidgetContent.InsertAtCursor("\n");
						sourceEditWidgetContent.CursorToLineEnd();
					}

					startIdx = i + 1;
				}
			}

			implSect.Clear();
			implSect.Append(implText, startIdx, implText.Length - startIdx);
			if (!implSect.IsEmpty)
			{
				sourceEditWidgetContent.InsertAtCursor(implSect);
			}
		}

		public void GetInsertText(String outStr)
		{
			if (mAutoCompleteListWidget != null)
			{
				var entry = mAutoCompleteListWidget.mEntryList[mAutoCompleteListWidget.mSelectIdx];
				outStr.Append(entry.mEntryInsert ?? entry.mEntryDisplay);
			}
		}

		public void InsertSelection(char32 keyChar, String insertType = null, String insertStr = null)
		{
			var sewc = mTargetEditWidget.Content as SourceEditWidgetContent;
			Debug.Assert(sewc.IsPrimaryTextCursor());
			var isExplicitInsert = (keyChar == '\0') || (keyChar == '\t') || (keyChar == '\n') || (keyChar == '\r');

			AutoCompleteListWidget.EntryWidget GetEntry()
			{
				var entry = mAutoCompleteListWidget.mEntryList[mAutoCompleteListWidget.mSelectIdx];
				if ((keyChar == '!') && (!entry.mEntryDisplay.EndsWith("!")))
				{
				    // Try to find one that DOES end with a '!'
				    for (var checkEntry in mAutoCompleteListWidget.mEntryList)
				    {
				        if (checkEntry.mEntryDisplay.EndsWith("!"))
							return checkEntry;
				    }
				}

				return entry;
			}

			EditSelection CalculateSelection(String implText)
			{
				var endPos = (int32)sewc.CursorTextPos;
				var startPos = endPos;
				var wentOverWhitespace = false;
				while ((startPos <= endPos) && (startPos > 0))
				{
					var data = sewc.mData.mText[startPos - 1];
					var type = (SourceElementType)data.mDisplayTypeId;

					// Explicit delimeters
					if ((data.mChar == '\n') || (data.mChar == '}') || (data.mChar == ';') || (data.mChar == '.'))
						break;

					var isWhiteSpace = data.mChar.IsWhiteSpace;
					var isLetterOrDigit = data.mChar.IsLetterOrDigit;

					// When it's not a override method for example
					// we break right after we find a non-letter-or-digit character
					// So we would only select last word
					if ((implText == null) && (!isLetterOrDigit) && (data.mChar != '_') && (data.mChar != '@'))
						break;

					// This is for cases, when we are searching for 
					if ((!isLetterOrDigit) && (type != .Keyword) && (!isWhiteSpace) && (data.mChar != '_'))
						break;

					wentOverWhitespace = isWhiteSpace;
					startPos--;
				}

				if (wentOverWhitespace)
					startPos++;

				return EditSelection(startPos, endPos);
			}

			var entry = GetEntry();
			if (insertStr != null)
				insertStr.Append(entry.mEntryInsert ?? entry.mEntryDisplay);

			if (entry.mEntryType == "fixit")
			{
				if (insertType != null)
					insertType.Append(entry.mEntryType);
				sewc.RemoveSecondaryTextCursors();
				ApplyFixit(entry.mEntryInsert);
				return;
			}

			var insertText = scope String(entry.mEntryInsert ?? entry.mEntryDisplay);
			bool moveCursorInsideParens =
				(entry.mEntryType == "token") &&
				(entry.mEntryDisplay == "cw") &&
				(insertText.EndsWith("()"));
			if ((!isExplicitInsert) && (insertText.Contains('\t')))
			{
				// Don't insert multi-line blocks unless we have an explicit insert request (click, tab, or enter)
				return;
			}

			if ((keyChar == '=') && (insertText.EndsWith("=")))
				insertText.RemoveToEnd(insertText.Length - 1);

			// Save persistent text positions
			PersistentTextPosition[] persistentInvokeSrcPositons = null;
			if (mInvokeSrcPositions != null)
			{
				persistentInvokeSrcPositons = scope:: PersistentTextPosition[mInvokeSrcPositions.Count];
			    for (int32 i = 0; i < mInvokeSrcPositions.Count; i++)
			    {
			        persistentInvokeSrcPositons[i] = new PersistentTextPosition(mInvokeSrcPositions[i]);
			        sewc.PersistentTextPositions.Add(persistentInvokeSrcPositons[i]);
			    }
			}

			String* keyPtr;
			int32* valuePtr;
			if (sAutoCompleteMRU.TryAdd(entry.mEntryDisplay, out keyPtr, out valuePtr))
			{
				// Only create new string if this entry doesn't exist already
				*keyPtr = new String(entry.mEntryDisplay);
			}
			*valuePtr = sAutoCompleteIdx++;

			String implText = null;
			int tabIdx = insertText.IndexOf('\t');
			int splitIdx = tabIdx;
			int crIdx = insertText.IndexOf('\r');
			if ((crIdx != -1) && (tabIdx != -1) && (crIdx < tabIdx))
				splitIdx = crIdx;
			if (splitIdx != -1)
			{
			    implText = scope:: String();
			    implText.Append(insertText, splitIdx);
			    insertText.RemoveToEnd(splitIdx);
			}

			for (var cursor in sewc.mTextCursors)
			{
				sewc.SetTextCursor(cursor);
				var editSelection = CalculateSelection(implText);

				var prevText = scope String();
				sewc.ExtractString(editSelection.MinPos, editSelection.Length, prevText);
				if ((prevText.Length > 0) && (insertText == prevText))
					continue;

				sewc.CurSelection = editSelection;
				sewc.CurCursorTextPos = (int32)editSelection.MaxPos;

				if (insertText.EndsWith("<>"))
				{
				    if (keyChar == '\t')
				        sewc.InsertCharPair(insertText);
				    else if (keyChar == '<')
					{
						var str = scope String();
						str.Append(insertText, 0, insertText.Length - 2);
				        sewc.InsertAtCursor(str, .NoRestoreSelectionOnUndo);
					}
				    else
						sewc.InsertAtCursor(insertText, .NoRestoreSelectionOnUndo);
				}
				else
					sewc.InsertAtCursor(insertText, .NoRestoreSelectionOnUndo);

				if (moveCursorInsideParens && (sewc.CursorTextPos > 0))
					sewc.CursorTextPos--;

				if (implText != null)
					InsertImplText(sewc, implText);
			}

			// Load persistent text positions back
			if (persistentInvokeSrcPositons != null)
			{
				for (int32 i = 0; i < mInvokeSrcPositions.Count; i++)
				{
					var persistentTextPositon = persistentInvokeSrcPositons[i];
				    mInvokeSrcPositions[i] = persistentTextPositon.mIndex;
				    sewc.PersistentTextPositions.Remove(persistentTextPositon);
					delete persistentTextPositon;
				}
			}

			TryApplyUsingFixit(sewc, entry);

			sewc.SetPrimaryTextCursor();
			sewc.EnsureCursorVisible();
		}

		public void MarkDirty()
		{
			if (mInvokeWidget != null)
				mInvokeWidget.MarkDirty();
			if (mAutoCompleteListWidget != null)
				mAutoCompleteListWidget.MarkDirty();
		}
		
		int32 GetMaxWindowHeight()
		{
			return (int32)(9 * mAutoCompleteListWidget.mItemSpacing) + GS!(20);
		}
    }
}
