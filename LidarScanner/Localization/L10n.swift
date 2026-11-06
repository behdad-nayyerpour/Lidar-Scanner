import Foundation

/// English copy lives in `en.lproj/Localizable.strings`.
/// Add `fa.lproj/Localizable.strings` later for Persian; keys stay stable.
enum L10n {
    static func tr(_ key: String, _ fallback: String) -> String {
        Bundle.main.localizedString(forKey: key, value: fallback, table: "Localizable")
    }

    static var appName: String { tr("app.name", "Lidar Scanner") }

    static var onboardingSkip: String { tr("onboarding.skip", "Skip") }
    static var onboardingContinue: String { tr("onboarding.continue", "Continue") }
    static var onboardingStart: String { tr("onboarding.start", "Get started") }
    static var onboardingWelcomeTitle: String { tr("onboarding.welcome.title", "Scan rooms and objects") }
    static var onboardingWelcomeBody: String { tr("onboarding.welcome.body", "Build a colored 3D model with LiDAR, then measure it and export it for design, printing, or a game engine.") }
    static var onboardingRoomTitle: String { tr("onboarding.room.title", "Walk the space slowly") }
    static var onboardingRoomBody: String { tr("onboarding.room.body", "Keep the iPhone moving at a steady pace. Cover floors, walls, and the objects you care about from more than one angle.") }
    static var onboardingObjectTitle: String { tr("onboarding.object.title", "Capture a single object") }
    static var onboardingObjectBody: String { tr("onboarding.object.body", "Use the LiDAR bounds for furniture in place, or the guided photo mode to walk around a smaller object and reconstruct it.") }
    static var onboardingPrivacyTitle: String { tr("onboarding.privacy.title", "Stays on this iPhone") }
    static var onboardingPrivacyBody: String { tr("onboarding.privacy.body", "Scans are saved in this app. Nothing is uploaded. Share a file only when you choose to.") }

    static var libraryTitle: String { tr("library.title", "Scans") }
    static var libraryEmptyTitle: String { tr("library.empty.title", "No scans yet") }
    static var libraryEmptyBody: String { tr("library.empty.body", "Start with a room, or capture a single object. Your models will show up here.") }
    static var libraryNewScan: String { tr("library.newScan", "New scan") }
    static var librarySearch: String { tr("library.search", "Search scans") }
    static var libraryRename: String { tr("library.rename", "Rename") }
    static var libraryDelete: String { tr("library.delete", "Delete") }
    static var libraryRenamePrompt: String { tr("library.rename.prompt", "Name") }
    static var librarySave: String { tr("library.save", "Save") }
    static var libraryCancel: String { tr("common.cancel", "Cancel") }
    static var libraryDeleteTitle: String { tr("library.delete.title", "Delete this scan?") }
    static var libraryDeleteBody: String { tr("library.delete.body", "The model and its files will be removed from this iPhone.") }
    static var libraryDeleteConfirm: String { tr("library.delete.confirm", "Delete") }
    static var libraryNeedsReconstruction: String { tr("library.needsReconstruction", "Photos saved. Build the model to finish.") }
    static var libraryNoResults: String { tr("library.noResults", "No matching scans") }
    static var libraryChoose: String { tr("library.choose", "Choose a scan") }
    static var libraryLidarMissingTitle: String { tr("library.lidarMissing.title", "This iPhone has no LiDAR") }
    static var libraryLidarMissingBody: String { tr("library.lidarMissing.body", "Room and object scanning need a LiDAR sensor, such as an iPhone Pro or a compatible iPad Pro. You can still open this app and read how scanning works.") }

    static var modeRoomTitle: String { tr("mode.room.title", "Room") }
    static var modeRoomBody: String { tr("mode.room.body", "Mesh the space around you with live LiDAR and surface types.") }
    static var modeObjectLidarTitle: String { tr("mode.objectLidar.title", "Object, LiDAR") }
    static var modeObjectLidarBody: String { tr("mode.objectLidar.body", "Keep a piece of furniture or a fixture inside a bounds sphere.") }
    static var modeObjectPhotoTitle: String { tr("mode.objectPhoto.title", "Object, photos") }
    static var modeObjectPhotoBody: String { tr("mode.objectPhoto.body", "Guided capture, then an on-device photogrammetry model.") }
    static var modeObjectPhotoUnavailable: String { tr("mode.objectPhoto.unavailable", "Guided photo capture is not available on this device.") }
    static var modeRoomLabel: String { tr("mode.room.label", "Room") }
    static var modeObjectLidarLabel: String { tr("mode.objectLidar.label", "LiDAR object") }
    static var modeObjectPhotoLabel: String { tr("mode.objectPhoto.label", "Photo object") }

