# Video View

A native macOS app for browsing, trimming, and tidying video clips. Built for photographers and videographers who work with large local libraries on Dropbox or a NAS.

![macOS 15+](https://img.shields.io/badge/macOS-15%2B-blue) ![SwiftUI](https://img.shields.io/badge/SwiftUI-5-orange) ![License: MIT](https://img.shields.io/badge/license-MIT-green)

## Features

- **Image-first grid**: fast poster thumbnails with hover scrub, plus a justified layout for vertical clips
- **Player**: J/K/L shuttle, frame step, in/out marks
- **Lossless trim**: container-level trim (no re-encode, no quality loss, Sony vendor boxes preserved), verified before anything is replaced
- **Space Saver**: HEVC re-encode with quality presets, a 10-second preview, and full verification before anything is replaced
- **Duplicates and look-alikes**: exact copies are badged on the card, and "looks similar" flags re-encodes and trimmed copies for you to check. It is only ever a hint, nothing acts on it automatically
- **Color flags**: orange, red, green, blue, with a filter
- **Folder browser**: Finder-style sidebar tree, move, rename, new folder, drag and drop, delete to Trash
- **Filters and sort**: by camera, media kind, date, name, size, duration, or bitrate
- **Bitrate and HEVC savings estimate** on each card
- **Keyboard navigation**: arrow keys and Space in the grid
- Also handles stills and audio files, not just video

## Requirements

- macOS 15 (Sequoia) or later
- Xcode 16+ (or the Command Line Tools with a recent Swift toolchain) to build from source

## Build and run

```bash
git clone https://github.com/kalinaworld/videoview.git
cd videoview
zsh app/build.sh --open
```

The script builds to `~/Library/Caches/VideoView-build` and installs to `~/Applications/Video View.app`. The app is signed ad hoc, so it runs fine on the Mac that built it. There are no prebuilt downloads yet.

## Be careful with your footage

This is a personal project that works on real video files. A few guardrails are built in, but try it on copies first.

- Trimming never uses AVAssetExportSession (it drops vendor metadata). It uses our own container-level trim in `ContainerTrim.swift`.
- Every trim and every Space Saver re-encode is verified (container checks, then duration, track count, and first and last frame decode). If a check fails, the original cannot be replaced or trashed.
- Replacing or trashing an original is a separate, explicit step, and it goes to the Trash, never a hard delete.
- Files the trimmer does not support (fragmented, multiple mdat, edit list rate other than 1) are refused, not guessed at.
- Clip flags and metadata live in a local SQLite index keyed by content ID, so they follow clips that are moved or renamed.

## Project layout

```
app/          SwiftUI app (Sources/VideoView/)
spike/        Command-line trim and container test tool, plus a Python reference trimmer
docs/         Project notes and the to-do list
```

Sample clips used for testing are not included in the repo.

## Feedback

Issues and pull requests are welcome. See `docs/video-view-todo.md` for what is planned.

## License

MIT. See [LICENSE](LICENSE).
