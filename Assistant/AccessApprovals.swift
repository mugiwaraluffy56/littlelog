import Foundation
import Observation

/// "ChatGPT wants to use littlelog" — the one-time approval step of the sign-in flow.
/// The request shows in the littlelog panel on the Mac, so only someone at this Mac can approve,
/// even though the sign-in page itself is reachable through the relay.
@Observable
final class AccessApprovals {
    struct Request: Identifiable, Equatable {
        let id = UUID()
        let appName: String
        let returnHost: String
    }

    static let timeout: Duration = .seconds(90)

    private(set) var pending: Request?
    @ObservationIgnored var onRequest: (() -> Void)?
    @ObservationIgnored private var continuation: CheckedContinuation<Bool, Never>?

    /// Waits for Allow or Deny. Only one request is shown at a time; others are declined, and an
    /// unanswered request is declined after `timeout`.
    func requestApproval(appName: String, returnHost: String) async -> Bool {
        guard pending == nil else { return false }
        let request = Request(appName: appName, returnHost: returnHost)
        pending = request
        onRequest?()
        return await withCheckedContinuation { continuation in
            self.continuation = continuation
            Task { [weak self] in
                do {
                    try await Task.sleep(for: Self.timeout)
                } catch {
                    return
                }
                self?.resolve(request.id, allowed: false)
            }
        }
    }

    func resolve(_ id: UUID, allowed: Bool) {
        guard pending?.id == id, let continuation else { return }
        pending = nil
        self.continuation = nil
        continuation.resume(returning: allowed)
    }
}
