#!/bin/bash
# Installs the latest Sugrob release into /Applications.
# Usage: curl -fsSL https://raw.githubusercontent.com/akoody/sugrob/main/install.sh | bash
set -euo pipefail

REPO="${SUGROB_REPO:-akoody/sugrob}"
URL="https://github.com/$REPO/releases/latest/download/Sugrob.zip"
TARGET="/Applications"
[ -w "$TARGET" ] || TARGET="$HOME/Applications"
mkdir -p "$TARGET"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

echo "Downloading Sugrob..."
curl -fsSL "$URL" -o "$WORK/Sugrob.zip"
ditto -x -k "$WORK/Sugrob.zip" "$WORK"

pkill -x Sugrob 2>/dev/null || true
rm -rf "$TARGET/Sugrob.app"
mv "$WORK/Sugrob.app" "$TARGET/Sugrob.app"
open "$TARGET/Sugrob.app"

echo "Done. Look for the snowflake in your menu bar."
