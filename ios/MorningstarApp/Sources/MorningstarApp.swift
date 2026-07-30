import SwiftUI

@main
struct MorningstarApp: App {
    @State private var model = AppModel()

    var body: some Scene {
        WindowGroup {
            HubView()
                .environment(model)
                .tint(Palette.wave)
        }
    }
}
