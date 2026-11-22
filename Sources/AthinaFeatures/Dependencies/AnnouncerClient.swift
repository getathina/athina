import AppKit
import Combine
import ComposableArchitecture

/// Tells VoiceOver about a change it would otherwise miss, as the toast, the
/// callout and the Settings panes do.
///
/// Its live value is the app's, which posts through the one place every
/// announcement goes and which a run serving the control API also logs, so a
/// scenario can wait on what VoiceOver was told. A test gives its own and
/// reads back what was said; one that gives none fails on the first
/// announcement.
@DependencyClient
public struct AnnouncerClient: Sendable {
  /// Posts `text` for VoiceOver at `priority`: `.medium` queues behind what
  /// it is saying, and `.high` interrupts, only for the answer to something
  /// the person just asked.
  public var post:
    @MainActor @Sendable (_ text: String, _ priority: NSAccessibilityPriorityLevel) -> Void
}

extension AnnouncerClient {
  /// An effect that announces `text` before the send that returned it
  /// returns: under a `HostedParent` once the windows have followed that send
  /// and before the parent acts on it, and with no parent as it starts.
  ///
  /// So announcements are heard in the order their actions were sent. An
  /// `Effect.run` promises no order between two sends, and a `.high` one that
  /// came late would cut off the `.medium` one meant to follow it.
  ///
  /// - Parameters:
  ///   - text: What VoiceOver says.
  ///   - priority: `.medium` to queue behind what it is saying, `.high` to
  ///     interrupt.
  /// - Returns: The effect, which sends no action.
  public func announce<Action>(
    _ text: String,
    priority: NSAccessibilityPriorityLevel = .medium
  ) -> Effect<Action> {
    @Dependency(\.announceOnceFollowed) var announceOnceFollowed
    return .publisher { [announceOnceFollowed] in
      Deferred {
        // A store starts its effects on the main actor.
        MainActor.assumeIsolated {
          announceOnceFollowed { post(text, priority) }
        }
        return Empty<Action, Never>()
      }
    }
  }
}

extension AnnouncerClient: TestDependencyKey {
  /// Fails the test on the first announcement.
  public static let testValue = AnnouncerClient()
}

extension DependencyValues {
  /// What VoiceOver is told (`AnnouncerClient`).
  public var announcer: AnnouncerClient {
    get { self[AnnouncerClient.self] }
    set { self[AnnouncerClient.self] = newValue }
  }
}
