import ComposableArchitecture
import Testing

/// The parent of every suite that makes a `TestStore`, so no two stores overlap.
///
/// A store puts every task in the process on the main thread while it lives,
/// and as it ends puts back what it found, so two that overlap can leave the
/// switch on for good. That reaches the whole process, which is why
/// scripts/test.sh also runs this target in a process of its own
/// (docs/testing.md "Stores in tests").
@Suite(.serialized, .leavesTheExecutorAlone) struct StoreTests {}

/// Fails a test that begins with the main serial executor on, as it does
/// beside another test's store, or that ends with it still on, as a store that
/// leaked it leaves it.
struct ExecutorGuard: SuiteTrait, TestTrait, TestScoping {
  var isRecursive: Bool { true }

  func provideScope(
    for test: Test,
    testCase: Test.Case?,
    performing function: @Sendable () async throws -> Void
  ) async throws {
    #expect(!uncheckedUseMainSerialExecutor, "began with another store's executor on")
    try await function()
    #expect(!uncheckedUseMainSerialExecutor, "ended with the main serial executor still on")
  }
}

extension Trait where Self == ExecutorGuard {
  /// The test begins and ends with the process's own executor.
  static var leavesTheExecutorAlone: Self { Self() }
}
