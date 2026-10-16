"""确保 Vosk 离线模型 zip 存在于 assets/（构建期下载，仅一次）。
红线：模型随包内置，禁止应用运行时/首启联网下载；此脚本仅在构建链执行。"""
import os
import sys
import urllib.request

SRC = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))  # tools/ -> 项目根
URL = "https://alphacephei.com/vosk/models/vosk-model-small-en-us-0.15.zip"
DST = os.path.join(SRC, "assets", "vosk-model-small-en-us-0.15.zip")


def main():
    if os.path.isfile(DST) and os.path.getsize(DST) > 1_000_000:
        print("  (Vosk 模型已存在，跳过下载)")
        return
    os.makedirs(os.path.dirname(DST), exist_ok=True)
    print("  下载 Vosk 模型（~39MB，构建期，仅一次）…")
    urllib.request.urlretrieve(URL, DST)
    print("  Vosk 模型就位：%d B" % os.path.getsize(DST))


if __name__ == "__main__":
    sys.exit(main())
