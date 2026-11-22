import AppKit
import AthinaFeatures
import ComposableArchitecture
import Testing

extension StoreTests {
  /// What VoiceOver is told, as a feature tells it: through an effect, so a test
  /// reads back every announcement and its priority.
  @MainActor
  @Suite(.timeLimit(.minutes(1)))
  struct AnnouncerClientTests {
    /// Announces whatever it is sent.
    @Reducer
    struct Say {
      @ObservableState
      struct State: Equatable {}

      enum Action {
        case say(String, NSAccessibilityPriorityLevel)
      }

      @Dependency(\.announcer) var announcer

      var body: some ReducerOf<Self> {
        Reduce { _, action in
          switch action {
          case .say(let text, let priority):
            return .run { [announcer] _ in
              await announcer.post(text, priority)
            }
          }
        }
      }
    }

    private struct Announcement: Equatable {
      var text: String
      var priority: NSAccessibilityPriorityLevel
    }

    @Test func aFeatureAnnouncesThroughTheClient() async {
      let said = LockIsolated<[Announcement]>([])
      let store = TestStore(initialState: Say.State()) {
        Say()
      } withDependencies: {
        $0.announcer.post = { text, priority in
          said.withValue { $0.append(Announcement(text: text, priority: priority)) }
        }
      }

      await store.send(.say("Listening", .medium))
      await store.send(.say("Athina answered: yes", .high))
      await store.finish()
      #expect(
        said.value == [
          Announcement(text: "Listening", priority: .medium),
          Announcement(text: "Athina answered: yes", priority: .high),
        ]
      )
    }

    /// Announces through the effect that keeps announcements in order.
    @Reducer
    struct SayInOrder {
      @ObservableState
      struct State: Equatable {}

      enum Action {
        case say(String, NSAccessibilityPriorityLevel)
      }

      @Dependency(\.announcer) var announcer

      var body: some ReducerOf<Self> {
        Reduce { _, action in
          switch action {
          case .say(let text, let priority):
            return announcer.announce(text, priority: priority)
          }
        }
      }
    }

    @Test func announcingIsDoneByTheTimeTheSendReturns() {
      let said = LockIsolated<[Announcement]>([])
      let store = Store(
        initialState: SayInOrder.State(),
        reducer: {
          SayInOrder()
        },
        withDependencies: {
          $0.announcer.post = { text, priority in
            said.withValue { $0.append(Announcement(text: text, priority: priority)) }
          }
        }
      )

      store.send(.say("Athina answered: yes", .high))
      #expect(said.value == [Announcement(text: "Athina answered: yes", priority: .high)])
      store.send(.say("Listening", .medium))
      #expect(
        said.value == [
          Announcement(text: "Athina answered: yes", priority: .high),
          Announcement(text: "Listening", priority: .medium),
        ]
      )
    }

    @Test func anAnnouncementATestDidNotExpectFails() {
      withKnownIssue {
        AnnouncerClient.testValue.post("Listening", .medium)
      }
    }
  }
}
