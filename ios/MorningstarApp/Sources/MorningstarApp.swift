import SwiftUI

@main
struct MorningstarApp: App {
    @State private var model = AppModel()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            HubView()
                .environment(model)
                .tint(Palette.wave)
                // Captures can arrive from Shortcuts, Siri, or the Action
                // button while the app is not in memory; re-read on return.
                .onChange(of: scenePhase) { _, phase in
                    if phase == .active { model.refresh() }
                }
        }
    }
}