    static var scanCancel: String { tr("scan.cancel", "Cancel") }
    static var scanDiscardTitle: String { tr("scan.discard.title", "Discard this scan?") }
    static var scanDiscardBody: String { tr("scan.discard.body", "Photos and mesh data from this session will be deleted.") }
    static var scanDiscardConfirm: String { tr("scan.discard.confirm", "Discard") }
    static var scanKeep: String { tr("scan.keep", "Keep") }
    static var scanStart: String { tr("scan.start", "Start") }
    static var scanPause: String { tr("scan.pause", "Pause") }
    static var scanResume: String { tr("scan.resume", "Resume") }
    static var scanFinish: String { tr("scan.finish", "Finish") }
    static var scanRestart: String { tr("scan.restart", "Restart") }
    static var scanSetCenter: String { tr("scan.setCenter", "Set center") }
    static var scanRadius: String { tr("scan.radius", "Bounds radius") }
    static var scanNotEnoughTitle: String { tr("scan.notEnough.title", "Not enough geometry") }
    static var scanNotEnoughBody: String { tr("scan.notEnough.body", "Move closer to real surfaces and cover a bit more area, then finish again.") }
    static var scanCameraDeniedTitle: String { tr("scan.cameraDenied.title", "Camera access is off") }
    static var scanCameraDeniedBody: String { tr("scan.cameraDenied.body", "Allow camera access in Settings to scan. LiDAR capture uses the camera.") }
    static var scanOpenSettings: String { tr("scan.openSettings", "Open Settings") }
    static var scanProcessingMesh: String { tr("scan.processing.mesh", "Building the mesh") }
    static var scanProcessingColor: String { tr("scan.processing.color", "Adding color from the camera") }
    static var scanProcessingSave: String { tr("scan.processing.save", "Saving the scan") }
    static var scanSavingGeometry: String { tr("scan.processing.geometry", "Saving the mesh") }
    static var overlayBoth: String { tr("overlay.both", "Wireframe and fill") }
    static var overlayFill: String { tr("overlay.fill", "Fill only") }
    static var overlayOff: String { tr("overlay.off", "Hide mesh") }
    static var colorAdd: String { tr("color.add", "Add color") }
    static var colorWorking: String { tr("color.working", "Adding color") }
    static var colorCancel: String { tr("color.cancel", "Cancel color") }
    static var colorCancelled: String { tr("color.cancelled", "Coloring cancelled. The mesh is unchanged.") }
    static var colorFailed: String { tr("color.failed", "Color could not be added. The mesh is unchanged.") }
    static var colorPartial: String { tr("color.partial", "Coloring stopped early. The mesh includes the color finished so far.") }
    static var colorUnavailable: String { tr("color.unavailable", "No camera frames were saved for this scan.") }
    static var colorBusy: String { tr("color.busy", "Another scan is already being colored.") }
    static var colorReady: String { tr("color.ready", "Ready to add color") }
    static var scanGuidanceReady: String { tr("scan.guidance.ready", "Press Start, then move slowly through the space.") }
    static var scanGuidancePaused: String { tr("scan.guidance.paused", "Paused") }
    static var scanGuidanceSlow: String { tr("scan.guidance.slow", "Slow down so the mesh can keep up.") }
    static var scanGuidanceGood: String { tr("scan.guidance.good", "Good pace. Keep overlapping what you already scanned.") }
    static var scanGuidanceMove: String { tr("scan.guidance.move", "Keep moving slowly. Standing still does not add coverage.") }
    static var scanGuidanceLight: String { tr("scan.guidance.light", "More light will help both tracking and color.") }
    static var scanGuidanceCloser: String { tr("scan.guidance.closer", "Move closer to a wall, floor, or object.") }
    static var scanGuidanceObject: String { tr("scan.guidance.object", "Put the object inside the sphere, then walk around it.") }
    static func scanTracking(_ reason: String) -> String {
        String(format: tr("scan.tracking", "Tracking limited: %@"), reason)
    }
    static var trackInitializing: String { tr("track.initializing", "initializing") }
    static var trackMotion: String { tr("track.motion", "too much motion") }
    static var trackFeatures: String { tr("track.features", "not enough visual detail") }
    static var trackRelocalizing: String { tr("track.relocalizing", "relocalizing") }
    static var trackLimited: String { tr("track.limited", "limited") }
    static var trackUnavailable: String { tr("track.unavailable", "unavailable") }

