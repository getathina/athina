import AppKit
import AthinaCore
import AthinaFeatures
import ComposableArchitecture
import CoreGraphics
import Foundation
import Testing

extension StoreTests {
  /// The toast's lifecycle on the test clock: every state change, every action
  /// its effects send back, what it delegates and what VoiceOver hears.
  @MainActor
  @Suite(.timeLimit(.minutes(1)))
  struct ToastFeatureTests {
    /// The toast's two countdowns.
    enum Countdown: CaseIterable {
      case suggestion
      case note
    }

    private struct Announcement: Equatable {
      var text: String
      var priority: NSAccessibilityPriorityLevel

      static func queued(_ text: String) -> Announcement {
        Announcement(text: text, priority: .medium)
      }

      static func interrupting(_ text: String) -> Announcement {
        Announcement(text: text, priority: .high)
      }
    }

    private static let start = Date(timeIntervalSince1970: 1_789_473_600)
    private static let timeout: TimeInterval = 60

    private let clock = AdjustableClock(startingAt: ToastFeatureTests.start)
    private let said = LockIsolated<[Announcement]>([])
    private let first = ToastFeatureTests.suggestion(1)
    private let second = ToastFeatureTests.suggestion(2)
    private let firstSaid = "Athina, Shortcut in TextEdit: Title 1. Body 1."
    private let secondSaid = "Athina, Shortcut in TextEdit: Title 2. Body 2."

    private static func suggestion(_ id: Int64) -> Suggestion {
      Suggestion(
        id: id,
        timestamp: start,
        bundleID: "com.apple.TextEdit",
        appName: "TextEdit",
        windowTitle: "notes.txt",
        category: .shortcut,
        title: "Title \(id)",
        body: "Body \(id).",
        explanation: "Explanation \(id).",
        confidence: 0.9,
        observationID: nil,
        model: "model",
        promptVersion: 1
      )
    }

    private static func followUp(answer: String?, error: String? = nil) -> FollowUp {
      FollowUp(
        id: 7,
        suggestionID: 1,
        timestamp: start,
        question: "does that work with tags",
        answer: answer,
        error: error,
        model: "model",
        promptVersion: 1
      )
    }

    private func makeStore(
      _ state: ToastFeature.State = ToastFeature.State()
    ) -> TestStoreOf<ToastFeature> {
      TestStore(
        initialState: state,
        reducer: {
          ToastFeature()
        },
        withDependencies: { [clock, said] in
          $0.athinaClock = clock
          $0.announcer.post = { text, priority in
            said.withValue { $0.append(Announcement(text: text, priority: priority)) }
          }
        }
      )
    }

    /// A suggestion on screen that waits to be answered, as a test that is not
    /// about its arrival starts from.
    private func showingFirst() -> ToastFeature.State {
      var state = ToastFeature.State(suggestion: first)
      state.saidWhereAnswersAre = true
      state.panel.presented = 1
      return state
    }

    /// Shows the first suggestion as one that came unasked and times out.
    private func arriveFirst(in store: TestStoreOf<ToastFeature>) async {
      let arrival = ToastFeature.Arrival.unasked(expiresAfter: Self.timeout)
      await store.send(.show(first, exchange: [], arrival: arrival)) {
        $0.suggestion = first
        $0.saidWhereAnswersAre = true
        $0.panel.presented = 1
        $0.countdown.run(for: Self.timeout, from: Self.start)
      }
      await clock.waitForSleepers()
    }

    private static let timedNote = ToastFeature.Note("Athina did not catch that.")

    /// Shows what `countdown` takes down when its time is up.
    private func starting(_ countdown: Countdown) -> ToastFeature.Action {
      switch countdown {
      case .suggestion:
        return .show(first, exchange: [], arrival: .unasked(expiresAfter: Self.timeout))
      case .note:
        return .showNote(Self.timedNote)
      }
    }

    private func length(of countdown: Countdown) -> TimeInterval {
      switch countdown {
      case .suggestion: return Self.timeout
      case .note: return ToastPlacement.noteDuration(for: Self.timedNote.text)
      }
    }

    private func isUp(_ countdown: Countdown, in state: ToastFeature.State) -> Bool {
      switch countdown {
      case .suggestion: return state.suggestion != nil
      case .note: return state.note != nil
      }
    }

    /// Lets whatever is due run, in a bounded number of turns.
    private func settle() async {
      for _ in 0..<100 { await Task.yield() }
    }

