#!/bin/bash
# Builds the display-mode CLI into ~/.local/bin (no LaunchAgent; it is a plain command).
set -euo pipefail
cd "$(dirname "$0")"
mkdir -p "$HOME/.local/bin"
swiftc -O -o "$HOME/.local/bin/display-mode" main.swift
echo "installed: $HOME/.local/bin/display-mode"
"$HOME/.local/bin/display-mode" | head -3
