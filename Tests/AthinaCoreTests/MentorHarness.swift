import Foundation

@testable import AthinaCore

/// A mentor loop under test: all that the loop suites send it and read back.
///
/// An implementation supplies only the loop. Making one, sending it screens
/// and waiting on what it publishes are the extensions below, so every
/// implementation is held to the same waits and the same test bodies.
protocol MentorHarness<Client>: Sendable {
  /// The client behind the loop, typed so a test can script it and count its calls.
  associatedtype Client: ClaudeClient

  var journal: Journal { get }
  var client: Client { get }
  var keyStore: any KeyStore { get }
  var clock: AdjustableClock { get }
  /// Everything the loop publishes from before it starts, for `drain(until:)`.
  var output: AsyncStream<MentorEvent> { get }
  /// The same events again, for waiting on the loop's state without polling.
  var updates: AsyncStream<MentorEvent> { get }
  /// Readable without waiting on the loop, as the app's lists read it.
  var suggestionFloor: SuggestionFloor { get }

  /// A loop that has not started, with `output` and `updates` already
  /// subscribed, deciding a new day on `MentorLoopTests.calendar`.
  init(
    unstartedWith settings: MentorSettings,
    journal: Journal,
    client: Client,
    keyStore: any KeyStore,
    clock: AdjustableClock,
    consented: Bool
  ) async

  /// Queues a sensing event and returns before the loop handles it.
  func send(_ event: SensingEvent)
  /// A subscription of its own to everything the loop publishes from now on.
  func events() async -> AsyncStream<MentorEvent>

  // The loop's commands and readings, each as `MentorLoop` documents it.
  func start() async
  func stop() async
  func currentStatus() async -> MentorStatus
  func currentUnderstanding() async -> UnderstandingRecord?
  var hasAPIKey: Bool { get async }
  func updateSettings(_ settings: MentorSettings) async
  func setConsented(_ granted: Bool) async
  func apiKeyChanged() async
  func testConnection() async -> Result<String, ClaudeClientError>
  func setTalkingBack(_ active: Bool, at now: Date?) async
  func expireHeldSuggestion(now: Date?) async
  func askFollowUp(about suggestion: Suggestion, question: String, at now: Date?) async -> FollowUp?
  func withdrawFollowUp() async
  func recordFeedback(
    suggestionID: Int64,
    feedback: SuggestionFeedback,
    at now: Date?
  ) async -> Suggestion?
  func noteCalloutShown(suggestionID: Int64) async -> Suggestion?
  func resetUnderstanding(at now: Date?) async
  func journalCleared() async
}

// A protocol requirement takes no default argument, so these give the
// commands the loop's own default: the clock's date.
extension MentorHarness {
  func setTalkingBack(_ active: Bool) async {
    await setTalkingBack(active, at: nil)
  }

  func askFollowUp(about suggestion: Suggestion, question: String) async -> FollowUp? {
    await askFollowUp(about: suggestion, question: question, at: nil)
  }

  func recordFeedback(suggestionID: Int64, feedback: SuggestionFeedback) async -> Suggestion? {
    await recordFeedback(suggestionID: suggestionID, feedback: feedback, at: nil)
  }

  func resetUnderstanding() async {
    await resetUnderstanding(at: nil)
  }
}

extension MentorHarness {
  /// Where every harness clock starts: noon, on the UTC calendar the loop
  /// is given, so a record written any test age ago is still today.
  static var start: Date { Date(timeIntervalSince1970: 1_789_473_600) }

  /// A loop that has started and is watching.
  init(
    startedWith settings: MentorSettings,
    journal: Journal,
    client: Client,
    keyStore: any KeyStore,
    clock: AdjustableClock,
    consented: Bool
  ) async {
    await self.init(
      unstartedWith: settings,
      journal: journal,
      client: client,
      keyStore: keyStore,
      clock: clock,
      consented: consented
    )
    await start()
    // Handled before init returns, so a test that moves the clock
    // first moves it with the loop already watching.
    send(.modeChanged(.watching))
    await wait { $0.mode == .watching }
  }

  /// Sends an observation and waits until the loop has gated it through both
  /// the triage and the refresh gate, made the expected number of calls, as
  /// `calls` counts them, and has nothing in flight.
  ///
  /// The observation arrives a millisecond after whatever came before it, so
  /// the refresh gate's verdict on it is told apart from the last one by its
  /// time.
  func observe(
    _ observation: ActivityObservation,
    calls: @Sendable () async -> Int,
    expectCalls: Int
  ) async {
    clock.advance(by: .milliseconds(1))
    let sentAt = clock.date
    send(.observation(observation))
    await wait(
      until: { status in
        status.lastGate?.observationID == observation.id && status.inFlight == nil
          && Self.refreshGateRan(status, since: sentAt)
      },
      and: { await calls() >= expectCalls }
    )
  }

