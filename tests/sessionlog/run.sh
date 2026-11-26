#!/bin/bash
# Standalone session log test: compiles Sources/App/Engine/SessionLog.swift (app glue left out via
# -D SESSIONLOG_STANDALONE) with tests/sessionlog/main.swift and runs it. No app, camera or Resolve needed.
#   bash tests/sessionlog/run.sh [outdir]
set -e
cd "$(dirname "$0")/../.."
OUT="${1:-${TMPDIR:-/tmp}/hongmix-sessionlog-test}"
mkdir -p "$OUT"
SWIFTC=swiftc; command -v xcrun >/dev/null 2>&1 && SWIFTC="xcrun swiftc"
$SWIFTC -swift-version 5 -O -D SESSIONLOG_STANDALONE -module-cache-path "$OUT/module-cache" \
  Sources/App/Engine/SessionLog.swift tests/sessionlog/main.swift -o "$OUT/sessionlog_test"
"$OUT/sessionlog_test" "$OUT/work"
