import ARKit
import Combine
import RealityKit

enum DeviceCapability {
    @MainActor
    static var supportsLiDAR: Bool {
        ARWorldTrackingConfiguration.supportsSceneReconstruction(.mesh)
            || ARWorldTrackingConfiguration.supportsSceneReconstruction(.meshWithClassification)
    }

    @MainActor
    static var supportsObjectCapture: Bool {
        ObjectCaptureSession.isSupported && PhotogrammetrySession.isSupported
    }
}

enum ReconstructionDetail: String, CaseIterable, Identifiable {
    case preview
    case reduced
    case medium
    case full

    var id: String { rawValue }

    var title: String {
        switch self {
        case .preview: return L10n.photoPreview
        case .reduced: return L10n.photoReduced
        case .medium: return L10n.photoMedium
        case .full: return L10n.photoFull
        }
    }

    var requestDetail: PhotogrammetrySession.Request.Detail {
        switch self {
        case .preview: return .preview
        case .reduced: return .reduced
        case .medium: return .medium
        case .full: return .full
        }
    }
}

@MainActor
enum PhotogrammetryRunner {
    static func run(
        images: URL,
        output: URL,
        detail: ReconstructionDetail,
        progress: @escaping (Double) -> Void,
        retain: @escaping (PhotogrammetrySession) -> Void
    ) async throws -> URL {
        let session = try PhotogrammetrySession(input: images, configuration: PhotogrammetrySession.Configuration())
        retain(session)
        let request = PhotogrammetrySession.Request.modelFile(url: output, detail: detail.requestDetail)
        try session.process(requests: [request])
        var modelURL: URL?
        var failure: Error?
        for try await event in session.outputs {
            switch event {
            case .requestProgress(_, let fraction):
                progress(fraction)
            case .requestComplete(_, let result):
                if case .modelFile(let url) = result {
                    modelURL = url
                }
            case .requestError(_, let error):
                failure = error
            case .processingComplete:
                if let failure { throw failure }
                guard let modelURL else { throw ScanError.reconstructionFailed(L10n.photoFailed) }
                return modelURL
            case .processingCancelled:
                throw ScanError.reconstructionFailed(L10n.photoCancelBuild)
            default:
                break
            }
        }
        throw ScanError.reconstructionFailed(L10n.photoFailed)
    }
}

@MainActor
final class PhotoCaptureModel: ObservableObject {
    enum CaptureUI: Equatable {
        case initializing
        case ready
        case detecting
        case capturing
        case finishing
        case completed
        case failed
    }

    enum Phase: Equatable {
        case preparing
        case unsupported
        case capture
        case readyToBuild
        case building(Double)
        case failed(String)
    }

    @Published var captureUI: CaptureUI = .initializing
    @Published var phase: Phase = .preparing
    @Published var feedbackText: String?
    @Published var hint: String?
    @Published var shotCount = 0
    @Published var shotLimit = 0
    @Published var orbitComplete = false
    @Published var isPaused = false
    @Published var canShutter = false
    @Published var detail: ReconstructionDetail = .medium
    @Published var finishedID: UUID?

    private(set) var session: ObjectCaptureSession?
    private var photoSession: PhotogrammetrySession?
    private var scanID: UUID?
    private var didPrepare = false
    private let library: ScanLibrary
    var onFinished: (UUID) -> Void

    init(library: ScanLibrary, onFinished: @escaping (UUID) -> Void) {
        self.library = library
        self.onFinished = onFinished
        if let stored = UserDefaults.standard.string(forKey: "photoDetail"),
           let value = ReconstructionDetail(rawValue: stored) {
            detail = value
        }
    }

    func prepare() {
        guard !didPrepare else { return }
        didPrepare = true
        guard DeviceCapability.supportsObjectCapture else {
            phase = .unsupported
            return
        }
        do {
            let id = UUID()
            scanID = id
            _ = try library.createPhotoPlaceholder(id: id)
            let images = library.paths(for: id).images
            let session = ObjectCaptureSession()
            self.session = session
            session.start(imagesDirectory: images, configuration: ObjectCaptureSession.Configuration())
            phase = .capture
        } catch {
            phase = .failed(error.localizedDescription)
        }
    }

    func refresh() {
        guard let session, phase == .capture || phase == .readyToBuild else { return }
        shotCount = session.numberOfShotsTaken
        shotLimit = session.maximumNumberOfInputImages
        orbitComplete = session.userCompletedScanPass
        isPaused = session.isPaused
        canShutter = session.canRequestImageCapture
        feedbackText = Self.feedbackText(session.feedback)
        switch session.state {
        case .initializing:
            captureUI = .initializing
        case .ready:
            captureUI = .ready
        case .detecting:
            captureUI = .detecting
        case .capturing:
            captureUI = .capturing
        case .finishing:
            captureUI = .finishing
        case .completed:
            captureUI = .completed
            phase = .readyToBuild
        case .failed(let error):
            captureUI = .failed
            phase = .failed(error.localizedDescription)
        @unknown default:
            break
        }
    }

