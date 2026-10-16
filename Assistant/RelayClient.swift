import AppKit
import Foundation
import OSLog

/// This Mac's identity at the relay: a public id (part of the ChatGPT link) and a secret that
/// proves ownership of it. Stored in the sandbox container, readable only by this user.
struct DeviceIdentity: Codable, Equatable {
    let id: String
    let secret: String

    static var defaultURL: URL {
        URL.applicationSupportDirectory
            .appending(path: "littlelog", directoryHint: .isDirectory)
            .appending(path: "relay-device.json", directoryHint: .notDirectory)
    }

    static func loadOrCreate(at url: URL = defaultURL) throws -> DeviceIdentity {
        if let data = try? Data(contentsOf: url),
           let identity = try? JSONDecoder().decode(DeviceIdentity.self, from: data),
           identity.id.wholeMatch(of: /[0-9a-f]{32}/) != nil, identity.secret.count >= 43 {
            return identity
        }
        let identity = DeviceIdentity(
            id: try SecureRandom.bytes(16).map { String(format: "%02x", $0) }.joined(),
            secret: try SecureRandom.token()
        )
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(identity).write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path(percentEncoded: false))
        return identity
    }
}

/// Wire format between the relay and this app (see relay/src/index.ts).
nonisolated struct RelayRequestFrame: Codable, Equatable {
    let type: String
    let id: String
    let method: String
    let path: String
    let query: String
    let headers: [String: String]
    let body: String

    var request: HTTPRequest? {
        guard type == "request", let body = Data(base64Encoded: body) else { return nil }
        return HTTPRequest(
            method: method,
            path: path,
            query: FormEncoding.decode(query),
            headers: Dictionary(headers.map { ($0.key.lowercased(), $0.value) }, uniquingKeysWith: { _, last in last }),
            body: body
        )
    }
}

nonisolated struct RelayResponseFrame: Codable, Equatable {
    var type = "response"
    let id: String
    let status: Int
    let headers: [String: String]
    let body: String

    init(id: String, response: HTTPResponse) {
        self.id = id
        status = response.status
        headers = response.headers
        body = response.body.base64EncodedString()
    }
}

/// Keeps one WebSocket open to the relay and answers the requests it forwards.
/// Reconnects with backoff (1 s doubling to 60 s), and right away when the Mac wakes from sleep.
@MainActor
final class RelayClient: NSObject, URLSessionWebSocketDelegate {
    enum Status: Equatable {
        case stopped
        case connecting
        case connected
        case offline(String)
    }

    static let pingInterval: Duration = .seconds(25)
    static let maxBackoff: Duration = .seconds(60)

    private(set) var status: Status = .stopped
    var onStatusChange: (() -> Void)?

    private let connectURL: URL
    private let identity: DeviceIdentity
    private let handler: (HTTPRequest) async -> HTTPResponse
    private var session: URLSession?
    private var socket: URLSessionWebSocketTask?
    private var keepAlive: Task<Void, Never>?
    private var reconnect: Task<Void, Never>?
    private var backoff: Duration = .seconds(1)
    private var wakeObserver: NSObjectProtocol?

    init(connectURL: URL, identity: DeviceIdentity, handler: @escaping (HTTPRequest) async -> HTTPResponse) {
        self.connectURL = connectURL
        self.identity = identity
        self.handler = handler
        super.init()
    }

