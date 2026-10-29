import SwiftUI

@main
struct LidarScannerApp: App {
    @StateObject private var library = ScanLibrary()
    @AppStorage("hasCompletedOnboarding") private var hasCompletedOnboarding = false

    var body: some Scene {
        WindowGroup {
            Group {
                if hasCompletedOnboarding {
                    RootView()
                } else {
                    OnboardingView {
                        hasCompletedOnboarding = true
                    }
                }
            }
            .environmentObject(library)
            .tint(AppColor.accent)
        }
    }
}
