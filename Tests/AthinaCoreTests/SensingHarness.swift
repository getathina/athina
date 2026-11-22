import Foundation

@testable import AthinaCore

/// The sensing loop as `SensingLoopTests` drives it: what the loop is built
/// over, its commands, and what it publishes.
///
/// The suite asks nothing else of a loop, so it holds for any implementation
/// of one.
protocol SensingHarness: Sendable {
  init(world: SensingWorld, settings: SensingSettings, source: SensingSource)
  func start() async
  func stop() async
  func setPaused(_ paused: Bool) async
  func updateSettings(_ settings: SensingSettings) async
  func captureNow() async
  func permissionsMayHaveChanged() async
  func clearJournal() async throws
  func events() async -> AsyncStream<SensingEvent>
}

/// Everything a loop under test is given, all of it fake but the journal,
/// which is in memory.
struct SensingWorld: Sendable {
  let clock: SensingTestClock
  let journal: Journal
  let screen: FakeScreen
  let recognizer: FakeRecognizer
  let focus: FakeFocus
  let input: FakeInput
  let permissions: FakePermissions
}

/// The harness over `SensingPipeline`.
struct PipelineHarness: SensingHarness {
  private let pipeline: SensingPipeline

  init(world: SensingWorld, settings: SensingSettings, source: SensingSource) {
    pipeline = SensingPipeline(
      settings: settings,
      journal: world.journal,
      capturer: world.screen,
      recognizer: world.recognizer,
      tracker: world.focus,
      input: world.input,
      permissions: world.permissions,
      clock: world.clock,
      source: source
    )
  }

  func start() async { await pipeline.start() }
  func stop() async { await pipeline.stop() }
  func setPaused(_ paused: Bool) async { await pipeline.setPaused(paused) }

  func updateSettings(_ settings: SensingSettings) async {
    await pipeline.updateSettings(settings)
  }

  func captureNow() async { await pipeline.captureNow() }
  func permissionsMayHaveChanged() async { await pipeline.permissionsMayHaveChanged() }
  func clearJournal() async throws { try await pipeline.clearJournal() }
  func events() async -> AsyncStream<SensingEvent> { await pipeline.events() }
}

/// One loop on fakes and the test clock.
///
/// A test moves the loop a turn at a time: it does the one thing that wakes the
/// loop, or moves the clock to when the loop would wake, and returns once the
/// loop waits again. So nothing waits on real time and every time is exact.
/// The times are seconds since the run started.
struct SensingRun {
  /// A kept capture's time and the reason it was made.
  struct Kept: Equatable, Sendable {
    var at: TimeInterval
    var reason: CaptureReason
  }

  /// The default settings with an Allow, the Vault excluded, and a focus delay
  /// in eighths of a second, so times add up exactly.
  static var defaultSettings: SensingSettings {
    var settings = SensingSettings()
    settings.consent = Consent(answer: .allowed, at: SensingTestClock.start)
    settings.excludedBundleIDs = [FakeWindow.vault.bundleID]
    settings.focusSettleDelay = 0.25
    return settings
  }

  let loop: any SensingHarness
  let settings: SensingSettings
  let clock: SensingTestClock
  let journal: Journal
  let screen: FakeScreen
  let recognizer: FakeRecognizer
  let focus: FakeFocus
  let input: FakeInput
  let permissions: FakePermissions

  // A stream for each kind of wait, so one never consumes what another needs.
  private let modes: AsyncStream<SensingEvent>
  private let cadences: AsyncStream<SensingEvent>
  private let journaled: AsyncStream<SensingEvent>
  private let focusChanges: AsyncStream<SensingEvent>
  private let everything: AsyncStream<SensingEvent>

  init(
    rate: Double = 1,
    window: FakeWindow? = .editor,
    source: SensingSource = .system,
    harness: any SensingHarness.Type = PipelineHarness.self,
    adjust: (inout SensingSettings) -> Void = { _ in }
  ) async throws {
    var settings = Self.defaultSettings
    adjust(&settings)
    let clock = SensingTestClock(rate: rate)
    let world = SensingWorld(
      clock: clock,
      journal: try Journal.inMemory(),
      screen: FakeScreen(clock: clock),
      recognizer: FakeRecognizer(),
      focus: FakeFocus(clock: clock, window: window),
      input: FakeInput(clock: clock),
      permissions: FakePermissions(clock: clock)
    )
    let loop = harness.init(world: world, settings: settings, source: source)
    self.loop = loop
    self.settings = settings
    self.clock = clock
    journal = world.journal
    screen = world.screen
    recognizer = world.recognizer
    focus = world.focus
    input = world.input
    permissions = world.permissions
    modes = await loop.events()
    cadences = await loop.events()
    journaled = await loop.events()
    focusChanges = await loop.events()
    everything = await loop.events()
  }

