import Foundation
import Security

// MARK: - Settings

/// WebDAV share DrDoctor reads albums from when another app (Zplayer) hands
/// over a `drdoctor://` link. Server and user live in UserDefaults, the
/// password in the Keychain.
@Observable
final class WebDAVSettings {
    static let shared = WebDAVSettings()

    private static let serverKey = "webdav.server"
    private static let userKey = "webdav.user"

    var serverURL: String {
        didSet { UserDefaults.standard.set(serverURL, forKey: Self.serverKey) }
    }
    var user: String {
        didSet { UserDefaults.standard.set(user, forKey: Self.userKey) }
    }
    var password: String {
        didSet { Keychain.set(password, account: "webdav") }
    }

    var isConfigured: Bool { !serverURL.trimmingCharacters(in: .whitespaces).isEmpty }

    private init() {
        serverURL = UserDefaults.standard.string(forKey: Self.serverKey) ?? ""
        user = UserDefaults.standard.string(forKey: Self.userKey) ?? ""
        password = Keychain.get(account: "webdav") ?? ""
    }
}

enum Keychain {
    private static let service = "com.drdoctor.audioanalyzer.webdav"

    static func get(account: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func set(_ value: String, account: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(query as CFDictionary)
        guard !value.isEmpty else { return }
        var add = query
        add[kSecValueData as String] = Data(value.utf8)
        SecItemAdd(add as CFDictionary, nil)
    }
}

// MARK: - Client

enum WebDAVError: Error, LocalizedError {
    case unauthorized(server: URL)
    case http(Int, String)
    case invalidServer(String)

    var errorDescription: String? {
        switch self {
        case .unauthorized(let server):
            return "The WebDAV server \(server.host ?? server.absoluteString) rejected the credentials."
        case .http(let code, let what):
            return "WebDAV error \(code) listing \(what)"
        case .invalidServer(let s):
            return "Invalid WebDAV server URL: \(s)"
        }
    }
}

enum WebDAV {
    /// Credentials handed over inside a link (older iOS-style links carry
    /// user/pass). Kept for this session only, keyed by host:port.
    private static let lock = NSLock()
    nonisolated(unsafe) private static var sessionCredentials: [String: (String, String)] = [:]

    static func isRemote(_ url: URL) -> Bool {
        url.scheme == "http" || url.scheme == "https"
    }

    private static func hostKey(_ url: URL) -> String? {
        guard let host = url.host?.lowercased() else { return nil }
        let port = url.port ?? (url.scheme == "https" ? 443 : 80)
        return "\(host):\(port)"
    }

    static func rememberForSession(server: URL, user: String, password: String) {
        guard let key = hostKey(server) else { return }
        lock.lock(); defer { lock.unlock() }
        sessionCredentials[key] = (user, password)
    }

    /// Basic auth for a request to `url`: session credentials first, then the
    /// saved settings when the URL is on the configured server.
    static func authorize(_ request: inout URLRequest, for url: URL) {
        guard let key = hostKey(url) else { return }
        lock.lock()
        var creds = sessionCredentials[key]
        lock.unlock()
        if creds == nil {
            let s = WebDAVSettings.shared
            if let server = URL(string: s.serverURL.trimmingCharacters(in: .whitespaces)),
               hostKey(server) == key, !s.user.isEmpty {
                creds = (s.user, s.password)
            }
        }
        guard let (user, pass) = creds else { return }
        let token = Data("\(user):\(pass)".utf8).base64EncodedString()
        request.setValue("Basic \(token)", forHTTPHeaderField: "Authorization")
    }

    /// Server base URL + a path relative to it (as Zplayer stores it), as a folder URL.
    static func folderURL(server: String, relativePath: String) throws -> URL {
        let trimmed = server.trimmingCharacters(in: .whitespaces)
        guard var url = URL(string: trimmed), isRemote(url), url.host != nil else {
            throw WebDAVError.invalidServer(trimmed)
        }
        let parts = relativePath.split(separator: "/").map(String.init)
        for (i, part) in parts.enumerated() {
            url.appendPathComponent(part, isDirectory: i == parts.count - 1)
        }
        return url
    }

    /// Audio files directly inside a remote folder (PROPFIND Depth 1), sorted by name.
    static func listFiles(in folder: URL, extensions: Set<String>) async throws -> [URL] {
        let entries = try await propfind(folder, depth: "1")
        return entries
            .filter { !$0.isCollection }
            .compactMap { resolve(href: $0.href, against: folder) }
            .filter { url in
                let name = url.lastPathComponent
                return !name.hasPrefix(".") && extensions.contains(url.pathExtension.lowercased())
            }
            .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
    }

