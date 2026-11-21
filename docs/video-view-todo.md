# Video View: to do

## Up next

- Similar clips (written Nov 12, not built yet): first build, then test on real clips. Try a Space Saver output next to its original, a lossless trim next to its source, and two different takes of the same fog scene (should not match). Tune `maxBits` and `needFraction` in `Similarity.swift` if it flags too much or too little.
- Stills in the grid (JPG, TIFF, RAW)
- Relocate button for moved folders

## Smaller items

- Test A7R V, Osmo Pocket and Mavic clips
- Sony camera XML Duration/timecode is stale after a trim (copied verbatim)
- Separate explicit "replace original" flow

## Notes on Similar clips

- Fingerprints are a 64-bit dHash per cached frame, stored in the `fingerprints` table by content id. Backfilled in the background from the existing cache, so nothing re-indexes.
- Compares across the whole index, but only folders you have opened have been indexed.
- Logic check on synthetic footage: re-encodes and trims matched, unrelated clips did not. Re-encodes whose keyframe snapping differs by about 2 seconds matched only about 80 percent of the time.
- Static or low contrast scenes (fog) can look alike, and mostly flat frames are skipped. It is a hint only. Nothing acts on it automatically.

## Shipped

Browse grid with cached posters and hover scrub, player with J/K/L, lossless trim with verification, delete to Trash after verified trim, color flags (orange/red/green/blue) with filter, camera filter and sort, Finder-style folder browsing, folder tree in sidebar, move/new folder/rename, justified grid for vertical clips, Control Room card, Minimal/Info view toggle, army green accent color, bitrate pill and HEVC savings estimate on each card, Space Saver (HEVC re-encode with presets, sample preview, verification), app design pass, date shot on cards, Reveal in Finder on sidebar and folder cards, grid keyboard navigation (arrow keys + Space), duplicates check (badge + filter toggle).
