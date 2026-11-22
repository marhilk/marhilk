import SwiftUI

@main
struct AltyaziTRApp: App {
    @StateObject private var model = AppModel()
    @StateObject private var store = Store()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(model)
                .environmentObject(store)
                .preferredColorScheme(.dark)
        }
    }
}
