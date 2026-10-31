import SwiftUI

struct QualitySheet: View {
    var onStart: (FusionSettings) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var preset = "balanced"
    @State private var voxel: Float = 10
    @State private var range: Float
    @State private var confidence: Int

    init(onStart: @escaping (FusionSettings) -> Void) {
        self.onStart = onStart
        let storedRange = UserDefaults.standard.object(forKey: "scanMaxRange") as? Double ?? 3
        let storedConfidence = UserDefaults.standard.object(forKey: "scanConfidence") as? Int ?? 2
        _range = State(initialValue: Float(min(5, max(0.3, storedRange))))
        _confidence = State(initialValue: min(2, max(0, storedConfidence)))
    }
    @State private var smoothing = 4.0
    @State private var triangles = 180_000.0
    @State private var texture = 2048

    private var settings: FusionSettings {
        switch preset {
        case "fast":
            return .fast
        case "hd":
            var hd = FusionSettings.hd
            hd.maxRange = range
            hd.minConfidence = confidence
            return hd
        case "custom":
            return .custom(
                voxelMillimeters: voxel,
                maxRange: range,
                minConfidence: confidence,
                smoothIterations: Int(smoothing.rounded()),
                targetTriangles: Int(triangles.rounded()),
                textureSize: texture
            )
        default:
            var balanced = FusionSettings.balanced
            balanced.maxRange = range
            balanced.minConfidence = confidence
            return balanced
        }
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Text(L10n.qualityBody)
                        .font(.subheadline)
                        .foregroundStyle(AppColor.textSecondary)
                }
                Section {
                    Picker(L10n.qualityTitle, selection: $preset) {
                        Text(L10n.qualityFast).tag("fast")
                        Text(L10n.qualityBalanced).tag("balanced")
                        Text(L10n.qualityHD).tag("hd")
                        Text(L10n.qualityCustom).tag("custom")
                    }
                    .pickerStyle(.segmented)
                    Text(detail).font(.caption).foregroundStyle(AppColor.textSecondary)
                    Text(settings.estimate).font(.subheadline.weight(.semibold))
                }
                Section(L10n.scanRange) {
                    HStack {
                        Text(L10n.scanRange)
                        Spacer()
                        Text(String(format: "%.1f m", range))
                    }
                    Slider(value: $range, in: 0.3...5)
                    Picker(L10n.scanConfidence, selection: $confidence) {
                        Text(L10n.confidenceLow).tag(0)
                        Text(L10n.confidenceMed).tag(1)
                        Text(L10n.confidenceHigh).tag(2)
                    }
                    .pickerStyle(.segmented)
                }
                if preset == "custom" {
                    Section(L10n.qualityCustom) {
                        Picker(L10n.qualityVoxel, selection: $voxel) {
                            Text("5 mm").tag(Float(5))
                            Text("10 mm").tag(Float(10))
                            Text("20 mm").tag(Float(20))
                            Text("40 mm").tag(Float(40))
                        }
                        Stepper(value: $smoothing, in: 0...12) {
                            Text("\(L10n.qualitySmooth): \(Int(smoothing.rounded()))")
                        }
                        Stepper(value: $triangles, in: 20_000...400_000, step: 20_000) {
                            Text("\(L10n.qualityTriangles): \(Int(triangles).formatted())")
                        }
                        Picker(L10n.qualityTexture, selection: $texture) {
                            Text("2K").tag(2048)
                            Text("4K").tag(4096)
                            Text("8K").tag(8192)
                        }
                        .pickerStyle(.segmented)
                    }
                }
            }
            .navigationTitle(L10n.qualityTitle)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(L10n.qualityLater) { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(L10n.qualityStart) {
                        onStart(settings)
                        dismiss()
                    }
                }
            }
        }
        .presentationDetents([.medium, .large])
    }

    private var detail: String {
        switch preset {
        case "fast": return L10n.qualityFastDetail
        case "hd": return L10n.qualityHDDetail
        case "custom": return L10n.qualityBody
        default: return L10n.qualityBalancedDetail
        }
    }
}
