#!/bin/bash
# Builds Video View and installs it to ~/Applications/Video View.app
# The build folder lives outside Dropbox so Dropbox does not sync thousands of build files.
set -euo pipefail
cd "$(dirname "$0")"

SCRATCH="$HOME/Library/Caches/VideoView-build"
APP="$HOME/Applications/Video View.app"

# One-time icon build from icon-1024.png (sips and iconutil ship with macOS)
if [ ! -f AppIcon.icns ] && [ -f icon-1024.png ]; then
  SET="$(mktemp -d)/AppIcon.iconset"; mkdir -p "$SET"
  for s in 16 32 128 256 512; do
    sips -z $s $s icon-1024.png --out "$SET/icon_${s}x${s}.png" >/dev/null
    sips -z $((s*2)) $((s*2)) icon-1024.png --out "$SET/icon_${s}x${s}@2x.png" >/dev/null
  done
  iconutil -c icns "$SET" -o AppIcon.icns
fi

echo "Building..."
swift build -c release --scratch-path "$SCRATCH"
BIN="$(swift build -c release --scratch-path "$SCRATCH" --show-bin-path)/VideoView"

mkdir -p "$HOME/Applications"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/VideoView"
cp Info.plist "$APP/Contents/Info.plist"
[ -f AppIcon.icns ] && cp AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
codesign --force --deep --sign - "$APP"

echo ""
echo "Installed: $APP"
if [ "${1:-}" = "--open" ]; then open "$APP"; fi
