# Lidar Scanner

Lidar Scanner is an iOS app for capturing rooms and objects as colored 3D meshes. It is aimed at architects, engineers, real-estate work, 3D artists, game developers, 3D-printing hobbyists, and anyone who wants a simple scan with a few pro controls underneath.

Scans stay on the device. You export a file only when you choose to share it.

The app requires **iOS 17** and a **LiDAR** sensor for scanning (iPhone Pro models and LiDAR iPad Pro). It still installs on other iPhones and explains that LiDAR is missing. A free Apple ID can re-sign the unsigned build; the project does not use iCloud, push notifications, App Groups, or other entitlements.

Bundle identifier: `com.example.lidarscanner` (change it in `project.yml` before you settle on a final id).

## What you can do

- Scan a room with ARKit scene reconstruction and a live, classification-colored mesh.
- Guidance while you scan: pace, light, tracking, and how much surface area has been meshed. Start, pause, resume, restart, and finish.
- Color the mesh from camera frames. The app keeps viewpoints as you move and samples the best ones onto each vertex.
- Scan an object two ways:
  - **LiDAR object** — a bounds sphere you place in the room (furniture, fixtures).
  - **Photo object** — RealityKit guided capture, then on-device photogrammetry. iOS only builds the mobile (reduced) detail level; finer levels need a Mac.
- Crop (triangles are clipped, not only deleted), smooth, simplify by merging nearby vertices, and drop small disconnected fragments. Revert to the original mesh.
- Measure distance by tapping two points. Units: meters, centimeters, feet, or inches.
- Export **PLY** (vertex color), **OBJ** (zip with MTL and a baked texture when it fits), **STL** (millimeters or meters, optional Z-up), **USDZ**, and **GLB**.
- A scan library with thumbnails, rename, delete, a SceneKit viewer, and AR Quick Look.
- Onboarding, light and dark mode, and English strings in `Localizable.strings` so another language (Persian is a likely next one) can be added as `fa.lproj` without rewriting the UI. Layout uses leading and trailing edges.

Files also show up in the Files app under On My iPhone → Lidar Scanner, because document sharing is enabled. That is an Info.plist flag, not a restricted entitlement.

## Architecture

```
LidarScanner/
  App/                  SwiftUI entry and root navigation
  Design/               Colors, buttons, scan HUD controls
  Localization/         L10n keys; English table is Resources/en.lproj
  Scanning/             ARKit room/object LiDAR session and Object Capture
  Mesh/                 Weld, clip, smooth, cluster decimation, PLY, texture bake
  Export/               OBJ, STL, USDZ, GLB, and USDZ mesh extraction
  Persistence/          Documents/Scans/<uuid>/
  Viewer/               SceneKit preview, measure, process, export, Quick Look
  Onboarding/           First-launch pages
```

A room or LiDAR-object scan copies `ARMeshAnchor` geometry into a `ScanMesh` (positions, normals, vertex colors, triangle indices, per-face classification). Camera keyframes are downscaled frames plus the view matrix and intrinsics. At finish, each vertex keeps a weighted blend of the best-facing samples. Vertices closer than a few millimeters are welded, then the mesh is saved as binary little-endian PLY. A texture atlas (one cell per triangle) is baked from those vertex colors for OBJ, GLB, and USDZ, because many DCC tools and Quick Look show a texture more reliably than raw vertex color.

Photo object capture writes Apple's images into the scan folder first, so a failed or interrupted reconstruction can be rebuilt from the library. The photogrammetry USDZ is kept as `capture.usdz`. The in-app tools use an extracted mesh when extraction succeeds.

```
Documents/Scans/<uuid>/
  scan.json
  mesh.ply
  mesh.original.ply
  thumbnail.png
  preview.usdz
  capture.usdz          photo mode only
  Images/               photo mode only
  measurements.json
```

Coordinates are meters, Y-up, except STL when you choose millimeters and/or Z-up.

## CI build

GitHub Actions (`.github/workflows/build-unsigned-ipa.yml`) runs on:

- push to `main`
- pull requests
- manual `workflow_dispatch`

