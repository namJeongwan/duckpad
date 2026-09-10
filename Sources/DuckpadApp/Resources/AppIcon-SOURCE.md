# Duckpad App Icon Source

- Attribution: user-provided Duckpad artwork, updated 2026-09-10.
- Original read-only input: `/Users/namjeongwan/Downloads/duckpad-duck.png`.
- Repository copy: `docs/assets/duckpad.png` (also used unchanged by README).
- Original SHA-256: `8db9959fc864df94232ab3453901523fb8e0d13ba0261b1a03f781d47e4721c1`.
- Original dimensions: 1254 × 1254 pixels, PNG with alpha.
- Artwork bounds measured from visible non-white pixels: x=108…1117, y=72…1182. Original left/top/right/bottom margins: 108/72/136/71 pixels.
- Crop: remove 54 pixels from the left, 68 from the right and 36 from the top; retain the bottom edge. This halves those three source margins, giving a 1132 × 1218 crop at (54, 36).
- Restore the transparent exterior to opaque white inside a macOS rounded-square tile. Keep pixels outside the tile transparent.
- At 1024 pixels, the tile is (80, 80, 864, 864) with a 184-pixel corner radius. Initially fit the cropped artwork uniformly into the tile; this gives visible left/right artwork margins of 68.81/78.74 pixels.
- Follow-up: reduce both visible horizontal margins by another 30%, to 48.17/55.12 pixels, while retaining vertical placement. This requires a 1.061782 horizontal-only scale relative to the initial fit. Final draw rectangle: (87.4935, 80, 852.6059, 864). The outer tile footprint and top/bottom margins stay unchanged.
- Render with Core Graphics high-quality interpolation; generate standard 16…1024-pixel iconset representations with `sips`, then assemble `Duckpad.icns` with `iconutil -c icns`.
- No generative redraw, recoloring of foreground artwork, or modification of the Downloads original.
