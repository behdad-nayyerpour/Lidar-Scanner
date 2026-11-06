import SwiftUI

struct OnboardingView: View {
    var onFinish: () -> Void
    @State private var page = 0

    private let pages: [(symbol: String, title: String, body: String)] = [
        ("cube.transparent", L10n.onboardingWelcomeTitle, L10n.onboardingWelcomeBody),
        ("figure.walk", L10n.onboardingRoomTitle, L10n.onboardingRoomBody),
        ("rotate.3d", L10n.onboardingObjectTitle, L10n.onboardingObjectBody),
        ("lock.iphone", L10n.onboardingPrivacyTitle, L10n.onboardingPrivacyBody)
    ]

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Spacer()
                if page < pages.count - 1 {
                    Button(L10n.onboardingSkip, action: onFinish)
                        .font(.headline)
                        .foregroundStyle(AppColor.textSecondary)
                }
            }
            .padding(.horizontal, 24)
            .frame(height: 44)

            TabView(selection: $page) {
                ForEach(pages.indices, id: \.self) { index in
                    VStack(spacing: 22) {
                        Image(systemName: pages[index].symbol)
                            .font(.system(size: 42, weight: .semibold))
                            .foregroundStyle(AppColor.accent)
                            .frame(width: 96, height: 96)
                            .background(AppColor.accent.opacity(0.14), in: RoundedRectangle(cornerRadius: 28, style: .continuous))
                        Text(pages[index].title)
                            .font(.largeTitle.weight(.semibold))
                            .multilineTextAlignment(.center)
                            .foregroundStyle(AppColor.textPrimary)
                        Text(pages[index].body)
                            .font(.body)
                            .multilineTextAlignment(.center)
                            .foregroundStyle(AppColor.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(.horizontal, 28)
                    .tag(index)
                }
            }
            .tabViewStyle(.page(indexDisplayMode: .always))

            Group {
                if page == pages.count - 1 {
                    PrimaryButton(title: L10n.onboardingStart, action: onFinish)
                } else {
                    PrimaryButton(title: L10n.onboardingContinue) {
                        withAnimation { page += 1 }
                    }
                }
            }
            .padding(.horizontal, 24)
            .padding(.bottom, 24)
        }
        .background(AppColor.background.ignoresSafeArea())
    }
}
