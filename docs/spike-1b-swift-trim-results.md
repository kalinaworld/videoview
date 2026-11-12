# Spike 1b: Swift container trim (Nov 10, 2026)

Follow-up to spike-1-inventory-results.md. The Python reference trimmer (spike/py/mp4trim.py) is now ported to Swift as spike/Sources/spike/ContainerTrim.swift. Run with `zsh spike/run.sh ctrim clip-spike/X --cut-start S --cut-end E` (or `--from/--to`, `--out`, `--dry`). Output goes to spike-output/trims-swift with a .verify.txt report.

## Results (on Noah's Mac, copies only, originals untouched)
- C0004 (Sony): 26.033 s, 191.6 MB of 238.9 MB, trim and verify 0.68 s.
- IMG_2176 (iPhone, 8 tracks): 6.707 s, 20.4 MB of 33.3 MB, 0.05 s.
- Stairs (HEVC 4K): 29.405 s, 78.0 MB of 103.8 MB, 0.18 s.
- All container checks passed: sample tables and sample bytes identical per track, vendor/metadata boxes byte-identical (Sony meta/xml, PROF, USMT, timed metadata track kept), top-level order kept, container creation time kept.
- Apple-side check passed (AVFoundation opens, duration matches, track counts kept, first and last frames decode). Matches the Python output exactly.
- Noah checked the trims in Final Cut (he does not use Resolve): looked good, so the edit-list pre-roll hiding works there.

## Decisions
- Trim path is our own container-level trim, not AVAssetExportSession. AVFoundation export stays out because it drops Sony vendor boxes and tracks.
- The app must verify every trim (container checks plus Apple-side open and decode) and block replace/delete of the original unless all pass.
- Unsupported files (fragmented, multiple mdat, rate != 1 edit lists) are refused rather than guessed at.

## Open
- Sony NonRealTimeMeta XML (Duration, timecode) is copied verbatim, so it is stale after a trim. Decide: patch or leave.
- Test A7RV, Osmo Pocket, Mavic (split ~4 GB files), 10-bit/S-Log/HDR, RAW and stills.
- Cold Dropbox and NAS timings.
- Next build step: grid + cache + index (SQLite WAL, packed thumbnails), then hover scrub and filmstrip.