    /// What taking the toast down leaves.
    private func takenDown(_ state: inout ToastFeature.State) {
      state.suggestion = nil
      state.exchange = []
      state.talkBack = .idle
      state.outlined = nil
      state.note = nil
      state.countdown.cancel()
      state.noteCountdown.cancel()
      state.pointerOverPanel = false
      state.panel.orderedOut += 1
    }

    // MARK: The countdown

    @Test func aSuggestionExpiresWhenItsTimeIsUp() async {
      let store = makeStore()
      await arriveFirst(in: store)
      clock.advance(by: .seconds(Self.timeout - 1))
      #expect(clock.sleeperCount == 1)
      clock.advance(by: .seconds(1))
      await store.receive(\.countdownEnded) {
        takenDown(&$0)
      }
      await store.receive(\.delegate, .answered(first, .expired))
      await store.finish()
    }

    @Test func thePointerHoldsTheCountdownAndLeavingResumesIt() async {
      let store = makeStore()
      await arriveFirst(in: store)
      clock.advance(by: .seconds(40))
      await store.send(.hoverChanged(true)) {
        $0.pointerOverPanel = true
        $0.suggestionHovered = true
        $0.countdown.hold(at: Self.start + 40)
      }
      #expect(store.state.countdown.held == 20)
      // Ten minutes under the pointer, and nothing is waiting to expire it.
      clock.advance(by: .seconds(600))
      #expect(clock.sleeperCount == 0)
      await store.send(.hoverChanged(false)) {
        $0.pointerOverPanel = false
        $0.suggestionHovered = false
        $0.countdown.run(for: 20, from: Self.start + 640)
      }
      await clock.waitForSleepers()
      clock.advance(by: .seconds(19))
      #expect(clock.sleeperCount == 1)
      clock.advance(by: .seconds(1))
      await store.receive(\.countdownEnded) {
        takenDown(&$0)
      }
      await store.receive(\.delegate, .answered(first, .expired))
      await store.finish()
    }

    @Test func aCountdownHeldAtItsLastMomentKeepsTheMinimum() async {
      let store = makeStore()
      await arriveFirst(in: store)
      clock.advance(by: .seconds(Self.timeout - 0.5))
      await store.send(.hoverChanged(true)) {
        $0.pointerOverPanel = true
        $0.suggestionHovered = true
        $0.countdown.hold(at: Self.start + Self.timeout - 0.5)
      }
      #expect(store.state.countdown.held == ToastCountdown.minimumRemaining)
      await store.finish()
    }

    @Test func aDeadlineThatIsNoLongerTheCountdownsExpiresNothing() async {
      let store = makeStore(showingFirst())
      await store.send(.countdownEnded(deadline: Self.start))
      await store.send(.noteCountdownEnded(deadline: Self.start))
      await store.finish()
    }

    /// A plain store, since a `TestStore` lets an effect begin before its send
    /// returns, which is after the turn this is about.
    @Test(arguments: Countdown.allCases)
    func aCancelInTheTurnOfAStartLeavesNoSleeper(countdown: Countdown) async {
      await withMainSerialExecutor {
        let store = Store(
          initialState: ToastFeature.State(),
          reducer: {
            ToastFeature()
          },
          withDependencies: { [clock] in
            $0.athinaClock = clock
            $0.announcer.post = { _, _ in }
          }
        )
        store.send(starting(countdown))
        store.send(.hoverChanged(true))
        await settle()
        #expect(clock.sleeperCount == 0, "a cancelled countdown is still waiting")
      }
    }

