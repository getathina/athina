import Combine
import ComposableArchitecture

extension Effect where Action: Sendable {
  /// An effect that is a task on the main actor from the moment it is
  /// returned, so it begins in the main queue's next turn and cancelling
  /// reaches it at once.
  ///
  /// `Effect.run` begins its operation some turns later, and can be cancelled
  /// only once it has.
  ///
  /// - Parameter operation: The work, given what sends an action. Each send is
  ///   over when it returns, and none is made once the task is cancelled.
  /// - Returns: The effect.
  static func mainTask(
    _ operation:
      @escaping @MainActor @Sendable (_ send: @MainActor (Action) -> Void) async -> Void
  ) -> Self {
    .publisher {
      Deferred {
        let actions = PassthroughSubject<Action, Never>()
        // A Combine subject may be sent on from any thread.
        nonisolated(unsafe) let subject = actions
        let task = Task { @MainActor in
          await operation { action in
            guard !Task.isCancelled else { return }
            subject.send(action)
          }
          subject.send(completion: .finished)
        }
        return actions.handleEvents(receiveCancel: { task.cancel() })
      }
    }
  }
}
