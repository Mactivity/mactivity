import Foundation

/// Why alerts are being held (1.6, quiet while you present).
public enum PresentingReason: String, Sendable, Hashable {
    /// The microphone or a camera is in use: a call, a meeting, a recording.
    case call
    /// Keynote or PowerPoint fills the screen.
    case presenting
    /// The display is mirrored, as to a projector.
    case mirroring
}

/// Whether the person is presenting, on a call or recording right now. Nil when not.
public protocol PresentingSource: Sendable {
    func current() async -> PresentingReason?
}
