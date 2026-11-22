import AthinaCore
import AthinaFeatures
import ComposableArchitecture
import Foundation
import Testing

/// The features' one clock as a dependency, driven the way every feature test
/// drives it: an `AdjustableClock` injected into a `TestStore`, advanced only
/// once the effect under test is waiting on it, so nothing waits on real time.
@MainActor
@Suite(.timeLimit(.minutes(1)))
struct AthinaClockDependencyTests {
  private static let start = Date(timeIntervalSince1970: 1_789_473_600)

  /// Waits out a minute on the clock, then says so with the date it woke at.
  @Reducer
  struct Wait {
    @ObservableState
    struct State: Equatable {
      var wokeAt: Date?
    }

    enum Action {
      case start
      case woke(Date)
    }

    @Dependency(\.athinaClock) var clock

    var body: some ReducerOf<Self> {
      Reduce { state, action in
        switch action {
        case .start:
          return .run { [clock] send in
            try await clock.sleep(for: .seconds(60))
            await send(.woke(clock.date))
          }
        case .woke(let date):
          state.wokeAt = date
          return .none
        }
      }
    }
  }

  @Test func aWaitEndsWhenTheInjectedClockReachesIt() async {
    let clock = AdjustableClock(startingAt: Self.start)
    let store = TestStore(initialState: Wait.State()) {
      Wait()
    } withDependencies: {
      $0.athinaClock = clock
    }

    await store.send(.start)
    await clock.waitForSleepers()
    clock.advance(by: .seconds(59))
    await clock.waitForSleepers()
    clock.advance(by: .seconds(1))
    await store.receive(\.woke) {
      $0.wokeAt = Self.start.addingTimeInterval(60)
    }
  }

  @Test func theDependencyIsTheInjectedClock() {
    let clock = AdjustableClock(startingAt: Self.start, uptime: 42)
    withDependencies {
      $0.athinaClock = clock
    } operation: {
      @Dependency(\.athinaClock) var injected
      #expect(injected.date == Self.start)
      #expect(injected.uptime == 42)
      #expect(injected.rate == 0)
    }
  }

  @Test func aTestThatInjectsNoClockFails() {
    withKnownIssue {
      @Dependency(\.athinaClock) var clock
      _ = clock.date
    }
  }
}
