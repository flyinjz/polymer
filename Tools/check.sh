#!/usr/bin/env bash
# Builds and runs the checks, printing only what matters: compiler errors,
# failed checks and the summary. Run from the repository root.
#   bash Tools/check.sh [debug|release] [filter]
set -u
config="${1:-release}"
filter="${2:-}"
dir="Release-windows-x86_64"
flag="-c release"
if [ "$config" = "debug" ]; then dir="Debug-windows-x86_64"; flag=""; fi

log="$(swift build $flag 2>&1)"
if ! echo "$log" | grep -q "Build complete"; then
    echo "$log" | sed 's/\x1b\[[0-9;]*m//g' | grep -E "error" | grep -v "SwiftCompile\|Build failed" | cut -c1-300 | sort -u | head -40
    echo "build failed"
    exit 1
fi
".build/out/Products/$dir/polymer.exe" check $filter 2>&1 | grep -v "^pass"
exit "${PIPESTATUS[0]}"
