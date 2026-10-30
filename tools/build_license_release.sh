#!/usr/bin/env bash
# 1.6.0 正式包构建 · 真 secret 注入（GATE-162 §三 指纹制）
#
# 用法
#   bash tools/build_license_release.sh --check    # 只校验 secret 就位并打印指纹，不构建
#   bash tools/build_license_release.sh            # 构建三 ABI（split-per-abi）
#
# 前置（放本机、不入 git、不入文档）
#   secret/unlock_secret.json
#   {"CS_UNLOCK_SECRET": "<真 secret>"}
#   轮换期需要同时兼容旧码时另加 {"CS_UNLOCK_SECRET_PREV": "<旧 secret>"}
#
# 纪律
#   1. secret **不经过命令行**：用 --dart-define-from-file 从文件读，
#      终端历史 / 进程列表 / 会话日志都不会出现 secret 本体。
#   2. 本脚本只打印**指纹前 8 位**（sha256(secret)[:8]，与 app 内 licenseSecretFp 同算法），
#      永不打印 secret 的内容、长度或任何片段。
#   3. 装机复核口径：kv 的 license.secretFp 必须等于本脚本打印的指纹。
#   4. 本脚本不做上传、不做 push、不碰线上清单。
set -euo pipefail
export PYTHONIOENCODING=utf-8

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SECRET_JSON="${ROOT}/secret/unlock_secret.json"
FLUTTER="${FLUTTER:-D:/tools/flutter/bin/flutter.bat}"
BUILD_NUMBER="${BUILD_NUMBER:-2064}"

mode="${1:-build}"

if [[ ! -f "$SECRET_JSON" ]]; then
  echo "[secret] 未就位：secret/unlock_secret.json" >&2
  echo "[secret] 按 GATE-162 §三：文件只放本机、不入 git；就位后回「已就位 + 指纹前 8 位」。" >&2
  exit 2
fi

python - "$SECRET_JSON" <<'PY'
import hashlib, json, sys
path = sys.argv[1]
try:
    with open(path, encoding='utf-8') as f:
        data = json.load(f)
except Exception as exc:
    print('[secret] 文件不是合法 JSON：%s' % type(exc).__name__, file=sys.stderr)
    sys.exit(2)
cur = data.get('CS_UNLOCK_SECRET')
if not isinstance(cur, str) or not cur.strip():
    print('[secret] 缺 CS_UNLOCK_SECRET（或值为空）', file=sys.stderr)
    sys.exit(2)
prev = data.get('CS_UNLOCK_SECRET_PREV')
fp = hashlib.sha256(cur.strip().encode('utf-8')).hexdigest()[:8]
print('[secret] 就位 · 指纹 %s%s' % (fp, ' · 含 PREV（轮换期兼容旧码）' if prev else ''))
PY

if [[ "$mode" == "--check" ]]; then
  exit 0
fi

cd "$ROOT"
"$FLUTTER" build apk --release --split-per-abi \
  --build-number="$BUILD_NUMBER" \
  --dart-define-from-file="$SECRET_JSON"

echo "[build] 完成：build/app/outputs/flutter-apk/chunkspoke-*-release.apk"
echo "[build] 复核：装机后 kv license.secretFp 必须等于上面的指纹；不符即作废重打。"
