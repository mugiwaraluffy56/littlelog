import Foundation

/// The opt-in ChatGPT connection: while it's on, littlelog stays connected to the relay so
/// ChatGPT can reach this Mac at `connectorURL`.
final class AssistantAccess {
    static let enabledDefaultsKey = "assistantAccessEnabled"
    /// Lets a self-hosted relay replace the default (`defaults write dev.littlelog.app relayURL https://…`).
    static let relayURLDefaultsKey = "relayURL"
    static let defaultRelayURL = "https://littlelog-relay.littlelog-relay.workers.dev"

    var status: RelayClient.Status { relay.status }
    var onStatusChange: (() -> Void)? {
        get { relay.onStatusChange }
        set { relay.onStatusChange = newValue }
    }

    /// What the user pastes into ChatGPT → Plugins → Add custom MCP server.
    let connectorURL: String

    private let relay: RelayClient
    private let oauthStore: OAuthStore
    private let defaults: UserDefaults

    init(
        library: Library,
        approvals: AccessApprovals,
        oauthStore: OAuthStore = OAuthStore(url: OAuthStore.defaultURL),
        identity: DeviceIdentity? = nil,
        defaults: UserDefaults = .standard
    ) throws {
        let identity = try identity ?? DeviceIdentity.loadOrCreate()
        let base = Self.relayBase(defaults)
        guard let connectURL = Self.connectURL(for: base) else {
            throw LibraryError.invalidArgument("The relay address \(base) must be an https:// URL")
        }
        self.oauthStore = oauthStore
        self.defaults = defaults
        connectorURL = "\(base)/d/\(identity.id)\(MCPServer.endpointPath)"

        let oauth = OAuthEndpoints(store: oauthStore) { appName, returnHost in
            await approvals.requestApproval(appName: appName, returnHost: returnHost)
        }
        let mcp = MCPServer(library: library, oauth: oauth)
        relay = RelayClient(connectURL: connectURL, identity: identity) { request in
            await mcp.respond(to: request)
        }
    }

    var isEnabled: Bool {
        defaults.bool(forKey: Self.enabledDefaultsKey)
    }

    func startIfEnabled() {
        if isEnabled { relay.start() }
    }

    func setEnabled(_ enabled: Bool) {
        defaults.set(enabled, forKey: Self.enabledDefaultsKey)
        enabled ? relay.start() : relay.stop()
    }

    /// Apps signed in to littlelog, oldest first.
    var connectedAppNames: [String] {
        oauthStore.connectedClients.map(\.name)
    }

    /// Signs out every app; ChatGPT has to sign in (and be allowed) again.
    func disconnectAll() throws {
        try oauthStore.revokeAll()
    }

    /// `https` becomes `wss`. Plain `http` is accepted only for a relay running on this Mac (development).
    static func connectURL(for base: String) -> URL? {
        guard var components = URLComponents(string: base), let host = components.host?.lowercased() else { return nil }
        switch components.scheme?.lowercased() {
        case "https": components.scheme = "wss"
        case "http" where ["127.0.0.1", "localhost"].contains(host): components.scheme = "ws"
        default: return nil
        }
        components.path += "/connect"
        return components.url
    }

    private static func relayBase(_ defaults: UserDefaults) -> String {
        let configured = defaults.string(forKey: relayURLDefaultsKey)?.trimmingCharacters(in: .whitespacesAndNewlines)
        let base = (configured?.isEmpty == false ? configured : nil) ?? defaultRelayURL
        return base.hasSuffix("/") ? String(base.dropLast()) : base
    }
}
