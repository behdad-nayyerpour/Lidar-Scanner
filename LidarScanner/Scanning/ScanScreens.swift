import ARKit
import SwiftUI

struct ScanRouter: View {
    let route: CaptureRoute
    var onFinished: (UUID) -> Void
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var library: ScanLibrary

    var body: some View {
        Group {
            switch route {
            case .room:
                RoomScanHost(mode: .room, onFinished: onFinished)
            case .objectLidar:
                RoomScanHost(mode: .objectLidar, onFinished: onFinished)
            case .objectPhoto:
                PhotoCaptureScreen(onFinished: onFinished)
            }
        }
        .environmentObject(library)
    }
}

enum CaptureRoute: String, Identifiable {
    case room
    case objectLidar
    case objectPhoto
    var id: String { rawValue }
}

struct RoomScanScreen: View {
    @Environment(\.dismiss) private var dismiss
    @StateObject private var model: RoomScanModel
    @AppStorage("measurementUnit") private var unitRaw = MeasurementUnit.meters.rawValue
    var onFinished: (UUID) -> Void
    @State private var confirmDiscard = false

    init(mode: ScanMode, library: ScanLibrary, onFinished: @escaping (UUID) -> Void) {
        self.onFinished = onFinished
        _model = StateObject(wrappedValue: RoomScanModel(mode: mode, library: library))
    }

    var body: some View {
        ZStack {
            RoomARView(model: model)
                .ignoresSafeArea()
            if model.mode == .objectLidar {
                Image(systemName: "plus")
                    .font(.title2.weight(.medium))
                    .foregroundStyle(.white.opacity(0.9))
                    .allowsHitTesting(false)
            }
            controls
            if model.cameraDenied {
                denied
            }
            if model.isProcessing {
                processing
            }
        }
        .preferredColorScheme(.dark)
        .interactiveDismissDisabled(true)
        .onAppear {
            model.prepare()
            UIApplication.shared.isIdleTimerDisabled = true
        }
        .onDisappear {
            model.stop()
            UIApplication.shared.isIdleTimerDisabled = false
        }
        .task {
            while !Task.isCancelled {
                model.tick += 1
                try? await Task.sleep(nanoseconds: 500_000_000)
            }
        }
        .onChange(of: model.savedID) { _, newValue in
            if let newValue {
                onFinished(newValue)
                dismiss()
            }
        }
        .alert(L10n.scanNotEnoughTitle, isPresented: alertBinding) {
            Button(L10n.commonOK, role: .cancel) {}
        } message: {
            Text(model.alertMessage ?? "")
        }
        .confirmationDialog(L10n.scanDiscardTitle, isPresented: $confirmDiscard, titleVisibility: .visible) {
            Button(L10n.scanDiscardConfirm, role: .destructive) {
                model.stop()
                dismiss()
            }
            Button(L10n.scanKeep, role: .cancel) {}
        } message: {
            Text(L10n.scanDiscardBody)
        }
    }

    private var unit: MeasurementUnit { MeasurementUnit(rawValue: unitRaw) ?? .meters }

    private var alertBinding: Binding<Bool> {
        Binding(get: { model.alertMessage != nil }, set: { if !$0 { model.alertMessage = nil } })
    }