  /// Every event published so far, up to and including the first that
  /// matches `predicate`.
  func drain(until predicate: (MentorEvent) -> Bool) async -> [MentorEvent] {
    var seen: [MentorEvent] = []
    for await event in output {
      seen.append(event)
      if predicate(event) { break }
    }
    return seen
  }

  /// The next suggestion the loop publishes.
  func nextSuggestion() async -> Suggestion? {
    for await event in output {
      if case .suggestion(let suggestion) = event { return suggestion }
    }
    return nil
  }

  /// Waits until `condition` holds of the loop's status and `met` holds,
  /// checking again after every event the loop publishes.
  ///
  /// The suite's time limit ends a wait that never ends.
  private func wait(
    until condition: (MentorStatus) -> Bool,
    and met: () async -> Bool = { true }
  ) async {
    var events = updates.makeAsyncIterator()
    while true {
      if condition(await currentStatus()), await met() { return }
      guard await events.next() != nil else { return }
    }
  }

  /// The refresh gate runs last for every observation, so a hold or a
  /// call of its own since the observation was sent means the loop has
  /// finished with it.
  private static func refreshGateRan(_ status: MentorStatus, since sentAt: Date) -> Bool {
    if let hold = status.lastRefreshHold, hold.at >= sentAt { return true }
    if let call = status.lastRefresh, call.timestamp >= sentAt { return true }
    return false
  }
}

extension MentorHarness where Client == ScriptedClaudeClient {
  /// `screens`, then `understanding`, when given, are journaled before the
  /// loop starts, so the loop seeds from them exactly as it would after a
  /// relaunch.
  ///
  /// The screens get ids 1, 2, and so on, in order. `activeUse` is how long
  /// the user worked right after the record was written, with nothing counted
  /// since, as the loop would have kept the count. The clock starts at
  /// `start`.
  init(
    settings: MentorSettings = MentorSettings(),
    key: String? = "sk-ant-test",
    screens: [ActivityObservation] = [],
    understanding: UnderstandingRecord? = nil,
    activeUse: TimeInterval? = nil,
    start: Date = Self.start,
    consented: Bool = true
  ) async throws {
    let journal = try Journal.inMemory()
    for screen in screens { try await journal.record(screen) }
    if let understanding {
      try await journal.record(understanding)
      if let activeUse {
        try await journal.storeRefreshPeriod(
          RefreshPeriod(
            startedAt: understanding.updatedAt,
            activeUse: activeUse,
            countedAt: understanding.updatedAt.addingTimeInterval(activeUse)
          )
        )
      }
    }
    let clock = AdjustableClock(startingAt: start)
    await self.init(
      settings: settings,
      key: key,
      journal: journal,
      client: ScriptedClaudeClient(clock: clock),
      clock: clock,
      consented: consented
    )
  }

  /// A loop over a journal, client, and clock that already exist, as a relaunch finds them.
  init(
    settings: MentorSettings = MentorSettings(),
    key: String? = "sk-ant-test",
    journal: Journal,
    client: ScriptedClaudeClient,
    clock: AdjustableClock,
    consented: Bool = true
  ) async {
    await self.init(
      startedWith: settings,
      journal: journal,
      client: client,
      keyStore: InMemoryKeyStore(key: key),
      clock: clock,
      consented: consented
    )
  }

  /// `observe(_:calls:expectCalls:)`, counting what the scripted client was sent.
  func observe(_ observation: ActivityObservation, expectCalls: Int) async {
    await observe(observation, calls: { await client.sent.count }, expectCalls: expectCalls)
  }

  /// Waits until `condition` holds of the loop's status and at least `calls`
  /// requests were sent.
  func waitUntil(calls: Int = 0, _ condition: (MentorStatus) -> Bool) async {
    await wait(until: condition, and: { await client.sent.count >= calls })
  }

  /// A loop over the same journal, client, and clock, started once `closed`
  /// has passed on the clock, as the app is opened again after sitting
  /// closed.
  ///
  /// Stop this loop first, as quitting does.
  func relaunched(
    settings: MentorSettings = MentorSettings(),
    after closed: Duration = .zero
  ) async -> Self {
    clock.advance(by: closed)
    return await Self(settings: settings, journal: journal, client: client, clock: clock)
  }
}
