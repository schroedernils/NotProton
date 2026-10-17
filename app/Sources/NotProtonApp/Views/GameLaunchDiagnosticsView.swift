import SwiftUI

/// Parent owns refreshing the diagnosis and routing retry/repair through Steam.
/// Runtime installation can be routed to
/// `try await PrefixTools.winetricks([verb], in: prefix)` after explicit review.
/// No action (including downloads) executes on appearance.
struct GameLaunchDiagnosticsView: View {
    let diagnostics: GameLaunchDiagnostics
    /// Nil means no actions are wired. In particular, no working retry is implied.
    var performAction: (@MainActor (GameLaunchDiagnostics.Action) async throws -> Void)? = nil
    @State private var busy = false
    @State private var actionIssue: String?
    @State private var pendingRuntime: GameLaunchDiagnostics.Action?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(diagnostics.title).font(.headline)
            Text(diagnostics.message).foregroundStyle(.secondary)
            if let issue = diagnostics.logIssue { Text(issue).foregroundStyle(.red).textSelection(.enabled) }
            ForEach(Array(diagnostics.evidence.enumerated()), id: \.offset) { _, line in
                Text(line).font(.caption.monospaced()).textSelection(.enabled)
            }
            HStack {
                ForEach(Array(diagnostics.actions.enumerated()), id: \.offset) { _, action in
                    Button(label(action)) {
                        if case .installRuntime = action { pendingRuntime = action }
                        else { run(action) }
                    }
                    .buttonStyle(.bordered)
                    .disabled(busy || performAction == nil)
                }
                if busy { ProgressView().controlSize(.small) }
            }
            if let actionIssue {
                Text("Action failed: \(actionIssue)").foregroundStyle(.red).textSelection(.enabled)
            }
        }
        .padding()
        .confirmationDialog("Install Visual C++ runtime?", isPresented: Binding(
            get: { pendingRuntime != nil }, set: { if !$0 { pendingRuntime = nil } }
        ), titleVisibility: .visible) {
            if let action = pendingRuntime {
                Button("Install with Winetricks") { pendingRuntime = nil; run(action) }
            }
            Button("Cancel", role: .cancel) { pendingRuntime = nil }
        } message: {
            Text("This uses NotProton’s existing Winetricks installation path. It may download Winetricks and Microsoft runtime files from the internet and will change this game’s Windows environment.")
        }
        .onChange(of: diagnostics) { _, _ in actionIssue = nil; pendingRuntime = nil }
    }

    private func label(_ action: GameLaunchDiagnostics.Action) -> String {
        switch action {
        case .revealLog(let url): url.lastPathComponent == "notproton-wine.log" ? "Open Wine Log" : "Open Launch Log"
        case .reviewEnvironmentRepair: "Review Environment Repair"
        case .installRuntime: "Review Runtime Installation…"
        case .retry: "Retry Launch"
        }
    }

    private func run(_ action: GameLaunchDiagnostics.Action) {
        guard !busy, let performAction else { return }
        busy = true
        actionIssue = nil
        Task { @MainActor in
            defer { busy = false }
            do { try await performAction(action) }
            catch { actionIssue = error.localizedDescription }
        }
    }
}
