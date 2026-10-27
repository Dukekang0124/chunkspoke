"""Subset Noto Sans SC to the glyphs this app actually renders.

Why: CanvasKit falls back to fonts.gstatic.com for missing glyphs, and that host
is unreachable on the target network -> tofu. Shipping a bundled subset removes
the dependency; subsetting from real content keeps the payload small.

Charset = ASCII + every non-ASCII rune found in lib/**/*.dart and assets/content/*.json
          + 中文 Material/Cupertino 本地化字符串（选择菜单、对话框按钮等系统文案）
          + CJK punctuation / fullwidth block.

Usage:
  python tool/subset_cjk_font.py <NotoSansSC-Regular.otf> assets/fonts/NotoSansSC-Subset.otf
"""

import json
import shutil
import sys
from pathlib import Path

from fontTools import subset

ROOT = Path(__file__).resolve().parent.parent
EXTRA = (
    "「」『』【】〖〗《》〈〉、·—…“”‘’•→←↑↓×÷≈≤≥±§℃～°"
    "，。！？；：（）【】￥％＋－＝／＼｜＠＃＆＊"
    "０１２３４５６７８９ＡＢＣＤＥＦＧＨＩＪＫＬＭＮＯＰＱＲＳＴＵＶＷＸＹＺ"
)


def flutter_root() -> Path | None:
    """Flutter 自带的中文系统文案也要进子集，否则 TextField 选择菜单会去 gstatic 拉字体。"""
    exe = shutil.which("flutter")
    if exe:
        # <flutter>/bin/flutter(.bat) -> <flutter>
        return Path(exe).resolve().parent.parent
    env = Path(sys.prefix) / "flutter"
    return env if env.is_dir() else None


def l10n_texts() -> str:
    root = flutter_root()
    if root is None:
        raise SystemExit("找不到 Flutter SDK：先把它加进 PATH 再跑本脚本")
    base = root / "packages/flutter_localizations/lib/src/l10n"
    parts = []
    for name in ("material_zh.arb", "cupertino_zh.arb"):
        path = base / name
        if not path.is_file():
            raise SystemExit(f"缺少本地化文件：{path}")
        parts.append(path.read_text(encoding="utf-8"))
    return "\n".join(parts)


def text_from_sources() -> str:
    parts = []
    for path in sorted(ROOT.joinpath("lib").rglob("*.dart")):
        parts.append(path.read_text(encoding="utf-8"))
    for path in sorted(ROOT.joinpath("assets/content").glob("*.json")):
        parts.append(path.read_text(encoding="utf-8"))
    for path in (ROOT / "web/index.html", ROOT / "web/manifest.json", ROOT / "pubspec.yaml"):
        if path.is_file():
            parts.append(path.read_text(encoding="utf-8"))
    parts.append(l10n_texts())
    return "\n".join(parts)


def charset() -> str:
    chars = {chr(c) for c in range(0x20, 0x7F)}
    chars.update(EXTRA)
    chars.update(ch for ch in text_from_sources() if ord(ch) > 0x7E)
    return "".join(sorted(chars))


def main() -> int:
    if len(sys.argv) != 3:
        print(__doc__)
        return 2
    source, target = sys.argv[1], sys.argv[2]
    chars = charset()
    options = subset.Options()
    options.layout_features = ["*"]
    options.name_IDs = ["*"]
    options.notdef_outline = True
    font = subset.load_font(source, options)
    subsetter = subset.Subsetter(options=options)
    subsetter.populate(text=chars)
    subsetter.subset(font)
    subset.save_font(font, target, options)
    (ROOT / "tool/font_subset_chars.json").write_text(
        json.dumps(sorted(chars), ensure_ascii=False, indent=0), encoding="utf-8"
    )
    print(f"wrote {target}: {len(chars)} chars")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
