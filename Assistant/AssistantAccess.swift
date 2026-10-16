import Foundation
import OSLog
import Security

/// Owns the opt-in MCP endpoint: whether it's enabled, its access token, and the loopback server.
final class AssistantAccess {
    static let port: UInt16 = 48177
    static let enabledDefaultsKey = "assistantAccessEnabled"
    static var endpoint: String { "http://127.0.0.1:\(port)\(MCPServer.endpointPath)" }

    enum Status: Equatable {
        case off
        case starting
        case running
        case failed(String)
    }

    private(set) var status: Status = .off
    var onStatusChange: (() -> Void)?

    private let mcp: MCPServer
    private let tokenStore: AccessTokenStore
    private let oauthStore: OAuthStore
    private let defaults: UserDefaults
    private var server: LocalHTTPServer?
    private(set) var token: String

    init(
        state: AppState,
        approvals: AccessApprovals,
        tokenStore: AccessTokenStore = AccessTokenStore(),
        oauthStore: OAuthStore = OAuthStore(url: OAuthStore.defaultURL),
        defaults: UserDefaults = .standard
    ) throws {
        self.tokenStore = tokenStore
        self.oauthStore = oauthStore
        self.defaults = defaults
        let token = try tokenStore.loadOrCreate()
        self.token = token
        // The MCP server reads the token through this box, so a reset applies to the next request.
        let box = TokenBox(token)
        tokenBox = box
        let oauth = OAuthEndpoints(store: oauthStore) { appName, returnHost in
            await approvals.requestApproval(appName: appName, returnHost: returnHost)
        }
        mcp = MCPServer(state: state, token: { box.value }, oauth: oauth)
    }

    private let tokenBox: TokenBox

    /// Apps signed in through OAuth (ChatGPT on the web), oldest first.
    var connectedAppNames: [String] {
        oauthStore.connectedClients.map(\.name)
    }

    var isEnabled: Bool {
        defaults.bool(forKey: Self.enabledDefaultsKey)
    }

    func startIfEnabled() {
        if isEnabled { start() }
    }

    func setEnabled(_ enabled: Bool) {
        defaults.set(enabled, forKey: Self.enabledDefaultsKey)
        enabled ? start() : stop()
    }

    /// Signs out every app: replaces the static token and revokes all OAuth sign-ins.
    func disconnectAll() throws {
        try oauthStore.revokeAll()
        token = try tokenStore.replace()
        tokenBox.value = token
    }

    // MARK: Server

    private func start() {
        guard server == nil else { return }
        let mcp = self.mcp
        let server = LocalHTTPServer(port: Self.port) { request in
            await mcp.respond(to: request)
        }
        update(.starting)
        do {
            try server.start { [weak self] state in
                Task { @MainActor in self?.serverStateChanged(state) }
            }
            self.server = server
        } catch {
            Logger.app.error("assistant server failed to start: \(error.localizedDescription, privacy: .public)")
            update(.failed(error.localizedDescription))
        }
    }

    private func stop() {
        server?.stop()
        server = nil
        update(.off)
    }

    private func serverStateChanged(_ state: LocalHTTPServer.State) {
        switch state {
        case .ready:
            update(.running)
        case .failed(let message):
            Logger.app.error("assistant server failed: \(message, privacy: .public)")
            server = nil
            update(.failed(message))
        case .stopped:
            if case .failed = status { return }
            if server == nil { update(.off) }
        }
    }

    private func update(_ status: Status) {
        guard self.status != status else { return }
        self.status = status
        onStatusChange?()
    }

    // MARK: Client setup

    /// The block for `~/.codex/config.toml`, shared by the Codex CLI and the ChatGPT desktop app.
    var codexConfigBlock: String {
        """
        [mcp_servers.littlelog]
        url = "\(Self.endpoint)"
        http_headers = { Authorization = "Bearer \(token)" }

        [mcp_servers.littlelog.tools.delete_task]
        approval_mode = "prompt"
        """
    }

    /// Gives littlelog a public HTTPS address for ChatGPT on the web and phone. ngrok's free plan
    /// includes one permanent domain, used automatically. Every request through it still needs
    /// a sign-in that was approved on this Mac.
    static let ngrokCommand = "ngrok http \(port)"
}

/// Mutable holder so the server closure sees token resets without being rebuilt.
private final class TokenBox: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: String

    init(_ value: String) {
        stored = value
    }

    var value: String {
        get { lock.withLock { stored } }
        set { lock.withLock { stored = newValue } }
    }
}

/// Stores the access token in the app's sandbox container, next to the notes database and
/// readable only by this user (0600). Keychain items for ad-hoc signed builds re-prompt after
/// every rebuild, which would break unattended assistant access.
struct AccessTokenStore {
    let url: URL

    init(url: URL? = nil) {
        self.url = url ?? URL.applicationSupportDirectory
            .appending(path: "littlelog", directoryHint: .isDirectory)
            .appending(path: "assistant-token", directoryHint: .notDirectory)
    }

    func loadOrCreate() throws -> String {
        if let data = try? Data(contentsOf: url),
           let token = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
           token.count >= 32 {
            return token
        }
        return try replace()
    }

    func replace() throws -> String {
        let token = try Self.generate()
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(token.utf8).write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path(percentEncoded: false))
        return token
    }

    /// 32 random bytes, base64url without padding.
    nonisolated static func generate() throws -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        let status = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        guard status == errSecSuccess else {
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(status), userInfo: [
                NSLocalizedDescriptionKey: "Couldn't generate a secure access token.",
            ])
        }
        return Data(bytes).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
