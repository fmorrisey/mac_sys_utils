#!/bin/bash
# DynDOLOD under Wine: runs TexGen / DynDOLOD inside the Skyrim (DXVK) wrapper by temporarily pointing the
# wrapper at the tool instead of Steam, then installs the outputs as mods through skymod.
#
#   ./dyndolod.sh texgen     # run TexGen (click Start; wait; close it)
#   ./dyndolod.sh dyndolod   # run DynDOLOD (pick worldspaces + preset; OK; wait; close it)
#   ./dyndolod.sh install    # package TexGen_Output / DynDOLOD_Output as mods and install them
#   ./dyndolod.sh restore    # put the wrapper back on Steam (done automatically when the tool exits)
set -euo pipefail
WRAP="/Applications/Ported Games/Steambuild 32 64bit DXVK.app"
PLIST="$WRAP/Contents/Info.plist"
C="$WRAP/Contents/SharedSupport/prefix/drive_c"
DL="$HOME/Games/Skyrim Mods/downloads"
HERE="$(cd "$(dirname "$0")" && pwd)"
PB=/usr/libexec/PlistBuddy
DATA='C:\Program Files (x86)\Steam\steamapps\common\Skyrim Special Edition\Data'
PLUGINS='C:\users\fmorrisey\AppData\Local\Skyrim Special Edition\Plugins.txt'
MYGAMES='C:\users\fmorrisey\Documents\My Games\Skyrim Special Edition'

wrapper_running() { pgrep -f 'Steambuild 32 64bit DXVK[.]app/Contents/(MacOS/wineskinlauncher|SharedSupport/wine)' >/dev/null; }
set_program() {  # $1 = exe path under C:, $2 = flags (plutil keeps backslashes and quotes verbatim; PlistBuddy mangles them)
  plutil -replace "Program Name and Path" -string "$1" "$PLIST"
  plutil -replace "Program Flags" -string "$2" "$PLIST"
}
restore() { set_program "/Program Files (x86)/Steam/steam.exe" ""; plutil -replace "Debug Mode" -bool false "$PLIST"; echo "wrapper restored to Steam"; }

case "${1:-}" in
  texgen|dyndolod)
    if wrapper_running; then echo "the Skyrim wrapper is running (Steam or the game); quit it first"; exit 1; fi
    if [ "$1" = texgen ]; then EXE="/DynDOLOD/TexGenx64.exe"; OUT='C:\DynDOLOD\TexGen_Output'; else EXE="/DynDOLOD/DynDOLODx64.exe"; OUT='C:\DynDOLOD\DynDOLOD_Output'; fi
    FLAGS="-sse -d:\"$DATA\" -p:\"$PLUGINS\" -m:\"$MYGAMES\" -o:\"$OUT\""
    cp -p "$PLIST" "/tmp/dxvk-Info.plist.bak-$(date +%H%M%S)"
    set_program "$EXE" "$FLAGS"
    plutil -replace "Debug Mode" -bool true "$PLIST"   # Wine log -> SharedSupport/Logs/LastRunWine.log for this run
    echo "wrapper now runs: $EXE $FLAGS"
    echo "launching $1; the window appears in 10-20 s. When you close it the wrapper goes back to Steam."
    open "$WRAP"
    sleep 20
    while wrapper_running; do sleep 5; done
    restore ;;
  install)
    for pair in "TexGen_Output:dyndolod-texgen-output" "DynDOLOD_Output:dyndolod-output"; do
      src="$C/DynDOLOD/${pair%%:*}"; id="${pair##*:}"
      if [ ! -d "$src" ] || [ -z "$(ls -A "$src")" ]; then echo "$src is empty; skipping $id"; continue; fi
      rm -f "$DL/$id.zip"; (cd "$src" && zip -qr "$DL/$id.zip" .) && echo "packaged $id.zip ($(du -sh "$DL/$id.zip" | cut -f1))"
    done
    "$HERE/skymod.py" --force install dyndolod-texgen-output dyndolod-output --reinstall ;;
  restore) restore ;;
  *) sed -n '2,9p' "$0" ;;
esac
