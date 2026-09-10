import SwiftUI

@main
struct LocalServersApp: App {
    @StateObject private var store = ServerStore()

    var body: some Scene {
        MenuBarExtra {
            MenuContentView(store: store)
        } label: {
            Image(systemName: "server.rack")
        }
        .menuBarExtraStyle(.window)
    }
}
