# Capture and texture validation

Automated tests use synthetic geometry and recorded phone frames. Verify appearance and capture speed on the target iPhone (reported device: iPhone 16 Pro Max).

1. Capture a fresh scan with a colored poster or checkerboard on a wall and an object in front. Move slowly enough to keep tracking normal. Build using Balanced and HD.
2. In the app, check the poster's top/bottom and left/right corners, the foreground silhouette, and walls at the selected capture range. Unseen surfaces should remain neutral rather than borrow another surface's photo.
3. Switch Original → Built → Original and check the app, AR preview, USDZ, OBJ and GLB exports against the selected version. Crop a copy and confirm it does not inherit the Built atlas.
4. Cancel Finish during saving, resume, then save again. Confirm the complete Frames manifest and photo/depth pairs remain available. Rebuild twice, including a run without usable photos, and confirm stale texture assets are not reused.
5. While rebuilding, attempt Add Color, version switching and deletion. Old workers must not overwrite the current model or restore a deleted scan.

For old scans, rebuilding can recover depth-only frame selection mistakes and repeated manifest indices when the last stored pose matches the last stored image. Photos overwritten or never saved cannot be recreated. A fresh capture is the reliable comparison for the new recorder.

The voxel resolution is limited by measured depth and the sparse volume budget. Large rooms use a coarser grid than small objects to avoid filling the volume on the first surfaces; extra atlas resolution does not create new geometric detail.
