import Core
import Foundation
import Observation
import Storage
import SwiftUI

/// The confirm step for Move to Trash: the file-shaped twin of `ConfirmedAction`.
///
/// `ConfirmedAction` only carries `TerminationTarget`s (processes, apps, containers), so files
/// get their own step with the same shape: a view asks, the system confirmation dialog shows,
/// and only `confirm()` creates the `TrashConfirmation` a `StorageTrashing` accepts. Nothing
/// else creates one (its init is `package`), and nothing is ever deleted: it goes to the Trash.
@MainActor
@Observable
final class StorageTrashConfirmation {
    struct Request: Identifiable {
        let id = UUID()
        /// Every item the one confirmation covers; usually one.
        let paths: [String]

        var path: String {
            paths.first ?? ""
        }

        /// "Move “DerivedData” (18.2 GB) to the Trash?"
        let title: String
        /// "You can put it back from the Trash." plus what rebuilding costs, when known.
        let message: String
        let completion: @MainActor (Result<URL?, any Error>) -> Void
        /// For several items: called per item instead of `completion`. Carried by the request, so
        /// the dialog's dismissal after Move to Trash can't drop it.
        var each: (@MainActor (String, Result<URL?, any Error>) -> Void)?
    }

    private(set) var pending: Request?
    private(set) var isRunning = false

    /// Shows the confirmation for one item. Nothing moves until `confirm()`.
    func ask(
        path: String,
        name: String,
        size: UInt64,
        note: String? = nil,
        completion: @escaping @MainActor (Result<URL?, any Error>) -> Void
    ) {
        guard !isRunning else {
            return
        }
        var message = String(localized: "You can put it back from the Trash.", bundle: .strings)
        if let note {
            message += "\n\n" + note
        }
        pending = Request(
            paths: [path],
            title: String(
                localized: "Move “\(name)” (\(Formatters.bytes(size))) to the Trash?",
                bundle: .strings,
                comment: "Confirmation title: the item's name and its size"
            ),
            message: message,
            completion: completion
        )
    }

    /// One confirmation for several items (Space's untouched projects, D-229). `completion`
    /// runs once per item, as each moves or fails.
    func ask(
        items: [(path: String, size: UInt64)],
        title: String,
        message: String,
        completion: @escaping @MainActor (String, Result<URL?, any Error>) -> Void
    ) {
        guard !isRunning, !items.isEmpty else {
            return
        }
        pending = Request(
            paths: items.map(\.path),
            title: title,
            message: String(localized: "You can put it back from the Trash.", bundle: .strings) + "\n\n" + message,
            completion: { _ in },
            each: completion
        )
    }

    func cancel() {
        pending = nil
    }

    /// The user said yes: takes the pending request at once, before the dialog's dismissal
    /// clears it through its binding (the same fix as `ConfirmedAction.accept()`).
    func accept() -> Request? {
        guard let request = pending else {
            return nil
        }
        pending = nil
        return request
    }

    /// Accept and perform in one step (tests).
    func confirm(using trasher: any StorageTrashing) async {
        if let request = accept() {
            await perform(request, using: trasher)
        }
    }

    /// Moves an accepted request's item to the Trash. Only accepted requests get here.
    func perform(_ request: Request, using trasher: any StorageTrashing) async {
        isRunning = true
        defer { isRunning = false }
        let each = request.each
        for path in request.paths {
            let confirmation = TrashConfirmation(path: path, confirmedAt: Date())
            let result: Result<URL?, any Error>
            do {
                result = try await .success(trasher.moveToTrash(confirmation))
            } catch {
                result = .failure(error)
            }
            if let each {
                each(path, result)
            } else {
                request.completion(result)
            }
        }
    }
}

extension View {
    /// Presents the pending Move to Trash as a system confirmation dialog, destructive button
    /// first (spec 10.2, "Confirmations").
    func storageTrashDialog(_ step: StorageTrashConfirmation, trasher: any StorageTrashing) -> some View {
        confirmationDialog(
            step.pending?.title ?? "",
            isPresented: Binding(get: { step.pending != nil }, set: {
                if !$0 {
                    step.cancel()
                }
            }),
            titleVisibility: .visible,
            presenting: step.pending
        ) { _ in
            Button(String(localized: "Move to Trash", bundle: .strings), role: .destructive) {
                // Accept now, before the dialog's dismissal cancels the pending request.
                if let request = step.accept() {
                    Task { await step.perform(request, using: trasher) }
                }
            }
            Button(String(localized: "Cancel", bundle: .strings), role: .cancel) {
                step.cancel()
            }
        } message: { request in
            Text(request.message)
        }
    }
}
