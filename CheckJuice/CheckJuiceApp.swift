import SwiftUI

@main
struct CheckJuiceApp: App {
    @State private var model = AppModel()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(model)
        }
    }
}
