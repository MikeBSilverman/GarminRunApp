#!/usr/bin/env bash
# Render one screen state in the simulator and screenshot it.
# usage: tools/preview.sh <device> <scenario> [dark]   -> bin/preview/shot_<device>_<scenario>.png
# Needs the simulator running (scripts/test.sh starts it) and a developer_key.der.
R="$(cd "$(dirname "$0")/.." && pwd)"
CFG="$HOME/AppData/Roaming/Garmin/ConnectIQ/current-sdk.cfg"
SDK="$(cygpath -u "$(tr -d '\r' < "$CFG")")/bin"
SP="$R/bin/preview"
python "$R/tools/mkpreview.py" $2 $3 || exit 1
cd "$SP"
"$SDK/monkeyc.bat" -d $1 -f monkey.jungle -o bin/p.prg -y developer_key.der -w 2>&1 | grep -E "ERROR|BUILD" | tail -5
MSYS2_ARG_CONV_EXCL='*' timeout 25 "$SDK/monkeydo.bat" bin/p.prg $1 > /dev/null 2>&1 &
sleep 12
powershell -ExecutionPolicy Bypass -File "$R/tools/shot.ps1" "$SP/shot_$1_$2.png" | tail -1
