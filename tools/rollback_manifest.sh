#!/usr/bin/env bash
# ASR-206 §五 · 分钟级回滚：把线上清单退回上一稳定版（红线：进度显示类 P0）
#
# 用法：
#   bash tools/rollback_manifest.sh 1.7.3 1.7.2            # 只演不发（默认 dry-run）
#   bash tools/rollback_manifest.sh 1.7.3 1.7.2 --apply    # 真回滚
#
# 为什么不用重传 APK：旧版本的包与清单一直在线上（apk/1.7.2/… 未删），
# 回滚 = 只把「应用读的那份清单」指回去 = 改两个 JSON + push + purge，一分钟内完成。
# 官网首页的下载链不自动回退（避免半路改文案），回滚后单独说明。
set -uo pipefail
BAD="${1:?用法: rollback_manifest.sh <坏版本> <回退目标版本> [--apply]}"
OK="${2:?缺少回退目标版本}"
APPLY="${3:-}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
REL=Dukekang0124/chunkspoke-releases
APP=Dukekang0124/chunkspoke
CURL="curl -s --ssl-no-revoke --max-time 120"

echo "== 1/4 取回退目标清单（$OK，以 raw 为权威字节）"
body=$($CURL "https://raw.githubusercontent.com/$REL/main/apk/$OK/version.json")
got=$(printf '%s' "$body" | python -c 'import sys,json;d=json.load(sys.stdin);print(d["versionName"],d["versionCode"],d["sha256"][:12])' 2>/dev/null) || {
  echo "  ✗ 目标清单无法解析，中止"; exit 1; }
echo "  ✓ $got"
case "$got" in "$OK "*) ;; *) echo "  ✗ 目标清单版本不是 $OK，中止"; exit 1;; esac

echo "== 2/4 写回仓库两份清单"
printf '%s\n' "$body" > "$ROOT/version.json"
printf '%s\n' "$body" > "$ROOT/docs/version.json"
grep -q "\"versionName\": \"$OK\"" "$ROOT/version.json" && echo "  ✓ version.json / docs/version.json 已切 $OK" || {
  echo "  ✗ 写入后校验失败"; exit 1; }

if [ "$APPLY" != "--apply" ]; then
  echo "== dry-run：未提交、未推送、未 purge。加 --apply 才真回滚。"
  git -C "$ROOT" checkout -- version.json docs/version.json 2>/dev/null || true
  exit 0
fi

echo "== 3/4 提交并推送 main"
git -C "$ROOT" add version.json docs/version.json
git -C "$ROOT" commit -m "revert(release): 线上清单退回 $OK（$BAD 触红线：进度显示类 P0）" || {
  echo "  ✗ 提交失败"; exit 1; }
git -C "$ROOT" push origin HEAD:main || { echo "  ✗ 推送失败"; exit 1; }

echo "== 4/4 purge 两条清单源"
for u in "gh/$APP@main/version.json" "gh/$APP@main/docs/version.json" \
         "gh/$REL@main/apk/$OK/version.json"; do
  printf '  %-46s ' "$u"
  $CURL "https://purge.jsdelivr.net/$u" | python -c 'import sys,json;print(json.load(sys.stdin).get("status"))' 2>/dev/null || echo "?"
done

sleep 30
bash "$ROOT/tools/spotcheck.sh" "$OK" || echo "  ✗ 回滚后抽验未过，需人工介入"
