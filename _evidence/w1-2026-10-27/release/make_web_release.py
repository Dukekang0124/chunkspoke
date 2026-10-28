"""Stage web 0.9.0 artifacts into the releases repo and emit a per-asset sha256 manifest."""
import hashlib
import json
import shutil
import sys
from datetime import datetime, timedelta, timezone
from pathlib import Path

SRC = Path(r"D:/写作工具/知识管理/01-Projects-项目/求职与作品集/03-作品集/chunkspoke/web-app/build/web")
REL = Path(r"D:/gtmp/chunkspoke-releases")
VERSION = "0.9.0-web"
SRC_COMMIT = "a29fd1f"
BASE_HREF = "/chunkspoke/web/"
DST = REL / "web" / "0.9.0"

PAGES = "https://dukekang0124.github.io/chunkspoke/web/"
JSD = "https://cdn.jsdelivr.net/gh/Dukekang0124/chunkspoke@main/docs/web/"
RAW = "https://raw.githubusercontent.com/Dukekang0124/chunkspoke/main/docs/web/"
JSD_REL = "https://cdn.jsdelivr.net/gh/Dukekang0124/chunkspoke-releases@main/web/0.9.0/"
RAW_REL = "https://raw.githubusercontent.com/Dukekang0124/chunkspoke-releases/main/web/0.9.0/"


def sha(p: Path) -> str:
    h = hashlib.sha256()
    with p.open("rb") as f:
        for chunk in iter(lambda: f.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()


def main() -> int:
    if DST.exists():
        shutil.rmtree(DST)
    DST.mkdir(parents=True)
    files = []
    for p in sorted(SRC.rglob("*")):
        if not p.is_file():
            continue
        rel = p.relative_to(SRC)
        if any(part.startswith(".") for part in rel.parts):
            continue  # Flutter 工具链内部标记（.last_build_id），非应用产物
        out = DST / rel
        out.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(p, out)
        files.append({
            "path": rel.as_posix(),
            "bytes": p.stat().st_size,
            "sha256": sha(p),
        })
    tz = timezone(timedelta(hours=8))
    now = datetime.now(tz).replace(microsecond=0).isoformat()
    app = next(f for f in files if f["path"] == "main.dart.js")
    total = sum(f["bytes"] for f in files)
    manifest = {
        "version": VERSION,
        "time": now,
        "sourceCommit": SRC_COMMIT,
        "baseHref": BASE_HREF,
        "appSha256": app["sha256"],
        "files": len(files),
        "bytes": total,
        "entries": files,
    }
    (DST / "sha256-manifest.json").write_text(
        json.dumps(manifest, ensure_ascii=False, indent=2) + "\n", encoding="utf-8"
    )
    version = {
        "version": VERSION,
        "sha": app["sha256"],
        "shaScope": "main.dart.js",
        "time": now,
        "url": PAGES,
        "urls": [PAGES, JSD, RAW, JSD_REL, RAW_REL],
        "manifest": f"{JSD_REL}sha256-manifest.json",
        "bytes": total,
        "files": len(files),
        "notes": "网页版 Beta 0.9.0：内容与本机学习可用；语音跟读/AI 点评请在 App 内使用；数据存本机，可导出备份。",
    }
    body = json.dumps(version, ensure_ascii=False, indent=2) + "\n"
    (DST / "version_web.json").write_text(body, encoding="utf-8")
    # 站点备份副本随 releases 一起存档（与 Pages 上的 docs/version_web.json 同字节）
    (REL / "web" / "version_web.json").write_text(body, encoding="utf-8")
    print(json.dumps({"files": len(files), "bytes": total, "appSha256": app["sha256"]}, ensure_ascii=False))
    return 0


if __name__ == "__main__":
    sys.exit(main())
