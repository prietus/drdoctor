import SwiftUI

@Observable
final class AppState {
    var pendingFileURL: URL?
    var pendingCompareURLs: (URL, URL)?
    var pendingError: String?
}

class AppDelegate: NSObject, NSApplicationDelegate {
    // Owned here (not by the App) so URLs that arrive while the app is still
    // launching are kept until ContentView appears and picks them up.
    let appState = AppState()

    func application(_ application: NSApplication, open urls: [URL]) {
        if let link = urls.first(where: { $0.scheme == "drdoctor" }) {
            handle(link: link)
            return
        }
        if urls.count >= 2 {
            // Two folders = comparison mode
            appState.pendingCompareURLs = (urls[0], urls[1])
        } else if let url = urls.first {
            appState.pendingFileURL = url
        }
    }

    // drdoctor://analyze and drdoctor://compare from Zplayer: albums on WebDAV.
    private func handle(link: URL) {
        do {
            switch try DrDoctorLink.parse(link) {
            case .analyze(let folder):
                appState.pendingFileURL = folder
            case .compare(let a, let b):
                appState.pendingCompareURLs = (a, b)
            case nil:
                appState.pendingError = "Unrecognised drdoctor:// link."
            }
        } catch {
            appState.pendingError = error.localizedDescription
        }
    }
}

@main
struct DrDoctorApp: App {
    @NSApplicationDelegateAdaptor private var appDelegate: AppDelegate

    var body: some Scene {
        Window("Dr. Doctor", id: "main") {
            ContentView(appState: appDelegate.appState)
        }
        .windowStyle(.titleBar)
        .defaultSize(width: 1100, height: 800)

        Settings {
            SettingsView()
        }
    }
}
