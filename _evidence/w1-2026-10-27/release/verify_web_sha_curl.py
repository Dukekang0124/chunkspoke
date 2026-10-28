"""Verify every published web asset byte-for-byte against the release manifest, from each source."""
import concurrent.futures as cf
import hashlib
import json
import os
import subprocess
import sys
import tempfile

MANIFEST = r"D:/gtmp/chunkspoke-releases/web/0.9.0/sha256-manifest.json"
ROOTS = {
    "pages": "https://dukekang0124.github.io/chunkspoke/web/",
    "jsdelivr": "https://cdn.jsdelivr.net/gh/Dukekang0124/chunkspoke@main/docs/web/",
    "raw_releases": "https://raw.githubusercontent.com/Dukekang0124/chunkspoke-releases/main/web/0.9.0/",
    "raw_site": "https://raw.githubusercontent.com/Dukekang0124/chunkspoke/main/docs/web/",
}


def fetch(url, want_bytes, timeout=900, retries=3):
    """Return (code, data). A reset mid-body still reports 200 in %{http_code},
    so the exit code and the transferred size are part of the success test."""
    code = "000"
    for i in range(retries + 1):
        fd, path = tempfile.mkstemp(suffix=".bin")
        os.close(fd)
        p = subprocess.run(
            [
                "curl", "-sS", "--ssl-no-revoke", "--max-time", str(timeout),
                "-o", path, "-w", "%{http_code} %{size_download}", url,
            ],
            capture_output=True,
        )
        out = p.stdout.decode(errors="replace").strip().split()
        code = out[0] if out else "000"
        size = int(out[1]) if len(out) > 1 and out[1].isdigit() else -1
        complete = p.returncode == 0 and code == "200" and size == want_bytes
        if complete:
            with open(path, "rb") as f:
                data = f.read()
            os.unlink(path)
            return code, data
        os.unlink(path)
        print(f"  retry({i+1}) rc={p.returncode} http={code} bytes={size}/{want_bytes} {url.split('/')[-1]}", flush=True)
    return code, b""


def check(root_name, root, entry):
    url = root + entry["path"]
    code, data = fetch(url, entry["bytes"])
    if code != "200":
        return {"path": entry["path"], "error": f"http {code}"}
    got = hashlib.sha256(data).hexdigest()
    if got != entry["sha256"] or len(data) != entry["bytes"]:
        return {
            "path": entry["path"],
            "want": entry["sha256"][:16],
            "got": got[:16],
            "wantBytes": entry["bytes"],
            "gotBytes": len(data),
        }
    return None


def main() -> int:
    manifest = json.load(open(MANIFEST, encoding="utf-8"))
    entries = manifest["entries"]
    summary = {}
    for name, root in ROOTS.items():
        print(f"== {name} ({len(entries)} files)", flush=True)
        bad = []
        with cf.ThreadPoolExecutor(max_workers=6) as ex:
            futs = {ex.submit(check, name, root, e): e for e in entries}
            for fut in cf.as_completed(futs):
                r = fut.result()
                if r:
                    bad.append(r)
                    print("  BAD", r, flush=True)
        ok = len(entries) - len(bad)
        summary[name] = {"ok": ok, "total": len(entries), "bad": bad}
        print(f"  {name}: {ok}/{len(entries)} match", flush=True)
    out = r"D:/tmp/w1e2e/sha_verify_curl.json"
    json.dump(summary, open(out, "w", encoding="utf-8"), ensure_ascii=False, indent=2)
    good = all(v["ok"] == v["total"] for v in summary.values())
    print("SHA VERIFY:", "PASS" if good else "FAIL")
    return 0 if good else 1


if __name__ == "__main__":
    sys.exit(main())
