# UI Font Change (Windows)

Purpose: Ensure UI text (e.g., debugger hover tooltips) can render CJK glyphs by adding Windows font alternates.

Modified file:
- BeefLibs/Beefy2D/src/theme/dark/DarkTheme.bf

Notes:
- Added "Microsoft YaHei UI" and "Microsoft YaHei" as alternate fonts for UI fonts (header, small, small bold) on Windows only.
