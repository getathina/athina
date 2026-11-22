import Foundation
import Testing

@testable import AthinaCore

/// The sensing pipeline over a world of fakes, with the pipeline and a focus
/// that can be held both in reach.
private struct HeldPipelineHarness: SensingHarness {
  let pipeline: SensingPipeline
  let focus: HeldFocus

  init(world: SensingWorld, settings: SensingSettings, source: SensingSource) {
    focus = HeldFocus(world.focus)
    pipeline = SensingPipeline(
      settings: settings,
      journal: world.journal,
      capturer: world.screen,
      recognizer: world.recognizer,
      tracker: focus,
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

/// Every await from a capture's start to its frame being published, in order.
private enum Step: CaseIterable {
  case focusRead
  case focusPublish
  case screenshot
  case frontmostAfterScreenshot
  case recognition
  case frontmostAfterRecognition
  case journalWrite
  case publish
}

/// What ends a capture in flight.
private enum Stop: CaseIterable {
  case pause
  case pauseThenResume
  case withdrawal
  case withdrawalThenAllow
  case deleteEverything

  /// Whether sensing carries on after it.
  var carriesOn: Bool {
    switch self {
    case .pause, .withdrawal: false
    case .pauseThenResume, .withdrawalThenAllow, .deleteEverything: true
    }
  }
}

/// A run's first capture, held at one step.
private struct HeldCapture {
  let run: SensingRun
  let pipeline: SensingPipeline
  /// What the pipeline published from before it started, for a mentor loop to
  /// read as the app's does.
  let events: AsyncStream<SensingEvent>
  private let release: @Sendable () -> Void

  init(at step: Step, prepare: (SensingRun) -> Void = { _ in }) async throws {
    let run = try await SensingRun(harness: HeldPipelineHarness.self)
    let harness = try #require(run.loop as? HeldPipelineHarness)
    // Every frame looks the same, so one wrongly taken as the last kept would
    // have the next dropped as its duplicate.
    run.screen.show(differingBits: 0)
    prepare(run)
    events = await harness.pipeline.events()
    await run.launch()
    self.run = run
    pipeline = harness.pipeline

    switch step {
    case .focusRead:
      let held = harness.focus.holdNext(.focus)
      run.elapse(to: 0.25)
      await held.waitUntilReached()
      release = { held.release() }
    case .focusPublish:
      let read = harness.focus.holdNext(.focus)
      run.elapse(to: 0.25)
      await read.waitUntilReached()
      let blocked = await harness.pipeline.publisher.holdStill()
      read.release()
      await Self.letFocusAnswer(harness.pipeline)
      release = { blocked.release() }
    case .screenshot:
      let held = run.screen.holdNext()
      run.elapse(to: 0.25)
      await held.waitUntilReached()
      release = { held.release() }
    case .frontmostAfterScreenshot:
      let held = harness.focus.holdNext(.frontmostApplication)
      run.elapse(to: 0.25)
      await held.waitUntilReached()
      release = { held.release() }
    case .recognition:
      let held = run.recognizer.holdNext()
      run.elapse(to: 0.25)
      await held.waitUntilReached()
      release = { held.release() }
    case .frontmostAfterRecognition:
      let held = await Self.reachLastFocusCheck(run, harness)
      release = { held.release() }
    case .journalWrite:
      let check = await Self.reachLastFocusCheck(run, harness)
      let blocked = await run.journal.holdStill()
      check.release()
      await Self.letFocusAnswer(harness.pipeline)
      release = { blocked.release() }
    case .publish:
      let check = await Self.reachLastFocusCheck(run, harness)
      let blocked = await harness.pipeline.publisher.holdStill()
      check.release()
      for try await entries in run.journal.liveEntries(limit: 10) {
        let written = entries.contains { entry in
          if case .observation = entry { return true }
          return false
        }
        if written { break }
      }
      _ = await harness.pipeline.settings
      release = { blocked.release() }
    }
  }

  private static func reachLastFocusCheck(
    _ run: SensingRun,
    _ harness: HeldPipelineHarness
  ) async -> BlockedCall {
    let recognition = run.recognizer.holdNext()
    run.elapse(to: 0.25)
    await recognition.waitUntilReached()
    let check = harness.focus.holdNext(.frontmostApplication)
    recognition.release()
    await check.waitUntilReached()
    return check
  }

  /// Returns once the focus read just released has answered and the pipeline
  /// has gone on to its next await.
  private static func letFocusAnswer(_ pipeline: SensingPipeline) async {
    await Task { @AXActor in }.value
    _ = await pipeline.settings
  }

  /// Does `stop` while the capture is held, then lets the capture go on and
  /// returns once both have finished.
  ///
  /// A stop can itself wait on what is held, so each is begun at once and
  /// finishes only after the release.
  func interrupt(by stop: Stop) async throws {
    let allowed = run.settings
    var withdrawn = allowed
    withdrawn.withdrawConsent(at: run.clock.date)
    let begun = await pipeline.begin(stop, allowed: allowed, withdrawn: withdrawn)
    await run.turn { release() }
    for task in begun { try await task.value }
  }
}

extension SensingPipeline {
  /// Begins `stop`, and returns with each part of it at its first await.
  ///
  /// The tasks start on this actor, so nothing here rests on the order its
  /// queue runs in.
  fileprivate func begin(
    _ stop: Stop,
    allowed: SensingSettings,
    withdrawn: SensingSettings
  ) -> [Task<Void, any Error>] {
    switch stop {
    case .pause:
      [Task.immediate { await self.setPaused(true) }]
    case .pauseThenResume:
      [
        Task.immediate { await self.setPaused(true) },
        Task.immediate { await self.setPaused(false) },
      ]
    case .withdrawal:
      [Task.immediate { await self.updateSettings(withdrawn) }]
    case .withdrawalThenAllow:
      [
        Task.immediate { await self.updateSettings(withdrawn) },
        Task.immediate { await self.updateSettings(allowed) },
      ]
    case .deleteEverything:
      [Task.immediate { try await self.clearJournal() }]
    }
  }
}

extension InFlightWorkTests {
  /// A capture in flight at Pause, a withdrawal or Delete Everything.
  struct Captures {
    @Test(arguments: [Step.focusRead, .focusPublish], [Stop.withdrawal, .withdrawalThenAllow])
    fileprivate func noScreenCaptureStartsOnceConsentIsWithdrawn(
      step: Step,
      stop: Stop
    ) async throws {
      let held = try await HeldCapture(at: step)
      try await held.interrupt(by: stop)
      #expect(held.run.screen.captures.isEmpty)
      await held.run.end()
    }

    @Test(
      arguments: [Step.screenshot, .frontmostAfterScreenshot],
      [Stop.withdrawal, .withdrawalThenAllow]
    )
    fileprivate func noTextRecognitionStartsOnceConsentIsWithdrawn(
      step: Step,
      stop: Stop
    ) async throws {
      let held = try await HeldCapture(at: step)
      try await held.interrupt(by: stop)
      #expect(held.run.recognizer.levels.isEmpty)
      await held.run.end()
    }

    @Test(arguments: Step.allCases, Stop.allCases)
    fileprivate func aFrameInFlightIsNeitherSavedNorPublished(
      step: Step,
      stop: Stop
    ) async throws {
      let held = try await HeldCapture(at: step)
      let run = held.run
      try await held.interrupt(by: stop)
      #expect(try await run.observations().isEmpty)
      #expect(try await run.journal.stats().thumbnailCount == 0)

      var expected: [TimeInterval] = []
      if stop.carriesOn {
        run.elapse(to: 1)
        await held.pipeline.captureNow()
        _ = await run.nextCadence { $0.keptCount + $0.droppedCount > 0 }
        // An Allow also makes a capture due by then, so either may be the one
        // that keeps the frame; the other drops it as a duplicate.
        expected = [1]
      }
      #expect(try await run.kept().map(\.at) == expected)
      await run.end()
      let published = await run.publishedObservations()
      #expect(
        published.map { $0.timestamp.timeIntervalSince(SensingTestClock.start) }
          == expected
      )
    }

    @Test(arguments: [Stop.pause, .pauseThenResume])
    fileprivate func aFrameIsNotKeptWhenItsScreenshotFailsAfterPause(stop: Stop) async throws {
      let held = try await HeldCapture(at: .screenshot) { $0.screen.fail(with: .noDisplays) }
      try await held.interrupt(by: stop)
      #expect(try await held.run.observations().isEmpty)
      #expect(held.run.recognizer.levels.isEmpty)
      await held.run.end()
      #expect(await held.run.publishedObservations().isEmpty)
    }

    @Test(arguments: [Stop.pause, .pauseThenResume])
    fileprivate func aFrameIsNotKeptWhenItsTextCannotBeReadAfterPause(stop: Stop) async throws {
      let held = try await HeldCapture(at: .recognition) { $0.recognizer.fail() }
      try await held.interrupt(by: stop)
      #expect(try await held.run.observations().isEmpty)
      await held.run.end()
      #expect(await held.run.publishedObservations().isEmpty)
    }

    @Test func theJournalAndTheBroadcasterAskWhetherTheCaptureStillStands() async throws {
      let journal = try Journal.inMemory()
      let observation = Fixtures.observation(id: 0, at: SensingTestClock.start)
      #expect(try await journal.record(observation, while: { false }) == nil)
      #expect(try await journal.stats().observationCount == 0)
      #expect(try await journal.record(observation, while: { true })?.id == 1)

      let broadcaster = EventBroadcaster<Int>()
      let stream = await broadcaster.subscribe()
      #expect(await !broadcaster.send(1, while: { false }))
      #expect(await broadcaster.send(2, while: { true }))
      await broadcaster.finish()
      var delivered: [Int] = []
      for await element in stream { delivered.append(element) }
      #expect(delivered == [2])
    }

    /// The pipeline and the mentor loop as the app joins them.
    @Test(arguments: [Step.screenshot, .recognition, .journalWrite, .publish])
    fileprivate func aCaptureInFlightAtPauseSendsNothing(step: Step) async throws {
      let held = try await HeldCapture(at: step)
      let clock = AdjustableClock(startingAt: held.run.clock.date)
      let mentor = await MentorLoopTests.Harness(
        journal: try Journal.inMemory(),
        client: ScriptedClaudeClient(clock: clock),
        clock: clock
      )
      let forward = Task {
        for await event in held.events { mentor.send(event) }
      }
      await mentor.setPaused(true)
      try await held.interrupt(by: .pause)
      await mentor.waitUntil { $0.mode == .paused }
      #expect(await mentor.client.sent.isEmpty)
      await held.run.end()
      await forward.value
      await mentor.stop()
    }
  }
}
