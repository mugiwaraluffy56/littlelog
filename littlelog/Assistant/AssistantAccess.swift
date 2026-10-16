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
    private let defaults: UserDefaults
    private var server: LocalHTTPServer?
    private(set) var token: String

    init(state: AppState, tokenStore: AccessTokenStore = AccessTokenStore(), defaults: UserDefaults = .standard) throws {
        self.tokenStore = tokenStore
        self.defaults = defaults
        let token = try tokenStore.loadOrCreate()
        self.token = token
        // The MCP server reads the token through this box, so a reset applies to the next request.
        let box = TokenBox(token)
        tokenBox = box
        mcp = MCPServer(state: state, token: { box.value })
    }

    private let tokenBox: TokenBox

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

    /// Replaces the token; every connected client must be set up again.
    func resetToken() throws {
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

    /// Runs OpenAI's Secure MCP Tunnel client so ChatGPT on the web and phone can reach littlelog
    /// while this Mac is awake. The tunnel id and runtime key come from platform.openai.com.
    /// The token is passed by `env:` reference, so it never appears in the process list.
    var tunnelCommand: String {
        """
        export CONTROL_PLANE_API_KEY="PASTE_YOUR_RUNTIME_KEY"
        export LITTLELOG_BEARER="Bearer \(token)"
        tunnel-client run \\
          --control-plane.tunnel-id PASTE_YOUR_TUNNEL_ID \\
          --mcp.server-url \(Self.endpoint) \\
          --mcp.extra-headers "Authorization: env:LITTLELOG_BEARER" \\
          --mcp.discovery-extra-headers "Authorization: env:LITTLELOG_BEARER"
        """
    }
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
    static func generate() throws -> String {
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
