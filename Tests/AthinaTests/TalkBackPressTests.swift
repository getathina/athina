import AthinaCore
import Foundation
import Testing

@testable import Athina

/// Talking back as a person drives it, through the app's own press, release,
/// transcript and typed-reply code, with a stand-in for the microphone and the
/// recognizer on the test clock.
///
/// Every step also checks that the microphone records only while talk-back
/// shows listening.
@MainActor
struct TalkBackPressTests {
  /// What the toast says when a press heard nothing.
  static let notCaught = "Athina did not catch that."

  @Test func oneHoldRecordsThroughTheGraceAndActsOnItsTranscript() async throws {
    let talk = try TalkBack()
    await talk.press()
    talk.expect(recording: true, listening: true)
    #expect(talk.state.talkBackLine == "Talk back: listening…")
    await talk.wait(1000)
    await talk.release()
    talk.expect(recording: true, listening: true)
    await talk.wait(701)
    talk.expect(recording: false, listening: true)
    await talk.recognize(final: "tell me more")
    talk.expect(recording: false, listening: false)
    #expect(talk.state.lastTranscript?.handling == "answered: Tell me more")
    #expect(talk.microphone.recordings.count == 1)
  }

  @Test func aTranscriptWithNoFinalResultSettlesAfterTheRecognizerWait() async throws {
    let talk = try TalkBack()
    await talk.press()
    await talk.release()
    await talk.wait(701)
    talk.expect(recording: false, listening: true)
    await talk.wait(2999)
    talk.expect(recording: false, listening: true)
    await talk.wait(2)
    talk.expect(recording: false, listening: false, note: TalkBackPressTests.notCaught)
    #expect(talk.state.lastTranscript?.handling == "nothing heard")
  }

  @Test func aSecondHoldAfterTheFirstSettledRecordsAsTheFirstDid() async throws {
    let talk = try TalkBack()
    await talk.press()
    await talk.release()
    await talk.wait(701)
    await talk.recognize(final: nil)
    talk.expect(recording: false, listening: false)
    await talk.press()
    talk.expect(recording: true, listening: true)
    await talk.release()
    await talk.wait(701)
    await talk.recognize(final: nil)
    talk.expect(recording: false, listening: false, note: TalkBackPressTests.notCaught)
    #expect(talk.microphone.recordings.count == 2)
  }

  /// A tap while a transcript is being finished is ignored, and so is its
  /// release: the first press keeps its grace and its transcript, and a press
  /// after its audio ended starts nothing until that transcript is settled.
  @Test func aPressAndReleaseWhileATranscriptIsFinishedLeaveItAlone() async throws {
    let talk = try TalkBack()
    await talk.press()
    await talk.release()
    await talk.press()
    await talk.release()
    talk.expect(recording: true, listening: true)
    await talk.wait(701)
    talk.expect(recording: false, listening: true)
    await talk.press()
    talk.expect(recording: false, listening: true)
    await talk.release()
    talk.expect(recording: false, listening: true)
    await talk.wait(3001)
    talk.expect(recording: false, listening: false, note: TalkBackPressTests.notCaught)
    #expect(talk.microphone.recordings.count == 1)
    await talk.finishAnExchange()
  }

  /// A press at each edge of the first transcript's time, counted from its
  /// release: during the grace, once its audio ended, at the end of the wait
  /// for the recognizer, and once that transcript is settled.
  @Test(arguments: [699, 701, 3700, 3702])
  func aPressDuringATranscriptStartsNothingUntilItIsSettled(at milliseconds: Int) async throws {
    let talk = try TalkBack()
    await talk.press()
    await talk.release()
    // A tap of its own, before the press at the edge.
    let tap = milliseconds < 700 ? 650 : 701
    await talk.wait(tap)
    await talk.press()
    await talk.release()
    await talk.wait(milliseconds - tap)
    await talk.press()
    switch milliseconds {
    case 699:
      talk.expect(recording: true, listening: true)
      await talk.wait(2)
      talk.expect(recording: false, listening: true)
    case 701, 3700:
      talk.expect(recording: false, listening: true)
    default:
      talk.expect(recording: true, listening: true)
      #expect(talk.microphone.recordings.count == 2)
      await talk.release()
    }
    await talk.wait(701)
    await talk.wait(3001)
    talk.expect(recording: false, listening: false)
    #expect(talk.microphone.recordings.count == (milliseconds == 3702 ? 2 : 1))
  }

  /// What can take the toast away while the first press's last words are
  /// recorded.
  enum ToastEnd: CaseIterable, Sendable {
    /// A new suggestion replaces it.
    case replaced
    /// It is closed.
    case closed
  }

