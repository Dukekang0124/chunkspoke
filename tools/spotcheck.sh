#!/usr/bin/env bash
# ASR-206 §五 · 线上抽验（24h 运行期，每班次跑一次）
#
# 用法：bash tools/spotcheck.sh 1.7.3 4073
# 判据（任一硬失败 → 退出码 1）：
#   1) 三源清单逐字节同值（sha256 全文），且 versionName/versionCode 与目标一致；
#   2) 官网首页已指向该版本（apk/<v>/ 链 + 徽标 v<v>）；
#   3) 分片 part0 全文 sha256 == 清单声明（jsDelivr 长度法无效，只信全文）。
# 每源最多试 3 次（Pages/CDN 边缘偶发抖动是已知现象，重试后仍失败才算硬失败）。
# 只读线上，不改任何东西。
set -uo pipefail
V="${1:?用法: bash tools/spotcheck.sh <versionName> [期望versionCode]}"
CODE="${2:-}"
REL=Dukekang0124/chunkspoke-releases
APP=Dukekang0124/chunkspoke
# GitHub Pages 的站点路径只到「仓库名」，不带 owner —— 拼成 /Dukekang0124/xxx 会 404。
PAGES_REL=https://dukekang0124.github.io/chunkspoke-releases
PAGES_APP=https://dukekang0124.github.io/chunkspoke
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
fail=0

# fetch <url> <out> → 打印 http 码；失败重试到 3 次
fetch() {
  local url="$1" out="$2" code i
  for i in 1 2 3; do
    code=$(curl -s --ssl-no-revoke --max-time 120 -o "$out" -w "%{http_code}" "$url" || echo 000)
    [ "$code" = "200" ] && [ -s "$out" ] && { echo "$code"; return; }
    [ "$i" = "3" ] || sleep 5
  done
  echo "$code"
}

echo "== 1/3 三源清单（$V）"
ref=""
for u in \
  "https://raw.githubusercontent.com/$REL/main/apk/$V/version.json" \
  "$PAGES_REL/apk/$V/version.json" \
  "https://cdn.jsdelivr.net/gh/$REL@main/apk/$V/version.json"; do
  o="$TMP/$(echo "$u" | md5sum | cut -c1-8).json"
  code=$(fetch "$u" "$o")
  s=$(sha256sum "$o" | cut -c1-16)
  got=$(python - "$o" <<'PY' 2>/dev/null || echo 解析失败
import json,sys
d=json.load(open(sys.argv[1],encoding='utf-8'))
print(d['versionName'],d['versionCode'])
PY
)
  printf '  %-28s http=%s sha=%s %s\n' "$(echo "$u" | cut -d/ -f3)" "$code" "$s" "$got"
  [ "$code" = "200" ] || { echo "    ✗ 三次重试后仍不可达"; fail=1; continue; }
  [ "$got" = "$V ${CODE:-$V}" ] || { [ -z "$CODE" ] && case "$got" in "$V "*) ;; *) echo "    ✗ 清单版本不是 $V"; fail=1;; esac; }
  [ -n "$CODE" ] && { case "$got" in "$V $CODE") ;; *) echo "    ✗ versionCode 不是 $CODE"; fail=1;; esac; }
  [ -z "$ref" ] && ref="$s" || { [ "$s" = "$ref" ] || { echo "    ✗ 与首源逐字节不一致（首源 $ref）"; fail=1; }; }
done

echo "== 2/3 官网首页"
o="$TMP/site.html"; code=$(fetch "$PAGES_APP/" "$o")
if grep -q "apk/$V/" "$o"; then echo "  ✓ 下载链已指 apk/$V/"; else echo "  ✗ 首页没有 apk/$V/ 链（http=$code）"; fail=1; fi
if grep -q "v$V" "$o"; then echo "  ✓ 版本徽标 v$V"; else echo "  ✗ 徽标未切到 v$V"; fail=1; fi

echo "== 3/3 分片全文 sha（part0）"
want=$(python - "$TMP/$(echo "https://raw.githubusercontent.com/$REL/main/apk/$V/version.json" | md5sum | cut -c1-8).json" <<'PY' 2>/dev/null
import json,sys
print(json.load(open(sys.argv[1],encoding='utf-8'))['parts'][0]['sha256'])
PY
)
o2="$TMP/p0"; code=$(fetch "https://cdn.jsdelivr.net/gh/$REL@main/apk/$V/parts/apk.part0" "$o2")
got=$(sha256sum "$o2" | cut -d' ' -f1)
if [ -n "$want" ] && [ "$got" = "$want" ]; then
  echo "  ✓ part0 sha256 = $got（$(stat -c%s "$o2") B）"
else
  echo "  ✗ part0 不一致：$got != ${want:-未取到清单}（http=$code）"; fail=1
fi

if [ "$fail" = "0" ]; then echo "[抽验通过] $V 链路完好"; else echo "[抽验失败] 见上面 ✗ 项"; fi
exit $fail
