# Video View

A native macOS app for browsing, trimming, and managing video clips. Built for photographers and videographers who work with large local libraries on Dropbox or a NAS.

![macOS 15+](https://img.shields.io/badge/macOS-15%2B-blue) ![SwiftUI](https://img.shields.io/badge/SwiftUI-5-orange)

## Features

- **Image-first grid** — fast poster thumbnails with hover scrub
- **Player** — J/K/L shuttle, frame step, in/out marks
- **Lossless trim** — container-level trim (no re-encode, no quality loss, Sony vendor boxes preserved)
- **Space Saver** — HEVC re-encode with quality presets, 10-second preview, and full verification before anything is replaced
- **Color flags** — orange, red, green, blue; filter by color
- **Folder browser** — Finder-style sidebar tree, move/rename/new folder
- **Camera filter and sort** — by date, name, size, duration, bitrate
- **Bitrate and savings estimate** on each card

## Requirements

- macOS 15 (Sequoia) or later
- Xcode 16+ (to build from source)

## Build

```bash
zsh app/build.sh --open
```

Builds to `~/Library/Caches/VideoView-build` and installs to `~/Applications/Video View.app`.

## Notes

- Trimming uses container-level editing (`ContainerTrim.swift`), never `AVAssetExportSession`, so Sony vendor boxes and timed metadata tracks are preserved.
- Clip flags and metadata are stored in a local SQLite index keyed by content ID, so they follow clips that are moved or renamed.
- The original clip is never modified. Trim and Space Saver outputs are written as new files; replacing the original is a separate, explicit step that goes to Trash.

## Project layout

```
app/          SwiftUI app (Sources/VideoView/)
spike/        Command-line trim and container test tool
clip-spike/   Sample clips for testing
docs/         Project notes
```