    /// The older start has other work merged with it, so an effect that can be
    /// cancelled only once it has begun would begin after the newer one and
    /// cancel it: the order the global executor may give any two starts, here
    /// made the same on every run.
    @Test(arguments: Countdown.allCases)
    func twoStartsCloseTogetherLeaveExactlyTheNewerOneLive(countdown: Countdown) async {
      await withMainSerialExecutor {
        let olderStarted = LockIsolated(false)
        let store = Store(
          initialState: ToastFeature.State(),
          reducer: {
            ToastFeature()
            Reduce { _, action in
              guard case .hoverChanged(false) = action, !olderStarted.value else { return .none }
              olderStarted.setValue(true)
              return .run { _ in }
            }
          },
          withDependencies: { [clock] in
            $0.athinaClock = clock
            $0.announcer.post = { _, _ in }
          }
        )
        store.send(starting(countdown))
        await settle()
        store.send(.hoverChanged(true))
        await settle()

        // In one turn: the older starts, is held, and the newer starts with a
        // deadline a second later.
        store.send(.hoverChanged(false))
        store.send(.hoverChanged(true))
        clock.advance(by: .seconds(1))
        store.send(.hoverChanged(false))
        await settle()
        #expect(clock.sleeperCount == 1, "not exactly one countdown is waiting")

        clock.advance(by: .seconds(length(of: countdown) - 1))
        await settle()
        #expect(isUp(countdown, in: store.state), "it ended at the older deadline")
        #expect(clock.sleeperCount == 1, "the older one was live in place of the newer")

        clock.advance(by: .seconds(1))
        await settle()
        #expect(!isUp(countdown, in: store.state), "nothing ended it at the newer deadline")
        #expect(clock.sleeperCount == 0)
      }
    }

    @Test func aSuggestionWithNoTimeoutWaitsToBeAnswered() async {
      let store = makeStore()
      let arrival = ToastFeature.Arrival.unasked(expiresAfter: nil)
      await store.send(.show(first, exchange: [], arrival: arrival)) {
        $0.suggestion = first
        $0.saidWhereAnswersAre = true
        $0.panel.presented = 1
      }
      #expect(clock.sleeperCount == 0)
      await store.finish()
    }

    // MARK: One suggestion after another

    @Test func onlyTheNewSuggestionsTimeCountsOnceTheOneItReplacesIsAnswered() async {
      let store = makeStore()
      await arriveFirst(in: store)
      clock.advance(by: .seconds(10))
      await store.send(.answered(suggestionID: 1, .expired)) {
        takenDown(&$0)
      }
      let arrival = ToastFeature.Arrival.unasked(expiresAfter: Self.timeout)
      await store.send(.show(second, exchange: [], arrival: arrival)) {
        $0.suggestion = second
        $0.panel.presented = 2
        $0.countdown.run(for: Self.timeout, from: Self.start + 10)
      }
      await clock.waitForSleepers()
      // The first one's time comes and goes; only the second's counts.
      clock.advance(by: .seconds(Self.timeout - 10))
      #expect(clock.sleeperCount == 1)
      clock.advance(by: .seconds(10))
      await store.receive(\.countdownEnded) {
        takenDown(&$0)
      }
      await store.receive(\.delegate, .answered(second, .expired))
      await store.finish()
    }

    @Test func showLeavesTheAnswerOfTheOneItReplacesToTheParent() async {
      let store = makeStore(showingFirst())
      await store.send(.show(second, exchange: [], arrival: .asked)) {
        $0.suggestion = second
        $0.panel.presented = 2
      }
      await store.finish()
    }

    @Test func aNewSuggestionStartsFoldedWithNothingOfTheOneItReplaced() async {
      var state = showingFirst()
      state.expanded = true
      state.exchange = [Self.followUp(answer: "Yes.")]
      state.outlined = "the capture call"
      state.talkBack = .thinking(question: "does that work with tags")
      state.note = ToastFeature.Note("A note.", untilClicked: true)
      state.suggestionHovered = true
      state.movedTopLeft = CGPoint(x: 10, y: 20)
      let store = makeStore(state)
      await store.send(.answered(suggestionID: 1, .expired)) {
        takenDown(&$0)
      }
      let exchange = [Self.followUp(answer: "With tags too.")]
      await store.send(.show(second, exchange: exchange, arrival: .asked)) {
        $0.suggestion = second
        $0.exchange = exchange
        $0.expanded = false
        $0.suggestionHovered = false
        $0.movedTopLeft = nil
        $0.panel.presented = 2
      }
      await store.finish()
    }

    @Test func aSuggestionTakesTheNotesPlaceAndEndsItsTime() async {
      var state = ToastFeature.State(talkBack: .thinking(question: "does it"))
      state.saidWhereAnswersAre = true
      let store = makeStore(state)
      let note = ToastFeature.Note("Athina did not catch that.")
      await store.send(.showNote(note)) {
        $0.note = note
        $0.panel.presented = 1
        $0.noteCountdown.run(for: ToastPlacement.noteDuration(for: note.text), from: Self.start)
      }
      await clock.waitForSleepers()
      await store.send(.show(first, exchange: [], arrival: .asked)) {
        $0.suggestion = first
        $0.talkBack = .idle
        $0.note = nil
        $0.noteCountdown.cancel()
        $0.panel.presented = 2
      }
      #expect(clock.sleeperCount == 0, "the note's time still runs")
      await store.finish()
    }