    static var photoDetect: String { tr("photo.detect", "Find object") }
    static var photoDetectFailed: String { tr("photo.detect.failed", "Point at the object. A surface under it helps.") }
    static var photoStart: String { tr("photo.start", "Start capture") }
    static var photoResetBox: String { tr("photo.resetBox", "Reset box") }
    static var photoAnotherLap: String { tr("photo.anotherLap", "Another lap") }
    static var photoFlipped: String { tr("photo.flipped", "I flipped it") }
    static var photoFinish: String { tr("photo.finish", "Finish capture") }
    static var photoShutter: String { tr("photo.shutter", "Shutter") }
    static var photoOrbitDone: String { tr("photo.orbitDone", "First lap looks complete. Flip the object, take another lap, or build the model.") }
    static var photoBuild: String { tr("photo.build", "Build model") }
    static var photoBuilding: String { tr("photo.building", "Building the 3D model") }
    static var photoKeepOpen: String { tr("photo.keepOpen", "Keep the app open. A detailed object can take several minutes.") }
    static var photoDetailCaption: String { tr("photo.detail.caption", "On this iPhone, reconstruction uses the mobile detail level. Higher detail levels need a Mac.") }
    static var photoPreview: String { tr("photo.detail.preview", "Draft") }
    static var photoReduced: String { tr("photo.detail.reduced", "Fast") }
    static var photoMedium: String { tr("photo.detail.medium", "Balanced") }
    static var photoFull: String { tr("photo.detail.full", "High") }
    static var photoUnsupportedTitle: String { tr("photo.unsupported.title", "Photo object capture is unavailable") }
    static var photoUnsupportedBody: String { tr("photo.unsupported.body", "This device cannot run guided object capture. Use LiDAR object mode instead.") }
    static var photoCancelBuild: String { tr("photo.cancelBuild", "Stop building") }
    static var photoFailed: String { tr("photo.failed", "The model could not be built.") }
    static var photoLowShots: String { tr("photo.lowShots", "More photos from other angles usually produce a cleaner model.") }
    static var photoReady: String { tr("photo.ready", "Capture looks ready to build.") }
    static var photoInitializing: String { tr("photo.initializing", "Starting the camera") }
    static var photoReadyState: String { tr("photo.state.ready", "Center the object, then find its bounds.") }
    static var photoDetecting: String { tr("photo.state.detecting", "Adjust the box so it hugs the object.") }
    static var photoCapturing: String { tr("photo.state.capturing", "Walk slowly around the object. The app takes photos for you.") }
    static var photoFinishing: String { tr("photo.state.finishing", "Saving photos") }
    static var feedbackTooFar: String { tr("photo.feedback.tooFar", "Move closer.") }
    static var feedbackTooClose: String { tr("photo.feedback.tooClose", "Move back a little.") }
    static var feedbackTooDark: String { tr("photo.feedback.tooDark", "The scene is too dark.") }
    static var feedbackLowLight: String { tr("photo.feedback.lowLight", "More light would help.") }
    static var feedbackFast: String { tr("photo.feedback.fast", "Slow down.") }
    static var feedbackMissing: String { tr("photo.feedback.missing", "The object is not in view.") }
    static var feedbackOut: String { tr("photo.feedback.out", "Keep the object in frame.") }
    static var feedbackOver: String { tr("photo.feedback.over", "Photo limit reached. You can build the model now.") }
    static var feedbackFlip: String { tr("photo.feedback.flip", "This object does not look flippable.") }
    static func shots(_ count: Int, _ limit: Int) -> String {
        String(format: tr("photo.shots", "%d / %d photos"), count, limit)
    }

    static var reconTitle: String { tr("recon.title", "Build model") }
    static var reconBody: String { tr("recon.body", "Photos are saved on this iPhone. Building the mesh can take several minutes.") }
    static var reconMissing: String { tr("recon.missing", "No photos were found for this scan.") }
    static var reconStart: String { tr("recon.start", "Build model") }