    func detect() {
        guard let session else { return }
        if session.startDetecting() == false {
            hint = L10n.photoDetectFailed
        } else {
            hint = nil
        }
    }

    func startCapturing() {
        session?.startCapturing()
        hint = nil
    }

    func resetDetection() {
        _ = session?.resetDetection()
    }

    func anotherLap() {
        session?.beginNewScanPass()
    }

    func flipped() {
        session?.beginNewScanPassAfterFlip()
    }

    func finishCapture() {
        if isPaused { session?.resume() }
        session?.finish()
    }

    func shutter() {
        session?.requestImageCapture()
    }

    func togglePause() {
        if isPaused { session?.resume() } else { session?.pause() }
    }

    func updateDetail(_ detail: ReconstructionDetail) {
        self.detail = detail
        UserDefaults.standard.set(detail.rawValue, forKey: "photoDetail")
    }

    func build() {
        guard let scanID else { return }
        let images = library.paths(for: scanID).images
        let output = library.paths(for: scanID).capture
        phase = .building(0)
        let detail = self.detail
        Task { @MainActor in
            do {
                let url = try await PhotogrammetryRunner.run(
                    images: images,
                    output: output,
                    detail: detail,
                    progress: { [weak self] value in self?.phase = .building(value) },
                    retain: { [weak self] session in self?.photoSession = session }
                )
                let mesh: ScanMesh? = try? await Task.detached(priority: .userInitiated) {
                    try USDZExtractor.extract(from: url)
                }.value
                try self.library.completePhoto(id: scanID, mesh: mesh, detail: detail.rawValue)
                Haptics.success()
                self.finishedID = scanID
                self.onFinished(scanID)
            } catch {
                self.phase = .failed(error.localizedDescription)
                Log.photo.error("Reconstruction failed: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    func cancelBuild() {
        photoSession?.cancel()
    }

    func discard() {
        session?.cancel()
        photoSession?.cancel()
        if let scanID {
            try? library.delete(scanID)
        }
    }

    static func feedbackText(_ feedback: Set<ObjectCaptureSession.Feedback>) -> String? {
        if feedback.contains(.objectNotDetected) { return L10n.feedbackMissing }
        if feedback.contains(.environmentTooDark) { return L10n.feedbackTooDark }
        if feedback.contains(.environmentLowLight) { return L10n.feedbackLowLight }
        if feedback.contains(.movingTooFast) { return L10n.feedbackFast }
        if feedback.contains(.objectTooClose) { return L10n.feedbackTooClose }
        if feedback.contains(.objectTooFar) { return L10n.feedbackTooFar }
        if feedback.contains(.outOfFieldOfView) { return L10n.feedbackOut }
        if feedback.contains(.overCapturing) { return L10n.feedbackOver }
        if feedback.contains(.objectNotFlippable) { return L10n.feedbackFlip }
        return nil
    }
}

@MainActor
final class RebuildModel: ObservableObject {
    @Published var detail: ReconstructionDetail = .medium
    @Published var progress: Double = 0
    @Published var running = false
    @Published var message: String?
    private var photoSession: PhotogrammetrySession?
    private let library: ScanLibrary
    private let scanID: UUID
    var onFinished: () -> Void

    init(library: ScanLibrary, scanID: UUID, onFinished: @escaping () -> Void) {
        self.library = library
        self.scanID = scanID
        self.onFinished = onFinished
        if let stored = library.record(scanID)?.reconstructionDetail,
           let value = ReconstructionDetail(rawValue: stored) {
            detail = value
        }
    }

    var imageCount: Int { library.imageCount(id: scanID) }

    func build() {
        guard imageCount > 0 else {
            message = L10n.reconMissing
            return
        }
        running = true
        message = nil
        let images = library.paths(for: scanID).images
        let output = library.paths(for: scanID).capture
        let detail = self.detail
        Task { @MainActor in
            do {
                let url = try await PhotogrammetryRunner.run(
                    images: images,
                    output: output,
                    detail: detail,
                    progress: { [weak self] value in self?.progress = value },
                    retain: { [weak self] session in self?.photoSession = session }
                )
                let mesh: ScanMesh? = try? await Task.detached(priority: .userInitiated) {
                    try USDZExtractor.extract(from: url)
                }.value
                try self.library.completePhoto(id: self.scanID, mesh: mesh, detail: detail.rawValue)
                Haptics.success()
                self.running = false
                self.onFinished()
            } catch {
                self.running = false
                self.message = error.localizedDescription
            }
        }
    }

    func cancel() {
        photoSession?.cancel()
    }
}
