import SwiftUI

struct SettingsView: View {
    var body: some View {
        TabView {
            WebDAVSettingsView()
                .tabItem { Label("WebDAV", systemImage: "network") }
        }
        .frame(width: 520)
    }
}

/// Settings → WebDAV: the share Zplayer hands albums over from.
struct WebDAVSettingsView: View {
    var body: some View {
        Form {
            Section {
                WebDAVFields()
            } header: {
                Text("Zplayer integration")
            } footer: {
                Text("“DR Analysis” and “Compare” in Zplayer open the album straight from this WebDAV share. Use the same server and user as in Zplayer. The password is stored in your Keychain.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .padding(.bottom, 8)
    }
}

/// Server / user / password fields plus a connection check. Shared by the
/// settings tab and the sign-in sheet shown when the server rejects a request.
struct WebDAVFields: View {
    @State private var settings = WebDAVSettings.shared
    @State private var testState: TestState = .idle

    private enum TestState: Equatable {
        case idle, testing, ok
        case failed(String)
    }

    var body: some View {
        @Bindable var settings = settings
        TextField("Server", text: $settings.serverURL, prompt: Text("https://music.example.com/"))
            .textContentType(.URL)
        TextField("User", text: $settings.user)
            .textContentType(.username)
        SecureField("Password", text: $settings.password)
        HStack {
            switch testState {
            case .idle: EmptyView()
            case .testing: ProgressView().controlSize(.small)
            case .ok: Label("Connected", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
            case .failed(let msg): Label(msg, systemImage: "xmark.octagon.fill").foregroundStyle(.red)
            }
            Spacer()
            Button("Test Connection") { test() }
                .disabled(!settings.isConfigured || testState == .testing)
        }
        .font(.callout)
        .onChange(of: settings.serverURL) { testState = .idle }
        .onChange(of: settings.user) { testState = .idle }
        .onChange(of: settings.password) { testState = .idle }
    }

    private func test() {
        testState = .testing
        let server = settings.serverURL
        Task {
            do {
                try await WebDAV.testConnection(server: server)
                testState = .ok
            } catch {
                testState = .failed(error.localizedDescription)
            }
        }
    }
}

/// Asks for the WebDAV credentials when a handed-over album can't be read,
/// then retries the request.
struct WebDAVSignInSheet: View {
    let message: String
    let onRetry: () -> Void
    let onCancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Sign in to WebDAV")
                .font(.headline)
            Text(message)
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Form { WebDAVFields() }
                .formStyle(.grouped)
            HStack {
                Spacer()
                Button("Cancel", role: .cancel, action: onCancel)
                    .keyboardShortcut(.cancelAction)
                Button("Connect", action: onRetry)
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
            }
        }
        .padding(20)
        .frame(width: 460)
    }
}
