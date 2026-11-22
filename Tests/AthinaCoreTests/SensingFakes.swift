import CoreGraphics
import Foundation
import Synchronization

@testable import AthinaCore

// Stand-ins for every sense the sensing loop reads. None touches the screen,
// Vision, Accessibility, the input counter, or a permission.

/// The test clock, telling a test when the loop has begun a wait.
///
/// Time is an `AdjustableClock`'s and moves only when a test moves it. Unlike
/// that clock its rate is not zero, since idle is the input counter's real
/// seconds at the clock's rate and would otherwise never come.
final class SensingTestClock: AthinaClock {
  typealias Instant = AdjustableClock.Instant

  /// Where every run starts, at a whole second, so that times in eighths of a
  /// second add up exactly.
  static let start = Date(timeIntervalSinceReferenceDate: 800_000_000)

  private struct Waits {
    var count = 0
    var deadline: Instant?
  }

  private let base = AdjustableClock(startingAt: SensingTestClock.start)
  private let waits = Mutex(Waits())
  private let waitBegan = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
  let rate: Double

  init(rate: Double) {
    self.rate = rate
  }

  var now: Instant { base.now }
  var minimumResolution: Swift.Duration { base.minimumResolution }
  var date: Date { base.date }
  var uptime: TimeInterval { base.uptime }

  /// Seconds since the run started.
  var seconds: TimeInterval { date.timeIntervalSince(Self.start) }

  /// How many waits have begun.
  var waitCount: Int { waits.withLock { $0.count } }

  /// When the newest wait ends.
  var wakeAt: Instant? { waits.withLock { $0.deadline } }

  func sleep(until deadline: Instant, tolerance: Swift.Duration? = nil) async throws {
    // A wait woken before its timer ran is no wait to wake again.
    try Task.checkCancellation()
    waits.withLock { waits in
      waits.count += 1
      waits.deadline = deadline
    }
    waitBegan.continuation.yield()
    try await base.sleep(until: deadline, tolerance: tolerance)
  }

  /// Moves time to `instant`, and not at all when that has passed, as it has
  /// in a test its time limit cut short, so that test fails alone.
  func move(to instant: Instant) {
    base.advance(by: max(.zero, base.now.duration(to: instant)))
  }

  /// Returns once more than `count` waits have begun.
  func waitForWait(after count: Int) async {
    var began = waitBegan.stream.makeAsyncIterator()
    while waitCount <= count {
      guard await began.next() != nil else { return }
    }
  }
}

/// A call a test keeps in flight until it releases it.
struct HeldCall: Sendable {
  private let reached = AsyncStream<Void>.makeStream()
  private let released = AsyncStream<Void>.makeStream()

  func suspend() async {
    reached.continuation.finish()
    for await _ in released.stream {}
  }

  func waitUntilReached() async {
    for await _ in reached.stream {}
  }

  func release() {
    released.continuation.finish()
  }
}

/// A screen that is only ever a drawn bitmap.
final class FakeScreen: ScreenCapturing {
  struct Capture {
    var at: TimeInterval
    var windowFrame: CGRect?
    var maxDimension: Int
  }

  private struct State {
    var captures: [Capture] = []
    var differingBits: Int?
    var failure: ScreenCaptureError?
    var held: HeldCall?
  }

  static let displayID: CGDirectDisplayID = 7
  static let display = CGRect(x: 100, y: 50, width: 1700, height: 1600)

  private let clock: SensingTestClock
  private let state = Mutex(State())

  init(clock: SensingTestClock) {
    self.clock = clock
  }

  var captures: [Capture] { state.withLock { $0.captures } }
  var captureTimes: [TimeInterval] { captures.map(\.at) }

  /// Shows from now on a frame `differingBits` hash bits from a blank one;
  /// until told, each capture is unlike the one before it.
  func show(differingBits: Int) {
    state.withLock { $0.differingBits = differingBits }
  }

  func fail(with failure: ScreenCaptureError?) {
    state.withLock { $0.failure = failure }
  }

  func holdNext() -> HeldCall {
    let held = HeldCall()
    state.withLock { $0.held = held }
    return held
  }

