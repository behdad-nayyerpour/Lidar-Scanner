# Surface texture pipeline (1.1.0)

There is one photograph texturing path: `SurfaceTextureBaker`. Both Add Color and Quality Build call it. The previous photo-crop atlas, region voting, flat triangle painting and vertex-photo colorization jobs have been removed.

1. xatlas unwraps the actual geometry into non-overlapping surface charts. UVs do not depend on the selected photographs. Atlas failure or cancellation produces no replacement texture; there is no per-triangle grid fallback.
2. A texel inside a surface triangle recovers its three-dimensional position using UV barycentrics. That point is projected into calibrated camera photos. This preserves perspective inside large or tilted triangles, rather than interpolating photo coordinates across them.
3. An observation requires an in-frame projection, the requested LiDAR confidence and agreement with recorded depth. The mesh visibility pass uses perspective-correct clip W and depth interpolation. Conflicting colors are rejected rather than averaged into ghosted edges.
4. Only observed texels receive photo colors. Unseen geometry remains opaque neutral gray; dilation is restricted to UV gutters. Padding never invents observations on an unseen face. Photo materials do not use mipmaps that can mix unrelated charts.
5. The baked PLY embeds its own UVs. The PLY and lossless PNG are saved as a single version-2 binary property-list asset with per-component SHA-256 validation. Viewer, AR and each export operation use one `ScanSurface` snapshot. Legacy split UV/JPEG files are not combined with the new vertex order.

Stored/OBJ UV V is bottom-up; image rows are top-down. SceneKit conversion is performed only by `Packed.sceneKitTexcoordData`; glTF conversion is performed only by its exporter. The layout convention is covered by actual GPU render tests, not inferred from CPU image sampling.

## Upgrading existing scans

Captured photos and depth remain intact. Existing scans need one Add Color / Fast Build to generate `surface.v2.plist`; a fresh capture is not required. Texture-only builds use the currently selected geometry. Balanced/HD can separately reconstruct geometry from the original capture. Old split texture files are removed only when the new build commits successfully. Original geometry and rollback behavior are preserved.

## Verification

- Two large oblique triangles with a camera-space gradient test detail inside triangles and perspective accuracy.
- A foreground depth stripe tests that hidden texels stay neutral, including after gutter padding.
- Corrupted assets are rejected; PLY UVs, topology and lossless pixels survive round trip.
- A camera-to-bake-to-save-to-app-viewer GPU test compares rendered pixels to the original photo pattern.
- Existing phone-frame, multi-wall, export, SceneKit and USDZ regressions remain enabled.

Private local replay of one supplied phone frame used the shipping C++ UV unwrapper plus a Python reference rasterizer: 3,722 triangles, 99.86% observed UV coverage, mean absolute RGB error 2.05/255 on observed reprojections. This validates that replay, not the final appearance of a whole room on a physical iPhone. Personal photos and scan archives are not committed.
