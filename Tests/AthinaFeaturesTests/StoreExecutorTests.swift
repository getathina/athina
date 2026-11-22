import ComposableArchitecture
import Testing

extension StoreTests {
  /// The switch a store flips, which a leak would leave on for every test
  /// after it.
  @MainActor
  @Suite(.timeLimit(.minutes(1)))
  struct StoreExecutorTests {
    @Reducer
    struct Nothing {
      @ObservableState
      struct State: Equatable {}

      enum Action {}

      var body: some ReducerOf<Self> {
        EmptyReducer()
      }
    }

    @Test func oneStoreAfterAnotherLeavesTheExecutorAsItWas() async {
      for _ in 1...2 {
        #expect(!uncheckedUseMainSerialExecutor)
        do {
          let store = TestStore(initialState: Nothing.State()) { Nothing() }
          #expect(uncheckedUseMainSerialExecutor)
          await store.finish()
        }
        #expect(!uncheckedUseMainSerialExecutor)
      }
    }
  }
}
