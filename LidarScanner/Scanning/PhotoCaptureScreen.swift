import RealityKit
import SwiftUI

struct PhotoCaptureScreen: View {
    @EnvironmentObject private var library: ScanLibrary
    var onFinished: (UUID) -> Void

    var body: some View {
        PhotoCaptureRuntime(library: library, onFinished: onFinished)
    }
}

private struct PhotoCaptureRuntime: View {
    @Environment(\.dismiss) private var dismiss
    @StateObject private var model: PhotoCaptureModel
    @State private var confirmDiscard = false

    init(library: ScanLibrary, onFinished: @escaping (UUID) -> Void) {
        _model = StateObject(wrappedValue: PhotoCaptureModel(library: library) { id in
            onFinished(id)
        })
    }

    var body: some View {
        ZStack {
            captureLayer
            VStack(spacing: 12) {
                topBar
                Spacer()
                bottomPanel
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            if case .building(let progress) = model.phase {
                building(progress)
            }
        }
        .background(Color.black)
        .preferredColorScheme(.dark)
        .interactiveDismissDisabled(true)
        .onAppear { UIApplication.shared.isIdleTimerDisabled = true }
        .onDisappear { UIApplication.shared.isIdleTimerDisabled = false }
        .task {
            model.prepare()
            while !Task.isCancelled {
                model.refresh()
                try? await Task.sleep(nanoseconds: 200_000_000)
            }
        }
        .onChange(of: model.finishedID) { _, id in
            if id != nil { dismiss() }
        }
        .confirmationDialog(L10n.scanDiscardTitle, isPresented: $confirmDiscard, titleVisibility: .visible) {
            Button(L10n.scanDiscardConfirm, role: .destructive) {
                model.discard()
                dismiss()
            }
            Button(L10n.scanKeep, role: .cancel) { dismiss() }
        } message: {
            Text(L10n.scanDiscardBody)
        }
    }

    @ViewBuilder
    private var captureLayer: some View {
        if let session = model.session, model.phase == .capture || model.phase == .readyToBuild {
            ObjectCaptureView(session: session)
                .ignoresSafeArea()
        } else if model.phase == .unsupported {
            messageScreen(title: L10n.photoUnsupportedTitle, body: L10n.photoUnsupportedBody)
        } else if case .failed(let text) = model.phase {
            messageScreen(title: L10n.photoFailed, body: text)
        } else {
            Color.black.ignoresSafeArea()
        }
    }

    private var topBar: some View {
        HStack {
            Button(L10n.scanCancel) {
                if model.shotCount == 0, model.phase != .readyToBuild {
                    model.discard()
                    dismiss()
                } else {
                    confirmDiscard = true
                }
            }
            .font(.headline)
            .foregroundStyle(.white)
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(.black.opacity(0.35), in: Capsule())
            Spacer()
            if model.shotLimit > 0 {
                HUDCapsule(text: L10n.shots(model.shotCount, model.shotLimit), systemImage: "camera")
            }
        }
    }

    @ViewBuilder
    private var bottomPanel: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(statusLine)
                .font(.headline)
                .foregroundStyle(.white)
                .fixedSize(horizontal: false, vertical: true)
            if let feedback = model.feedbackText ?? model.hint {
                Text(feedback)
                    .font(.subheadline)
                    .foregroundStyle(.white.opacity(0.9))
            }
            if model.orbitComplete, model.captureUI == .capturing {
                Text(L10n.photoOrbitDone)
                    .font(.subheadline)
                    .foregroundStyle(.white.opacity(0.9))
            }
            if model.shotCount > 0, model.shotCount < 20, model.captureUI == .capturing {
                Text(L10n.photoLowShots)
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.8))
            }
            controls
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
    }

    @ViewBuilder
    private var controls: some View {
        switch model.phase {
        case .readyToBuild:
            detailPicker
            PrimaryButton(title: L10n.photoBuild, systemImage: "cube.transparent") {
                model.build()
            }
        case .failed:
            SecondaryButton(title: L10n.commonClose) { dismiss() }
        case .unsupported:
            SecondaryButton(title: L10n.commonClose) { dismiss() }
        default:
            captureButtons
        }
    }

    @ViewBuilder
    private var captureButtons: some View {
        switch model.captureUI {
        case .ready:
            PrimaryButton(title: L10n.photoDetect, systemImage: "viewfinder") { model.detect() }
        case .detecting:
            PrimaryButton(title: L10n.photoStart, systemImage: "play.fill") { model.startCapturing() }
            SecondaryButton(title: L10n.photoResetBox, systemImage: "arrow.counterclockwise") { model.resetDetection() }
        case .capturing:
            if model.orbitComplete {
                HStack(spacing: 8) {
                    SecondaryButton(title: L10n.photoAnotherLap) { model.anotherLap() }
                    SecondaryButton(title: L10n.photoFlipped) { model.flipped() }
                }
            }
            PrimaryButton(title: L10n.photoFinish, systemImage: "checkmark") { model.finishCapture() }
            HStack(spacing: 8) {
                SecondaryButton(
                    title: model.isPaused ? L10n.scanResume : L10n.scanPause,
                    systemImage: model.isPaused ? "play" : "pause"
                ) { model.togglePause() }
                SecondaryButton(title: L10n.photoShutter, systemImage: "camera.shutter.button") { model.shutter() }
                    .disabled(!model.canShutter)
                    .opacity(model.canShutter ? 1 : 0.45)
            }
        case .finishing, .initializing:
            ProgressView().tint(.white)
        default:
            EmptyView()
        }
    }

    private var detailPicker: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(L10n.photoDetailCaption)
                .font(.caption)
                .foregroundStyle(AppColor.textSecondary)
            Picker(L10n.photoDetailCaption, selection: Binding(
                get: { model.detail },
                set: { model.updateDetail($0) }
            )) {
                ForEach(ReconstructionDetail.allCases) { detail in
                    Text(detail.title).tag(detail)
                }
            }
            .pickerStyle(.segmented)
        }
    }

    private var statusLine: String {
        switch model.phase {
        case .readyToBuild:
            return L10n.photoReady
        case .preparing:
            return L10n.photoInitializing
        default:
            switch model.captureUI {
            case .initializing: return L10n.photoInitializing
            case .ready: return L10n.photoReadyState
            case .detecting: return L10n.photoDetecting
            case .capturing: return L10n.photoCapturing
            case .finishing: return L10n.photoFinishing
            case .completed: return L10n.photoReady
            case .failed: return L10n.photoFailed
            }
        }
    }

    private func building(_ progress: Double) -> some View {
        VStack(spacing: 16) {
            ProgressView(value: progress)
                .tint(AppColor.accent)
            Text(L10n.photoBuilding).font(.headline)
            Text(L10n.photoKeepOpen)
                .font(.subheadline)
                .multilineTextAlignment(.center)
                .foregroundStyle(AppColor.textSecondary)
            Button(L10n.photoCancelBuild) { model.cancelBuild() }
                .font(.headline)
        }
        .padding(24)
        .frame(maxWidth: 360)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.black.opacity(0.45))
    }

    private func messageScreen(title: String, body: String) -> some View {
        VStack(spacing: 12) {
            Text(title).font(.title3.weight(.semibold))
            Text(body)
                .multilineTextAlignment(.center)
                .foregroundStyle(.white.opacity(0.75))
        }
        .foregroundStyle(.white)
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct ReconstructionScreen: View {
    let scanID: UUID
    @EnvironmentObject private var library: ScanLibrary
    var body: some View {
        ReconstructionRuntime(library: library, scanID: scanID)
    }
}

private struct ReconstructionRuntime: View {
    @StateObject private var model: RebuildModel
    @Environment(\.dismiss) private var dismiss

    init(library: ScanLibrary, scanID: UUID) {
        _model = StateObject(wrappedValue: RebuildModel(library: library, scanID: scanID, onFinished: {}))
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Text(L10n.reconBody)
                    .foregroundStyle(AppColor.textSecondary)
                Text(L10n.shots(model.imageCount, max(model.imageCount, 1)))
                    .font(.headline)
                detailPicker
                if let message = model.message {
                    Text(message).foregroundStyle(AppColor.danger)
                }
                if model.running {
                    ProgressView(value: model.progress)
                        .tint(AppColor.accent)
                    Text(L10n.photoKeepOpen)
                        .font(.subheadline)
                        .foregroundStyle(AppColor.textSecondary)
                    SecondaryButton(title: L10n.photoCancelBuild) { model.cancel() }
                } else {
                    PrimaryButton(title: L10n.reconStart, systemImage: "cube.transparent") {
                        model.build()
                    }
                    .disabled(model.imageCount == 0)
                }
            }
            .padding(20)
        }
        .background(AppColor.background)
        .navigationTitle(L10n.reconTitle)
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { UIApplication.shared.isIdleTimerDisabled = true }
        .onDisappear { UIApplication.shared.isIdleTimerDisabled = false }
    }

    private var detailPicker: some View {
        Picker(L10n.photoDetailCaption, selection: $model.detail) {
            ForEach(ReconstructionDetail.allCases) { detail in
                Text(detail.title).tag(detail)
            }
        }
        .pickerStyle(.segmented)
    }
}