    @Test func showingTheOneOnScreenBringsItToTheFrontWithItsCountdownOff() async {
      let store = makeStore()
      await arriveFirst(in: store)
      await store.send(.show(first, exchange: [], arrival: .asked)) {
        $0.countdown.cancel()
        $0.panel.raised = 1
      }
      await store.finish()
      #expect(said.value.count == 1)
    }

    // MARK: Answers

    @Test func tellMeMoreStopsTheCountdown() async {
      let store = makeStore()
      await arriveFirst(in: store)
      await store.send(.expandButtonTapped) {
        $0.expanded = true
        $0.countdown.cancel()
      }
      await store.receive(\.delegate, .answered(first, .tellMeMore))
      clock.advance(by: .seconds(3600))
      await store.send(.expandButtonTapped) {
        $0.expanded = false
      }
      await store.finish()
    }

    @Test func tellMeMoreFromTheMenuStopsTheCountdownToo() async {
      let store = makeStore()
      await arriveFirst(in: store)
      await store.send(.expand) {
        $0.expanded = true
      }
      await store.send(.raise) {
        $0.panel.raised = 1
      }
      await store.send(.answered(suggestionID: 1, .tellMeMore)) {
        $0.countdown.cancel()
      }
      await store.finish()
      #expect(said.value.last == .interrupting("Explanation 1."))
    }

    @Test(arguments: [SuggestionFeedback.dismissed, .notNow, .never])
    func anAnswerAtTheToastTakesItDownAndTellsTheParent(feedback: SuggestionFeedback) async {
      let store = makeStore()
      await arriveFirst(in: store)
      await store.send(.answerButtonTapped(feedback)) {
        takenDown(&$0)
      }
      await store.receive(\.delegate, .answered(first, feedback))
      await store.finish()
    }

    @Test(arguments: [SuggestionFeedback.dismissed, .notNow, .never, .expired])
    func anAnswerFromTheParentTakesItDownAndDelegatesNothing(feedback: SuggestionFeedback) async {
      let store = makeStore()
      await arriveFirst(in: store)
      await store.send(.answered(suggestionID: 1, feedback)) {
        takenDown(&$0)
      }
      await store.finish()
    }

    @Test func anAnswerToAnotherSuggestionLeavesTheToastBe() async {
      let store = makeStore(showingFirst())
      await store.send(.answered(suggestionID: 2, .notNow))
      await store.finish()
    }

    @Test func anAnswersConsequenceIsANoteWhereTheToastWas() async {
      let text = "Shortcut suggestions in TextEdit are off."
      let moved = CGPoint(x: 10, y: 20)
      var state = showingFirst()
      state.movedTopLeft = moved
      let store = makeStore(state)
      await store.send(.answerButtonTapped(.never)) {
        takenDown(&$0)
      }
      await store.receive(\.delegate, .answered(first, .never))
      let duration = ToastPlacement.noteDuration(for: text)
      await store.send(.showNote(ToastFeature.Note(text))) {
        $0.note = ToastFeature.Note(text)
        $0.panel.presented = 2
        $0.noteCountdown.run(for: duration, from: Self.start)
      }
      #expect(store.state.movedTopLeft == moved)
      #expect(!store.state.watchesClicks)
      #expect(said.value == [.queued(text)])
      await clock.waitForSleepers()
      clock.advance(by: .seconds(duration))
      await store.receive(\.noteCountdownEnded) {
        $0.note = nil
        $0.noteCountdown.cancel()
        $0.panel.orderedOut = 2
      }
      await store.finish()
    }

    // MARK: Notes

