import Foundation

@testable import AthinaCore

/// `MentorHarness` over the `MentorLoop` actor.
///
/// The actor and the stream it reads are private, so a test reaches neither
/// except through the protocol.
struct MentorLoopHarness<Client: ClaudeClient>: MentorHarness {
  let journal: Journal
  let client: Client
  let keyStore: any KeyStore
  let clock: AdjustableClock
  let output: AsyncStream<MentorEvent>
  let updates: AsyncStream<MentorEvent>
  private let loop: MentorLoop
  private let input: AsyncStream<SensingEvent>.Continuation

  var suggestionFloor: SuggestionFloor { loop.suggestionFloor }
  var hasAPIKey: Bool {
    get async { await loop.hasAPIKey }
  }

  init(
    unstartedWith settings: MentorSettings,
    journal: Journal,
    client: Client,
    keyStore: any KeyStore,
    clock: AdjustableClock,
    consented: Bool
  ) async {
    self.journal = journal
    self.client = client
    self.keyStore = keyStore
    self.clock = clock
    let (stream, continuation) = AsyncStream<SensingEvent>.makeStream()
    input = continuation
    loop = MentorLoop(
      settings: settings,
      journal: journal,
      client: client,
      keyStore: keyStore,
      events: stream,
      consented: consented,
      clock: clock,
      calendar: MentorLoopTests.calendar
    )
    output = await loop.events()
    updates = await loop.events()
  }

  func send(_ event: SensingEvent) {
    input.yield(event)
  }

  func events() async -> AsyncStream<MentorEvent> {
    await loop.events()
  }

  func start() async {
    await loop.start()
  }

  func stop() async {
    await loop.stop()
  }

  func currentStatus() async -> MentorStatus {
    await loop.currentStatus()
  }

  func currentUnderstanding() async -> UnderstandingRecord? {
    await loop.currentUnderstanding()
  }

  func updateSettings(_ settings: MentorSettings) async {
    await loop.updateSettings(settings)
  }

  func setConsented(_ granted: Bool) async {
    await loop.setConsented(granted)
  }

  func setPaused(_ paused: Bool) async {
    await loop.setPaused(paused)
  }

  func apiKeyChanged() async {
    await loop.apiKeyChanged()
  }

  func testConnection() async -> Result<String, ClaudeClientError> {
    await loop.testConnection()
  }

  func setTalkingBack(_ active: Bool, at now: Date?) async {
    await loop.setTalkingBack(active, at: now)
  }

  func expireHeldSuggestion(now: Date?) async {
    await loop.expireHeldSuggestion(now: now)
  }

  func askFollowUp(
    about suggestion: Suggestion,
    question: String,
    at now: Date?
  ) async -> FollowUp? {
    await loop.askFollowUp(about: suggestion, question: question, at: now)
  }

  func withdrawFollowUp() async {
    await loop.withdrawFollowUp()
  }

  func recordFeedback(
    suggestionID: Int64,
    feedback: SuggestionFeedback,
    at now: Date?
  ) async -> Suggestion? {
    await loop.recordFeedback(suggestionID: suggestionID, feedback: feedback, at: now)
  }

  func noteCalloutShown(suggestionID: Int64) async -> Suggestion? {
    await loop.noteCalloutShown(suggestionID: suggestionID)
  }

  func resetUnderstanding(at now: Date?) async {
    await loop.resetUnderstanding(at: now)
  }

  func journalWillClear() async {
    await loop.journalWillClear()
  }

  func journalCleared() async {
    await loop.journalCleared()
  }
}