    static var viewerMeasure: String { tr("viewer.measure", "Measure") }
    static var viewerMeasureHelp: String { tr("viewer.measure.help", "Tap two points on the model.") }
    static var viewerClear: String { tr("viewer.clear", "Clear") }
    static var viewerProcess: String { tr("viewer.process", "Process") }
    static var viewerQuickLook: String { tr("viewer.quickLook", "AR") }
    static var viewerExport: String { tr("viewer.export", "Export") }
    static var viewerView: String { tr("viewer.view", "View") }
    static var viewerLighting: String { tr("viewer.lighting", "Shading") }
    static var viewerClasses: String { tr("viewer.classes", "Surface types") }
    static var viewerWire: String { tr("viewer.wire", "Wireframe") }
    static var viewerReset: String { tr("viewer.reset", "Reset view") }
    static var viewerRevert: String { tr("viewer.revert", "Revert to original") }
    static var viewerRevertTitle: String { tr("viewer.revert.title", "Revert to the original scan?") }
    static var viewerRevertBody: String { tr("viewer.revert.body", "Cropping, smoothing, and simplification will be undone.") }
    static var viewerLoading: String { tr("viewer.loading", "Opening model") }
    static var viewerProcessUnavailable: String { tr("viewer.process.unavailable", "This model cannot be edited yet. Export the USDZ, or rebuild it from the saved photos.") }
    static var viewerNoQuickLook: String { tr("viewer.noQuickLook", "A Quick Look model is not available for this scan yet.") }
    static var viewerStats: String { tr("viewer.stats", "Details") }

    static var processTitle: String { tr("process.title", "Process") }
    static var processCrop: String { tr("process.crop", "Crop") }
    static var processCropHelp: String { tr("process.crop.help", "Trim each side of the bounding box. Partial triangles are clipped.") }
    static var processSmooth: String { tr("process.smooth", "Smooth") }
    static var processIterations: String { tr("process.iterations", "Strength") }
    static var processSimplify: String { tr("process.simplify", "Simplify") }
    static var processSimplifyHelp: String { tr("process.simplify.help", "Merges nearby vertices. Useful before a game engine or a smaller export.") }
    static var processFloaters: String { tr("process.floaters", "Remove fragments") }
    static var processFloatersHelp: String { tr("process.floaters.help", "Drops disconnected pieces that are small compared with the main surface.") }
    static var processSuggested: String { tr("process.suggested", "Suggested cleanup") }
    static var processApply: String { tr("process.apply", "Apply") }
    static var processWorking: String { tr("process.working", "Updating the mesh") }
    static var processEmpty: String { tr("process.empty", "That would delete the whole model. Relax the crop or fragment size.") }
    static func processKeep(_ percent: Int) -> String {
        String(format: tr("process.keep", "Keep about %d%%"), percent)
    }
    static var processResultSize: String { tr("process.resultSize", "Resulting size") }