  /// A recording started after the toast went away mid-grace runs until its
  /// own key comes up: the first press's transcript, cut short, ends nothing
  /// newer.
  @Test(arguments: ToastEnd.allCases)
  func aPressAfterTheToastWentAwayRecordsUntilItsOwnRelease(_ end: ToastEnd) async throws {
    let talk = try TalkBack()
    await talk.press()
    await talk.release()
    await talk.wait(100)
    await talk.press()
    await talk.wait(50)
    await talk.release()
    switch end {
    case .replaced:
      talk.state.handle(.suggestion(talk.suggestion(2)))
    case .closed:
      talk.state.respond(to: talk.first.id, with: .dismissed)
    }
    await talk.settle()
    talk.expect(recording: false, listening: false)
    await talk.wait(100)
    await talk.press()
    talk.expect(recording: true, listening: true)
    await talk.wait(451)
    talk.expect(recording: true, listening: true)
    await talk.release()
    talk.expect(recording: true, listening: true)
    await talk.wait(701)
    talk.expect(recording: false, listening: true)
    await talk.recognize(final: nil)
    talk.expect(recording: false, listening: false, note: TalkBackPressTests.notCaught)
  }

  /// A key held past the time limit is released by the limit; the key coming
  /// up afterwards is not a second release.
  @Test func aKeyHeldPastTheLimitIsReleasedOnce() async throws {
    let talk = try TalkBack()
    await talk.press()
    await talk.wait(30_001)
    talk.expect(recording: true, listening: true)
    await talk.release()
    talk.expect(recording: true, listening: true)
    await talk.wait(700)
    talk.expect(recording: false, listening: true)
    await talk.press()
    talk.expect(recording: false, listening: true)
    await talk.release()
    await talk.wait(3001)
    talk.expect(recording: false, listening: false, note: TalkBackPressTests.notCaught)
    #expect(talk.microphone.recordings.count == 1)
    await talk.finishAnExchange()
  }

  /// A press in the same turn as a reply typed in the debug panel takes the
  /// reply's place, as a press takes a waiting question's: the reply ends
  /// nothing the press started.
  @Test(arguments: ["tell me more", "um"])
  func aPressInTheTurnOfATypedReplyTakesItsPlace(typed: String) async throws {
    let talk = try TalkBack(toastUp: true)
    talk.state.talkBack(typed: typed)
    talk.state.hotKeyPressed(.pushToTalk)
    await talk.settle()
    talk.expect(recording: true, listening: true)
    await talk.wait(701)
    talk.expect(recording: true, listening: true)
    #expect(talk.state.lastTranscript == nil)
    await talk.release()
    await talk.wait(701)
    await talk.recognize(final: nil)
    talk.expect(recording: false, listening: false, note: TalkBackPressTests.notCaught)
  }

  /// Pause and a press, in either order and with or without a turn between
  /// them: nothing is recorded while paused, and a press refused for the pause
  /// says what it says once sensing is paused.
  @Test(arguments: [false, true])
  func nothingIsRecordedAfterPauseWhicheverComesFirst(inOneTurn: Bool) async throws {
    let paused = "Athina is paused, so it is not listening."

    let pausedFirst = try TalkBack(toastUp: true)
    pausedFirst.state.hotKeyPressed(.pause)
    if !inOneTurn { await pausedFirst.settle() }
    pausedFirst.state.hotKeyPressed(.pushToTalk)
    await pausedFirst.settle()
    #expect(pausedFirst.state.isPaused)
    pausedFirst.expect(recording: false, listening: false, note: paused)
    #expect(pausedFirst.microphone.recordings.isEmpty)
    await pausedFirst.release()
    await pausedFirst.wait(3600_000)
    pausedFirst.expect(recording: false, listening: false)

    let pressedFirst = try TalkBack(toastUp: true)
    pressedFirst.state.hotKeyPressed(.pushToTalk)
    if !inOneTurn { await pressedFirst.settle() }
    pressedFirst.state.hotKeyPressed(.pause)
    await pressedFirst.settle()
    #expect(pressedFirst.state.isPaused)
    pressedFirst.expect(recording: false, listening: false)
    await pressedFirst.press()
    pressedFirst.expect(recording: false, listening: false, note: paused)
    #expect(pressedFirst.microphone.recordings.count == 1)
  }
}

/// A detached app state with a suggestion to talk to, its toast off screen and
/// its microphone a stand-in, on a clock that moves only when a test moves it.
@MainActor
final class TalkBack {
  let microphone = FakeMicrophone()
  let state: AppState
  let clock: AdjustableClock
  /// The suggestion the presses talk to.
  let first: Suggestion

