import SwiftUI

@Observable
final class AppState {
    var pendingFileURL: URL?
    var pendingCompareURLs: (URL, URL)?
}

class AppDelegate: NSObject, NSApplicationDelegate {
    var appState: AppState?

    func application(_ application: NSApplication, open urls: [URL]) {
        if urls.count >= 2 {
            // Two folders = comparison mode
            appState?.pendingCompareURLs = (urls[0], urls[1])
        } else if let url = urls.first {
            appState?.pendingFileURL = url
        }
    }
}

@main
struct DrDoctorApp: App {
    @NSApplicationDelegateAdaptor private var appDelegate: AppDelegate
    @State private var appState = AppState()

    var body: some Scene {
        Window("Dr. Doctor", id: "main") {
            ContentView(appState: appState)
                .onAppear {
                    appDelegate.appState = appState
                }
        }
        .windowStyle(.titleBar)
        .defaultSize(width: 1100, height: 800)
    }
}
