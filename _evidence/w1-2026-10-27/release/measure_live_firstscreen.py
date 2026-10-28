"""Measure the real first-screen transfer from GitHub Pages.

Uses the exact 13/14-file request set recorded in _evidence .../size/firstscreen_multi.txt.
We send `Accept-Encoding: gzip` (what a browser sends) and read %{size_download},
which is the on-the-wire compressed size — not a re-gzip estimate.
"""
import json, subprocess, sys, os

BASE = "https://dukekang0124.github.io/chunkspoke/web/"
OUT = r"D:/tmp/w1e2e/firstscreen_live.json"
MAN = r"D:/gtmp/chunkspoke-releases/web/0.9.0/sha256-manifest.json"

CHROME = [
    ("", "index.html"),
    ("assets/FontManifest.json", "assets/FontManifest.json"),
    ("assets/assets/content/articles.json", "assets/assets/content/articles.json"),
    ("assets/assets/content/chunks.json", "assets/assets/content/chunks.json"),
    ("assets/assets/fonts/NotoSansSC-Subset.otf", "assets/assets/fonts/NotoSansSC-Subset.otf"),
    ("assets/fonts/MaterialIcons-Regular.otf", "assets/fonts/MaterialIcons-Regular.otf"),
    ("assets/fonts/fallback/Roboto-Regular.ttf", "assets/fonts/fallback/Roboto-Regular.ttf"),
    ("assets/packages/cupertino_icons/assets/CupertinoIcons.ttf", "assets/packages/cupertino_icons/assets/CupertinoIcons.ttf"),
    ("canvaskit/chromium/canvaskit.js", "canvaskit/chromium/canvaskit.js"),
    ("canvaskit/chromium/canvaskit.wasm", "canvaskit/chromium/canvaskit.wasm"),
    ("favicon.png", "favicon.png"),
    ("flutter_bootstrap.js", "flutter_bootstrap.js"),
    ("main.dart.js", "main.dart.js"),
]
FIREFOX_ONLY = [
    ("canvaskit/canvaskit.js", "canvaskit/canvaskit.js"),
    ("canvaskit/canvaskit.wasm", "canvaskit/canvaskit.wasm"),
    ("icons/Icon-192.png", "icons/Icon-192.png"),
]

man = {e["path"]: e for e in json.load(open(MAN, encoding="utf-8"))["entries"]}


def get(url):
    tmp = r"D:/tmp/w1e2e/_m.bin"
    for i in range(4):
        p = subprocess.run(["curl", "-sSL", "--ssl-no-revoke", "--max-time", "300",
                            "-H", "Accept-Encoding: gzip", "-o", tmp,
                            "-w", "%{http_code} %{size_download}", url],
                           capture_output=True)
        o = p.stdout.decode(errors="replace").split()
        code = o[0] if o else "000"
        size = int(o[1]) if len(o) > 1 and o[1].isdigit() else -1
        try:
            raw = os.path.getsize(tmp)
        except OSError:
            raw = -1
        if p.returncode == 0 and code == "200" and size == raw and size > 0:
            return code, size
        print(f"  retry({i+1}) rc={p.returncode} http={code} size={size} file={raw}", flush=True)
    return code, -1


def measure(name, files, extra=()):
    rows, total, engine = [], 0, 0
    for path, manpath in list(files) + list(extra):
        url = BASE + path if path else BASE
        code, xfer = get(url)
        want = man[manpath]["bytes"]
        ok = code == "200" and xfer > 0
        rows.append({"path": path or "/", "manifestBytes": want, "transferBytes": xfer,
                     "gzipRatio": round(xfer / want, 4) if ok and want else None, "ok": ok})
        if ok:
            total += xfer
            if path.startswith("canvaskit/"):
                engine += xfer
        print(f"  {path or '/':60s} {want:>9,} -> {xfer:>9,}  {code}")
    return {"browser": name, "files": len(rows), "transferTotal": total,
            "transferEngine": engine, "transferAppContent": total - engine, "rows": rows}


res = {"base": BASE, "acceptEncoding": "gzip", "chromeEdge": measure("chrome/edge", CHROME)}
# firefox substitutes its own engine + icon; drop chromium engine files
ff = [f for f in CHROME if not f[0].startswith("canvaskit/")]
ff = [f for f in ff if f[0] != ""]
ff = [f for f in ff if f[0] != "favicon.png"]
res["firefox"] = measure("firefox", ff, FIREFOX_ONLY)
json.dump(res, open(OUT, "w", encoding="utf-8"), ensure_ascii=False, indent=2)
for k in ("chromeEdge", "firefox"):
    r = res[k]
    print(f"{k}: files={r['files']} transfer={r['transferTotal']:,} "
          f"engine={r['transferEngine']:,} app+content={r['transferAppContent']:,}")
