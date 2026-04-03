import SwiftUI

@Observable
final class AppState {
    var pendingFileURL: URL?
}

class AppDelegate: NSObject, NSApplicationDelegate {
    var appState: AppState?

    func application(_ application: NSApplication, open urls: [URL]) {
        if let url = urls.first {
            appState?.pendingFileURL = url
        }
    }
}

@main
struct DrDoctorApp: App {
    @NSApplicationDelegateAdaptor private var appDelegate: AppDelegate
    @State private var appState = AppState()

    var body: some Scene {
        WindowGroup {
            ContentView(appState: appState)
                .onAppear {
                    appDelegate.appState = appState
                }
        }
        .windowStyle(.titleBar)
        .defaultSize(width: 1100, height: 800)
    }
}