  /// `toastUp` brings the suggestion back as a toast first, as Show Last
  /// Suggestion does; otherwise the first press brings it.
  init(toastUp: Bool = false) throws {
    var settings = SensingSettings()
    settings.setConsent(
      Consent(answer: .allowed, at: Snapshots.referenceDate),
      for: settings.mentor.provider
    )
    settings.mentor.pushToTalkHotKey = HotKey(keyCode: 49, modifiers: [.control, .option])
    state = AppState(sampleWithSettings: settings, speechInput: microphone)
    clock = try #require(state.clock as? AdjustableClock)
    state.permissions = AppState.hermeticPermissions
    state.mode = .watching
    first = Self.suggestion(1, at: clock.date)
    state.journaledSuggestions = [first]
    if toastUp { state.showLastSuggestion() }
  }

  static func suggestion(_ id: Int64, at date: Date) -> Suggestion {
    Suggestion(
      id: id,
      timestamp: date,
      bundleID: "com.apple.dt.Xcode",
      appName: "Xcode",
      windowTitle: "main.swift",
      category: .shortcut,
      title: "Rename in one step",
      body: "Refactor > Rename changes every use at once.",
      explanation: "You renamed the same symbol in several files by hand.",
      confidence: 0.9,
      observationID: nil,
      model: "claude-test",
      promptVersion: MentorPrompts.version
    )
  }

  func suggestion(_ id: Int64) -> Suggestion { Self.suggestion(id, at: clock.date) }

  var recording: Bool { microphone.recording }

  var listening: Bool {
    if case .listening = state.talkBack { return true }
    return false
  }

  func press() async {
    state.hotKeyPressed(.pushToTalk)
    await settle()
  }

  func release() async {
    state.hotKeyReleased(.pushToTalk)
    await settle()
  }

  func wait(_ milliseconds: Int) async {
    clock.advance(by: .milliseconds(milliseconds))
    await settle()
  }

  /// The recognizer's final result for the latest recording; nil reports
  /// that it heard nothing.
  func recognize(final words: String?) async {
    microphone.recordings.last?.recognize(words, isFinal: true)
    await settle()
  }

  /// A whole exchange after the others have settled: one hold, as a person
  /// makes it, heard as nothing.
  func finishAnExchange(sourceLocation: SourceLocation = #_sourceLocation) async {
    let before = microphone.recordings.count
    await press()
    expect(recording: true, listening: true, sourceLocation: sourceLocation)
    await release()
    await wait(701)
    await recognize(final: nil)
    expect(recording: false, listening: false, sourceLocation: sourceLocation)
    #expect(microphone.recordings.count == before + 1, sourceLocation: sourceLocation)
  }

  /// Lets everything the step started on the main actor run, then checks
  /// that the microphone records only while talk-back shows listening.
  func settle(sourceLocation: SourceLocation = #_sourceLocation) async {
    for _ in 0..<200 { await Task.yield() }
    #expect(
      listening || !recording,
      "the microphone records while talk-back is \(state.talkBack)",
      sourceLocation: sourceLocation
    )
    #expect(microphone.recordings.count { $0.recording } <= 1, sourceLocation: sourceLocation)
  }

  func expect(
    recording: Bool,
    listening: Bool,
    note: String? = nil,
    sourceLocation: SourceLocation = #_sourceLocation
  ) {
    #expect(self.recording == recording, "recording", sourceLocation: sourceLocation)
    #expect(
      self.listening == listening,
      "talk-back is \(state.talkBack)",
      sourceLocation: sourceLocation
    )
    if !listening {
      #expect(state.talkBack == .idle, sourceLocation: sourceLocation)
    }
    if let note {
      #expect(state.toast.note == note, sourceLocation: sourceLocation)
    }
  }
}

/// Stands in for the microphone and the recognizer: each recording records
/// from its start until its audio is stopped, and reports what a test makes it
/// recognize.
@MainActor
final class FakeMicrophone: SpeechInput {
  private(set) var recordings: [FakeRecording] = []

  var recording: Bool { recordings.contains { $0.recording } }

  func makeRecording() throws -> any SpeechRecording {
    let recording = FakeRecording()
    recordings.append(recording)
    return recording
  }
}

@MainActor
final class FakeRecording: SpeechRecording {
  private(set) var recording = false
  private var report: (@Sendable (String?, Bool, String?) -> Void)?

  func start(reporting result: @escaping @Sendable (String?, Bool, String?) -> Void) throws {
    report = result
    recording = true
  }

  func stopAudio() {
    recording = false
  }

  func endAudio() {}

  func cancel() {
    report = nil
  }

  /// Reports a result, or with no words the recognizer's error for nothing
  /// heard.
  func recognize(_ words: String?, isFinal: Bool) {
    report?(words, isFinal, words == nil ? "no speech detected" : nil)
  }
}