    static var exportTitle: String { tr("export.title", "Export") }
    static var exportOBJ: String { tr("export.obj", "OBJ") }
    static var exportOBJDetail: String { tr("export.obj.detail", "Zip with MTL and a baked texture when the mesh fits an atlas.") }
    static var exportPLY: String { tr("export.ply", "PLY") }
    static var exportPLYDetail: String { tr("export.ply.detail", "Binary mesh with vertex color. Best for MeshLab and Blender.") }
    static var exportSTL: String { tr("export.stl", "STL") }
    static var exportSTLDetail: String { tr("export.stl.detail", "Geometry only. Choose millimeters for printing.") }
    static var exportUSDZ: String { tr("export.usdz", "USDZ") }
    static var exportUSDZDetail: String { tr("export.usdz.detail", "Quick Look and AR, with texture when one was baked.") }
    static var exportOriginalUSDZ: String { tr("export.originalUsdz", "Original photo USDZ") }
    static var exportOriginalDetail: String { tr("export.originalUsdz.detail", "The photogrammetry model, before in-app edits.") }
    static var exportGLB: String { tr("export.glb", "GLB") }
    static var exportGLBDetail: String { tr("export.glb.detail", "glTF binary for game engines and web viewers.") }
    static var exportAll: String { tr("export.all", "All formats") }
    static var exportAllDetail: String { tr("export.all.detail", "One zip with OBJ, PLY, STL, DXF, USDZ, and GLB.") }
    static var exportMillimeters: String { tr("export.mm", "Millimeters") }
    static var exportMeters: String { tr("export.m", "Meters") }
    static var exportZUp: String { tr("export.zUp", "Z-up for 3D printing") }
    static var exportWorking: String { tr("export.working", "Preparing the file") }
    static var exportFailed: String { tr("export.failed", "The file could not be created.") }
    static var exportSTLUnits: String { tr("export.stlUnits", "STL units") }
    static var exportCADUnits: String { tr("export.cadUnits", "Units for STL and DXF") }
    static var exportDXF: String { tr("export.dxf", "DXF") }
    static var exportDXFDetail: String { tr("export.dxf.detail", "Triangle faces for AutoCAD and other CAD apps. Uses the units and Z-up setting above.") }
    static var viewerAppearance: String { tr("viewer.appearance", "Appearance") }
    static var viewerBackground: String { tr("viewer.background", "Background") }
    static var viewerMeshColor: String { tr("viewer.meshColor", "Uncolored mesh") }
    static var viewerMeshColorHelp: String { tr("viewer.meshColor.help", "Used before color is added. Shading stays on so the shape stays readable.") }
    static var backdropDark: String { tr("viewer.backdrop.dark", "Dark") }
    static var backdropLight: String { tr("viewer.backdrop.light", "Light") }
    static var backdropCustom: String { tr("viewer.backdrop.custom", "Custom") }
    static var tintClay: String { tr("viewer.tint.clay", "Clay") }
    static var tintWhite: String { tr("viewer.tint.white", "White") }
    static var tintSlate: String { tr("viewer.tint.slate", "Slate") }
    static var arClose: String { tr("ar.close", "Close") }
    static var arHint: String { tr("ar.hint", "Move the phone to place the model in the room.") }
    static var arFailed: String { tr("ar.failed", "The model could not be opened in AR.") }

    static var settingsTitle: String { tr("settings.title", "Settings") }
    static var settingsUnits: String { tr("settings.units", "Units") }
    static var settingsIntro: String { tr("settings.intro", "Show introduction") }
    static var settingsLidar: String { tr("settings.lidar", "LiDAR mesh") }
    static var settingsPhoto: String { tr("settings.photo", "Photo object capture") }
    static var settingsAvailable: String { tr("settings.available", "Available") }
    static var settingsMissing: String { tr("settings.missing", "Not available") }
    static var settingsVersion: String { tr("settings.version", "Version") }
    static var settingsBundle: String { tr("settings.bundle", "Bundle ID") }
    static var settingsCapabilities: String { tr("settings.capabilities", "This device") }

    static var tipsTitle: String { tr("tips.title", "Scanning tips") }
    static var tips1: String { tr("tips.1", "Move slowly. Fast turns leave holes and blur the color.") }
    static var tips2: String { tr("tips.2", "Use ordinary room light. LiDAR struggles with glass, mirrors, and very dark surfaces.") }
    static var tips3: String { tr("tips.3", "Overlap your path. Seeing the same wall from a second angle fills gaps.") }
    static var tips4: String { tr("tips.4", "For a small object, clear the area around it and complete at least one full circle.") }
    static var tips5: String { tr("tips.5", "Finish the scan before leaving the app. A room mesh is not saved until you finish.") }
    static var tips6: String { tr("tips.6", "Exports are in meters, Y-up, except STL, which can be millimeters and Z-up.") }

    static var commonOK: String { tr("common.ok", "OK") }
    static var commonClose: String { tr("common.close", "Close") }
    static var commonError: String { tr("common.error", "Something went wrong") }
    static var commonDone: String { tr("common.done", "Done") }

    static var unitMeters: String { tr("unit.meters", "Meters") }
    static var unitCentimeters: String { tr("unit.centimeters", "Centimeters") }
    static var unitFeet: String { tr("unit.feet", "Feet") }
    static var unitInches: String { tr("unit.inches", "Inches") }

    static var classFloor: String { tr("class.floor", "Floor") }
    static var classWall: String { tr("class.wall", "Wall") }
    static var classCeiling: String { tr("class.ceiling", "Ceiling") }
    static var classTable: String { tr("class.table", "Table") }
    static var classSeat: String { tr("class.seat", "Seat") }
    static var classWindow: String { tr("class.window", "Window") }
    static var classDoor: String { tr("class.door", "Door") }
    static var classOther: String { tr("class.other", "Other") }

    static var defaultRoomName: String { tr("name.room", "Room") }
    static var defaultObjectName: String { tr("name.object", "Object") }
    static var defaultPhotoName: String { tr("name.photo", "Photo object") }

