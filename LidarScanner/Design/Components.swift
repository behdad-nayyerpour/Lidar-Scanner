import SwiftUI

enum AppColor {
    static let background = Color("AppBackground")
    static let surface = Color("AppSurface")
    static let elevated = Color("AppSurfaceElevated")
    static let textPrimary = Color("AppTextPrimary")
    static let textSecondary = Color("AppTextSecondary")
    static let separator = Color("AppSeparator")
    static let accent = Color("AppAccent")
    static let accentSecondary = Color("AppAccentSecondary")
    static let onAccent = Color("AppOnAccent")
    static let danger = Color("AppDanger")
    static let success = Color("AppSuccess")
    static let warning = Color("AppWarning")
}

struct PrimaryButton: View {
    let title: String
    var systemImage: String?
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                if let systemImage {
                    Image(systemName: systemImage)
                }
                Text(title)
            }
            .font(.headline)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 16)
            .foregroundStyle(AppColor.onAccent)
            .background(AppColor.accent, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
        .buttonStyle(.plain)
    }
}

struct SecondaryButton: View {
    let title: String
    var systemImage: String?
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                if let systemImage {
                    Image(systemName: systemImage)
                }
                Text(title)
            }
            .font(.headline)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 16)
            .foregroundStyle(AppColor.textPrimary)
            .background(AppColor.elevated, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .stroke(AppColor.separator, lineWidth: 1)
            }
        }
        .buttonStyle(.plain)
    }
}

struct ModeCard: View {
    let title: String
    let bodyText: String
    let systemImage: String
    var enabled: Bool = true
    var footnote: String?
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(alignment: .top, spacing: 14) {
                Image(systemName: systemImage)
                    .font(.title2)
                    .foregroundStyle(enabled ? AppColor.accent : AppColor.textSecondary)
                    .frame(width: 44, height: 44)
                    .background(AppColor.accent.opacity(enabled ? 0.14 : 0.06), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                VStack(alignment: .leading, spacing: 4) {
                    Text(title)
                        .font(.headline)
                        .foregroundStyle(AppColor.textPrimary)
                    Text(bodyText)
                        .font(.subheadline)
                        .foregroundStyle(AppColor.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                    if let footnote {
                        Text(footnote)
                            .font(.caption)
                            .foregroundStyle(AppColor.warning)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.forward")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(AppColor.textSecondary)
                    .padding(.top, 4)
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(AppColor.surface, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.55)
    }
}

struct HUDCapsule: View {
    let text: String
    var systemImage: String?
    var tone: ScanGuidance.Tone = .info

    var body: some View {
        HStack(spacing: 8) {
            if let systemImage {
                Image(systemName: systemImage)
            }
            Text(text)
                .multilineTextAlignment(.leading)
        }
        .font(.subheadline.weight(.semibold))
        .foregroundStyle(Color.white)
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(background, in: Capsule())
    }

    private var background: Color {
        switch tone {
        case .info: return Color.black.opacity(0.45)
        case .good: return AppColor.success.opacity(0.88)
        case .warn: return AppColor.warning.opacity(0.92)
        }
    }
}

struct ScanRoundButton: View {
    let systemImage: String
    let title: String
    var prominent = false
    var enabled = true
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 6) {
                Image(systemName: systemImage)
                    .font(.title2.weight(.semibold))
                    .frame(width: prominent ? 72 : 56, height: prominent ? 72 : 56)
                    .foregroundStyle(prominent ? AppColor.onAccent : Color.white)
                    .background(prominent ? AppColor.accent : Color.white.opacity(0.18), in: Circle())
                    .overlay {
                        Circle().stroke(Color.white.opacity(prominent ? 0 : 0.35), lineWidth: 1)
                    }
                Text(title)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Color.white)
            }
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.4)
        .accessibilityLabel(title)
    }
}
