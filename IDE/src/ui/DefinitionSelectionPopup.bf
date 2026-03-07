using System;
using System.Collections;
using System.IO;
using Beefy;
using Beefy.events;
using Beefy.gfx;
using Beefy.theme.dark;
using Beefy.widgets;

namespace IDE.ui
{
	class DefinitionSelectionEntry
	{
		public String mFilePath ~ delete _;
		public int32 mLine;
		public int32 mLineChar;
	}

	class DefinitionSelectionListViewItem : DarkListViewItem
	{
		public int32 mEntryIdx;
	}

	class DefinitionSelectionListView : DarkListView
	{
		protected override ListViewItem CreateListViewItem()
		{
			return new DefinitionSelectionListViewItem();
		}
	}

	class DefinitionSelectionPanel : Panel
	{
		SourceViewPanel mSourceViewPanel;
		public PanelPopup mPopup;
		public DefinitionSelectionListView mListView;
		public List<DefinitionSelectionEntry> mEntries = new .() ~ DeleteContainerAndItems!(_);
		bool mIsNavigating;

		public this(SourceViewPanel sourceViewPanel)
		{
			mSourceViewPanel = sourceViewPanel;

			mListView = new .();
			mListView.SetShowHeader(false);
			mListView.InitScrollbars(false, true);
			mListView.mAllowMultiSelect = false;
			mListView.mAutoFocus = true;
			mListView.mOnItemMouseDown.Add(new => ItemMouseDown);
			mListView.mOnKeyDown.Add(new => ListViewKeyDown);
			AddWidget(mListView);

			mListView.AddColumn(GS!(360), "Definition");
		}

		public float GetDesiredHeight()
		{
			float rowHeight = Math.Max(mListView.mFont.GetLineSpacing() + GS!(8), GS!(24));
			float visibleRowCount = Math.Min((float)mEntries.Count, 8.0f);
			return GS!(8) + visibleRowCount * rowHeight + GS!(8);
		}

		public void AddEntry(StringView filePath, int32 line, int32 lineChar)
		{
			var entry = new DefinitionSelectionEntry();
			entry.mFilePath = new .(filePath);
			entry.mLine = line;
			entry.mLineChar = lineChar;
			mEntries.Add(entry);

			var item = (DefinitionSelectionListViewItem)mListView.GetRoot().CreateChildItem();
			item.mEntryIdx = (.)mEntries.Count - 1;

			String fileName = scope .();
			Path.GetFileName(filePath, fileName);
			item.Label = scope String()..AppendF("{}:{}", fileName, line + 1);

			if (mEntries.Count == 1)
			{
				mListView.GetRoot().SelectItemExclusively(item);
				item.Focused = true;
			}
		}

		void NavigateTo(int32 entryIdx)
		{
			if (mIsNavigating)
				return;
			if ((entryIdx < 0) || (entryIdx >= mEntries.Count))
				return;

			mIsNavigating = true;

			var entry = mEntries[entryIdx];
			mSourceViewPanel?.RecordHistoryLocation();

			var usePath = scope String(entry.mFilePath);
			if (usePath.StartsWith("$Emit$"))
				usePath.Insert("$Emit$".Length, "Resolve$");

			var sourceViewPanel = gApp.ShowSourceFileLocation(usePath, -1, -1, entry.mLine, entry.mLineChar, LocatorType.Smart, true);
			if (sourceViewPanel != null)
				sourceViewPanel.RecordHistoryLocation(true);
			else
			{
				DeleteAndNullify!(gApp.mDeferredShowSource);
				gApp.mDeferredShowSource = new IDEApp.DeferredShowSource()
					{
						mFilePath = new .(usePath),
						mShowHotIdx = -1,
						mRefHotIdx = -1,
						mLine = entry.mLine,
						mColumn = entry.mLineChar,
						mHilitePosition = LocatorType.Smart,
						mShowTemp = true
					};
			}

			mPopup?.Close();
		}

		void ItemMouseDown(ListViewItem item, float x, float y, int32 btnNum, int32 btnCount)
		{
			let baseItem = (item as DefinitionSelectionListViewItem) ?? (DefinitionSelectionListViewItem)item.GetSubItem(0);
			if (baseItem == null)
				return;
			mListView.GetRoot().SelectItemExclusively(baseItem);
			mListView.SetFocus();
			if (btnNum == 0)
				NavigateTo(baseItem.mEntryIdx);
		}

		void ListViewKeyDown(KeyDownEvent evt)
		{
			if (evt.mKeyCode == .Return)
			{
				if (let selectedItem = (DefinitionSelectionListViewItem)mListView.GetRoot().FindFirstSelectedItem())
				{
					evt.mHandled = true;
					NavigateTo(selectedItem.mEntryIdx);
				}
			}
		}

		public override void Resize(float x, float y, float width, float height)
		{
			base.Resize(x, y, width, height);
			mListView.Resize(GS!(4), GS!(4), width - GS!(12), height - GS!(12));
		}
	}
}