  // MARK: Driving

  /// Starts the loop and returns once it waits for the first time.
  func launch() async {
    await turn { await loop.start() }
  }

  /// Does what wakes the loop and returns once it waits again.
  func turn(after action: () async -> Void) async {
    let waits = clock.waitCount
    await action()
    await clock.waitForWait(after: waits)
  }

  /// Moves the clock to `seconds`, stopping for a whole turn at each time the
  /// loop wakes on the way.
  func advance(to seconds: TimeInterval) async {
    let end = SensingTestClock.Instant(offset: .seconds(seconds))
    while !Task.isCancelled, let wake = clock.wakeAt, wake <= end {
      await turn { clock.move(to: wake) }
    }
    clock.move(to: end)
  }

  /// Moves the clock to `seconds` while a call is held, when the loop cannot
  /// wait.
  func elapse(to seconds: TimeInterval) {
    clock.move(to: SensingTestClock.Instant(offset: .seconds(seconds)))
  }

  /// Stops the loop and lets its last wait run out, so nothing outlives the
  /// test.
  func end() async {
    await loop.stop()
    // Longer than the longest wait `validated()` allows.
    clock.move(to: clock.now.advanced(by: .seconds(31)))
  }

  /// When the loop will next wake.
  var wakesAt: TimeInterval? {
    clock.wakeAt.map { wake in
      clock.date.addingTimeInterval(clock.now.duration(to: wake).timeInterval)
        .timeIntervalSince(SensingTestClock.start)
    }
  }

  // MARK: What it published

  /// The next change of mode not read yet, so reading each in turn also shows
  /// there was none between them.
  func nextMode() async -> SensingMode? {
    for await event in modes {
      if case .modeChanged(let mode) = event { return mode }
    }
    return nil
  }

  /// The next cadence not read yet that `matches` accepts.
  func nextCadence(where matches: (CadenceStatus) -> Bool = { _ in true }) async -> CadenceStatus? {
    for await event in cadences {
      if case .cadence(let cadence) = event, matches(cadence) { return cadence }
    }
    return nil
  }

  /// The next journal event of `kind` not read yet.
  func nextEvent(_ kind: JournalEvent.Kind) async -> JournalEvent? {
    for await event in journaled {
      if case .event(let journalEvent) = event, journalEvent.kind == kind { return journalEvent }
    }
    return nil
  }

  /// The next focus published that `matches` accepts.
  func nextFocus(where matches: (FocusContext) -> Bool) async -> FocusContext? {
    for await event in focusChanges {
      if case .focusChanged(let context) = event, matches(context) { return context }
    }
    return nil
  }

  /// Everything published, once the loop has stopped.
  func published() async -> [SensingEvent] {
    var events: [SensingEvent] = []
    for await event in everything { events.append(event) }
    return events
  }

  /// Every observation published, once the loop has stopped.
  func publishedObservations() async -> [ActivityObservation] {
    await published().compactMap { event in
      if case .observation(let observation) = event { return observation }
      return nil
    }
  }

  // MARK: What it journaled

  func kept() async throws -> [Kept] {
    try await observations().map { observation in
      Kept(
        at: observation.timestamp.timeIntervalSince(SensingTestClock.start),
        reason: observation.reason
      )
    }
  }

  func observations() async throws -> [ActivityObservation] {
    try await journal.recentObservations(limit: 500).reversed()
  }

  func events() async throws -> [JournalEvent] {
    try await journal.recentEvents(limit: 500).reversed()
  }

  func events(_ kind: JournalEvent.Kind) async throws -> [JournalEvent] {
    try await events().filter { $0.kind == kind }
  }

  func times(of kind: JournalEvent.Kind) async throws -> [TimeInterval] {
    try await events(kind).map { $0.timestamp.timeIntervalSince(SensingTestClock.start) }
  }
}
