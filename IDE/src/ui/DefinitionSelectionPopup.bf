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
		public String mFileName ~ delete _;
		public String mDirectoryPath ~ delete _;
		public int32 mLine;
		public int32 mLineChar;
	}

	class DefinitionSelectionListViewItem : DarkListViewItem
	{
		public const float ROW_HEIGHT = 54;

		public DefinitionSelectionPanel mOwner;
		public int32 mEntryIdx;

		public override void Init(ListView listView)
		{
			base.Init(listView);
			mSelfHeight = GS!(ROW_HEIGHT);
		}

		public override void Draw(Graphics g)
		{
			if ((mColumnIdx != 0) || (mOwner == null) || (mEntryIdx < 0) || (mEntryIdx >= mOwner.mEntries.Count))
			{
				base.Draw(g);
				return;
			}

			let entry = mOwner.mEntries[mEntryIdx];
			float insetX = GS!(8);
			float insetY = GS!(4);
			float cardX = insetX;
			float cardY = insetY;
			float cardWidth = Math.Max(GS!(40), mWidth - insetX - GS!(10));
			float cardHeight = Math.Max(GS!(36), mHeight - insetY - GS!(6));

			uint32 rowBg = 0xFF2B2D30;
			uint32 rowBorder = 0xFF393D42;
			uint32 primaryText = AutoComplete.C_ENTRY_TEXT;
			uint32 secondaryText = 0xFF8F98A3;
			uint32 accent = AutoComplete.C_BEEF_GREEN;

			if (Selected)
			{
				rowBg = 0xFF31353A;
				rowBorder = 0xFF4A545F;
				primaryText = 0xFFF3F7F4;
				secondaryText = 0xFFAAB5AE;
			}
			else if (mMouseOver)
			{
				rowBg = 0xFF2E3136;
				rowBorder = 0xFF43474E;
			}

			using (g.PushColor(rowBg))
				g.FillRect(cardX, cardY, cardWidth, cardHeight);
			using (g.PushColor(rowBorder))
				g.OutlineRect(cardX, cardY, cardWidth, cardHeight);
			using (g.PushColor(accent))
				g.FillRect(cardX, cardY, GS!(3), cardHeight);

			let fileFont = IDEApp.sApp.mCodeFont;
			g.SetFont(fileFont);

			float iconX = cardX + GS!(10);
			float iconY = cardY + GS!(12);
			let iconWidth = AutoComplete.DrawBeefBadge(g, iconX, iconY);

			float textX = iconX + iconWidth + GS!(10);
			float textRight = cardX + cardWidth - GS!(10);
			float textWidth = Math.Max(GS!(40), textRight - textX);
			float fileY = cardY + GS!(6);
			float metaY = cardY + GS!(29);

			String metaText = scope .();
			metaText.Append(entry.mDirectoryPath);
			if (!metaText.IsEmpty)
				metaText.Append("  ");
			metaText.AppendF("Ln {0}, Col {1}", entry.mLine + 1, entry.mLineChar + 1);

			using (g.PushColor(primaryText))
				g.DrawString(entry.mFileName, textX, fileY, .Left, textWidth, .Ellipsis);
			using (g.PushColor(secondaryText))
				g.DrawString(metaText, textX, metaY, .Left, textWidth, .Ellipsis);
		}
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
		const float HEADER_HEIGHT = 26;

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
			float rowHeight = GS!(DefinitionSelectionListViewItem.ROW_HEIGHT);
			float visibleRowCount = Math.Min((float)mEntries.Count, 8.0f);
			return GS!(8) + GS!(HEADER_HEIGHT) + visibleRowCount * rowHeight + GS!(8);
		}

		public void AddEntry(StringView filePath, int32 line, int32 lineChar)
		{
			var entry = new DefinitionSelectionEntry();
			entry.mFilePath = new .(filePath);
			entry.mFileName = new .();
			Path.GetFileName(filePath, entry.mFileName);
			entry.mDirectoryPath = new .();
			Path.GetDirectoryPath(filePath, entry.mDirectoryPath).IgnoreError();
			entry.mLine = line;
			entry.mLineChar = lineChar;
			mEntries.Add(entry);

			var item = (DefinitionSelectionListViewItem)mListView.GetRoot().CreateChildItem();
			item.mOwner = this;
			item.mEntryIdx = (.)mEntries.Count - 1;
			item.Label = entry.mFileName;

			if (mEntries.Count == 1)
			{
				mListView.GetRoot().SelectItemExclusively(item);
				item.Focused = true;
			}
		}

		public override void Draw(Graphics g)
		{
			using (g.PushColor(0xFF202224))
				g.FillRect(0, 0, mWidth, mHeight);
			using (g.PushColor(AutoComplete.C_BEEF_GREEN))
				g.FillRect(0, 0, mWidth, GS!(2));
			using (g.PushColor(0xFF41454B))
				g.OutlineRect(0, 0, mWidth, mHeight);

			base.Draw(g);

			g.SetFont(IDEApp.sApp.mCodeFont);
			float badgeX = GS!(10);
			float badgeY = GS!(6);
			float badgeWidth = AutoComplete.DrawBeefBadge(g, badgeX, badgeY);
			using (g.PushColor(0xFFF3F6F4))
				g.DrawString("Partial Definitions", badgeX + badgeWidth + GS!(8), GS!(4));
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
			mListView.Resize(GS!(6), GS!(HEADER_HEIGHT) + GS!(4), width - GS!(14), height - GS!(HEADER_HEIGHT) - GS!(10));
		}
	}
}