    private var controls: some View {
        VStack(spacing: 14) {
            HStack {
                Button(L10n.scanCancel) { confirmDiscard = true }
                    .font(.headline)
                    .foregroundStyle(.white)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .background(.black.opacity(0.35), in: Capsule())
                Spacer()
                HUDCapsule(text: model.elapsedText, systemImage: "timer")
                    .opacity(model.tick >= 0 ? 1 : 1)
            }
            HStack(spacing: 8) {
                HUDCapsule(text: unit.formatArea(model.surfaceArea), systemImage: "square.dashed")
                HUDCapsule(text: compactCount(model.faceCount), systemImage: "triangle")
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Spacer()
            HUDCapsule(
                text: model.guidance.message,
                systemImage: model.guidance.tone == .good ? "checkmark" : "info.circle",
                tone: model.guidance.tone
            )
            if model.mode == .objectLidar {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text(L10n.scanRadius)
                        Spacer()
                        Text(unit.formatDistance(model.objectRadius))
                    }
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.white)
                    Slider(
                        value: Binding(
                            get: { model.objectRadius },
                            set: { model.objectRadius = $0; model.updateSphere() }
                        ),
                        in: 0.12...2.5
                    )
                    .tint(AppColor.accent)
                }
                .padding(14)
                .background(.black.opacity(0.35), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            }
            HStack(alignment: .bottom, spacing: 22) {
                ScanRoundButton(systemImage: "arrow.counterclockwise", title: L10n.scanRestart) {
                    model.restart()
                }
                ScanRoundButton(
                    systemImage: model.isRecording && !model.isPaused ? "pause.fill" : "play.fill",
                    title: !model.isRecording ? L10n.scanStart : (model.isPaused ? L10n.scanResume : L10n.scanPause),
                    prominent: !model.isRecording
                ) {
                    if !model.isRecording { model.startRecording() }
                    else if model.isPaused { model.resume() }
                    else { model.pause() }
                }
                ScanRoundButton(
                    systemImage: "checkmark",
                    title: L10n.scanFinish,
                    prominent: true,
                    enabled: model.isRecording && model.faceCount > 20 && !model.isProcessing
                ) {
                    model.finish()
                }
            }
            if model.mode == .objectLidar {
                Button(action: model.setCenterFromCrosshair) {
                    Label(L10n.scanSetCenter, systemImage: "scope")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 8)
                        .background(.white.opacity(0.16), in: Capsule())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 12)
        .padding(.bottom, 18)
    }

    private var denied: some View {
        VStack(spacing: 16) {
            Image(systemName: "camera.fill")
                .font(.largeTitle)
            Text(L10n.scanCameraDeniedTitle).font(.title3.weight(.semibold))
            Text(L10n.scanCameraDeniedBody)
                .multilineTextAlignment(.center)
                .foregroundStyle(AppColor.textSecondary)
            PrimaryButton(title: L10n.scanOpenSettings, systemImage: "gear") {
                if let url = URL(string: UIApplication.openSettingsURLString) {
                    UIApplication.shared.open(url)
                }
            }
            SecondaryButton(title: L10n.scanCancel) { dismiss() }
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(AppColor.background)
        .foregroundStyle(AppColor.textPrimary)
    }

    private var processing: some View {
        VStack(spacing: 16) {
            ProgressView(value: model.colorProgress)
                .tint(AppColor.accent)
            Text(model.processingText)
                .font(.headline)
            Text(L10n.photoKeepOpen)
                .font(.subheadline)
                .multilineTextAlignment(.center)
                .foregroundStyle(AppColor.textSecondary)
        }
        .padding(24)
        .frame(maxWidth: 360)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.black.opacity(0.35))
    }

    private func compactCount(_ value: Int) -> String {
        value.formatted(.number.notation(.compactName))
    }
}

struct RoomScanHost: View {
    let mode: ScanMode
    var onFinished: (UUID) -> Void
    @EnvironmentObject private var library: ScanLibrary

    var body: some View {
        RoomScanScreen(mode: mode, library: library, onFinished: onFinished)
    }
}

private struct RoomARView: UIViewRepresentable {
    @ObservedObject var model: RoomScanModel

    func makeUIView(context: Context) -> ARSCNView {
        let view = model.sceneView
        if view.subviews.contains(where: { $0 is ARCoachingOverlayView }) == false {
            let coaching = ARCoachingOverlayView()
            coaching.session = view.session
            coaching.goal = .tracking
            coaching.activatesAutomatically = true
            coaching.translatesAutoresizingMaskIntoConstraints = false
            view.addSubview(coaching)
            NSLayoutConstraint.activate([
                coaching.leadingAnchor.constraint(equalTo: view.leadingAnchor),
                coaching.trailingAnchor.constraint(equalTo: view.trailingAnchor),
                coaching.topAnchor.constraint(equalTo: view.topAnchor),
                coaching.bottomAnchor.constraint(equalTo: view.bottomAnchor)
            ])
        }
        return view
    }

    func updateUIView(_ uiView: ARSCNView, context: Context) {}
}

