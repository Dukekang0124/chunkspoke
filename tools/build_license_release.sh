#!/usr/bin/env bash
# 1.6.0 正式包构建 · 真 secret 注入（GATE-162 §三 指纹制）
#
# 用法
#   bash tools/build_license_release.sh --check    # 只校验 secret 就位并打印指纹，不构建
#   bash tools/build_license_release.sh            # 构建三 ABI（split-per-abi）
#
# 前置（放本机、不入 git、不入文档）
#   主源（纯文本，与运营侧 cs_codes.py --secret-file 同一份）：
#     secret/unlock.secret        一行，就是 secret 本体
#     secret/unlock.prev.secret   可选，轮换期兼容旧码用
#   兼容源（JSON，若已按旧约定放好也行）：
#     secret/unlock_secret.json   {"CS_UNLOCK_SECRET": "...", "CS_UNLOCK_SECRET_PREV": "..."}
#
# 纪律
#   1. secret **不经过命令行**：用 --dart-define-from-file 读临时 JSON，
#      终端历史 / 进程列表 / 会话日志都不会出现 secret 本体。
#   2. 临时 JSON 建在 secret/ 目录内（已 gitignore），构建结束即删（trap 兜底）。
#   3. 本脚本只打印**指纹前 8 位**（sha256(secret)[:8]，与 app 内 licenseSecretFp 同算法），
#      永不打印 secret 的内容、长度或任何片段。
#   4. 装机复核口径：kv 的 license.secretFp 必须等于本脚本打印的指纹。
#   5. 本脚本不做上传、不做 push、不碰线上清单。
set -euo pipefail
export PYTHONIOENCODING=utf-8

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SECRET_DIR="${ROOT}/secret"
PLAIN="${SECRET_DIR}/unlock.secret"
PLAIN_PREV="${SECRET_DIR}/unlock.prev.secret"
JSON_SRC="${SECRET_DIR}/unlock_secret.json"
DEFINES="${SECRET_DIR}/.dart_defines.json"
FLUTTER="${FLUTTER:-D:/tools/flutter/bin/flutter.bat}"
BUILD_NUMBER="${BUILD_NUMBER:-2064}"

mode="${1:-build}"

if [[ ! -f "$PLAIN" && ! -f "$JSON_SRC" ]]; then
  echo "[secret] 未就位：secret/unlock.secret（或 unlock_secret.json）" >&2
  echo "[secret] 按 GATE-162 §三：文件只放本机、不入 git；就位后回「已就位 + 指纹前 8 位」。" >&2
  exit 2
fi

# 把来源归一成一份临时 defines（同目录、构建后删），并只打印指纹。
python - "$PLAIN" "$PLAIN_PREV" "$JSON_SRC" "$DEFINES" <<'PY'
import hashlib, json, os, sys

plain, plain_prev, json_src, out = sys.argv[1:5]

def read_plain(path):
    if not os.path.isfile(path):
        return None
    with open(path, encoding='utf-8') as f:
        s = f.read().strip()
    return s or None

cur = read_plain(plain)
prev = read_plain(plain_prev)

if cur is None:
    with open(json_src, encoding='utf-8') as f:
        data = json.load(f)
    cur = (data.get('CS_UNLOCK_SECRET') or '').strip()
    prev = (data.get('CS_UNLOCK_SECRET_PREV') or '').strip() or prev

if not cur:
    print('[secret] secret 为空', file=sys.stderr)
    sys.exit(2)

defines = {'CS_UNLOCK_SECRET': cur}
if prev:
    defines['CS_UNLOCK_SECRET_PREV'] = prev

# 0600：仅当前用户可读
fd = os.open(out, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
with os.fdopen(fd, 'w', encoding='utf-8') as f:
    json.dump(defines, f)

fp = hashlib.sha256(cur.encode('utf-8')).hexdigest()[:8]
print('[secret] 就位 · 指纹 %s%s' % (fp, ' · 含 PREV（轮换期兼容旧码）' if prev else ''))
PY

cleanup() { rm -f "$DEFINES"; }
trap cleanup EXIT

if [[ "$mode" == "--check" ]]; then
  exit 0
fi

cd "$ROOT"
"$FLUTTER" build apk --release --split-per-abi \
  --build-number="$BUILD_NUMBER" \
  --dart-define-from-file="$DEFINES"

echo "[build] 完成：build/app/outputs/flutter-apk/chunkspoke-*-release.apk"
echo "[build] 复核：装机后 kv license.secretFp 必须等于上面的指纹；不符即作废重打。"
