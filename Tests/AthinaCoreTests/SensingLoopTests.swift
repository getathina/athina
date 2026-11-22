import CoreGraphics
import Foundation
import Testing

@testable import AthinaCore

/// The sensing loop on the test clock, through `SensingHarness`, with a fake
/// for every sense: when it captures, what it keeps, what it reads, and the
/// mode it is in.
///
/// It reads nothing of this Mac, and no test waits on real time. Every time is
/// in seconds since the loop's run started.
@Suite(.timeLimit(.minutes(1)))
struct SensingLoopTests {
  typealias Kept = SensingRun.Kept

  // MARK: Cadence

  @Test func itCapturesOnceFocusSettlesThenAtTheFloor() async throws {
    let run = try await SensingRun()
    await run.launch()
    await run.advance(to: 11)
    #expect(
      try await run.kept() == [
        Kept(at: 0.25, reason: .focusChange),
        Kept(at: 5.25, reason: .floor),
        Kept(at: 10.25, reason: .floor),
      ]
    )
    await run.end()
  }

  @Test func aSwitchIsCapturedOnceTheLastOneSettles() async throws {
    let run = try await SensingRun()
    await run.launch()
    await run.advance(to: 2)
    await run.turn { await run.focus.activate(.browser) }
    await run.advance(to: 2.125)
    await run.turn { await run.focus.activate(.editor) }
    await run.advance(to: 3)
    #expect(
      try await run.kept() == [
        Kept(at: 0.25, reason: .focusChange),
        Kept(at: 2.375, reason: .focusChange),
      ]
    )
    await run.end()
  }

  @Test func typingIsCapturedOnceTheBurstSettles() async throws {
    let run = try await SensingRun()
    await run.launch()
    for time in [1, 2, 2.5] {
      await run.advance(to: time)
      run.input.type()
    }
    await run.advance(to: 4.5)
    #expect(
      try await run.kept() == [
        Kept(at: 0.25, reason: .focusChange),
        Kept(at: 4, reason: .inputSettled),
      ]
    )
    await run.end()
  }

  @Test(arguments: [CaptureReason.focusChange, .inputSettled, .floor])
  func theMinimumIntervalHoldsBackEveryTrigger(trigger: CaptureReason) async throws {
    let run = try await SensingRun { settings in
      settings.minCaptureInterval = 3
      if trigger == .floor { settings.floorInterval = 1 }
    }
    await run.launch()
    await run.advance(to: 0.5)
    if trigger == .focusChange { await run.turn { await run.focus.activate(.browser) } }
    if trigger == .inputSettled { run.input.type() }
    await run.advance(to: 3.125)
    #expect(run.screen.captureTimes == [0.25])
    await run.advance(to: 3.25)
    #expect(
      try await run.kept() == [
        Kept(at: 0.25, reason: .focusChange),
        Kept(at: 3.25, reason: trigger),
      ]
    )
    await run.end()
  }

  @Test func theMinimumIntervalShortensTheWaitAfterACapture() async throws {
    let run = try await SensingRun { $0.minCaptureInterval = 0.125 }
    await run.launch()
    await run.advance(to: 0.25)
    #expect(run.wakesAt == 0.375)
    await run.advance(to: 0.375)
    #expect(run.wakesAt == 0.875)
    await run.end()
  }

  @Test func captureNowIgnoresTheMinimumInterval() async throws {
    let run = try await SensingRun()
    await run.launch()
    await run.advance(to: 0.375)
    await run.turn { await run.loop.captureNow() }
    #expect(
      try await run.kept() == [
        Kept(at: 0.25, reason: .focusChange),
        Kept(at: 0.375, reason: .manual),
      ]
    )
    await run.end()
  }

  @Test func captureNowWhilePausedWaitsForTheResume() async throws {
    let run = try await SensingRun()
    await run.launch()
    await run.advance(to: 1)
    await run.turn { await run.loop.setPaused(true) }
    await run.advance(to: 2)
    await run.turn { await run.loop.captureNow() }
    await run.advance(to: 3)
    #expect(run.screen.captureTimes == [0.25])
    await run.turn { await run.loop.setPaused(false) }
    #expect(
      try await run.kept() == [
        Kept(at: 0.25, reason: .focusChange),
        Kept(at: 3, reason: .manual),
      ]
    )
    await run.end()
  }

  @Test func inputFromBeforeLaunchIsCapturedAtOnceWhenAlreadySettled() async throws {
    let run = try await SensingRun()
    run.input.setLastEvent(at: -10)
    await run.launch()
    #expect(try await run.kept() == [Kept(at: 0, reason: .inputSettled)])
    let cadence = await run.nextCadence()
    #expect(cadence?.lastInputAt == SensingTestClock.start - 10)
    await run.end()
  }

  @Test(
    arguments: [
      (movedTo: 0.25, captures: [0.25]),
      (movedTo: 0.375, captures: [0.25, 1.875]),
    ]
  )
  func onlyAnInputTimeMovedByMoreThanTheJitterIsNewInput(
    movedTo: TimeInterval,
    captures: [TimeInterval]
  ) async throws {
    let run = try await SensingRun()
    await run.launch()
    await run.advance(to: 0.5)
    run.input.setLastEvent(at: movedTo)
    await run.advance(to: 3)
    #expect(run.screen.captureTimes == captures)
    await run.end()
  }

  @Test func inputDuringACaptureSchedulesTheNextOne() async throws {
    let run = try await SensingRun()
    await run.launch()
    let held = run.screen.holdNext()
    run.elapse(to: 0.25)
    await held.waitUntilReached()
    run.elapse(to: 0.75)
    run.input.type()
    await run.turn { held.release() }
    await run.advance(to: 3)
    #expect(
      try await run.kept() == [
        Kept(at: 0.25, reason: .focusChange),
        Kept(at: 2.25, reason: .inputSettled),
      ]
    )
    await run.end()
  }

  @Test func captureNowDuringACaptureFollowsItAtOnce() async throws {
    let run = try await SensingRun()
    await run.launch()
    let held = run.screen.holdNext()
    run.elapse(to: 0.25)
    await held.waitUntilReached()
    run.elapse(to: 0.75)
    await run.loop.captureNow()
    await run.turn { held.release() }
    #expect(
      try await run.kept() == [
        Kept(at: 0.25, reason: .focusChange),
        Kept(at: 0.75, reason: .manual),
      ]
    )
    await run.end()
  }

  @Test func aSlowCaptureIsDatedWhenItStartedAndPacedFromWhenItFinished() async throws {
    let run = try await SensingRun()
    await run.launch()
    let held = run.screen.holdNext()
    run.elapse(to: 0.25)
    await held.waitUntilReached()
    run.elapse(to: 2.25)
    await run.turn { held.release() }
    await run.advance(to: 8)
    #expect(
      try await run.kept() == [
        Kept(at: 0.25, reason: .focusChange),
        Kept(at: 7.25, reason: .floor),
      ]
    )
    await run.end()
  }

  @Test func changedSettingsReachTheLoopAtOnceAndValidated() async throws {
    let run = try await SensingRun()
    await run.launch()
    await run.advance(to: 1)
    var changed = run.settings
    changed.floorInterval = 0
    changed.maxFrameDimension = 10
    changed.ocrLevel = .fast
    let settings = changed
    await run.turn { await run.loop.updateSettings(settings) }
    await run.advance(to: 1.25)
    // A floor of 0 is held at its least, a second, and 10 pixels at 320.
    #expect(run.screen.captureTimes == [0.25, 1.25])
    #expect(run.screen.captures.map(\.maxDimension) == [1280, 320])
    #expect(run.recognizer.levels == [.accurate, .fast])
    await run.end()
  }

  @Test func cadenceSaysWhatIsNextAndIsPublishedAtMostFiveTimesASecond() async throws {
    let run = try await SensingRun()
    await run.launch()
    let first = await run.nextCadence()
    #expect(first?.mode == .watching)
    #expect(first?.nextDueAt == SensingTestClock.start + 0.25)
    #expect(first?.nextDueReason == .focusChange)
    #expect(first?.keptCount == 0)

    for time in [0.125, 0.1875] {
      await run.advance(to: time)
      await run.turn { await run.loop.captureNow() }
    }
    await run.advance(to: 0.6875)
    // Two captures within a fifth of a second of the first are told as one.
    let second = await run.nextCadence()
    #expect(second?.keptCount == 2)
    #expect(second?.lastCaptureAt == SensingTestClock.start + 0.1875)
    #expect(second?.lastCaptureReason == .manual)
    await run.end()
  }

  // MARK: Idle

  @Test(arguments: [1.0, 4.0])
  func idleStartsAtTheThresholdOnTheClock(rate: Double) async throws {
    let run = try await SensingRun(rate: rate) { $0.idleThreshold = 10 }
    // With no captures to move them, the polls fall on every half second.
    run.permissions.grant(screenRecording: false, accessibility: true)
    await run.launch()
    #expect(await run.nextMode() == .accessibilityOnly)
    await run.advance(to: 9.5)
    #expect(try await run.events(.idleStart).isEmpty)
    await run.advance(to: 10)
    #expect(await run.nextMode() == .idle)
    #expect(try await run.times(of: .idleStart) == [10])
    #expect(try await run.events(.idleStart).first?.detail == "no input for 10s")
    // Idle polls slower.
    #expect(run.wakesAt == 12)
    await run.end()
  }

  @Test func idleCapturesNothingAndEndsAtThePollThatSeesInput() async throws {
    let run = try await SensingRun { $0.idleThreshold = 10 }
    await run.launch()
    await run.advance(to: 13)
    run.input.type()
    await run.advance(to: 15)
    #expect(try await run.times(of: .idleStart) == [10.25])
    #expect(try await run.times(of: .idleEnd) == [14.25])
    #expect(try await run.events(.idleEnd).first?.detail == nil)
    #expect(
      try await run.kept() == [
        Kept(at: 0.25, reason: .focusChange),
        Kept(at: 5.25, reason: .floor),
        // The floor fell due while idle, so it does not wait for focus to settle.
        Kept(at: 14.25, reason: .floor),
      ]
    )
    await run.end()
  }

  @Test func inputOlderThanTheThresholdAtLaunchIsIdleAtOnce() async throws {
    let run = try await SensingRun()
    run.input.setLastEvent(at: -60)
    await run.launch()
    #expect(await run.nextMode() == .idle)
    await run.advance(to: 10)
    #expect(run.screen.captures.isEmpty)
    #expect(try await run.times(of: .idleStart) == [0])
    await run.end()
  }

  // MARK: Keep and drop

  @Test(
    arguments: [
      (distance: 0, keeps: false),
      (distance: 4, keeps: false),
      (distance: 5, keeps: true),
    ]
  )
  func aFrameIsKeptOnlyPastTheThreshold(distance: Int, keeps: Bool) async throws {
    let run = try await SensingRun()
    run.screen.show(differingBits: 0)
    await run.launch()
    await run.advance(to: 1)
    run.screen.show(differingBits: distance)
    await run.advance(to: 5.25)
    #expect(try await run.observations().count == (keeps ? 2 : 1))
    // A dropped frame is never read.
    #expect(run.recognizer.levels.count == (keeps ? 2 : 1))
    let cadence = await run.nextCadence { $0.keptCount + $0.droppedCount == 2 }
    #expect(cadence?.droppedCount == (keeps ? 0 : 1))
    #expect(cadence?.lastDropDistance == (keeps ? nil : distance))
    await run.end()
  }

  @Test func eachFrameIsComparedWithTheLastOneKept() async throws {
    let run = try await SensingRun()
    run.screen.show(differingBits: 0)
    await run.launch()
    await run.advance(to: 1)
    run.screen.show(differingBits: 4)
    await run.advance(to: 6)
    run.screen.show(differingBits: 8)
    await run.advance(to: 10.25)
    // The last is 4 from the one dropped, but 8 from the one kept.
    #expect(try await run.kept().map(\.at) == [0.25, 10.25])
    await run.end()
  }

  enum ReadingChange: CaseIterable {
    case windowTitle
    case focusedText
  }

  @Test(arguments: ReadingChange.allCases)
  func theSameFrameIsKeptWhenWhatIsFocusedChanged(change: ReadingChange) async throws {
    let run = try await SensingRun()
    run.screen.show(differingBits: 0)
    await run.launch()
    await run.advance(to: 1)
    var window = FakeWindow.editor
    switch change {
    case .windowTitle: window.title = "plan.txt"
    case .focusedText: window.text += ", chapter two"
    }
    await run.focus.setReading(window)
    await run.advance(to: 5.25)
    #expect(try await run.kept().map(\.at) == [0.25, 5.25])
    await run.end()
  }

  @Test func clearingTheJournalKeepsTheNextFrameWhateverItShows() async throws {
    let run = try await SensingRun()
    run.screen.show(differingBits: 0)
    await run.launch()
    await run.advance(to: 1)
    try await run.loop.clearJournal()
    #expect(await run.nextEvent(.journalCleared) != nil)
    await run.advance(to: 5.25)
    #expect(try await run.kept() == [Kept(at: 5.25, reason: .floor)])
    await run.end()
  }

  @Test func aKeptCaptureIsJournaledAndPublishedWhole() async throws {
    let run = try await SensingRun()
    await run.launch()
    await run.advance(to: 1)
    await run.end()
    let journaled = try #require(try await run.observations().first)
    let observation = try #require(await run.publishedObservations().first)
    #expect(observation.id == journaled.id)
    #expect(observation.timestamp == SensingTestClock.start + 0.25)
    #expect(observation.focus.appName == "Editor")
    #expect(observation.focus.windowTitle == "notes.txt")
    #expect(observation.focus.focusedValue == "chapter one")
    #expect(observation.textBlocks == [FakeRecognizer.block])
    #expect(observation.frame.displayID == FakeScreen.displayID)
    #expect(observation.frame.screenRect == FakeScreen.display)
    #expect(observation.frame.width == PerceptualHash.gridColumns)
    #expect(observation.frame.height == PerceptualHash.gridRows)
    #expect(observation.frame.jpeg != nil)
    #expect(run.screen.captures.first?.windowFrame == FakeWindow.frame)
  }

  // MARK: What fails

  @Test func aFailedCaptureIsReportedAndReadsPermissionsAgain() async throws {
    let run = try await SensingRun()
    run.screen.fail(with: .noDisplays)
    await run.launch()
    await run.advance(to: 0.75)
    let failed = await run.nextCadence { $0.lastError != nil }
    #expect(failed?.lastError == "capture: no displays available to capture")
    #expect(run.permissions.readTimes == [0, 0.75])

    run.screen.fail(with: nil)
    await run.advance(to: 5.25)
    // The failed capture still counts for the cadence.
    #expect(try await run.kept() == [Kept(at: 5.25, reason: .floor)])
    let recovered = try #require(await run.nextCadence { $0.keptCount == 1 })
    #expect(recovered.lastError == nil)
    await run.end()
  }

  @Test func aFrameWhoseTextCannotBeReadIsKeptWithoutIt() async throws {
    let run = try await SensingRun()
    run.recognizer.fail()
    await run.launch()
    await run.advance(to: 0.25)
    let observation = try #require(try await run.observations().first)
    #expect(observation.textBlocks.isEmpty)
    let failed = await run.nextCadence { $0.lastError != nil }
    #expect(failed?.lastError == "ocr: unreadable")
    await run.end()
  }

  @Test func withNoFreshReadingTheLastFocusIsUsed() async throws {
    let run = try await SensingRun()
    await run.launch()
    await run.turn { await run.focus.activate(.browser) }
    await run.focus.setReading(nil)
    await run.advance(to: 0.25)
    #expect(try await run.observations().map(\.focus.appName) == ["Browser"])
    await run.end()
  }

  @Test func withNoFocusAtAllNothingIsCapturedAndTheLoopKeepsItsPace() async throws {
    let run = try await SensingRun(window: nil)
    await run.launch()
    await run.advance(to: 10)
    #expect(run.screen.captures.isEmpty)
    #expect(await run.focus.calls.filter { $0 == .readCurrent }.count == 2)
    await run.end()
  }

  // MARK: Mode

  @Test(
    arguments: [
      (screen: true, accessibility: true, mode: SensingMode.watching),
      (screen: true, accessibility: false, mode: .screenOnly),
      (screen: false, accessibility: true, mode: .accessibilityOnly),
      (screen: false, accessibility: false, mode: .waitingForPermissions),
    ]
  )
  func eachSetOfPermissionsHasItsMode(
    screen: Bool,
    accessibility: Bool,
    mode: SensingMode
  ) async throws {
    let run = try await SensingRun()
    run.permissions.grant(screenRecording: screen, accessibility: accessibility)
    await run.launch()
    #expect(await run.nextMode() == mode)
    await run.advance(to: 1)
    #expect(run.screen.captureTimes == (mode.capturesFrames ? [0.25] : []))
    await run.end()
  }

  @Test func eachModeOutranksTheOnesBelowIt() async throws {
    let run = try await SensingRun { settings in
      settings.idleThreshold = 10
      settings.floorInterval = 600
    }
    func readPermissions(screen: Bool, accessibility: Bool) async {
      run.permissions.grant(screenRecording: screen, accessibility: accessibility)
      await run.turn { await run.loop.permissionsMayHaveChanged() }
    }
    var refused = run.settings
    refused.withdrawConsent(at: SensingTestClock.start)
    let withdrawn = refused

    await run.launch()
    #expect(await run.nextMode() == .watching)
    await readPermissions(screen: true, accessibility: false)
    #expect(await run.nextMode() == .screenOnly)
    await run.advance(to: 11)
    #expect(await run.nextMode() == .idle)
    await run.turn { await run.focus.activate(.vault) }
    #expect(await run.nextMode() == .excluded)
    await readPermissions(screen: false, accessibility: false)
    #expect(await run.nextMode() == .waitingForPermissions)
    await run.turn { await run.loop.setPaused(true) }
    #expect(await run.nextMode() == .paused)
    await run.turn { await run.loop.updateSettings(withdrawn) }
    #expect(await run.nextMode() == .waitingForConsent)

    await run.turn { await run.loop.updateSettings(run.settings) }
    #expect(await run.nextMode() == .paused)
    await run.turn { await run.loop.setPaused(false) }
    #expect(await run.nextMode() == .waitingForPermissions)
    await readPermissions(screen: true, accessibility: false)
    // Focus starts afresh at the Allow, and none has been announced yet.
    #expect(await run.nextMode() == .idle)
    run.input.type()
    await readPermissions(screen: true, accessibility: false)
    #expect(await run.nextMode() == .screenOnly)
    await readPermissions(screen: false, accessibility: true)
    #expect(await run.nextMode() == .accessibilityOnly)
    await run.end()
  }

  @Test(
    arguments: [
      (resumeAt: 2.0, next: Kept(at: 2.25, reason: .focusChange)),
      (resumeAt: 20.0, next: Kept(at: 20, reason: .floor)),
    ]
  )
  func aResumeCapturesOnceSettledOrAtOnceWhenTheFloorIsOverdue(
    resumeAt: TimeInterval,
    next: Kept
  ) async throws {
    let run = try await SensingRun()
    await run.launch()
    #expect(await run.nextMode() == .watching)
    await run.advance(to: 1)
    await run.turn { await run.loop.setPaused(true) }
    #expect(await run.nextMode() == .paused)
    await run.loop.setPaused(true)
    await run.advance(to: resumeAt)
    #expect(run.screen.captureTimes == [0.25])
    await run.turn { await run.loop.setPaused(false) }
    #expect(await run.nextMode() == .watching)
    await run.advance(to: resumeAt + 0.25)
    #expect(try await run.kept() == [Kept(at: 0.25, reason: .focusChange), next])
    #expect(try await run.times(of: .paused) == [1])
    #expect(try await run.times(of: .resumed) == [resumeAt])
    await run.end()
  }

  // MARK: Focus and exclusion

  @Test func anAppSwitchIsJournaledForAnotherAppOrProcess() async throws {
    let run = try await SensingRun()
    await run.launch()
    await run.turn { await run.focus.activate(.browser) }
    await run.advance(to: 1)
    await run.turn { await run.focus.activate(.browser) }
    var relaunched = FakeWindow.browser
    relaunched.pid += 1
    let window = relaunched
    await run.advance(to: 2)
    await run.turn { await run.focus.activate(window) }
    let switches = try await run.events(.appSwitch)
    #expect(try await run.times(of: .appSwitch) == [0, 2])
    #expect(switches.map(\.appName) == ["Browser", "Browser"])
    #expect(switches.map(\.detail) == [nil, "from Browser"])
    await run.end()
  }

  @Test func aWindowSwitchIsJournaledAndCapturedOnceItSettles() async throws {
    let run = try await SensingRun()
    await run.launch()
    await run.advance(to: 2)
    var plan = FakeWindow.editor
    plan.title = "plan.txt"
    let window = plan
    await run.turn { await run.focus.activate(window, as: .window) }
    await run.advance(to: 2.25)
    #expect(try await run.times(of: .windowSwitch) == [2])
    #expect(try await run.events(.windowSwitch).first?.detail == "plan.txt")
    #expect(try await run.kept().last == Kept(at: 2.25, reason: .focusChange))
    await run.end()
  }

  @Test(arguments: [FocusChangeKind.window, .element])
  func aChangeWithinTheSameWindowIsPublishedButIsNoSwitch(kind: FocusChangeKind) async throws {
    let run = try await SensingRun()
    await run.launch()
    await run.advance(to: 1)
    await run.focus.activate(.editor, as: kind)
    let published = await run.nextFocus { $0.timestamp == SensingTestClock.start + 1 }
    #expect(published?.appName == "Editor")
    await run.advance(to: 5)
    #expect(run.screen.captureTimes == [0.25])
    #expect(try await run.events(.windowSwitch).isEmpty)
    #expect(try await run.events(.appSwitch).isEmpty)
    await run.end()
  }

  @Test func anExcludedAppIsNamedAndNeverCaptured() async throws {
    let run = try await SensingRun()
    await run.launch()
    #expect(await run.nextMode() == .watching)
    await run.advance(to: 1)
    await run.turn { await run.focus.activate(.vault) }
    #expect(await run.nextMode() == .excluded)
    let focus = try #require(await run.nextFocus { $0.isExcluded })
    #expect(focus.appName == "Vault")
    #expect(focus.windowTitle == nil)
    #expect(focus.focusedValue == nil)
    await run.advance(to: 4)
    await run.turn { await run.focus.activate(.vault) }
    await run.advance(to: 8)
    #expect(run.screen.captureTimes == [0.25])

    await run.turn { await run.focus.activate(.editor) }
    #expect(await run.nextMode() == .watching)
    await run.advance(to: 8.25)
    #expect(try await run.kept().last == Kept(at: 8, reason: .floor))
    #expect(try await run.times(of: .excluded) == [1])
    #expect(try await run.events(.appSwitch).map(\.detail) == ["from Editor", "from Vault"])
    await run.end()
  }

  @Test func anExcludedAppFoundByTheCapturesOwnReadIsNotCaptured() async throws {
    let run = try await SensingRun(window: .vault)
    await run.launch()
    #expect(await run.nextMode() == .watching)
    await run.advance(to: 0.75)
    #expect(await run.nextMode() == .excluded)
    #expect(run.screen.captures.isEmpty)
    await run.end()
  }

  @Test func excludingTheAppInFrontReachesTheTrackerAndStopsItsCaptures() async throws {
    let run = try await SensingRun()
    await run.launch()
    await run.advance(to: 1)
    var changed = run.settings
    changed.excludedBundleIDs = ["COM.Example.Editor"]
    let settings = changed
    await run.turn { await run.loop.updateSettings(settings) }
    #expect(await run.focus.calls.contains(.updateExcluded(["com.example.editor"])))
    await run.advance(to: 6)
    #expect(run.screen.captureTimes == [0.25])
    await run.end()
  }

  enum Stage: CaseIterable {
    case screenshot
    case recognition
  }

  enum Interruption: CaseIterable {
    case anotherAppInFront
    case noAppInFront
    case excludedInSettings
    case excludedAppAnnounced
  }

  @Test(arguments: Stage.allCases, Interruption.allCases)
  func aCaptureIsDiscardedWhenItsAppIsExcludedOrNoLongerInFront(
    stage: Stage,
    interruption: Interruption
  ) async throws {
    let run = try await SensingRun()
    await run.launch()
    let held = stage == .screenshot ? run.screen.holdNext() : run.recognizer.holdNext()
    run.elapse(to: 0.25)
    await held.waitUntilReached()
    switch interruption {
    case .anotherAppInFront:
      await run.focus.bringForward(.browser)
    case .noAppInFront:
      await run.focus.bringForward(nil)
    case .excludedInSettings:
      var settings = run.settings
      settings.excludedBundleIDs.append(FakeWindow.editor.bundleID)
      await run.loop.updateSettings(settings)
    case .excludedAppAnnounced:
      // Announced while the app captured is still the one in front.
      await run.focus.notify(.vault)
      #expect(await run.nextEvent(.excluded) != nil)
    }
    await run.turn { held.release() }
    #expect(try await run.observations().isEmpty)
    #expect(run.recognizer.levels.count == (stage == .screenshot ? 0 : 1))
    await run.end()
    #expect(await run.publishedObservations().isEmpty)
  }

  // MARK: Permissions

  @Test func permissionsAreReadEveryTwoSeconds() async throws {
    let run = try await SensingRun()
    run.permissions.grant(screenRecording: false, accessibility: false)
    await run.launch()
    await run.advance(to: 6)
    #expect(run.permissions.readTimes == [0, 2, 4, 6])
    await run.end()
  }

  @Test func permissionsAreReadAtOnceWhenTheyMayHaveChanged() async throws {
    let run = try await SensingRun()
    run.permissions.grant(screenRecording: false, accessibility: false)
    await run.launch()
    await run.advance(to: 0.5)
    await run.turn { await run.loop.permissionsMayHaveChanged() }
    await run.advance(to: 3)
    #expect(run.permissions.readTimes == [0, 0.5, 2.5])
    await run.end()
  }

  @Test func permissionsAreStillReadWhilePaused() async throws {
    let run = try await SensingRun()
    await run.loop.setPaused(true)
    await run.launch()
    await run.advance(to: 4)
    #expect(run.permissions.readTimes == [0, 2, 4])
    await run.end()
  }

  @Test func aChangeOfPermissionsIsJournaledIncludingLosingTheLast() async throws {
    let run = try await SensingRun()
    run.permissions.grant(screenRecording: false, accessibility: false)
    await run.launch()
    await run.advance(to: 1)
    run.permissions.grant(screenRecording: true, accessibility: false)
    await run.turn { await run.loop.permissionsMayHaveChanged() }
    #expect(
      await run.nextEvent(.permissionsChanged)?.detail
        == "screen granted, accessibility denied, microphone denied, speech denied"
    )
    run.permissions.grant(screenRecording: false, accessibility: false)
    await run.turn { await run.loop.permissionsMayHaveChanged() }
    #expect(
      await run.nextEvent(.permissionsChanged)?.detail
        == "screen denied, accessibility denied, microphone denied, speech denied"
    )
    // None at launch, when there was none to lose and none to gain.
    #expect(try await run.times(of: .permissionsChanged) == [1, 1])
    await run.end()
  }

  @Test func onlyAChangeOfAccessibilityRefreshesTheObserver() async throws {
    let run = try await SensingRun()
    await run.launch()
    await run.focus.waitForRefreshes(1)
    #expect(await run.nextEvent(.permissionsChanged) != nil)
    run.permissions.grant(screenRecording: false, accessibility: true)
    await run.turn { await run.loop.permissionsMayHaveChanged() }
    #expect(await run.nextEvent(.permissionsChanged) != nil)
    run.permissions.grant(screenRecording: false, accessibility: false)
    await run.turn { await run.loop.permissionsMayHaveChanged() }
    await run.focus.waitForRefreshes(1)
    #expect(await run.focus.calls.filter { $0 == .refreshObserver }.count == 2)
    await run.end()
  }

  // MARK: Retention

  enum RetentionState: CaseIterable {
    case watching
    case paused
    case idle
    case waitingForConsent
  }

  @Test(arguments: RetentionState.allCases)
  func retentionRunsAtStartAndAtEachIntervalInEveryState(state: RetentionState) async throws {
    let run = try await SensingRun { settings in
      settings.retentionInterval = 30
      if state == .waitingForConsent { settings.consent = nil }
    }
    if state == .paused { await run.loop.setPaused(true) }
    if state == .idle { run.input.setLastEvent(at: -120) }
    try await journalExpiredEvent(in: run)
    await run.launch()
    #expect(try await run.times(of: .retention) == [0])
    #expect(
      try await run.events(.retention).first?.detail
        == "removed 0 thumbnails, 0 observations, 1 events"
    )

    try await journalExpiredEvent(in: run)
    await run.advance(to: 29.75)
    #expect(try await run.times(of: .retention) == [0])
    await run.advance(to: 32)
    // It runs on the first turn at or past the interval, and a watching
    // loop's turns follow its capture a quarter of a second in.
    let secondRun = state == .watching ? 30.25 : 30
    #expect(try await run.times(of: .retention) == [0, secondRun])
    #expect(try await run.events(.windowSwitch).isEmpty)
    await run.end()
  }

  @Test func aShorterRetentionIntervalTakesEffectAtOnce() async throws {
    let run = try await SensingRun { $0.consent = nil }
    await run.launch()
    try await journalExpiredEvent(in: run)
    await run.advance(to: 100)
    #expect(try await run.events(.retention).isEmpty)
    var changed = run.settings
    changed.retentionInterval = 60
    let settings = changed
    await run.turn { await run.loop.updateSettings(settings) }
    #expect(try await run.times(of: .retention) == [100])
    await run.end()
  }

  private func journalExpiredEvent(in run: SensingRun) async throws {
    let expired = run.clock.date - run.settings.textRetention - 60
    try await run.journal.record(JournalEvent(timestamp: expired, kind: .windowSwitch))
  }

  // MARK: Consent

  @Test func withoutConsentNothingIsSensed() async throws {
    let run = try await SensingRun { $0.consent = nil }
    await run.launch()
    #expect(await run.nextMode() == .waitingForConsent)
    await run.loop.captureNow()
    await run.advance(to: 20)
    #expect(run.screen.captures.isEmpty)
    #expect(run.recognizer.levels.isEmpty)
    #expect(run.input.readCount == 0)
    #expect(run.permissions.readTimes.isEmpty)
    #expect(
      await run.focus.calls == [
        .updateExcluded([FakeWindow.vault.bundleID]),
        .setHandler(isSet: true),
      ]
    )
    #expect(try await run.events().map(\.kind) == [.started])
    #expect(run.wakesAt == 22)
    await run.end()
  }

  @Test func allowingStartsSensingWithoutACaptureAskedForBeforeIt() async throws {
    let run = try await SensingRun { $0.consent = nil }
    await run.launch()
    #expect(await run.nextMode() == .waitingForConsent)
    await run.loop.captureNow()
    await run.advance(to: 4)
    // The click on Allow is input.
    run.input.type()
    let allowed = SensingRun.defaultSettings
    await run.turn { await run.loop.updateSettings(allowed) }
    #expect(await run.nextMode() == .watching)
    #expect(await run.focus.calls.contains(.start))
    await run.advance(to: 4.25)
    #expect(try await run.kept() == [Kept(at: 4.25, reason: .focusChange)])
    await run.end()
  }

  @Test func afterAWithdrawalBetweenCapturesNoSenseIsReadAgain() async throws {
    let run = try await SensingRun { $0.idleThreshold = 5 }
    await run.launch()
    // Both follow the first permission reading; after them nothing is owed.
    await run.focus.waitForRefreshes(1)
    #expect(await run.nextEvent(.permissionsChanged) != nil)
    await run.advance(to: 1)
    var refused = run.settings
    refused.withdrawConsent(at: run.clock.date)
    let withdrawn = refused
    await run.turn { await run.loop.updateSettings(withdrawn) }

    let focusCalls = await run.focus.calls
    let inputReads = run.input.readCount
    let permissionReads = run.permissions.readTimes
    #expect(focusCalls.last == .stop)
    run.permissions.grant(screenRecording: false, accessibility: false)
    await run.loop.captureNow()
    await run.advance(to: 30)
    #expect(await run.focus.calls == focusCalls)
    #expect(run.input.readCount == inputReads)
    #expect(run.permissions.readTimes == permissionReads)
    #expect(run.screen.captureTimes == [0.25])
    #expect(try await run.events(.idleStart).isEmpty)
    await run.end()
  }

  @Test(arguments: Stage.allCases)
  func withdrawingConsentStopsACaptureInFlight(stage: Stage) async throws {
    let run = try await SensingRun()
    await run.launch()
    #expect(await run.nextMode() == .watching)
    let held = stage == .screenshot ? run.screen.holdNext() : run.recognizer.holdNext()
    run.elapse(to: 0.25)
    await held.waitUntilReached()
    var withdrawn = run.settings
    withdrawn.withdrawConsent(at: run.clock.date)
    await run.loop.updateSettings(withdrawn)
    // Said while the capture is still out.
    #expect(await run.nextMode() == .waitingForConsent)
    #expect(await run.focus.calls.contains(.stop))

    await run.turn { held.release() }
    await run.advance(to: 30)
    // The app captured is still in front, so only the withdrawal keeps it out.
    #expect(try await run.observations().isEmpty)
    #expect(run.screen.captureTimes == [0.25])
    #expect(run.recognizer.levels.count == (stage == .screenshot ? 0 : 1))
    await run.end()
    #expect(await run.publishedObservations().isEmpty)
  }

  @Test func aFocusChangeSentBeforeTheTrackerStoppedIsIgnored() async throws {
    let run = try await SensingRun()
    await run.launch()
    var refused = run.settings
    refused.withdrawConsent(at: run.clock.date)
    let withdrawn = refused
    await run.turn { await run.loop.updateSettings(withdrawn) }
    await run.focus.activate(.vault)
    await run.advance(to: 10)
    #expect(try await run.events(.appSwitch).isEmpty)
    #expect(try await run.events(.excluded).isEmpty)
    await run.end()
  }

  // MARK: Start, stop, and a hermetic run

  @Test func startingTwiceStartsOneLoop() async throws {
    let run = try await SensingRun()
    await run.launch()
    await run.loop.start()
    #expect(try await run.times(of: .started) == [0])
    #expect(await run.focus.calls.filter { $0 == .start }.count == 1)
    await run.end()
  }

  @Test func stoppingEndsTrackingAndEveryStream() async throws {
    let run = try await SensingRun()
    await run.launch()
    await run.advance(to: 1)
    await run.end()
    #expect(await run.focus.calls.suffix(2) == [.stop, .setHandler(isSet: false)])
    #expect(try await run.times(of: .stopped) == [1])
    // Returns only because the stream ended.
    let published = await run.published()
    #expect(!published.isEmpty)
  }

  @Test func aHermeticRunCallsNoneOfItsSenses() async throws {
    let run = try await SensingRun(source: .hermetic)
    await run.launch()
    #expect(await run.nextMode() == .watching)
    await run.turn { await run.loop.captureNow() }
    await run.advance(to: 10)
    #expect(run.screen.captures.isEmpty)
    #expect(run.recognizer.levels.isEmpty)
    #expect(run.input.readCount == 0)
    #expect(run.permissions.readTimes.isEmpty)
    #expect(await run.focus.calls.isEmpty)
    await run.end()
  }
}