  func capture(windowFrame: CGRect?, maxDimension: Int) async throws -> CapturedFrame {
    let capture = Capture(at: clock.seconds, windowFrame: windowFrame, maxDimension: maxDimension)
    let (bits, failure, held) = state.withLock { state in
      state.captures.append(capture)
      let held = state.held
      state.held = nil
      let bits = state.differingBits ?? (state.captures.count.isMultiple(of: 2) ? 16 : 0)
      return (bits, state.failure, held)
    }
    await held?.suspend()
    if let failure { throw failure }
    guard let image = Self.image(differingBits: bits) else {
      throw ScreenCaptureError.captureFailed("the fake frame could not be drawn")
    }
    return CapturedFrame(image: image, displayID: Self.displayID, screenRect: Self.display)
  }

  /// An image the size of the hash's grid, with one bit set in each of its
  /// first `differingBits` rows.
  private static func image(differingBits: Int) -> CGImage? {
    precondition((0...PerceptualHash.gridRows).contains(differingBits), "a row holds one bit")
    let width = PerceptualHash.gridColumns
    let height = PerceptualHash.gridRows
    guard
      let context = CGContext(
        data: nil,
        width: width,
        height: height,
        bitsPerComponent: 8,
        bytesPerRow: width,
        space: CGColorSpaceCreateDeviceGray(),
        bitmapInfo: CGImageAlphaInfo.none.rawValue
      )
    else { return nil }
    context.setFillColor(gray: 0, alpha: 1)
    context.fill(CGRect(x: 0, y: 0, width: width, height: height))
    context.setFillColor(gray: 1, alpha: 1)
    context.fill(CGRect(x: 0, y: 0, width: 1, height: differingBits))
    return context.makeImage()
  }
}

/// Text recognition that answers with the same block every time.
final class FakeRecognizer: TextRecognizing {
  struct Unreadable: Error, CustomStringConvertible {
    var description: String { "unreadable" }
  }

  private struct State {
    var levels: [OCRLevel] = []
    var fails = false
    var held: HeldCall?
  }

  static let block = TextBlock(
    text: "Reading notes",
    confidence: 1,
    imageRect: CGRect(x: 1, y: 1, width: 8, height: 2),
    screenRect: CGRect(x: 200, y: 150, width: 800, height: 200)
  )

  private let state = Mutex(State())

  var levels: [OCRLevel] { state.withLock { $0.levels } }

  func fail() {
    state.withLock { $0.fails = true }
  }

  func holdNext() -> HeldCall {
    let held = HeldCall()
    state.withLock { $0.held = held }
    return held
  }

  func recognize(_ frame: CapturedFrame, level: OCRLevel) async throws -> [TextBlock] {
    let (fails, held) = state.withLock { state in
      state.levels.append(level)
      let held = state.held
      state.held = nil
      return (state.fails, held)
    }
    await held?.suspend()
    if fails { throw Unreadable() }
    return [Self.block]
  }
}

/// A window that could have the focus.
struct FakeWindow: Sendable {
  static let editor = FakeWindow(
    appName: "Editor",
    bundleID: "com.example.editor",
    pid: 101,
    title: "notes.txt",
    text: "chapter one"
  )
  static let browser = FakeWindow(
    appName: "Browser",
    bundleID: "com.example.browser",
    pid: 202,
    title: "Search",
    text: "swift actors"
  )
  /// The app every run excludes.
  static let vault = FakeWindow(
    appName: "Vault",
    bundleID: "com.example.vault",
    pid: 303,
    title: "Passwords",
    text: "secret"
  )
  static let frame = CGRect(x: 120, y: 80, width: 900, height: 700)

  var appName: String
  var bundleID: String
  var pid: pid_t
  var title: String
  var text: String
}

/// Focus that changes only when a test changes it.
///
/// Starting it or changing its exclusions announces nothing by itself, so each
/// turn of the loop has the one cause the test gave it.
@AXActor
final class FakeFocus: FocusTracking {
  enum Call: Equatable {
    case updateExcluded(Set<String>)
    case setHandler(isSet: Bool)
    case start
    case stop
    case refreshObserver
    case readCurrent
    case frontmostApplication
  }

  private(set) var calls: [Call] = []
  private var onChange: (@Sendable (FocusChange) -> Void)?
  private var excluded: Set<String> = []
  private var tracked: FakeWindow?
  private var inFront: FakeWindow?
  private let clock: SensingTestClock
  private let refreshed = AsyncStream<Void>.makeStream()

  nonisolated init(clock: SensingTestClock, window: FakeWindow?) {
    self.clock = clock
    tracked = window
    inFront = window
  }

  // MARK: What a test does