    static func triangles(_ count: Int) -> String {
        String(format: tr("stats.triangles", "%d triangles"), count)
    }

    static var statVertices: String { tr("stats.vertices", "Vertices") }
    static var statTriangles: String { tr("stats.triangles.label", "Triangles") }
    static var statArea: String { tr("stats.area", "Area") }
    static var statVolume: String { tr("stats.volume", "Volume") }
    static var statSize: String { tr("stats.size", "Size (W × L × H)") }

    static var scanGuidanceFast: String { tr("scan.guidance.fast", "Moving too fast. Slow down so the frames stay sharp.") }
    static var scanGuidanceCeiling: String { tr("scan.guidance.ceiling", "Tilt up and cover the ceiling.") }
    static var scanHighRes: String { tr("scan.highRes", "High-res capture") }
    static var scanRange: String { tr("scan.range", "Range") }
    static var scanConfidence: String { tr("scan.confidence", "Depth confidence") }
    static var confidenceLow: String { tr("scan.confidence.low", "Low") }
    static var confidenceMed: String { tr("scan.confidence.med", "Med") }
    static var confidenceHigh: String { tr("scan.confidence.high", "High") }

    static var qualityTitle: String { tr("quality.title", "Build the model") }
    static var qualityBody: String { tr("quality.body", "The gray mesh is already saved. A finer build fuses the LiDAR frames and textures each face from the photos.") }
    static var qualityFast: String { tr("quality.fast", "Fast") }
    static var qualityBalanced: String { tr("quality.balanced", "Balanced") }
    static var qualityHD: String { tr("quality.hd", "HD") }
    static var qualityCustom: String { tr("quality.custom", "Custom") }
    static var qualityFastDetail: String { tr("quality.fast.detail", "Texture the live mesh. Quickest.") }
    static var qualityBalancedDetail: String { tr("quality.balanced.detail", "10 mm fusion, 2K texture.") }
    static var qualityHDDetail: String { tr("quality.hd.detail", "Fusion no finer than the depth sensor, 4K texture.") }
    static var qualityFellBack: String { tr("quality.fellBack", "Depth fusion did not cover the original scan, so this build kept that mesh and textured it.") }
    static var qualityFilledGaps: String { tr("quality.filledGaps", "Surfaces the depth fusion missed were kept from the original mesh.") }
    static var viewerShowGray: String { tr("viewer.showGray", "Show original mesh") }
    static var viewerShowBuilt: String { tr("viewer.showBuilt", "Show built mesh") }
    static var qualityVoxel: String { tr("quality.voxel", "Voxel size") }
    static var qualitySmooth: String { tr("quality.smooth", "Smoothing") }
    static var qualityTriangles: String { tr("quality.triangles", "Target triangles") }
    static var qualityTexture: String { tr("quality.texture", "Texture size") }
    static var qualityStart: String { tr("quality.start", "Build") }
    static var qualityLater: String { tr("quality.later", "Not now") }
    static var qualityEstimateFast: String { tr("quality.estimate.fast", "About half a minute") }
    static var qualityEstimateBalanced: String { tr("quality.estimate.balanced", "About 1–3 minutes") }
    static var qualityEstimateHD: String { tr("quality.estimate.hd", "About 3–8 minutes") }
    static var qualityWorkingMesh: String { tr("quality.working.mesh", "Fusing depth") }
    static var qualityWorkingClean: String { tr("quality.working.clean", "Cleaning the mesh") }
    static var qualityWorkingTexture: String { tr("quality.working.texture", "Texturing") }
    static var qualityStageAtlas: String { tr("quality.stage.atlas", "Packing the texture") }
    static var qualityStageViews: String { tr("quality.stage.views", "Choosing photos") }
    static var qualityStagePaint: String { tr("quality.stage.paint", "Painting the texture") }
    static var overlayStudio: String { tr("overlay.studio", "Shaded") }
    static var qualityNeedsFrames: String { tr("quality.needsFrames", "This scan has no saved camera frames to rebuild from.") }
    static var qualityRefine: String { tr("quality.refine", "Refine mesh") }
    static var qualityRetexture: String { tr("quality.retexture", "Re-texture") }
    static var exportAllData: String { tr("export.allData", "All data") }
    static var exportAllDataDetail: String { tr("export.allData.detail", "Photos, camera poses, depth, and confidence for this scan.") }
}
