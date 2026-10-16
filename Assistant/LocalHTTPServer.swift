import Foundation
import Network

/// A loopback-only HTTP/1.1 server. It binds to 127.0.0.1, so nothing outside this Mac can connect.
/// All socket work happens on one private queue; request handling is delegated to `handler`.
nonisolated final class LocalHTTPServer: @unchecked Sendable {
    typealias Handler = @Sendable (HTTPRequest) async -> HTTPResponse

    enum State: Sendable, Equatable {
        case ready(port: UInt16)
        case failed(String)
        case stopped
    }

    enum StartError: LocalizedError {
        case invalidPort(UInt16)

        var errorDescription: String? {
            switch self {
            case .invalidPort(let port): "\(port) is not a valid port"
            }
        }
    }

    static let maxConnections = 16

    private let queue = DispatchQueue(label: "dev.littlelog.assistant.http")
    private let port: UInt16
    private let handler: Handler
    // Only touched on `queue`.
    private var listener: NWListener?
    private var connections: [ObjectIdentifier: NWConnection] = [:]

    init(port: UInt16, handler: @escaping Handler) {
        self.port = port
        self.handler = handler
    }

    func start(onStateChange: @escaping @Sendable (State) -> Void) throws {
        guard let endpointPort = NWEndpoint.Port(rawValue: port) else { throw StartError.invalidPort(port) }
        let parameters = NWParameters.tcp
        parameters.requiredInterfaceType = .loopback
        parameters.allowLocalEndpointReuse = true
        parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: endpointPort)

        let listener = try NWListener(using: parameters)
        listener.stateUpdateHandler = { [weak listener] state in
            switch state {
            case .ready:
                onStateChange(.ready(port: listener?.port?.rawValue ?? 0))
            case .failed(let error):
                onStateChange(.failed(Self.describe(error)))
                listener?.cancel()
            case .cancelled:
                onStateChange(.stopped)
            default:
                break
            }
        }
        listener.newConnectionHandler = { [weak self] connection in
            self?.accept(connection)
        }
        queue.sync { self.listener = listener }
        listener.start(queue: queue)
    }

    func stop() {
        queue.async {
            self.listener?.cancel()
            self.listener = nil
            for connection in self.connections.values { connection.cancel() }
            self.connections.removeAll()
        }
    }

    // MARK: Connections (on `queue`)

    private func accept(_ connection: NWConnection) {
        guard connections.count < Self.maxConnections else {
            connection.cancel()
            return
        }
        let id = ObjectIdentifier(connection)
        connections[id] = connection
        connection.stateUpdateHandler = { [weak self] state in
            switch state {
            case .failed, .cancelled:
                self?.connections[id] = nil
            default:
                break
            }
        }
        connection.start(queue: queue)
        receive(on: connection, buffer: Data())
    }

    private func receive(on connection: NWConnection, buffer: Data) {
        // A request may already be fully buffered from the previous read (pipelining).
        if !buffer.isEmpty, case .request = HTTPParser.parse(buffer) {
            process(buffer, on: connection, isComplete: false)
            return
        }
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            if error != nil {
                connection.cancel()
                return
            }
            var accumulated = buffer
            if let data { accumulated.append(data) }
            self.process(accumulated, on: connection, isComplete: isComplete)
        }
    }

    private func process(_ buffer: Data, on connection: NWConnection, isComplete: Bool) {
        switch HTTPParser.parse(buffer) {
        case .incomplete:
            if isComplete {
                connection.cancel()
            } else {
                receive(on: connection, buffer: buffer)
            }
        case .invalid(let response):
            send(response, on: connection, keepAlive: false, remainder: Data())
        case .request(let request, let remainder):
            let keepAlive = request.keepsAlive && !isComplete
            let handler = self.handler
            Task {
                let response = await handler(request)
                self.queue.async {
                    self.send(response, on: connection, keepAlive: keepAlive, remainder: remainder)
                }
            }
        }
    }

    private func send(_ response: HTTPResponse, on connection: NWConnection, keepAlive: Bool, remainder: Data) {
        connection.send(
            content: response.serialized(keepAlive: keepAlive),
            completion: .contentProcessed { [weak self] error in
                guard let self, error == nil, keepAlive else {
                    connection.cancel()
                    return
                }
                self.receive(on: connection, buffer: remainder)
            }
        )
    }

    private static func describe(_ error: NWError) -> String {
        if case .posix(let code) = error, code == .EADDRINUSE {
            return "the port is already in use by another app"
        }
        return error.localizedDescription
    }
}