The job uses `macos-latest`, selects the newest Xcode installed on that image, installs [XcodeGen](https://github.com/yonaskolb/XcodeGen), and runs `scripts/build-unsigned-ipa.sh`:

1. `xcodegen generate` from `project.yml` (the `.xcodeproj` is not committed).
2. `xcodebuild` for generic iOS, Release, with `CODE_SIGNING_ALLOWED=NO` and an empty signing identity. There is no entitlements file.
3. Zip `Payload/LidarScanner.app` into an unsigned IPA.

Artifact name: **`LidarScanner-unsigned-ipa`**  
File inside it: **`dist/LidarScanner-unsigned.ipa`**

### Where to download it

1. Open the repository on GitHub and choose **Actions**.
2. Open the **Build unsigned IPA** workflow.
3. Open a successful run (a push to `main`, or **Run workflow**).
4. Download the artifact **LidarScanner-unsigned-ipa**.
5. Unzip that download once. Inside is `LidarScanner-unsigned.ipa`. Do not unzip the IPA itself.

Pull requests also upload the artifact on the PR’s workflow run, which is useful before merging.

You can repeat the same script on a Mac after `brew install xcodegen`.

## Install with AltStore

The IPA is unsigned on purpose. AltStore (or SideStore) re-signs it with your Apple ID. A free Apple ID works because the app does not request paid-only capabilities.

You do not need a Mac if AltServer is running on Windows, or if you already use SideStore on the phone.

1. Install [AltServer](https://altstore.io) on Windows (or a Mac, if you have one) and install AltStore on the iPhone. SideStore is the on-device alternative after its one-time setup.
2. Download `LidarScanner-unsigned.ipa` on the iPhone, or send it to the phone.
3. Share the IPA to AltStore (Share → AltStore, or open it from the AltStore “My Apps” + button).
4. Sign in with your Apple ID when asked. AltStore registers the bundle id `com.example.lidarscanner` to that Apple ID.
5. Trust the developer certificate if iOS asks: Settings → General → VPN & Device Management.
6. Open Lidar Scanner and allow the camera.

Free Apple IDs expire the signature after about 7 days and allow a limited number of app ids (usually 10). Refresh the app in AltStore before it expires. If you change the bundle id later, it counts as a new app id.

To use a different bundle id, edit `PRODUCT_BUNDLE_IDENTIFIER` in `project.yml` and run the workflow again before the first install you want to keep.

## Localization

User-facing copy goes through `L10n` and `LidarScanner/Resources/en.lproj/Localizable.strings`. To add Persian later:

1. Add `LidarScanner/Resources/fa.lproj/Localizable.strings` with the same keys.
2. Add `fa` under `knownRegions` in `project.yml`.
3. Keep SwiftUI alignment on `leading` / `trailing` so right-to-left layout still works.

## Not in this version

- Accounts, cloud sync, or a collaboration link.
- A floor plan, CAD, or BIM export. Classification is stored and can be shown in the viewer; it is not exported as a separate semantic file.
- A photo-quality UV unwrap of the original camera images for room scans. Color is sampled onto vertices, then baked into a texture atlas for formats that expect a texture.
- Area or volume measurement (distance only).
- Gaussian splats or NeRF.
- Persian strings (the key table is ready).
- On-device photogrammetry is limited to Apple's mobile detail level. Preview, medium, full, and raw requests are not available in the iOS SDK.

Object Capture is included, not replaced by LiDAR. LiDAR object mode is still there because it works for things you cannot walk all the way around, and because photo reconstruction can fail or take several minutes. Photo mode only appears when `ObjectCaptureSession` and `PhotogrammetrySession` both report support.

## What to test first on a device

CI only compiles the app. LiDAR, the camera, and photogrammetry have to be checked on hardware.

1. Install with AltStore on a LiDAR iPhone and allow the camera.
2. Room scan: confirm the live mesh, the pace warning, pause, and finish. In the viewer, confirm the model is in color, not gray.
3. Walk slowly and overlap surfaces. Glass, mirrors, and very dark materials will have holes.
4. LiDAR object mode: set the center, change the radius, and confirm the saved mesh is limited to that volume.
5. Photo object mode, if the device offers it: complete a lap, build at Balanced, and wait with the app open. Then open the result and try AR Quick Look.
6. Measure two points and compare with a tape measure.
7. Crop, smooth, simplify, remove fragments, then revert.
8. Export each format and open it on a computer (Blender, MeshLab, a slicer, or Quick Look).
9. Rename, delete, and confirm the scan folder in Files.
10. If you have a non-LiDAR iPhone, confirm it installs and shows the “no LiDAR” explanation instead of crashing.
11. Check the library in both light and dark mode.

Finish a room scan before leaving the app. The mesh is not written until you tap Finish. Photo captures are stored as soon as the session starts, so they can be rebuilt from the library.