    func start() {
        guard status == .stopped else { return }
        session = URLSession(configuration: .default, delegate: self, delegateQueue: .main)
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.reconnectNow() }
        }
        connect()
    }

    func stop() {
        reconnect?.cancel()
        keepAlive?.cancel()
        socket?.cancel(with: .goingAway, reason: nil)
        socket = nil
        session?.invalidateAndCancel()
        session = nil
        if let wakeObserver { NSWorkspace.shared.notificationCenter.removeObserver(wakeObserver) }
        wakeObserver = nil
        update(.stopped)
    }

    // MARK: Connection

    private func connect() {
        guard let session else { return }
        var request = URLRequest(url: connectURL)
        request.setValue("Bearer \(identity.secret)", forHTTPHeaderField: "Authorization")
        request.setValue(identity.id, forHTTPHeaderField: "X-Littlelog-Device")
        let socket = session.webSocketTask(with: request)
        socket.maximumMessageSize = 4 * 1024 * 1024
        self.socket = socket
        update(.connecting)
        socket.resume()
        receive(on: socket)
    }

    private func reconnectNow() {
        guard status != .stopped, status != .connected else { return }
        reconnect?.cancel()
        backoff = .seconds(1)
        socket?.cancel(with: .goingAway, reason: nil)
        connect()
    }

    private func connectionLost(_ socket: URLSessionWebSocketTask, _ error: any Error) {
        guard socket === self.socket, status != .stopped else { return }
        self.socket = nil
        keepAlive?.cancel()
        Logger.app.info("relay connection lost: \(error.localizedDescription, privacy: .public)")
        update(.offline(Self.describe(error)))
        let delay = backoff
        backoff = min(backoff * 2, Self.maxBackoff)
        reconnect = Task { [weak self] in
            do {
                try await Task.sleep(for: delay)
            } catch {
                return
            }
            self?.connect()
        }
    }

    private func receive(on socket: URLSessionWebSocketTask) {
        socket.receive { [weak self] result in
            Task { @MainActor in
                guard let self else { return }
                switch result {
                case .success(.string(let text)):
                    self.handle(text, on: socket)
                    self.receive(on: socket)
                case .success:
                    self.receive(on: socket)
                case .failure(let error):
                    self.connectionLost(socket, error)
                }
            }
        }
    }

    /// Requests are answered concurrently; a slow one (sign-in approval) doesn't block others.
    private func handle(_ text: String, on socket: URLSessionWebSocketTask) {
        guard text != "pong" else { return }
        let frame: RelayRequestFrame
        do {
            frame = try JSONDecoder().decode(RelayRequestFrame.self, from: Data(text.utf8))
        } catch {
            Logger.app.error("ignoring malformed relay frame: \(error.localizedDescription, privacy: .public)")
            return
        }
        let handler = self.handler
        Task {
            let response = if let request = frame.request {
                await handler(request)
            } else {
                HTTPResponse.text("Malformed request", status: 400)
            }
            do {
                let data = try JSONEncoder().encode(RelayResponseFrame(id: frame.id, response: response))
                try await socket.send(.string(String(decoding: data, as: UTF8.self)))
            } catch {
                Logger.app.error("couldn't answer relay request: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    private func startKeepAlive(on socket: URLSessionWebSocketTask) {
        keepAlive?.cancel()
        keepAlive = Task { [weak self] in
            while !Task.isCancelled {
                do {
                    try await Task.sleep(for: Self.pingInterval)
                    try await socket.send(.string("ping"))
                } catch {
                    if !Task.isCancelled { self?.connectionLost(socket, error) }
                    return
                }
            }
        }
    }

    // MARK: URLSessionWebSocketDelegate

    nonisolated func urlSession(
        _ session: URLSession,
        webSocketTask: URLSessionWebSocketTask,
        didOpenWithProtocol protocol: String?
    ) {
        MainActor.assumeIsolated {
            guard webSocketTask === socket else { return }
            backoff = .seconds(1)
            update(.connected)
            startKeepAlive(on: webSocketTask)
        }
    }

    nonisolated func urlSession(
        _ session: URLSession,
        webSocketTask: URLSessionWebSocketTask,
        didCloseWith closeCode: URLSessionWebSocketTask.CloseCode,
        reason: Data?
    ) {
        MainActor.assumeIsolated {
            let detail = reason.flatMap { String(data: $0, encoding: .utf8) } ?? "closed (\(closeCode.rawValue))"
            connectionLost(webSocketTask, RelayError.closed(detail))
        }
    }

    private func update(_ status: Status) {
        guard self.status != status else { return }
        self.status = status
        onStatusChange?()
    }

    private static func describe(_ error: any Error) -> String {
        if let relay = error as? RelayError { return relay.localizedDescription }
        let nsError = error as NSError
        if nsError.domain == NSURLErrorDomain, nsError.code == NSURLErrorNotConnectedToInternet {
            return "no internet connection"
        }
        if let response = (error as NSError).userInfo["NSErrorFailingURLResponseKey"] as? HTTPURLResponse,
           response.statusCode == 403 {
            return "the relay rejected this Mac's identity"
        }
        return error.localizedDescription
    }
}

enum RelayError: LocalizedError {
    case closed(String)

    var errorDescription: String? {
        switch self {
        case .closed(let detail): "relay \(detail)"
        }
    }
}
