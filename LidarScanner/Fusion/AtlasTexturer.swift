import UIKit

/// Compatibility entry point. There is exactly one implementation: world-space surface baking.
enum AtlasTexturer {
    static func texture(mesh: ScanMesh, directory: URL, frames: [StoredKeyframe], settings: FusionSettings,
                        signal: WorkSignal?, progress: ((Double) -> Void)?, reference: ScanMesh? = nil,
                        fillTolerance: Float = 0.05) -> SurfaceBakeResult? {
        SurfaceTextureBaker.bake(mesh: mesh, directory: directory, frames: frames,
                                 settings: settings, signal: signal, progress: progress)
    }
}
