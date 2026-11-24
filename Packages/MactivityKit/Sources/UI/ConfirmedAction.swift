import Core
import Foundation
import Observation
import SwiftUI

/// The one path that stops or quits anything (CLAUDE.md rule 4, spec 5.8). A view asks; the
/// system confirmation dialog shows; only the user's confirm creates the `ConfirmedTermination`
/// tokens a `ProcessTerminator` accepts. Nothing else in the codebase creates them.
@MainActor
@Observable
public final class ConfirmedAction {
    /// Where a request's dialog shows. Several views attach the dialog (app lists, Projects, the
    /// diagnosis and unused-apps sheets, Quick Search); each shows only its own requests, so a
    /// Quit… from a sheet doesn't also open a dialog in the app list behind it (D-137).
    public enum Presenter: Hashable, Sendable {
        case window, sheet, panel
    }

    public struct Request: Identifiable {
        public let id = UUID()
        /// "Stop storefront-web?"
        public let title: String
        /// What will stop and what it frees.
        public let message: String
        /// "Stop", "Quit", "Force Quit".
        public let confirmTitle: String
        public let targets: [TerminationTarget]
        public let mode: TerminationMode
        public let presenter: Presenter
        let completion: @MainActor ([TerminationResult]) -> Void

        public init(
            title: String, message: String, confirmTitle: String, targets: [TerminationTarget], mode: TerminationMode,
            presenter: Presenter = .window,
            completion: @escaping @MainActor ([TerminationResult]) -> Void
        ) {
            self.presenter = presenter
            self.title = title
            self.message = message
            self.confirmTitle = confirmTitle
            self.targets = targets
            self.mode = mode
            self.completion = completion
        }
    }

    /// The request the dialog is showing, if any.
    public private(set) var pending: Request?
    public private(set) var isRunning = false

    @ObservationIgnored private var terminator: any ProcessTerminator

    public init(terminator: any ProcessTerminator) {
        self.terminator = terminator
    }

    /// Switching data sources (Simulated data on or off) drops a question still open: it was
    /// asked about the other source's processes, and confirming would have signalled real ones
    /// with the same PIDs (D-145).
    public func setTerminator(_ terminator: any ProcessTerminator) {
        pending = nil
        self.terminator = terminator
    }

    /// Shows the confirmation. Nothing happens until `confirm()`.
    public func ask(_ request: Request) {
        guard !isRunning else {
            return
        }
        pending = request
    }

    public func cancel() {
        pending = nil
    }

    /// A request the user said yes to. Only `accept()` makes one, so only a confirmed request
    /// can reach the terminator (CLAUDE.md rule 4).
    public struct Accepted {
        fileprivate let request: Request
    }

    /// The user said yes: takes the pending request at once. The dialog's dismissal then clears
    /// `pending` through its binding (`cancel()`), before an async confirm would get to read it;
    /// taking it first is what makes Quit, Stop and Move to Trash act (they did nothing, 2026-09-28).
    public func accept() -> Accepted? {
        guard let request = pending else {
            return nil
        }
        pending = nil
        return Accepted(request: request)
    }

    /// Accept and perform in one step (tests, and callers without a dialog).
    public func confirm() async {
        if let accepted = accept() {
            await perform(accepted)
        }
    }

    /// Signals each target of an accepted request, then calls its completion.
    public func perform(_ accepted: Accepted) async {
        let request = accepted.request
        isRunning = true
        defer { isRunning = false }
        let terminator = terminator
        let mode = request.mode
        // All at once: each waits up to 5 s for its target to exit, and one after another made
        // Stop All of six slow servers take half a minute, with every other Quit… ignored (D-145).
        let results = await withTaskGroup(of: TerminationResult?.self) { group in
            for target in request.targets {
                let token = ConfirmedTermination(target: target, mode: mode, confirmedAt: Date())
                group.addTask { try? await terminator.terminate(token) }
            }
            var results: [TerminationResult] = []
            for await result in group {
                if let result {
                    results.append(result)
                }
            }
            return results
        }
        request.completion(results)
    }
}

extension View {
    /// Presents `action`'s pending request as a system confirmation dialog with a destructive
    /// button (spec 10.2, "Confirmations").
    public func confirmedActionDialog(_ action: ConfirmedAction, presenter: ConfirmedAction.Presenter = .window) -> some View {
        modifier(ConfirmedActionDialog(action: action, presenter: presenter))
    }
}

private struct ConfirmedActionDialog: ViewModifier {
    let action: ConfirmedAction
    let presenter: ConfirmedAction.Presenter

    func body(content: Content) -> some View {
        content.confirmationDialog(
            action.pending?.title ?? "",
            isPresented: Binding(get: { action.pending?.presenter == presenter }, set: {
                if !$0 {
                    action.cancel()
                }
            }),
            titleVisibility: .visible,
            presenting: action.pending.flatMap { $0.presenter == presenter ? $0 : nil }
        ) { request in
            Button(request.confirmTitle, role: .destructive) {
                // Accept now, before the dialog's dismissal cancels the pending request.
                if let accepted = action.accept() {
                    Task { await action.perform(accepted) }
                }
            }
            Button(String(localized: "Cancel", bundle: .strings), role: .cancel) {
                action.cancel()
            }
        } message: { request in
            Text(request.message)
        }
    }
}
