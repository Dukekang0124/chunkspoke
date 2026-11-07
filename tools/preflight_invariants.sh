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
  if [ ! -d "$REL/sandbox" ]; then
    bad "releases 里没有 sandbox/ 目录（第 5～6 格无法核对）"
  else
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
  fi

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

# ── ASR-231 裁定 1：清单自洽闸 ────────────────────────────────────────────
# 起因：dev 工作树曾躺着一份「半截清单」——urls/parts 已换成 1.8.6，
# sha256/size 却还是 1.8.5.1 的真身（015a9c79…）。这种文件带进 bump 轮＝发布事故
# （用户下到 1.8.6 的包、按 1.8.5.1 的 sha 校验，必然失败）。
# 规则：清单里第一个 sha256 就是 arm64 整包 sha ⇒ 必须等于 releases 里同代
#       apk/<versionName>/chunkspoke-latest.apk 的实算值。main 底版硬判；
#       本代未 bump 前只记 INFO（第 4 步才改），bump 后转硬判。
vn_of() { grep -o '"versionName": *"[^"]*"' "$1" | head -1 | sed 's/.*: *"//; s/"//'; }
sha_of() { grep -o '"sha256": *"[^"]*"' "$1" | head -1 | sed 's/.*: *"//; s/"//'; }
merged=0
selfcheck_manifest() { # $1=标签 $2=清单文件 $3=releases 根
  local tag="$1" file="$2" rel="$3" vn sh actual apk
  vn=$(vn_of "$file"); sh=$(sha_of "$file")
  apk="$rel/apk/$vn/chunkspoke-latest.apk"
  if [ ! -f "$apk" ]; then
    warn "$tag：清单写 $vn，但 releases 里没有 apk/$vn/chunkspoke-latest.apk，无法对账"
    return
  fi
  actual=$(sha256sum "$apk" | awk '{print $1}')
  if [ -n "$sh" ] && [ "$sh" = "$actual" ]; then
    ok "$tag：$vn 的清单 sha=${sh:0:16}… == 同代 arm64 整包实算（自洽）"
  else
    bad "$tag：$vn 的清单 sha=${sh:0:16}… ≠ 实算 ${actual:0:16}…（半截清单形态：URL 换了、sha 没换）"
  fi
}
echo "== 8. 清单自洽（merge 底版 + bump 后 arm64 sha=新包 sha）"
cd "$ROOT" || exit 1
tmp_main_vj="$ROOT/.pf_main_version.json"
if git show origin/main:assets/version.json > "$tmp_main_vj" 2>/dev/null; then
  selfcheck_manifest "main 底版" "$tmp_main_vj" "$REL"
  mvn=$(vn_of "$tmp_main_vj")
  mcommit=$(git log -1 --format=%h origin/main -- assets/version.json)
  if git merge-base --is-ancestor "$mcommit" HEAD 2>/dev/null; then
    merged=1
    ok "dev HEAD 已含 main 的清单提交（$mcommit / $mvn）⇒ 清单自洽已转硬判"
  else
    warn "dev HEAD 落后 main 的清单提交（$mcommit / $mvn）⇒ 合并时必须以 main 清单为底再改写，不许让 dev 陈旧件覆盖"
  fi
  # 底版 sha 只出前 8 位，方便与发布记录对眼。
  info "main 底版 sha（前 8 位）= $(sha_of "$tmp_main_vj" | cut -c1-8)"
else
  bad "读不到 origin/main:assets/version.json（fetch 未做？）"
fi
rm -f "$tmp_main_vj"
pubver=$(grep -oE '^version: [0-9][^ ]*' pubspec.yaml | head -1 | sed 's/^version: //; s/+.*//')
wtvn=$(vn_of assets/version.json 2>/dev/null)
wtsha=$(sha_of assets/version.json 2>/dev/null)
if [ "$wtvn" = "$pubver" ] && [ "${merged:-0}" = "1" ]; then
  # merge 已把 main 底版带进来 ⇒ 这条从此是硬闸（原子轮第 4 步不改到位就别想推）。
  selfcheck_manifest "本代（已 merge 底版、已 bump）" assets/version.json "$REL"
elif [ "$wtvn" = "$pubver" ]; then
  # dev 还没 merge main 的清单提交：这里的清单是「上代头 + 来历不明的 sha」，
  # 不判死但必须说清——它会在 merge 后那一轮被 main 底版覆盖，届时转硬判。
  warn "本代清单 sha=${wtsha:0:16}… 未与任何在库 APK 对过账（dev 尚未取 main 底版）；merge 后本条转硬判"
else
  info "清单仍是上代态（$wtvn，pubspec 本代 $pubver）⇒ 属原子轮第 4 步，本轮不硬判"
fi
echo
echo "结果：FAIL=$fails WARN=$warns"
[ "$fails" = "0" ] && echo "结论：可继续（无停车点）" || echo "结论：停车回报"