  /// Puts `window` in front and announces it as a change of `kind`.
  func activate(_ window: FakeWindow, as kind: FocusChangeKind = .application) {
    inFront = window
    notify(window, as: kind)
  }

  /// Announces `window`, whatever app is in front.
  func notify(_ window: FakeWindow, as kind: FocusChangeKind = .application) {
    tracked = window
    onChange?(FocusChange(kind: kind, context: context(of: window)))
  }

  /// Puts the app of `window` in front, ahead of any announcement of it.
  func bringForward(_ window: FakeWindow?) {
    inFront = window
  }

  /// Changes what a fresh read gives, announcing nothing.
  func setReading(_ window: FakeWindow?) {
    tracked = window
  }

  /// Returns once `count` more refreshes have been made.
  func waitForRefreshes(_ count: Int) async {
    var iterator = refreshed.stream.makeAsyncIterator()
    for _ in 0..<count {
      guard await iterator.next() != nil else { return }
    }
  }

  // MARK: FocusTracking

  func updateExcluded(_ bundleIDs: Set<String>) {
    calls.append(.updateExcluded(bundleIDs))
    excluded = bundleIDs
  }

  func setOnChange(_ handler: (@Sendable (FocusChange) -> Void)?) {
    calls.append(.setHandler(isSet: handler != nil))
    onChange = handler
  }

  func start() {
    calls.append(.start)
  }

  func stop() {
    calls.append(.stop)
  }

  func refreshObserver() {
    calls.append(.refreshObserver)
    refreshed.continuation.yield()
  }

  func frontmostApplication() -> (pid: pid_t, bundleID: String?)? {
    calls.append(.frontmostApplication)
    return inFront.map { ($0.pid, $0.bundleID) }
  }

  func readCurrent() -> FocusContext? {
    calls.append(.readCurrent)
    return tracked.map(context(of:))
  }

  private func context(of window: FakeWindow) -> FocusContext {
    var context = FocusContext(
      timestamp: clock.date,
      pid: window.pid,
      bundleID: window.bundleID,
      appName: window.appName
    )
    if ExcludedApps.matches(bundleID: window.bundleID, excluded: excluded) {
      context.isExcluded = true
      return context
    }
    context.windowTitle = window.title
    context.windowFrame = FakeWindow.frame
    context.focusedRole = "AXTextArea"
    context.focusedValue = window.text
    context.focusedValueLength = window.text.count
    return context
  }
}

/// An input counter in real seconds, over the test clock's time.
final class FakeInput: InputActivityReading {
  private struct State {
    var lastEventAt: TimeInterval = 0
    var reads = 0
  }

  /// How long the Mac was up before a run, in the clock's seconds.
  private static let upBefore: TimeInterval = 100_000

  private let clock: SensingTestClock
  private let state = Mutex(State())

  init(clock: SensingTestClock) {
    self.clock = clock
  }

  var readCount: Int { state.withLock { $0.reads } }

  /// Puts the last event `seconds` after the run's start, or before it when
  /// negative.
  func setLastEvent(at seconds: TimeInterval) {
    state.withLock { $0.lastEventAt = seconds }
  }

  /// An event now.
  func type() {
    setLastEvent(at: clock.seconds)
  }

  func secondsSinceLastInput() -> TimeInterval {
    let lastEventAt = state.withLock { state in
      state.reads += 1
      return state.lastEventAt
    }
    return (clock.seconds - lastEventAt) / clock.rate
  }

  func systemUptime() -> TimeInterval {
    (Self.upBefore + clock.seconds) / clock.rate
  }
}

/// Permissions that are whatever a test says, asking macOS nothing.
final class FakePermissions: PermissionReading {
  private struct State {
    var status = PermissionStatus(screenRecording: true, accessibility: true)
    var reads: [TimeInterval] = []
  }

  private let clock: SensingTestClock
  private let state = Mutex(State())

  init(clock: SensingTestClock) {
    self.clock = clock
  }

  var readTimes: [TimeInterval] { state.withLock { $0.reads } }

  func grant(screenRecording: Bool, accessibility: Bool) {
    let status = PermissionStatus(screenRecording: screenRecording, accessibility: accessibility)
    state.withLock { $0.status = status }
  }

  func current() -> PermissionStatus {
    let seconds = clock.seconds
    return state.withLock { state in
      state.reads.append(seconds)
      return state.status
    }
  }
}