    @Test func aNotesCountdownIsHeldUnderThePointer() async {
      let text = "Nothing to reply to yet: Athina has not made a suggestion."
      let duration = ToastPlacement.noteDuration(for: text)
      let store = makeStore()
      await store.send(.showNote(ToastFeature.Note(text))) {
        $0.note = ToastFeature.Note(text)
        $0.panel.presented = 1
        $0.noteCountdown.run(for: duration, from: Self.start)
      }
      await clock.waitForSleepers()
      clock.advance(by: .seconds(1))
      await store.send(.hoverChanged(true)) {
        $0.pointerOverPanel = true
        $0.suggestionHovered = true
        $0.noteCountdown.hold(at: Self.start + 1)
      }
      clock.advance(by: .seconds(600))
      #expect(clock.sleeperCount == 0)
      await store.send(.hoverChanged(false)) {
        $0.pointerOverPanel = false
        $0.suggestionHovered = false
        $0.noteCountdown.run(for: duration - 1, from: Self.start + 601)
      }
      await clock.waitForSleepers()
      clock.advance(by: .seconds(duration - 1))
      await store.receive(\.noteCountdownEnded) {
        $0.note = nil
        $0.noteCountdown.cancel()
        $0.panel.orderedOut = 1
      }
      await store.finish()
    }

    @Test func aNoteShownUnderThePointerStartsHeld() async {
      var state = ToastFeature.State()
      state.pointerOverPanel = true
      let store = makeStore(state)
      let note = ToastFeature.Note("Athina did not catch that.")
      await store.send(.showNote(note)) {
        $0.note = note
        $0.panel.presented = 1
        $0.noteCountdown.run(for: ToastPlacement.noteDuration(for: note.text), from: Self.start)
        $0.noteCountdown.hold(at: Self.start)
      }
      #expect(clock.sleeperCount == 0)
      await store.finish()
    }

    @Test func aNoteInsideTheToastLeavesTheToastUpWhenItsTimeIsUp() async {
      let store = makeStore(showingFirst())
      let note = ToastFeature.Note("Athina did not catch that.")
      let duration = ToastPlacement.noteDuration(for: note.text)
      await store.send(.showNote(note)) {
        $0.note = note
        $0.noteCountdown.run(for: duration, from: Self.start)
      }
      await clock.waitForSleepers()
      clock.advance(by: .seconds(duration))
      await store.receive(\.noteCountdownEnded) {
        $0.note = nil
        $0.noteCountdown.cancel()
      }
      await store.finish()
    }

    @Test(arguments: [SensingMode.waitingForConsent, .paused, .excluded])
    func aNoteUntilClickedWaitsForAClickWhereNoKeyIsWatched(mode: SensingMode) async {
      var state = ToastFeature.State()
      state.sensingMode = mode
      let store = makeStore(state)
      let note = ToastFeature.Note("Choose Allow Watching.", untilClicked: true)
      await store.send(.showNote(note)) {
        $0.note = note
        $0.panel.presented = 1
        $0.panel.waitingNotes = 1
      }
      #expect(store.state.watchesClicks)
      #expect(!store.state.watchesKeyPresses)
      clock.advance(by: .seconds(3600))
      await store.send(.keyDown(isRepeat: false))
      // Any click will do, one on the note too.
      await store.send(.mouseDown(.onToast)) {
        $0.note = nil
        $0.panel.orderedOut = 1
      }
      await store.finish()
    }

    @Test func aNoteUntilClickedNoticesAKeyOnlyWhileWatchingAndNeverARepeat() async {
      var state = showingFirst()
      state.sensingMode = .watching
      let store = makeStore(state)
      let note = ToastFeature.Note("Answer the system's request.", untilClicked: true)
      await store.send(.showNote(note)) {
        $0.note = note
        $0.panel.waitingNotes = 1
      }
      #expect(store.state.watchesKeyPresses)
      await store.send(.keyDown(isRepeat: true))
      await store.send(.sensingModeChanged(.paused)) {
        $0.sensingMode = .paused
      }
      await store.send(.keyDown(isRepeat: false))
      await store.send(.sensingModeChanged(.watching)) {
        $0.sensingMode = .watching
      }
      await store.send(.keyDown(isRepeat: false)) {
        $0.note = nil
      }
      await store.finish()
    }

    // MARK: Clicks

    @Test func onlyAClickElsewhereDismissesASuggestion() async {
      let store = makeStore(showingFirst())
      await store.send(.mouseDown(.onToast))
      await store.send(.mouseDown(.onMenuBarItem))
      await store.send(.mouseDown(.elsewhere)) {
        takenDown(&$0)
      }
      await store.receive(\.delegate, .answered(first, .dismissed))
      await store.send(.mouseDown(.elsewhere))
      await store.finish()
    }

