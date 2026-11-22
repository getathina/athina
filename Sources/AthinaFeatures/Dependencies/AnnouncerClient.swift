import AppKit
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
