"""Subset Noto Sans SC to GB2312 + ASCII so the web shell never depends on fonts.gstatic.com.

Usage:
  python tool/subset_cjk_font.py <NotoSansSC-Regular.otf> assets/fonts/NotoSansSC-Subset.otf
"""

import sys

from fontTools import subset


def charset() -> str:
    chars = {chr(c) for c in range(0x20, 0x7F)}
    for hi in range(0xA1, 0xF8):
        for lo in range(0xA1, 0xFF):
            try:
                chars.add(bytes([hi, lo]).decode("gb2312"))
            except UnicodeDecodeError:
                continue
    chars.update("「」『』【】〖〗《》〈〉、·—…“”‘’•→←↑↓×÷≈≤≥±§℃～°")
    return "".join(sorted(chars))


def main() -> int:
    if len(sys.argv) != 3:
        print(__doc__)
        return 2
    source, target = sys.argv[1], sys.argv[2]
    options = subset.Options()
    options.layout_features = ["*"]
    options.name_IDs = ["*"]
    options.notdef_outline = True
    font = subset.load_font(source, options)
    subsetter = subset.Subsetter(options=options)
    subsetter.populate(text=charset())
    subsetter.subset(font)
    subset.save_font(font, target, options)
    print(f"wrote {target}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
