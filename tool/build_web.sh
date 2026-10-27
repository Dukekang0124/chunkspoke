#!/usr/bin/env bash
# Web 构建：本地化 CanvasKit（不依赖 gstatic CDN，红线「无遥测/无外链」）
set -euo pipefail
cd "$(dirname "$0")/.."
flutter build web --release --no-web-resources-cdn --tree-shake-icons "$@"
