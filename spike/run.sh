#!/bin/zsh
# Builds outside Dropbox so build files do not sync, then runs the spike.
# Usage: zsh spike/run.sh clip-spike [--only TEXT] [--frames N] [--gop-seconds S] [--no-frames]
set -e
HERE="$(cd "$(dirname "$0")" && pwd)"
BUILD="$HOME/Library/Caches/VideoViewSpike"
(cd "$HERE" && swift build -c release --scratch-path "$BUILD")
BIN="$(cd "$HERE" && swift build -c release --scratch-path "$BUILD" --show-bin-path)/spike"
"$BIN" "$@"