    @Test(
      arguments: [
        TalkBackState.listening(partial: "does"),
        .waiting(question: "does it"),
        .thinking(question: "does it"),
      ]
    )
    func noClickTakesDownAToastBeingTalkedTo(talkBack: TalkBackState) async {
      var state = showingFirst()
      state.talkBack = talkBack
      let store = makeStore(state)
      await store.send(.mouseDown(.elsewhere))
      await store.finish()
    }

    // MARK: Talking back

    @Test func aPressThatCameToNothingGivesTheCountdownBack() async {
      let store = makeStore()
      await arriveFirst(in: store)
      clock.advance(by: .seconds(10))
      await store.send(.talkBackBegan) {
        $0.countdown.hold(at: Self.start + 10)
      }
      await store.send(.talkBackChanged(.listening(partial: ""))) {
        $0.talkBack = .listening(partial: "")
        $0.panel.raised = 1
      }
      // The pointer coming and going resumes nothing during an exchange.
      await store.send(.hoverChanged(true)) {
        $0.pointerOverPanel = true
        $0.suggestionHovered = true
      }
      await store.send(.hoverChanged(false)) {
        $0.pointerOverPanel = false
        $0.suggestionHovered = false
      }
      clock.advance(by: .seconds(100))
      #expect(clock.sleeperCount == 0)
      await store.send(.talkBackChanged(.idle)) {
        $0.talkBack = .idle
      }
      let outcome = TalkBackPress.Outcome.notAnExchange(countdown: 50)
      await store.send(.pressEnded(suggestionID: 1, outcome)) {
        $0.countdown.run(for: 50, from: Self.start + 110)
      }
      await clock.waitForSleepers()
      clock.advance(by: .seconds(50))
      await store.receive(\.countdownEnded) {
        takenDown(&$0)
      }
      await store.receive(\.delegate, .answered(first, .expired))
      await store.finish()
    }

    @Test func aCountdownGivenBackUnderThePointerStaysHeld() async {
      let store = makeStore()
      await arriveFirst(in: store)
      await store.send(.talkBackBegan) {
        $0.countdown.hold(at: Self.start)
      }
      await store.send(.hoverChanged(true)) {
        $0.pointerOverPanel = true
        $0.suggestionHovered = true
      }
      let outcome = TalkBackPress.Outcome.notAnExchange(countdown: Self.timeout)
      await store.send(.pressEnded(suggestionID: 1, outcome))
      #expect(store.state.countdown.held == Self.timeout)
      #expect(clock.sleeperCount == 0)
      await store.finish()
    }

    @Test func aToastTalkedToHasNoCountdown() async {
      let store = makeStore()
      await arriveFirst(in: store)
      await store.send(.talkBackBegan) {
        $0.countdown.hold(at: Self.start)
      }
      await store.send(.pressEnded(suggestionID: 1, .talkedTo)) {
        $0.countdown.cancel()
      }
      await store.finish()
    }

    /// The countdown is turned off and nothing is cancelled: its sleep ends at
    /// the deadline it had and does nothing.
    @Test func aPressesEndTurnsTheCountdownOffWithoutCancellingItsSleep() async {
      await withMainSerialExecutor {
        let store = Store(
          initialState: ToastFeature.State(),
          reducer: {
            ToastFeature()
          },
          withDependencies: { [clock] in
            $0.athinaClock = clock
            $0.announcer.post = { _, _ in }
          }
        )
        store.send(starting(.suggestion))
        await settle()
        store.send(.pressEnded(suggestionID: first.id, .talkedTo))
        await settle()
        #expect(store.state.countdown == ToastCountdown())
        #expect(clock.sleeperCount == 1, "the sleep was cancelled")

        clock.advance(by: .seconds(Self.timeout))
        await settle()
        #expect(store.state.suggestion == first)
        #expect(clock.sleeperCount == 0)
      }
    }

    // MARK: What else the toast keeps

    @Test func aDragIsKeptUntilTheNextSuggestion() async {
      let moved = CGPoint(x: 100, y: 700)
      let store = makeStore(showingFirst())
      await store.send(.dragged(topLeft: moved)) {
        $0.movedTopLeft = moved
      }
      await store.send(.answered(suggestionID: 1, .dismissed)) {
        takenDown(&$0)
      }
      #expect(store.state.movedTopLeft == moved)
      await store.send(.show(second, exchange: [], arrival: .asked)) {
        $0.suggestion = second
        $0.movedTopLeft = nil
        $0.panel.presented = 2
      }
      await store.finish()
    }

