#!/bin/bash
# Builds Ticker Evaluator (Release) from this repo and installs it into /Applications.
#   ./scripts/install.sh                 install to /Applications (asks for your password only if needed)
#   DEST=~/Applications ./scripts/install.sh   install somewhere else
#   ./scripts/install.sh --test          also run the test suite first
set -euo pipefail
cd "$(dirname "$0")/.."

DEST="${DEST:-/Applications}"
APP="TickerEvaluator.app"

command -v xcodebuild >/dev/null || { echo "Xcode is required (install it from the App Store, then open it once)."; exit 1; }
if [ "$(xcode-select -p)" = "/Library/Developer/CommandLineTools" ]; then
  echo "Xcode's command-line tools point at CommandLineTools. Run:"
  echo "  sudo xcode-select -s /Applications/Xcode.app/Contents/Developer"
  exit 1
fi

# The Xcode project is committed; regenerate it only if xcodegen is installed and project.yml changed.
if command -v xcodegen >/dev/null && [ project.yml -nt TickerEvaluator.xcodeproj/project.pbxproj ]; then
  xcodegen generate
fi

if [ "${1:-}" = "--test" ]; then
  echo "Running tests…"
  xcodebuild -project TickerEvaluator.xcodeproj -scheme TickerEvaluator -derivedDataPath build test -quiet
fi

echo "Building (Release)…"
xcodebuild -project TickerEvaluator.xcodeproj -scheme TickerEvaluator -configuration Release \
  -derivedDataPath build build -quiet

SRC="build/Build/Products/Release/$APP"
[ -d "$SRC" ] || { echo "Build output not found at $SRC"; exit 1; }

pkill -x TickerEvaluator 2>/dev/null || true
mkdir -p "$DEST"
if [ -w "$DEST" ]; then
  rm -rf "$DEST/$APP" && cp -R "$SRC" "$DEST/"
else
  echo "Copying to $DEST needs your password:"
  sudo rm -rf "$DEST/$APP" && sudo cp -R "$SRC" "$DEST/"
fi
echo "Installed $DEST/$APP"
[ "${NO_OPEN:-}" = "1" ] || open "$DEST/$APP"
