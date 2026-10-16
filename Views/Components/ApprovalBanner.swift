import SwiftUI

/// Asks the person at this Mac to allow an app (ChatGPT) that's signing in to littlelog.
struct ApprovalBanner: View {
    @Environment(AccessApprovals.self) private var approvals
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack {
            if let request = approvals.pending {
                card(for: request)
                    .transition(reduceMotion ? .opacity : .move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(reduceMotion ? nil : Style.motion, value: approvals.pending)
    }

    private func card(for request: AccessApprovals.Request) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Label {
                Text("\(request.appName) wants to use littlelog")
                    .font(.headline)
            } icon: {
                Image(systemName: "key")
            }
            Text("It will be able to see, add and change your tasks, and read your notes. The request came from \(request.returnHost).")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 8) {
                Spacer()
                Button("Don't Allow") {
                    approvals.resolve(request.id, allowed: false)
                }
                .buttonStyle(.glass)
                Button("Allow") {
                    approvals.resolve(request.id, allowed: true)
                }
                .buttonStyle(.glassProminent)
            }
            .controlSize(.large)
        }
        .padding(16)
        .glassEffect(.regular, in: .rect(cornerRadius: 18, style: .continuous))
        .padding(12)
        .accessibilityElement(children: .contain)
        .accessibilityAddTraits(.isModal)
    }
}
