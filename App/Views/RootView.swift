import SwiftUI

struct RootView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        if model.settings.hasCompletedOnboarding {
            MainNavigation()
        } else {
            OnboardingView()
        }
    }
}

private struct MainNavigation: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        NavigationStack(path: $model.path) {
            HomeView()
                .navigationDestination(for: Route.self) { route in
                    switch route {
                    case .review: ReviewView()
                    case .processing: ProcessingView()
                    case .history: HistoryView()
                    case .settings: SettingsView()
                    }
                }
        }
    }
}
