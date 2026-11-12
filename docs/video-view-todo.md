# Video View: to do

## New (added Nov 10, 2026)

1. **Color flags (red, green, blue)**
   - Replace the single flag with three colors so Noah can sort for different purposes.
   - Keys and context menu per color, flag filter by color, colored marker on the card and in the player.
   - Existing flags should migrate to one color (pick a default). Flags live in the index DB, keyed by content id, so they follow moved and renamed clips.

2. **Space Saver (shrink / re-encode)**
   - A "Space Saver" button for big videos that no longer need to be that size.
   - Re-encode so it still looks great but takes far less space (likely HEVC, quality-targeted, not a fixed tiny bitrate).
   - Safety rules same as trim: original never touched, new file written next to it, verified (duration, tracks, first/last frame decode, plus a frame comparison score like PSNR/SSIM and a side-by-side) before the original can be moved to Trash as a separate, explicit step.
   - Presets instead of a slider: "Looks identical", "Great", "Small". Same resolution and fps by default, plus an optional "Shrink to 1080p" for 4K that is only watched small.
   - Preview first: encode a ~10 second sample, show the projected size, then run the full file.
   - Say so when there is little to gain (iPhone clips are already HEVC) instead of making a bigger file.
   - Keep metadata (dates, camera info). Tag the new file with the original's name.
   - Batch: Space Saver on a multi-selection, with a running total of GB saved.
   - Start with the Sony and Mavic clips, likely the biggest wins (high bitrate H.264 or all-intra).
   - Related: Noah's existing HEVC shrink workflow (Compressor) could inform the quality settings.

3. **Show bitrate and "potential savings" on each card (build this first)**
   - Makes it easy to spot the big files worth shrinking before Space Saver exists.

4. **App design pass**
   - Make the look a little more interesting.
   - Plan: mock up 3 or 4 directions on paper first, review together, then implement the chosen one.
   - Directions: dark cinematic "screening room"; light, quiet, editorial photo-book feel; dense tool-like layout with a bigger filmstrip; one more playful option.
   - Grid stays image-first. Changes are mostly typography, sidebar, and how selection and flags look.
   - Add an optional inspector panel on the right (camera, codec, bitrate, dates) that shows only when wanted.

5. **Duplicates check**
   - The same clip probably exists in several folders. Content id already makes this possible to detect.

6. **Grid keyboard navigation**
   - Arrow keys to move between clips, Space to quick-look a clip from the grid.

7. **Date shot on each card (added Nov 11, 2026)**
   - Show the date shot in the info line under the thumbnail, next to resolution, fps and size.
   - Use the camera's creation date from the file metadata and fall back to the file creation date when it is missing, so older exports like the "Untitled" clips still show something sensible.
   - Keep it consistent with the date sort and the inspector panel idea.

## Already offered, not built yet

- Stills in the grid (JPG, TIFF, RAW)
- NAS testing (WytheNAS): first pass went well, grid is fast
- Relocate button for moved folders
- Test A7R V, Osmo Pocket and Mavic clips
- Sony camera XML Duration/timecode is stale after a trim (copied verbatim)
- Separate explicit "replace original" flow

## Shipped so far

Browse grid with cached posters and hover scrub, player with J/K/L, lossless trim with verification, delete to Trash after verified trim, flags, camera filter and sort, Finder-style folder browsing, folder tree in the sidebar, move/new folder/rename, justified grid for vertical clips, click-to-play and close button in the player, Control Room card.
