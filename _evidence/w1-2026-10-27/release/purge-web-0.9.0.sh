#!/usr/bin/env bash
# WEB-W1 发布第 3 步：jsDelivr purge（站点 /web/** + version_web.json + @main）+ releases 产物。
# 用法：bash purge-web-0.9.0.sh [日志文件]
set -u
LOG="${1:-purge-web-0.9.0.log}"
SITE=Dukekang0124/chunkspoke
REL=Dukekang0124/chunkspoke-releases
BAD=0
echo "=== web 0.9.0 purge $(date '+%F %T') ===" > "$LOG"

urls=(
  "https://purge.jsdelivr.net/gh/$SITE@main/docs/web/"
  "https://purge.jsdelivr.net/gh/$SITE@main/version_web.json"
  "https://purge.jsdelivr.net/gh/$SITE@main/docs/version_web.json"
  "https://purge.jsdelivr.net/gh/$SITE@main/"
  "https://purge.jsdelivr.net/gh/$REL@main/web/"
  "https://purge.jsdelivr.net/gh/$REL@main/web/version_web.json"
)
# 关键单文件兜底（目录 purge 若不被接受，这些仍能逐个刷新）
for f in index.html main.dart.js flutter_bootstrap.js flutter_service_worker.js \
         canvaskit/canvaskit.wasm canvaskit/chromium/canvaskit.wasm \
         assets/AssetManifest.bin.json sha256-manifest.json version_web.json; do
  urls+=("https://purge.jsdelivr.net/gh/$SITE@main/docs/web/$f")
done

for u in "${urls[@]}"; do
  r=$(curl -sS --ssl-no-revoke --max-time 60 "$u" 2>&1)
  if echo "$r" | grep -Eq '"(status|state)": *"finished"'; then
    echo "$u -> finished" | tee -a "$LOG"
  else
    echo "$u -> FAILED: ${r:0:160}" | tee -a "$LOG"; BAD=$((BAD+1))
  fi
done

echo "@latest 现状（不 purge）：$(curl -sS --ssl-no-revoke --max-time 30 "https://cdn.jsdelivr.net/gh/$SITE@latest/version.json" 2>&1 | head -c 200)" | tee -a "$LOG"
echo "PURGE_DONE bad=$BAD total=${#urls[@]}" | tee -a "$LOG"
