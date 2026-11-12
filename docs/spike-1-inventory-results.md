# Spike 1: inventory, frame extraction, lossless trim (Nov 10, 2026)

Machine: MacBook Pro M1 Pro, 32 GB, macOS 26.6.2, Swift 6.3.3, Xcode installed. Tool: spike/ in the Video View folder (SwiftPM, run with `zsh spike/run.sh clip-spike`; trim with `zsh spike/run.sh trim clip-spike/X.MOV --cut-start 2 --cut-end 2`; container check with `zsh spike/run.sh atoms original trimmed`). Never modifies a clip. Clips were local (Dropbox), run sequentially on one thread, NAS not tested. exiftool is not installed on this Mac.

## Set tested
23 clips, 6.0 GB total. Sony C0003/C0004 (container XML says Sony FDR-AX33, a camcorder, not the A7RV), iPhone 17 Pro Max (IMG_2176, 2177, 2178, 2182), a Canon-style MVI_6873, and about a dozen edited exports/screen recordings. No A7RV, Osmo Pocket, Mavic, 10-bit, S-Log, or HDR clips yet. No stills yet.

## Frame extraction
- Every clip opened and gave 30/30 frames in both fast (keyframe-snapped) and exact modes. No failures.
- 30 small frames cost 0.3 to 1.7 s (fast) and 0.3 to 2.5 s (exact), nearly independent of clip length. 4K Sony and iPhone clips are slowest at about 1.5 to 1.7 s fast, 1.8 to 2.5 s exact.
- Fast mode lands up to about 0.5 s from the requested time (1.4 s worst case). Good for hover scrub and filmstrips. Use exact only for the grid poster.
- Keyframes about once per second almost everywhere. Exceptions: Blix v19 (about 2 s), the 20 fps mp4 (2 s), MVI_6873 (irregular). Keyframe scan takes tens of ms.

## Cameras and metadata
- iPhone 17 Pro Max: H.264 High, 4K30, about 25 Mbps, Rec.709 SDR. Make, model, creation date, GPS readable through AVFoundation. Container (mvhd) creation time on the copies is the copy time, not the capture time, so use the QuickTime creationdate item.
- Sony FDR-AX33 clips: AVC High, 4K 29.97, 55 to 59 Mbps, long-GOP, keyframe every 30 frames, normal color (not log). AVFoundation exposes zero metadata for these. The camera model, creation date, duration and timecode live in a top-level `meta`/`xml` box (Sony NonRealTimeMeta). Also a top-level `uuid` PROF box, `uuid` USMT boxes, and a third "Timed Metadata" track with one sample per frame.
- Exports are mostly HEVC 8-bit or H.264, tagged Rec.709, no camera metadata.

## Lossless trim with AVAssetExportSession passthrough (option A, rejected as sole path)
- Works and is near instant (0.06 to 0.23 s). Codec, dimensions and audio are unchanged, file shrinks in proportion, original untouched, first and last frames decode.
- Output duration equals the requested length exactly even when the in point is past a keyframe (edit list hides pre-roll).
- iPhone: every metadata box byte-identical after the trim. Only the container creation time was reset to the export time.
- **Sony: the passthrough export silently drops the `meta`/`xml` box (camera model, creation date), the PROF and USMT uuid boxes, the per-frame timed metadata track, and resets the container creation time.** The AVFoundation-level metadata check could not see this (0 items before and after), so it passed wrongly. The container-level `atoms` check caught it.

## Own container-level trim (option B, chosen)
Decision: write our own trim that copies every track and box and only rewrites sample tables, edit lists and durations. Reference implementation is spike/py/mp4trim.py (Python, stdlib only), to be ported to Swift.

Method: clip each track's edit list to the window; start at the last sync sample at or before the in point (audio backed up 2 samples for AAC priming); end at the last sample before the out point; rebuild stts/ctts/stss/stsc/stsz/stco(co64)/sdtp/sbgp; new elst per track so pre-roll frames are hidden; keep every other box byte-for-byte; write to a .partial file, verify by an independent re-parse, then rename. Never overwrites its output or the source.

Real-cut results (all on copies, originals untouched):
- IMG_2176 (iPhone, 8 tracks incl. timed metadata), cut 2 s each end: 6.71 s, 20.4 MB of 33.3 MB. Sample tables and sample bytes identical per track, all 52 moov metadata boxes byte-identical, container creation/modification time kept, top-level order kept. ffmpeg decodes 201 frames, no errors.
- C0004 (Sony), cut 4 s start, 3 s end: 26.03 s, 191.6 MB of 238.9 MB. All 3 tracks including the timed metadata track kept, sample bytes identical, meta/xml, PROF and USMT boxes byte-identical, creation time kept. ffmpeg decodes 781 frames, no errors. This fixes the Sony loss found with AVFoundation.
- Stairs (HEVC 4K, 2 tracks), cut 5 s each end: 29.405 s, 78.0 MB of 103.8 MB. Vendor and top-level boxes byte-identical, creation time kept. ffmpeg decodes 881 frames, no errors.
- Identity (no cut) test passed earlier on IMG_7439, IMG_2176, C0004, Stairs.

Known caveats:
- Pre-roll frames sit in the file hidden by the edit list (up to about 1 s at the start). Need to confirm QuickTime and DaVinci Resolve honor the edit list.
- Sony NonRealTimeMeta XML (Duration, timecode) is copied verbatim, so it is stale after a trim. Decide whether to patch it or leave it.
- The cloud sandbox cannot delete files in the connected folder, so re-runs need a fresh output folder (spike-output/trims-c holds the latest outputs; trims-b holds the first set).

## Open
- Confirm trimmed start in QuickTime and DaVinci Resolve (edit list honored?).
- Port mp4trim.py to Swift with the same verification; app must block replace/delete of the original unless verification passes.
- Run the `atoms` compare on the new trims on the Mac to double-check with the Swift tool.
- A7RV, Osmo Pocket, Mavic (including split files), 10-bit/S-Log/HDR iPhone, RAW and stills.
- Cold Dropbox and NAS timings.
