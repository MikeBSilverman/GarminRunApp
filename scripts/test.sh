#!/usr/bin/env bash
# Build and run the unit tests in the Connect IQ simulator, then run the
# static checks. Usage (Git Bash on Windows, or a POSIX shell):
#   scripts/test.sh [device]        default device: fr965
#
# Needs: Connect IQ SDK (path from ~/AppData/Roaming/Garmin/ConnectIQ/current-sdk.cfg
# or $CIQ_SDK), a developer_key.der in the repo root (git-ignored), Python 3.
set -euo pipefail
cd "$(dirname "$0")/.."

DEVICE="${1:-fr965}"
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
"$BIN/monkeyc$EXT" -d "$DEVICE" -f monkey.jungle -o bin/CourseRun-test.prg -y developer_key.der --unit-test -l 2 -w

if ! tasklist 2>/dev/null | grep -qi simulator; then
    if [ -f "$BIN/simulator.exe" ]; then "$BIN/simulator.exe" >/dev/null 2>&1 & else "$BIN/connectiq" >/dev/null 2>&1 & fi
    sleep 8
fi
# In Git Bash, /t would be path-mangled without MSYS2_ARG_CONV_EXCL.
MSYS2_ARG_CONV_EXCL='*' "$BIN/monkeydo$EXT" bin/CourseRun-test.prg "$DEVICE" /t | tee bin/test-output.txt
grep -q "^PASSED" bin/test-output.txt
