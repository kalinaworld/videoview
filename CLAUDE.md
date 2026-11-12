# Video View

A native macOS app (SwiftUI, SwiftPM, macOS 15+) for browsing, trimming and tidying Noah's video clips. Image-first grid, fast on Dropbox and the NAS (WytheNAS). Owner: Noah Kalina, a photographer who edits in Final Cut Pro (not DaVinci Resolve).

## Layout
- `app/` the app. Sources in `app/Sources/VideoView/` (Database, Indexer, ThumbStore, ContainerTrim, PlayerSheet, Cards, ContentView, etc.).
- `spike/` command-line spike tool, used for trim and container testing. `spike/py/mp4trim.py` is the Python reference trimmer.
- `clip-spike/` sample clips (copies). `spike-output/` spike results.
- `docs/` project notes. Read the relevant one before starting a feature.

## Build and run
- App: `zsh app/build.sh` (add `--open` to launch). Builds to `~/Library/Caches/VideoView-build` and installs to `~/Applications/Video View.app`.
- Spike: `zsh spike/run.sh clip-spike` (inventory), `zsh spike/run.sh ctrim clip-spike/X --cut-start S --cut-end E` (Swift container trim), `zsh spike/run.sh atoms original trimmed` (container compare).
- Build folders live outside Dropbox on purpose, so Dropbox does not sync build files. Keep it that way. Do not put build output in this folder.
- This folder is in Dropbox. Never leave stray large or temporary files in it.

## Non-negotiables
- Never modify, overwrite or delete a user clip as a side effect. Test on copies in `clip-spike/`.
- Trimming uses our own container-level trim (`ContainerTrim.swift`), never AVAssetExportSession. AVFoundation export drops Sony vendor boxes (meta/xml, PROF, USMT) and the timed metadata track.
- Every trim and every future re-encode must be verified (container checks plus Apple-side open, duration, track count, first and last frame decode). If any check fails, the original cannot be replaced or trashed.
- Replacing or trashing an original is a separate, explicit user step, and goes to Trash, never a hard delete.
- Files the trimmer does not support (fragmented, multiple mdat, edit list rate != 1) are refused, not guessed at.
- Flags and other user data live in the index DB keyed by content id, so they follow moved and renamed clips.

## Status
Shipped: browse grid with cached posters and hover scrub, player (J/K/L), lossless trim with verification, delete to Trash after verified trim, color flags (orange/red/green/blue) with filter, camera filter and sort, Finder-style folder browsing and sidebar tree, move/new folder/rename, justified grid for vertical clips, Control Room card, Minimal/Info view toggle, army green accent, bitrate pill and HEVC savings on cards, Space Saver (HEVC re-encode with presets, sample preview, verification), app design pass, date shot on cards, Reveal in Finder on sidebar and folder cards, grid keyboard navigation (arrow keys + Space), duplicates check (badge on cards + toolbar filter toggle).

Next: see docs/video-view-todo.md

Full list, including smaller items, is in `docs/video-view-todo.md`. Update it when something ships or a new idea comes up.

## Notes
- `docs/spike-1-inventory-results.md`: test set, frame extraction timings, camera metadata findings, why the container-level trim was chosen.
- `docs/spike-1b-swift-trim-results.md`: Swift port results, decisions, open questions.
- Writing style for anything Noah reads: smart but casual, no em dashes.
