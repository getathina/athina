import Dispatch
import Foundation
import Synchronization
import Testing

@testable import AthinaCore

/// What Pause, a withdrawal and Delete Everything guarantee about work already
/// under way, on fakes and the test clock.
///
/// A few tests hold an actor still to stop work at one await, so the suite
/// runs one test at a time.
@Suite(.serialized, .timeLimit(.minutes(1)))
struct InFlightWorkTests {}

/// A synchronous call held where it runs until a test releases it.
///
/// Focus is read synchronously and an actor's queue moves on only when its job
/// returns, so these are held by blocking, unlike a `HeldCall`.
struct BlockedCall: Sendable {
  private let reached = AsyncStream<Void>.makeStream()
  private let released = DispatchSemaphore(value: 0)

  func block() {
    reached.continuation.finish()
    if released.wait(timeout: .now() + 30) == .timedOut {
      Issue.record("a blocked call was never released")
    }
  }

  func waitUntilReached() async {
    for await _ in reached.stream {}
  }

  func release() {
    released.signal()
  }
}

/// Runs each job on a thread of its own, so an actor held still takes none of
/// the threads every other test runs on.
private final class OwnThreadExecutor: TaskExecutor {
  static let shared = OwnThreadExecutor()

  func enqueue(_ job: consuming ExecutorJob) {
    let job = UnownedJob(job)
    let executor = asUnownedTaskExecutor()
    Thread.detachNewThread { job.runSynchronously(on: executor) }
  }
}

extension Journal {
  /// Keeps every other call to the journal waiting until the returned call is
  /// released.
  nonisolated func holdStill() async -> BlockedCall {
    let call = BlockedCall()
    Task.detached(executorPreference: OwnThreadExecutor.shared) { await self.occupy(call) }
    await call.waitUntilReached()
    return call
  }

  private func occupy(_ call: BlockedCall) {
    call.block()
  }
}

extension EventBroadcaster {
  /// Keeps every send waiting until the returned call is released.
  nonisolated func holdStill() async -> BlockedCall {
    let call = BlockedCall()
    Task.detached(executorPreference: OwnThreadExecutor.shared) { await self.occupy(call) }
    await call.waitUntilReached()
    return call
  }

  private func occupy(_ call: BlockedCall) {
    call.block()
  }
}

/// `FakeFocus`, with a read a test can hold.
@AXActor
final class HeldFocus: FocusTracking {
  enum Read {
    case focus
    case frontmostApplication
  }

  private let focus: FakeFocus
  private nonisolated let held = Mutex<[Read: BlockedCall]>([:])

  nonisolated init(_ focus: FakeFocus) {
    self.focus = focus
  }

  /// Holds the next `read`.
  nonisolated func holdNext(_ read: Read) -> BlockedCall {
    let call = BlockedCall()
    held.withLock { $0[read] = call }
    return call
  }

  func updateExcluded(_ bundleIDs: Set<String>) {
    focus.updateExcluded(bundleIDs)
  }

  func setOnChange(_ handler: (@Sendable (FocusChange) -> Void)?) {
    focus.setOnChange(handler)
  }

  func start() {
    focus.start()
  }

  func stop() {
    focus.stop()
  }

  func refreshObserver() {
    focus.refreshObserver()
  }

  func frontmostApplication() -> (pid: pid_t, bundleID: String?)? {
    held.withLock { $0.removeValue(forKey: .frontmostApplication) }?.block()
    return focus.frontmostApplication()
  }

  func readCurrent() -> FocusContext? {
    held.withLock { $0.removeValue(forKey: .focus) }?.block()
    return focus.readCurrent()
  }
}
