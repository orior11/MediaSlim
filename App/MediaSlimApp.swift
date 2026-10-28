import SwiftUI

@main
struct MediaSlimApp: App {
    @State private var model: AppModel
    @Environment(\.scenePhase) private var scenePhase

    init() {
        let model = AppModel.make()
        _model = State(initialValue: model)
        if !model.isDemo {
            // The model lives as long as the app, so a strong reference is correct here.
            BackgroundProcessing.register { model }
        }
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(model)
                .task { await model.refresh() }
        }
        .onChange(of: scenePhase) { _, phase in
            model.isAppActive = phase == .active
            switch phase {
            case .active:
                Task { await model.refresh() }
            case .background:
                if model.isRunning, model.settings.continueWhileCharging, !model.isDemo {
                    BackgroundProcessing.schedule()
                }
            default:
                break
            }
        }
    }
}
