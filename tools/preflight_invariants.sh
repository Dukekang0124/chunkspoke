#!/usr/bin/env bash
# ASR-227 §三 / ASR-228 §四 · 每轮自查前置闸（入库版，N1 起以本文件为准）
#
# 语义：FAIL = 停车点（须停下回报）；WARN = 未到点但已登记；INFO = 现状记录，不判生死。
# 只读脚本：不写仓库、不推远端、不碰任何 version.json。
#
# 用法：
#   bash tools/preflight_invariants.sh
#   CS_RELEASES_DIR=/path/to/chunkspoke-releases bash tools/preflight_invariants.sh
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
REL="${CS_RELEASES_DIR:-/d/gtmp/chunkspoke-releases}"
fails=0; warns=0
ok()   { printf '  PASS %s\n' "$1"; }
bad()  { printf '  FAIL %s\n' "$1"; fails=$((fails+1)); }
warn() { printf '  WARN %s\n' "$1"; warns=$((warns+1)); }
info() { printf '  INFO %s\n' "$1"; }

echo "== 0. 前置存在性"
[ -d "$REL/.git" ] && ok "releases 仓在位：$REL" || { bad "releases 仓不在位（CS_RELEASES_DIR 未设？）；后续检查无意义"; }

echo "== 1. 四红线（不合 main / 不动 version.json / 零落库切片不外溢 / 沙盒不入发布链）"
cd "$ROOT" || exit 1
if git cat-file -e origin/main:lib/services/user_package.dart 2>/dev/null; then
  bad "main 已含 user_package.dart（D 轮被合入，违反红线 3）"
else
  ok "main 不含 D 轮代码（未合 main）"
fi
dirty=$(git status --porcelain -- version.json docs/version.json assets/version.json | tr -d ' ')
[ -z "$dirty" ] && ok "工作树 version.json 三份均未改" \
  || warn "version.json 有本地差异：$dirty（只许 bump 轮出现）"
# 检查对象＝发布链真身四个脚本（预检脚本自己会提到 sandbox/，不能把自己算进去）。
_chain=$(grep -l "sandbox/" tools/build_license_release.sh tools/stage_release.py tools/spotcheck.sh tools/verify_release.py tools/rollback_manifest.sh 2>/dev/null || true)
[ -z "$_chain" ] && ok "发布链脚本不引用 sandbox/" || bad "发布链脚本引用了 sandbox/：$_chain"

echo "== 2. 发布链两脚本一字未动（对 origin/main）"
d1=$(git diff --stat origin/main -- tools/build_license_release.sh tools/stage_release.py | wc -l | tr -d ' ')
[ "$d1" = "0" ] && ok "build_license_release.sh / stage_release.py 与 origin/main 零差异" \
  || bad "发布链脚本出现 $d1 行差异"

echo "== 3. codes.json / secret / 码体"
if [ -d "$REL" ]; then
  cd "$REL" || exit 1
  codes_sha=$(sha256sum codes.json | awk '{print substr($1,1,16)}')
  info "codes.json 指纹（只出前 16 位）= $codes_sha"
  git diff --quiet HEAD@{1} HEAD -- codes.json && ok "最近一次提交未碰 codes.json" \
    || warn "codes.json 在最近提交有变动，需核对"
  if [ -f /d/cs_build/secret/unlock.secret ]; then
    fp=$(sha256sum /d/cs_build/secret/unlock.secret | awk '{print substr($1,1,16)}')
    ok "secret 仅在 cs_build/secret/，指纹=$fp（不回显内容）"
  else
    warn "cs_build/secret/unlock.secret 不在原位，需确认未被他处存放"
  fi

  echo "== 4. 附录 B 承重墙（voice/models/web/sandbox 当前代/legacy 必须在位）"
  for p in voice models web sandbox legacy apk/1.8.6; do
    if [ -e "$REL/$p" ]; then ok "在位：$p"; else bad "缺失：$p"; fi
  done
  vm="$REL/voice/hd-voice-piper-en-us-joe-medium/voice-model.json"
  if [ -f "$vm" ]; then
    info "voice-model.json 里 Pages 引用条数 = $(grep -o 'dukekang0124.github.io' "$vm" | wc -l | tr -d ' ')（>0 即证承重墙不可动）"
  fi

  echo "== 5. sandbox 只留最新一代 + sha sidecar"
  cd "$REL/sandbox" || exit 1
  n=$(ls *.apk 2>/dev/null | wc -l | tr -d ' ')
  [ "$n" = "1" ] && ok "sandbox/ 只有 1 个 APK" || bad "sandbox/ 有 $n 个 APK（裁定：只留最新一代）"
  for a in *.apk; do
    [ -f "$a.sha256" ] && ok "sidecar 在位：$a.sha256" || bad "缺 sidecar：$a.sha256"
    exp=$(awk '{print $1}' "$a.sha256" 2>/dev/null)
    got=$(sha256sum "$a" | awk '{print $1}')
    [ -n "$exp" ] && { [ "$exp" = "$got" ] && ok "sha 匹配：${got:0:16}…" \
      || bad "sha 不匹配：期望 ${exp:0:16} 实得 ${got:0:16}"; }
  done
  raw=$(curl -s --ssl-no-revoke -m 40 -o /dev/null -w '%{http_code}' \
    "https://raw.githubusercontent.com/Dukekang0124/chunkspoke-releases/main/sandbox/$(ls *.apk | head -1)")
  [ "$raw" = "200" ] && ok "沙盒 raw 直链 200" || bad "沙盒 raw 直链 $raw"

  echo "== 6. 体积格（B-6 末格；原子轮后才是硬闸）"
  wt=$(du -sm --exclude=.git "$REL" 2>/dev/null | awk '{print $1}')
  gitobj=$(du -sm "$REL/.git" 2>/dev/null | awk '{print $1}')
  info "releases 工作树 ${wt} MB + .git ${gitobj} MB（.git 不占 Pages 额度）"
  if [ "${wt:-0}" -le 1024 ]; then ok "工作树 ≤1 GB（体积格已过）"; else
    warn "工作树 ${wt} MB >1 GB：原子轮（#355 第 1 步）后必须转 PASS，本轮不判死"
  fi
fi

echo "== 7. 停车点自检口径"
info "FAIL 四类=硬断言/钉测红、票5 未过、Pages 复验失败、读回闸不绿；其余 WARN/INFO 不拦路"
echo
echo "结果：FAIL=$fails WARN=$warns"
[ "$fails" = "0" ] && echo "结论：可继续（无停车点）" || echo "结论：停车回报"