    @Test func theCalloutIsNotedOnlyForTheSuggestionOnScreen() async {
      let store = makeStore(showingFirst())
      var other = second
      other.calloutShown = true
      await store.send(.calloutNoted(other))
      var updated = first
      updated.calloutShown = true
      await store.send(.calloutNoted(updated)) {
        $0.suggestion?.calloutShown = true
      }
      await store.send(.outlinedChanged("this capture call")) {
        $0.outlined = "this capture call"
      }
      await store.send(.talkBackKeyChanged("⌃⌥⌘T")) {
        $0.talkBackKey = "⌃⌥⌘T"
      }
      await store.finish()
    }

    // MARK: What VoiceOver hears

    @Test func voiceOverHearsWhereTheAnswersAreOnceAndInterruptsOnlyWhenAsked() async {
      let store = makeStore()
      await arriveFirst(in: store)
      await store.send(.answered(suggestionID: 1, .dismissed)) {
        takenDown(&$0)
      }
      await store.send(.show(second, exchange: [], arrival: .asked)) {
        $0.suggestion = second
        $0.panel.presented = 2
      }
      await store.finish()
      #expect(
        said.value == [
          .queued("\(firstSaid) Answer it from the Athina menu."),
          .interrupting(secondSaid),
        ]
      )
    }

    @Test func voiceOverHearsEachStageOfTalkingBackOnce() async {
      let store = makeStore(showingFirst())
      let stages: [TalkBackState] = [
        .listening(partial: ""),
        .listening(partial: "does it"),
        .thinking(question: "does it"),
        .waiting(question: "does it"),
        .thinking(question: "does it"),
      ]
      for (index, stage) in stages.enumerated() {
        await store.send(.talkBackChanged(stage)) {
          $0.talkBack = stage
          $0.panel.raised = index + 1
        }
      }
      await store.send(.talkBackChanged(.idle)) {
        $0.talkBack = .idle
      }
      await store.finish()
      #expect(
        said.value == [
          .queued("Listening"),
          .queued("Asking the mentor"),
          .queued("Asking the mentor"),
        ]
      )
    }

    @Test func voiceOverHearsAnAnswerOnceAndAtOnce() async {
      let store = makeStore(showingFirst())
      let answered = Self.followUp(answer: "Yes, with tags too.")
      await store.send(.exchangeChanged([answered], provider: .openAI)) {
        $0.exchange = [answered]
        $0.provider = .openAI
      }
      await store.send(.exchangeChanged([answered], provider: .openAI))
      await store.finish()
      #expect(said.value == [.interrupting("Athina answered: Yes, with tags too.")])
    }

    @Test func voiceOverHearsWhyAQuestionGotNoAnswer() async {
      let store = makeStore(showingFirst())
      let failed = Self.followUp(answer: nil, error: "timed out")
      await store.send(.exchangeChanged([failed], provider: .openAI)) {
        $0.exchange = [failed]
        $0.provider = .openAI
      }
      await store.finish()
      let why = UserFacing.followUpError("timed out", provider: .openAI)
      #expect(said.value == [.interrupting(why)])
    }

    @Test func voiceOverHearsANote() async {
      let store = makeStore()
      let note = ToastFeature.Note("Choose Allow Watching.", untilClicked: true)
      await store.send(.showNote(note)) {
        $0.note = note
        $0.panel.presented = 1
        $0.panel.waitingNotes = 1
      }
      await store.finish()
      #expect(said.value == [.queued(note.text)])
    }

    /// A press with no toast up brings the last suggestion back and then says
    /// Listening, which an announcement out of order would cut off.
    @Test func announcementsAreMadeInTheOrderSentBeforeEachSendReturns() {
      let store = Store(
        initialState: ToastFeature.State(),
        reducer: {
          ToastFeature()
        },
        withDependencies: { [clock, said] in
          $0.athinaClock = clock
          $0.announcer.post = { text, priority in
            said.withValue { $0.append(Announcement(text: text, priority: priority)) }
          }
        }
      )
      store.send(.show(first, exchange: [], arrival: .asked))
      store.send(.talkBackChanged(.listening(partial: "")))
      #expect(
        said.value == [
          .interrupting("\(firstSaid) Answer it from the Athina menu."),
          .queued("Listening"),
        ]
      )
    }
  }
}
