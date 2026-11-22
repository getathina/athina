import Foundation
import Synchronization

/// Where the pipeline's senses come from.
public enum SensingSource: Sendable {
  /// The senses the pipeline was created with, which are the Mac's own unless
  /// it was given others: focus, input, permissions, and the screen.
  case system
  /// Nothing real, for a hermetic run (`ControlMode.isHermetic`): no focus
  /// tracking, no read of input or permissions, and no capture, so the run
  /// journals nothing of the screen of whoever is at the Mac and never asks
  /// macOS for a permission. Every permission reads as granted and input as
  /// recent, so the pipeline is in the mode a person using the app sees,
  /// watching, until it is paused. What it senses is only what is scripted:
  /// the window in front and what it shows (`observe(_:)`), and whether
  /// input has gone idle (`setScriptedIdle(_:)`).
  case hermetic
}

/// Orchestrates focus tracking, input polling, screen capture, frame diffing,
/// OCR, and journaling, and publishes `SensingEvent`s to subscribers.
///
/// Until the settings carry the person's consent (`SensingSettings.hasConsent`)
/// the pipeline stays in `waitingForConsent`: focus tracking is not started, and
/// no input, idle, permission, focus, or capture is read or journaled. Only
/// retention runs, so what an earlier consent let in still ages out. Settings
/// that withdraw consent stop all of that at once, a capture in flight included.
///
/// A withdrawal, Pause and Delete Everything each end every capture begun
/// before it (`CaptureGeneration`): such a capture starts no screen capture or
/// text recognition from then on, and its frame is neither kept in the journal
/// nor published, whatever follows.
public actor SensingPipeline {
  /// The sensing settings in effect: those it was created with, until
  /// `updateSettings(_:)` replaces them with validated ones.
  public private(set) var settings: SensingSettings
  private let journal: Journal
  private let tracker: any FocusTracking
  private let source: SensingSource
  private let capturer: any ScreenCapturing
  private let recognizer: any TextRecognizing
  private let inputActivity: any InputActivityReading
  private let permissionReader: any PermissionReading
  private let broadcaster = EventBroadcaster<SensingEvent>()
  /// Every date the pipeline stamps and every cadence it waits out.
  private let clock: any AthinaClock
  private let signal: AsyncSignal

  private var scheduler: CaptureScheduler
  private let captures = CaptureGeneration()
  private var loopTask: Task<Void, Never>?
  private var userPaused = false
  private var isIdle = false
  private var permissions = PermissionStatus(screenRecording: false, accessibility: false)
  private var permissionsCheckedAt: Date = .distantPast
  private var retentionRanAt: Date = .distantPast
  private var mode: SensingMode = .stopped
  private var cadence = CadenceStatus()
  private var lastFocus: FocusContext?
  /// The system uptime of the last input event seen, to tell a new one apart.
  private var lastInputUptime: TimeInterval?
  private var lastKept: (hash: PerceptualHash, windowSignature: String, textSignature: String)?
  private var lastPublishedCadence: Date = .distantPast
  private var lastPublishedSnapshot: CadenceStatus?

  /// Creates a stopped pipeline over this Mac's senses that journals into
  /// `journal`, follows focus with `tracker`, and stamps and paces everything
  /// on `clock`.
  public init(
    settings: SensingSettings,
    journal: Journal,
    tracker: FocusTracker,
    clock: any AthinaClock,
    source: SensingSource = .system
  ) {
    self.init(
      settings: settings,
      journal: journal,
      capturer: ScreenCapturer(),
      recognizer: TextRecognizer(),
      tracker: tracker,
      input: SystemInputActivity(),
      permissions: SystemPermissions(),
      clock: clock,
      source: source
    )
  }

  /// Creates a stopped pipeline over exactly the senses it is given.
  ///
  /// None has a default, so a test that passes fakes cannot sense this Mac by
  /// leaving one out.
  public init(
    settings: SensingSettings,
    journal: Journal,
    capturer: any ScreenCapturing,
    recognizer: any TextRecognizing,
    tracker: any FocusTracking,
    input: any InputActivityReading,
    permissions permissionReader: any PermissionReading,
    clock: any AthinaClock,
    source: SensingSource
  ) {
    self.settings = settings
    self.journal = journal
    self.capturer = capturer
    self.recognizer = recognizer
    self.tracker = tracker
    inputActivity = input
    self.permissionReader = permissionReader
    self.source = source
    if source == .hermetic {
      permissions = PermissionStatus(
        screenRecording: true,
        accessibility: true,
        microphone: true,
        speechRecognition: true
      )
    }
    self.clock = clock
    signal = AsyncSignal(clock: clock)
    self.scheduler = CaptureScheduler(settings: settings)
  }

  // MARK: Subscription

  /// Every subscriber gets every event from the moment it subscribes.
  public func events() async -> AsyncStream<SensingEvent> {
    await broadcaster.subscribe()
  }

  /// What publishes the events, internal so a test can hold a publish in
  /// flight.
  var publisher: EventBroadcaster<SensingEvent> { broadcaster }

  // MARK: Control

  /// Starts focus tracking and the sensing loop, and journals a `started`
  /// event; does nothing when already started.
  public func start() async {
    guard loopTask == nil else { return }
    if source == .system {
      await tracker.updateExcluded(settings.excludedBundleIDSet)
      await tracker.setOnChange { [weak self] change in
        guard let self else { return }
        Task { await self.focusDidChange(change) }
      }
      if settings.hasConsent { await tracker.start() }
    }
    await journalEvent(JournalEvent(timestamp: clock.date, kind: .started))
    loopTask = Task { [weak self] in
      await self?.runLoop()
    }
  }

  /// Stops the sensing loop and focus tracking, journals a `stopped` event,
  /// and ends every subscriber's stream.
  public func stop() async {
    loopTask?.cancel()
    loopTask = nil
    await tracker.stop()
    await tracker.setOnChange(nil)
    await journalEvent(JournalEvent(timestamp: clock.date, kind: .stopped))
    setMode(.stopped)
    await broadcaster.finish()
  }

  /// Pauses or resumes sensing at the owner's request, journaling a `paused`
  /// or `resumed` event when that changes anything.
  ///
  /// A pause ends a capture in flight, even one sensing resumes during.
  public func setPaused(_ paused: Bool) async {
    guard paused != userPaused else { return }
    userPaused = paused
    if paused { captures.end() }
    await journalEvent(JournalEvent(timestamp: clock.date, kind: paused ? .paused : .resumed))
    await signal.signal()
  }

  /// Validates and applies new sensing settings, including the excluded
  /// apps, and wakes the loop so they take effect at once.
  public func updateSettings(_ newSettings: SensingSettings) async {
    let validated = newSettings.validated()
    let consentChanged = validated.hasConsent != settings.hasConsent
    settings = validated
    if consentChanged, !validated.hasConsent { captures.end() }
    scheduler.settings = validated
    await tracker.updateExcluded(validated.excludedBundleIDSet)
    if consentChanged, loopTask != nil {
      if validated.hasConsent {
        if source == .system { await tracker.start() }
      } else {
        if source == .system { await tracker.stop() }
        lastFocus = nil
        // Said now rather than on the loop's next turn, so everything
        // listening stops with it.
        setMode(.waitingForConsent)
        scheduler.setActive(false, at: clock.date)
      }
    }
    await signal.signal()
  }

  /// Captures as soon as the loop wakes, regardless of cadence.
  public func captureNow() async {
    guard settings.hasConsent else { return }
    scheduler.requestManualCapture(at: clock.date)
    await signal.signal()
  }

  /// Senses `scripted` as the window in front, in a hermetic pipeline, the
  /// way the live one senses a real window: an app or window switch is
  /// journaled as one, an excluded app is read no further than its name, and
  /// a capture is taken at once, as one after a switch or after typing is,
  /// and kept or dropped as a capture of the screen is. `.notScripted` when
  /// the pipeline senses the real Mac.
  public func observe(_ scripted: ScriptedObservation) async -> ScriptedOutcome {
    guard source == .hermetic else { return .notScripted }
    guard settings.hasConsent else {
      return .notKept(
        "sensing is \(SensingMode.waitingForConsent.rawValue), which captures nothing"
      )
    }
    let now = clock.date
    let stands = captures.begin()
    let focus = scripted.focus(at: now, excluded: settings.isExcluded(bundleID: scripted.bundleID))
    let previous = lastFocus
    if previous?.bundleID != focus.bundleID {
      await focusDidChange(FocusChange(kind: .application, context: focus))
    } else if previous?.windowSignature != focus.windowSignature {
      await focusDidChange(FocusChange(kind: .window, context: focus))
    } else {
      lastFocus = focus
      await broadcaster.send(.focusChanged(focus))
    }
    let mode = computeMode()
    setMode(mode)
    guard mode.capturesFrames else {
      return .notKept("sensing is \(mode.rawValue), which captures nothing")
    }
    let reason: CaptureReason =
      lastKept?.windowSignature == focus.windowSignature ? .inputSettled : .focusChange
    guard let (image, blocks) = scripted.frame(maxDimension: settings.maxFrameDimension),
      let hash = FrameImaging.perceptualHash(of: image)
    else {
      cadence.lastError = "capture: could not draw the scripted frame"
      return .notKept("the scripted frame could not be drawn")
    }
    let verdict = keepVerdict(hash: hash, focus: focus)
    defer { publishCadence(now: clock.date) }
    guard verdict.keep else {
      cadence.droppedCount += 1
      cadence.lastDropDistance = verdict.distance
      return .notKept(verdict.reason)
    }
    let frame = CapturedFrame(image: image, displayID: 0, screenRect: ScriptedObservation.display)
    let kept = await journalCapture(
      frame,
      hash: hash,
      blocks: blocks,
      focus: focus,
      reason: reason,
      at: now,
      while: stands
    )
    guard let kept else {
      return .notKept("sensing was paused, withdrawn or cleared during the capture")
    }
    return .kept(kept)
  }

  /// Senses input going idle, or coming back, in a hermetic pipeline.
  ///
  /// It stands in for the live pipeline noticing that no input has come for
  /// the idle threshold, or that some has. False when the pipeline senses the
  /// real Mac.
  public func setScriptedIdle(_ idle: Bool) async -> Bool {
    guard source == .hermetic else { return false }
    await setIdle(idle, detail: idle ? "no input (scripted)" : nil)
    setMode(computeMode())
    return true
  }

  /// Call when the permissions page sees a change so the loop reacts at once.
  public func permissionsMayHaveChanged() async {
    permissionsCheckedAt = .distantPast
    await signal.signal()
  }

  /// Deletes everything in the journal, leaving one `journalCleared` event,
  /// and publishes that event.
  ///
  /// A capture begun before it finishes is not kept. The next frame captured
  /// is kept whatever it looks like, since there is no earlier frame left to
  /// compare it with.
  public func clearJournal() async throws {
    captures.end()
    try await journal.clear(at: clock.date)
    captures.end()
    lastKept = nil
    if let cleared = try? await journal.recentEvents(limit: 1).first {
      await broadcaster.send(.event(cleared))
    }
  }

  // MARK: Focus

  private func focusDidChange(_ change: FocusChange) async {
    // A change the tracker sent just before it was stopped.
    guard settings.hasConsent else { return }
    let previous = lastFocus
    lastFocus = change.context
    await broadcaster.send(.focusChanged(change.context))

    switch change.kind {
    case .application:
      if previous?.bundleID != change.context.bundleID || previous?.pid != change.context.pid {
        await journalEvent(
          JournalEvent(
            timestamp: clock.date,
            kind: .appSwitch,
            bundleID: change.context.bundleID,
            appName: change.context.appName,
            detail: previous.map { "from \($0.appName)" }
          )
        )
      }
      if change.context.isExcluded, previous?.isExcluded != true {
        await journalEvent(
          JournalEvent(
            timestamp: clock.date,
            kind: .excluded,
            bundleID: change.context.bundleID,
            appName: change.context.appName
          )
        )
      }
      scheduler.noteFocusChange(at: clock.date)
      await signal.signal()
    case .window:
      if previous?.windowSignature != change.context.windowSignature {
        await journalEvent(
          JournalEvent(
            timestamp: clock.date,
            kind: .windowSwitch,
            bundleID: change.context.bundleID,
            appName: change.context.appName,
            detail: change.context.windowTitle
          )
        )
        scheduler.noteFocusChange(at: clock.date)
        await signal.signal()
      }
    case .element:
      break
    }
  }

  // MARK: Loop

  private func runLoop() async {
    while !Task.isCancelled {
      let now = clock.date
      await runRetentionIfDue(now: now)
      guard settings.hasConsent else {
        setMode(.waitingForConsent)
        scheduler.setActive(false, at: now)
        publishCadence(now: now)
        await signal.wait(for: .seconds(settings.idlePollInterval))
        continue
      }
      if source == .hermetic {
        // Only the person's own choices move a hermetic pipeline:
        // pausing, and the settings.
        setMode(computeMode())
        await signal.wait(for: .seconds(settings.idlePollInterval))
        continue
      }
      refreshPermissionsIfDue(now: now)

      // The system counts real seconds since the last event, so a new event is told
      // apart in real time, which a replay's faster or moved clock does not change.
      // The counter only says how long ago the last event was, so its time jitters by
      // milliseconds from poll to poll; a new event moves it by far more.
      let realSecondsSinceInput = inputActivity.secondsSinceLastInput()
      let inputUptime = inputActivity.systemUptime() - realSecondsSinceInput
      // How long ago that was, and the idle threshold, are read on the app's clock.
      let secondsSinceInput = realSecondsSinceInput * clock.rate
      if lastInputUptime.map({ inputUptime - $0 > 0.25 }) ?? true {
        lastInputUptime = inputUptime
        let inputAt = now.addingTimeInterval(-secondsSinceInput)
        cadence.lastInputAt = inputAt
        scheduler.noteInput(at: inputAt)
      }
      await updateIdle(secondsSinceInput: secondsSinceInput)

      let newMode = computeMode()
      setMode(newMode)
      scheduler.setActive(newMode.capturesFrames, at: now)

      var waitFor = newMode == .idle ? settings.idlePollInterval : settings.inputPollInterval
      switch scheduler.evaluate(now: now) {
      case .capture(let reason):
        await performCapture(reason: reason)
        waitFor = min(waitFor, settings.minCaptureInterval)
      case .wait(let until):
        if let until {
          waitFor = min(waitFor, max(0.01, until.timeIntervalSince(now)))
        }
      }
      publishCadence(now: now)
      await signal.wait(for: .seconds(waitFor))
    }
  }

  private func refreshPermissionsIfDue(now: Date) {
    guard now.timeIntervalSince(permissionsCheckedAt) >= 2 else { return }
    permissionsCheckedAt = now
    let fresh = permissionReader.current()
    if fresh != permissions {
      let hadAny = permissions.anyGranted
      let accessibilityChanged = fresh.accessibility != permissions.accessibility
      permissions = fresh
      if accessibilityChanged {
        Task { await tracker.refreshObserver() }
      }
      if hadAny || fresh.anyGranted {
        Task {
          await journalEvent(
            JournalEvent(
              timestamp: now,
              kind: .permissionsChanged,
              detail:
                """
                screen \(fresh.screenRecording ? "granted" : "denied"), accessibility \
                \(fresh.accessibility ? "granted" : "denied"), microphone \
                \(fresh.microphone ? "granted" : "denied"), speech \
                \(fresh.speechRecognition ? "granted" : "denied")
                """
            )
          )
        }
      }
    }
  }

  private func runRetentionIfDue(now: Date) async {
    guard now.timeIntervalSince(retentionRanAt) >= settings.retentionInterval else { return }
    retentionRanAt = now
    do {
      let result = try await journal.applyRetention(RetentionPolicy(settings: settings), now: now)
      if result.deletedAnything {
        var detail =
          """
          removed \(result.thumbnailsDeleted) thumbnails, \(result.observationsDeleted) \
          observations, \(result.eventsDeleted) events
          """
        if result.suggestionsDeleted + result.modelCallsDeleted > 0 {
          detail +=
            ", \(result.suggestionsDeleted) suggestions, \(result.modelCallsDeleted) model calls"
        }
        await journalEvent(JournalEvent(timestamp: now, kind: .retention, detail: detail))
      }
    } catch {
      cadence.lastError = "retention: \(error)"
    }
  }

  private func updateIdle(secondsSinceInput: TimeInterval) async {
    let nowIdle = secondsSinceInput >= settings.idleThreshold
    await setIdle(nowIdle, detail: nowIdle ? "no input for \(Int(secondsSinceInput))s" : nil)
  }

  private func setIdle(_ nowIdle: Bool, detail: String?) async {
    guard nowIdle != isIdle else { return }
    isIdle = nowIdle
    await journalEvent(
      JournalEvent(timestamp: clock.date, kind: nowIdle ? .idleStart : .idleEnd, detail: detail)
    )
  }

  private func computeMode() -> SensingMode {
    SensingMode.resolve(
      consented: settings.hasConsent,
      paused: userPaused,
      permissions: permissions,
      frontmostExcluded: lastFocus?.isExcluded ?? false,
      idle: isIdle
    )
  }

  private func setMode(_ newMode: SensingMode) {
    guard newMode != mode else { return }
    mode = newMode
    cadence.mode = newMode
    Task { await broadcaster.send(.modeChanged(newMode)) }
  }

  private func publishCadence(now: Date) {
    let next = scheduler.nextDue(now: now)
    cadence.nextDueAt = next?.at
    cadence.nextDueReason = next?.reason
    cadence.lastCaptureAt = scheduler.lastCaptureAt
    guard cadence != lastPublishedSnapshot, now.timeIntervalSince(lastPublishedCadence) >= 0.2
    else { return }
    lastPublishedCadence = now
    lastPublishedSnapshot = cadence
    let snapshot = cadence
    Task { await broadcaster.send(.cadence(snapshot)) }
  }

  // MARK: Capture

  private func performCapture(reason: CaptureReason) async {
    let startedAt = clock.date
    defer { scheduler.noteCaptureFinished(startedAt: startedAt, at: clock.date) }
    let stands = captures.begin()

    let focus: FocusContext
    if let fresh = await tracker.readCurrent() {
      guard stands() else { return }
      focus = fresh
      lastFocus = fresh
      await broadcaster.send(.focusChanged(fresh))
    } else if let lastFocus {
      focus = lastFocus
    } else {
      return
    }
    guard !focus.isExcluded, stands() else { return }

    let frame: CapturedFrame
    do {
      frame = try await capturer.capture(
        windowFrame: focus.windowFrame,
        maxDimension: settings.maxFrameDimension
      )
      cadence.lastError = nil
    } catch {
      cadence.lastError = "capture: \(error)"
      permissionsCheckedAt = .distantPast
      return
    }
    // The user may have switched apps, possibly to an excluded one, while the
    // screenshot was in flight. `lastFocus` lags behind the activation
    // notification, so the live frontmost app is checked as well.
    guard await mayGoOn(with: focus, while: stands) else { return }

    guard let hash = FrameImaging.perceptualHash(of: frame.image) else {
      cadence.lastError = "capture: could not hash frame"
      return
    }
    let verdict = keepVerdict(hash: hash, focus: focus)
    guard verdict.keep else {
      cadence.droppedCount += 1
      cadence.lastDropDistance = verdict.distance
      return
    }

    var blocks: [TextBlock] = []
    do {
      blocks = try await recognizer.recognize(frame, level: settings.ocrLevel)
    } catch {
      cadence.lastError = "ocr: \(error)"
    }
    // Checked again here: OCR can take hundreds of milliseconds, and this is
    // the last point before the frame and its text head for the journal.
    guard await mayGoOn(with: focus, while: stands) else { return }
    await journalCapture(
      frame,
      hash: hash,
      blocks: blocks,
      focus: focus,
      reason: reason,
      at: startedAt,
      while: stands
    )
  }

  /// Whether a frame with `hash` of `focus` is kept, against the frame kept last.
  private func keepVerdict(hash: PerceptualHash, focus: FocusContext) -> FrameKeepPolicy.Verdict {
    FrameKeepPolicy.decide(
      distance: lastKept.map { $0.hash.distance(to: hash) },
      threshold: settings.hashDistanceThreshold,
      windowChanged: lastKept.map { $0.windowSignature != focus.windowSignature } ?? true,
      textChanged: lastKept.map { $0.textSignature != focus.textSignature } ?? true
    )
  }

  /// Journals a kept frame and the text read from it, and publishes it, while
  /// the capture stands.
  ///
  /// Returns nil when it stopped standing first, leaving nothing of it behind:
  /// the journal and the broadcaster each ask as they act, and a row written
  /// just before is taken out again.
  @discardableResult
  private func journalCapture(
    _ frame: CapturedFrame,
    hash: PerceptualHash,
    blocks: [TextBlock],
    focus: FocusContext,
    reason: CaptureReason,
    at startedAt: Date,
    while stands: @Sendable () -> Bool
  ) async -> ActivityObservation? {
    let jpeg = FrameImaging.jpegData(from: frame.image, quality: settings.thumbnailJPEGQuality)
    let info = FrameInfo(
      hash: hash,
      width: frame.image.width,
      height: frame.image.height,
      displayID: frame.displayID,
      screenRect: frame.screenRect,
      jpeg: jpeg
    )
    var observation = ActivityObservation(
      timestamp: startedAt,
      focus: focus,
      frame: info,
      textBlocks: blocks,
      reason: reason
    )
    do {
      guard let stored = try await journal.record(observation, while: stands) else { return nil }
      observation = stored
    } catch {
      cadence.lastError = "journal: \(error)"
    }
    guard await broadcaster.send(.observation(observation), while: stands) else {
      do {
        try await journal.discard(observation)
      } catch {
        cadence.lastError = "journal: \(error)"
      }
      return nil
    }
    // A clear since it was published leaves nothing to compare the next frame with.
    if stands() { lastKept = (hash, focus.windowSignature, focus.textSignature) }
    cadence.keptCount += 1
    cadence.lastCaptureAt = startedAt
    cadence.lastCaptureReason = reason
    return observation
  }

  /// Whether a capture of `focus` may take its next step: it stands, and
  /// still does once the app in front has been read and is unchanged.
  private func mayGoOn(
    with focus: FocusContext,
    while stands: @Sendable () -> Bool
  ) async -> Bool {
    guard stands(), lastFocus?.isExcluded != true, await frontmostIsStill(focus) else {
      return false
    }
    return stands()
  }

  private func frontmostIsStill(_ focus: FocusContext) async -> Bool {
    guard let front = await tracker.frontmostApplication() else { return false }
    return front.pid == focus.pid && !settings.isExcluded(bundleID: front.bundleID)
  }

  private func journalEvent(_ event: JournalEvent) async {
    var stored = event
    do {
      stored = try await journal.record(event)
    } catch {
      cadence.lastError = "journal: \(error)"
    }
    await broadcaster.send(.event(stored))
  }
}

/// Tells a capture begun before Pause, a withdrawal or Delete Everything from
/// one begun after it.
///
/// It is read from any actor, so the journal and the broadcaster can ask at
/// the moment they act rather than when they were called.
private final class CaptureGeneration: Sendable {
  private let generation = Atomic(0)

  /// Ends every capture begun so far, for good.
  func end() {
    generation.wrappingAdd(1, ordering: .sequentiallyConsistent)
  }

  /// Returns a check of whether a capture begun now still stands.
  func begin() -> @Sendable () -> Bool {
    let begun = generation.load(ordering: .sequentiallyConsistent)
    return { self.generation.load(ordering: .sequentiallyConsistent) == begun }
  }
}
