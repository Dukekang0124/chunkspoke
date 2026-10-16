"""修补 vosk_flutter(0.3.48) 插件的 android/build.gradle 以兼容 AGP 8+（本项目 AGP 9）。
该插件较旧：未声明 namespace（AGP 8+ 必需），compileSdk=33 过低。
幂等，可重复执行；作用于 pub 缓存中的插件源码。"""
import glob
import os
import re
import sys

CACHE = os.environ.get("PUB_CACHE") or os.path.join(
    os.environ.get("LOCALAPPDATA", ""), "Pub", "Cache", "hosted", "pub.dev")


def patch(path):
    s = open(path, encoding="utf-8").read()
    orig = s
    # 1) compileSdk 33 -> 35
    s = re.sub(r"compileSdk\s+33\b", "compileSdk 35", s, count=1)
    # 2) 在首个 android { 后补 namespace（若无）
    if "namespace" not in s:
        s = re.sub(r"android\s*\{", "android {\n    namespace 'org.vosk.vosk_flutter'", s, count=1)
    if s != orig:
        open(path, "w", encoding="utf-8").write(s)
        return True
    return False


def main():
    hits = glob.glob(os.path.join(CACHE, "vosk_flutter-*", "android", "build.gradle"))
    if not hits:
        print("  (未找到 vosk_flutter 插件，跳过修补——请先 pub get)")
        return 0
    for p in hits:
        print("  ✓ 修补 vosk_flutter (namespace/compileSdk):" if patch(p) else "  (vosk_flutter 已修补，跳过):", p)
    return 0


if __name__ == "__main__":
    sys.exit(main())