    /// Checks the server answers and accepts the credentials.
    static func testConnection(server: String) async throws {
        _ = try await propfind(try folderURL(server: server, relativePath: ""), depth: "0")
    }

    private static func resolve(href: String, against base: URL) -> URL? {
        if let url = URL(string: href, relativeTo: base) { return url.absoluteURL }
        let encoded = href.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? href
        return URL(string: encoded, relativeTo: base)?.absoluteURL
    }

    private static func propfind(_ url: URL, depth: String) async throws -> [PropfindParser.Entry] {
        var request = URLRequest(url: url, timeoutInterval: 30)
        request.httpMethod = "PROPFIND"
        request.setValue(depth, forHTTPHeaderField: "Depth")
        request.setValue("application/xml; charset=utf-8", forHTTPHeaderField: "Content-Type")
        request.httpBody = Data("""
            <?xml version="1.0" encoding="utf-8"?>
            <d:propfind xmlns:d="DAV:"><d:prop><d:resourcetype/><d:getcontentlength/></d:prop></d:propfind>
            """.utf8)
        authorize(&request, for: url)

        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        if status == 401 || status == 403 {
            var root = URLComponents(url: url, resolvingAgainstBaseURL: false)
            root?.path = "/"
            throw WebDAVError.unauthorized(server: root?.url ?? url)
        }
        guard status == 207 || status == 200 else {
            throw WebDAVError.http(status, url.lastPathComponent)
        }
        return PropfindParser.parse(data)
    }
}

/// Minimal multistatus parser: href + whether the resource is a collection.
/// Namespace-aware so any DAV prefix (D:, d:, lp1:) works.
final class PropfindParser: NSObject, XMLParserDelegate {
    struct Entry {
        var href = ""
        var isCollection = false
    }

    private var entries: [Entry] = []
    private var current: Entry?
    private var text = ""

    static func parse(_ data: Data) -> [Entry] {
        let delegate = PropfindParser()
        let parser = XMLParser(data: data)
        parser.shouldProcessNamespaces = true
        parser.delegate = delegate
        parser.parse()
        return delegate.entries
    }

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?,
                qualifiedName qName: String?, attributes attributeDict: [String: String] = [:]) {
        switch elementName {
        case "response": current = Entry()
        case "collection": current?.isCollection = true
        default: break
        }
        text = ""
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        text += string
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?,
                qualifiedName qName: String?) {
        switch elementName {
        case "href": current?.href = text.trimmingCharacters(in: .whitespacesAndNewlines)
        case "response":
            if let entry = current { entries.append(entry) }
            current = nil
        default: break
        }
    }
}

// MARK: - drdoctor:// links

/// Links other apps (Zplayer) open DrDoctor with. Same shape as the iOS app's:
///   drdoctor://analyze?server=<base>&path=<album folder>[&user=&pass=]
///   drdoctor://compare?server=<base>&pathA=<folder>&pathB=<folder>[&user=&pass=]
/// Paths are relative to `server`. Without `server` the configured one is used.
enum DrDoctorLink {
    enum Action {
        case analyze(URL)
        case compare(URL, URL)
    }

    static func parse(_ url: URL) throws -> Action? {
        guard url.scheme == "drdoctor",
              let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems else { return nil }
        func value(_ name: String) -> String? {
            items.first { $0.name == name }?.value.flatMap { $0.isEmpty ? nil : $0 }
        }
        let server = value("server") ?? WebDAVSettings.shared.serverURL
        if let user = value("user"), let pass = value("pass"),
           let base = URL(string: server) {
            WebDAV.rememberForSession(server: base, user: user, password: pass)
        } else if let user = value("user"), WebDAVSettings.shared.user.isEmpty {
            // Pre-fill the credentials prompt if the server turns out to need them.
            WebDAVSettings.shared.user = user
        }
        if !WebDAVSettings.shared.isConfigured, value("server") != nil {
            WebDAVSettings.shared.serverURL = server
        }

        switch url.host {
        case "analyze":
            guard let path = value("path") else { return nil }
            return .analyze(try WebDAV.folderURL(server: server, relativePath: path))
        case "compare":
            guard let a = value("pathA"), let b = value("pathB") else { return nil }
            return .compare(try WebDAV.folderURL(server: server, relativePath: a),
                            try WebDAV.folderURL(server: server, relativePath: b))
        default:
            return nil
        }
    }
}
