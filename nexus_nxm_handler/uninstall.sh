#!/bin/bash
set -u
rm -rf "$HOME/Applications/NXM Handler.app" "$HOME/.local/bin/nxm-fetch.py"
security delete-generic-password -s com.fmorrisey.nexus-api >/dev/null 2>&1 && echo "API key removed from Keychain"
echo "removed. (Downloads in ~/Games are kept.)"
