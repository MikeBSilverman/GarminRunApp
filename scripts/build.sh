#!/usr/bin/env bash
# Build the sideload binary and the store package, named with the manifest
# version, e.g. bin/CourseRun-0.2.0.prg and bin/CourseRun-0.2.0.iq.
# Usage (Git Bash on Windows, or a POSIX shell):
#   scripts/build.sh [device]        default device: fr965
set -euo pipefail
cd "$(dirname "$0")/.."

DEVICE="${1:-fr965}"
VERSION="$(sed -nE 's/.*version="([0-9]+\.[0-9]+\.[0-9]+)".*/\1/p' manifest.xml | head -1)"
[ -n "$VERSION" ] || { echo "no version= in manifest.xml"; exit 1; }

if [ -z "${CIQ_SDK:-}" ]; then
    CFG="$HOME/AppData/Roaming/Garmin/ConnectIQ/current-sdk.cfg"
    [ -f "$CFG" ] || { echo "Set CIQ_SDK to the SDK folder (no current-sdk.cfg found)"; exit 1; }
    CIQ_SDK="$(tr -d '\r' < "$CFG")"
    CIQ_SDK="$(cygpath -u "$CIQ_SDK" 2>/dev/null || echo "$CIQ_SDK")"
fi
BIN="$CIQ_SDK/bin"
EXT=""; [ -f "$BIN/monkeyc.bat" ] && EXT=".bat"

python scripts/check.py
mkdir -p bin
"$BIN/monkeyc$EXT" -d "$DEVICE" -f monkey.jungle -o "bin/CourseRun-$VERSION.prg" -y developer_key.der -l 2 -w
"$BIN/monkeyc$EXT" -e -o "bin/CourseRun-$VERSION.iq" -f monkey.jungle -y developer_key.der -l 2 -w
ls -la "bin/CourseRun-$VERSION.prg" "bin/CourseRun-$VERSION.iq"
