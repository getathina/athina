import AthinaCore
import AthinaFeatures
import ComposableArchitecture
import CoreGraphics
import Foundation
import Testing

extension StoreTests {
  /// What follows a send through a `HostedStore`: the window, then what
  /// VoiceOver is told, then the parent, all by the time the send returns, so
  /// nothing already queued comes between a change and what follows from it.
  @MainActor
  @Suite(.timeLimit(.minutes(1)))
  struct HostedParentTests {
    /// Every way an input reaches the toast.
    enum Input: CaseIterable {
      case expandButton
      case answerButton
      case click
      case key
      case pointer
      case drag
    }

    /// The toast's two countdowns.
    enum Countdown: CaseIterable {
      case suggestion
      case note
    }

    /// The toast under a parent, as the app's root has it.
    @Reducer
    struct Root {
      @ObservableState
      struct State: Equatable {
        var toast = ToastFeature.State()
      }

      enum Action {
        case toast(ToastFeature.Action)
      }

      let parent: HostedParent<ToastFeature.Action.Delegate>

      var body: some ReducerOf<Self> {
        Scope(\.toast, action: \.toast) {
          ToastFeature()
        }
        Reduce { _, action in
          switch action {
          case .toast(.delegate(let delegate)):
            return parent.forward(delegate)
          case .toast:
            return .none
          }
        }
      }
    }

    private struct Answer: Equatable {
      var id: Int64
      var feedback: SuggestionFeedback
    }

    /// As much of the app as follows a send: a parent that acts on what the
    /// toast delegates and a window that follows it.
    @MainActor
    private final class App {
      let toast: HostedStoreOf<ToastFeature>
      private let parent = HostedParent<ToastFeature.Action.Delegate>()
      var talkBack = TalkBackState.idle
      var isPaused = false
      var held: Suggestion?
      var answers: [Answer] = []
      var whileActing: (@MainActor (Suggestion) -> Void)?
      private(set) var shown = ToastFeature.State()
      /// Times the window installed its key monitors.
      private(set) var keyInstalls = 0
      private var watchesKeys = false
      /// What was done, by the window, VoiceOver and the parent, in one order.
      let done = LockIsolated<[String]>([])

      init(clock: AdjustableClock) {
        let parent = parent
        let done = done
        let features: HostedStoreOf<Root> = HostedStore(
          initialState: Root.State(),
          parent: parent,
          reducer: {
            Root(parent: parent)
          },
          withDependencies: {
            $0.athinaClock = clock
            $0.announcer.post = { text, _ in done.withValue { $0.append("said \(text)") } }
          }
        )
        toast = features.scope(\.toast, action: \.toast)
        parent.receive = { [weak self] delegate in self?.act(on: delegate) }
        toast.follow { [weak self] in self?.followToast() }
      }

      private func followToast() {
        let state = toast.state
        if state != shown {
          done.withValue { $0.append("window") }
        }
        if state.panel.looksAgainForKeys(since: shown.panel) {
          watchesKeys = false
        }
        if state.watchesKeyPresses, !watchesKeys {
          keyInstalls += 1
        }
        watchesKeys = state.watchesKeyPresses
        shown = state
      }

      private func act(on delegate: ToastFeature.Action.Delegate) {
        guard case .answered(let suggestion, let feedback) = delegate else { return }
        answers.append(Answer(id: suggestion.id, feedback: feedback))
        done.withValue { $0.append("parent") }
        whileActing?(suggestion)
        guard feedback != .tellMeMore else { return }
        talkBack = .idle
        guard let held else { return }
        self.held = nil
        // A pause that came first expires what was held instead.
        if !isPaused {
          toast.send(.show(held, exchange: [], arrival: .unasked(expiresAfter: nil)))
        }
      }

      func listen(to suggestion: Suggestion) {
        guard talkBack == .idle else { return }
        talkBack = .listening(partial: "")
        toast.send(.show(suggestion, exchange: [], arrival: .asked))
        toast.send(.talkBackChanged(talkBack))
      }

      func clickOutside() {
        // Only a window that is watching hears a click.
        guard shown.watchesClicks else { return }
        toast.send(
          .mouseDown(ToastClick(onToast: false, location: .zero, menuBarItems: []))
        )
      }
    }

    private static let firstSaid = "Athina, Shortcut in TextEdit: Title 1. Body 1."
    private static let whereAnswers = " Answer it from the Athina menu."

    private static let start = Date(timeIntervalSince1970: 1_789_473_600)

    private let clock = AdjustableClock(startingAt: HostedParentTests.start)
    private let first = HostedParentTests.suggestion(1)
    private let second = HostedParentTests.suggestion(2)

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

    private func makeApp() -> App {
      App(clock: clock)
    }

    /// Runs `one` and `other` as two jobs that were both on the main queue
    /// before either ran, as two inputs that come in together are.
    private func queuedTogether(
      _ one: @escaping @MainActor @Sendable () -> Void,
      _ other: @escaping @MainActor @Sendable () -> Void
    ) async {
      await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
        DispatchQueue.main.async { MainActor.assumeIsolated { one() } }
        DispatchQueue.main.async {
          MainActor.assumeIsolated { other() }
          done.resume()
        }
      }
    }

    /// Reads `value` from a job that stands in the main queue behind whatever
    /// a timeout has queued, again each turn until `isDue`, within a bound.
    private func readBehind<Value: Sendable>(
      until isDue: @escaping @MainActor @Sendable () -> Bool,
      _ value: @escaping @MainActor @Sendable () -> Value
    ) async -> Value? {
      await withCheckedContinuation { (done: CheckedContinuation<Value?, Never>) in
        @Sendable func look(turnsLeft: Int) {
          DispatchQueue.main.async {
            MainActor.assumeIsolated {
              if isDue() {
                done.resume(returning: value())
              } else if turnsLeft == 0 {
                done.resume(returning: nil)
              } else {
                look(turnsLeft: turnsLeft - 1)
              }
            }
          }
        }
        look(turnsLeft: 1_000)
      }
    }

    /// Lets whatever is due run, in a bounded number of turns.
    private func settle() async {
      for _ in 0..<100 { await Task.yield() }
    }

    // MARK: Two inputs that come in together

    @Test func aPressQueuedBehindNotNowIsHeard() async {
      let app = makeApp()
      app.listen(to: first)
      await queuedTogether(
        { app.toast.send(.answerButtonTapped(.notNow)) },
        { [first] in app.listen(to: first) }
      )
      #expect(app.talkBack == .listening(partial: ""), "the press was lost")
      #expect(app.toast.suggestion == first)
    }

    @Test func aPauseQueuedBehindACloseLeavesTheHeldSuggestionShown() async {
      let app = makeApp()
      app.listen(to: first)
      app.held = second
      await queuedTogether(
        { app.toast.send(.answerButtonTapped(.dismissed)) },
        { app.isPaused = true }
      )
      #expect(app.toast.suggestion == second, "the held suggestion was expired unseen")
    }

    @Test func aClickQueuedBehindAnArrivalTakesItDown() async {
      let app = makeApp()
      await queuedTogether(
        { [first] in app.toast.send(.show(first, exchange: [], arrival: .asked)) },
        { app.clickOutside() }
      )
      #expect(app.toast.suggestion == nil, "the click was ignored")
      #expect(app.answers == [Answer(id: 1, feedback: .dismissed)])
    }

    // MARK: Every send

    @Test(arguments: Input.allCases)
    func everyInputIsFollowedBeforeItsSendReturns(input: Input) {
      let app = makeApp()
      let action: ToastFeature.Action
      var expected: [Answer] = []
      if input == .key {
        app.toast.send(.sensingModeChanged(.watching))
        app.toast.send(.showNote(ToastFeature.Note("Choose Allow.", untilClicked: true)))
      } else {
        app.toast.send(.show(first, exchange: [], arrival: .asked))
      }
      switch input {
      case .expandButton:
        action = .expandButtonTapped
        expected = [Answer(id: 1, feedback: .tellMeMore)]
      case .answerButton:
        action = .answerButtonTapped(.notNow)
        expected = [Answer(id: 1, feedback: .notNow)]
      case .click:
        action = .mouseDown(ToastClick(onToast: false, location: .zero, menuBarItems: []))
        expected = [Answer(id: 1, feedback: .dismissed)]
      case .key:
        action = .keyDown(isRepeat: false)
      case .pointer:
        action = .hoverChanged(true)
      case .drag:
        action = .dragged(topLeft: CGPoint(x: 120, y: 640))
      }

      app.toast.send(action)
      let windowHasFollowed = app.shown == app.toast.state
      #expect(windowHasFollowed, "the window has yet to follow")
      #expect(app.answers == expected, "the parent has yet to act")
    }

    /// The job behind the timeout is already queued as the timeout's send
    /// runs, so it comes before anything a later turn of the run loop does.
    @Test(arguments: Countdown.allCases)
    func aTimeoutIsFollowedBeforeWorkQueuedBehindIt(countdown: Countdown) async {
      await withMainSerialExecutor {
        let app = makeApp()
        let expected: [Answer]
        let length: TimeInterval
        switch countdown {
        case .suggestion:
          length = 60
          expected = [Answer(id: 1, feedback: .expired)]
          app.toast.send(.show(first, exchange: [], arrival: .unasked(expiresAfter: length)))
        case .note:
          let note = ToastFeature.Note("Athina did not catch that.")
          length = ToastPlacement.noteDuration(for: note.text)
          expected = []
          app.toast.send(.showNote(note))
        }
        await settle()
        clock.advance(by: .seconds(length))
        let found = await readBehind(
          until: { !app.toast.isUp },
          { (windowHasFollowed: app.shown == app.toast.state, answers: app.answers) }
        )
        #expect(found?.windowHasFollowed == true, "the window has yet to follow")
        #expect(found?.answers == expected, "the parent has yet to act")
      }
    }

    // MARK: The order

    @Test func whatIsSaidWaitsForTheWindow() {
      let app = makeApp()
      app.toast.send(.show(first, exchange: [], arrival: .asked))
      app.toast.send(.talkBackChanged(.listening(partial: "")))
      app.toast.send(.showNote(ToastFeature.Note("A note.")))
      #expect(
        app.done.value == [
          "window", "said \(Self.firstSaid)\(Self.whereAnswers)",
          "window", "said Listening",
          "window", "said A note.",
        ]
      )
    }

    @Test func whatIsSaidComesBeforeTheParentActs() {
      let app = makeApp()
      app.toast.send(.show(first, exchange: [], arrival: .asked))
      // A window's own send announces while the answer waits for the parent.
      app.toast.follow { [weak app] in
        guard let app, app.toast.suggestion == nil, app.toast.note == nil else { return }
        app.toast.send(.showNote(ToastFeature.Note("A note.")))
      }
      app.done.setValue([])
      app.whileActing = { [weak app] _ in
        app?.done.withValue { $0.append("parent said") }
      }
      app.toast.send(.answerButtonTapped(.dismissed))
      #expect(app.done.value == ["window", "window", "said A note.", "parent", "parent said"])
    }

    @Test func whatASendOfTheParentsSaysWaitsForTheWindowAndNoLonger() {
      let app = makeApp()
      app.toast.send(.show(first, exchange: [], arrival: .asked))
      app.done.setValue([])
      app.whileActing = { [weak app] _ in
        guard let app else { return }
        app.toast.send(.showNote(ToastFeature.Note("A note.")))
        app.done.withValue { $0.append("parent said") }
      }
      app.toast.send(.answerButtonTapped(.dismissed))
      #expect(app.done.value == ["window", "parent", "window", "said A note.", "parent said"])
    }

    @Test func whatAFollowsOwnSendSaysWaitsForEveryFollowInTheOrderItWasSent() {
      let app = makeApp()
      app.toast.follow { [weak app] in
        guard let app, app.toast.suggestion != nil, app.toast.note == nil else { return }
        app.toast.send(.showNote(ToastFeature.Note("A note.")))
      }
      app.toast.send(.show(first, exchange: [], arrival: .asked))
      #expect(
        app.done.value == [
          "window", "window", "said \(Self.firstSaid)\(Self.whereAnswers)", "said A note.",
        ]
      )
    }

    @Test func eachNoteThatWaitsLooksAgainForKeysInsideTheToastToo() {
      let app = makeApp()
      app.toast.send(.sensingModeChanged(.watching))
      app.toast.send(.show(first, exchange: [], arrival: .asked))
      app.toast.send(.showNote(ToastFeature.Note("Allow it.", untilClicked: true)))
      #expect(app.keyInstalls == 1)
      app.toast.send(.showNote(ToastFeature.Note("Allow that.", untilClicked: true)))
      #expect(app.keyInstalls == 2, "the note that replaced it did not look again")
      // What is not a note that waits looks at nothing.
      app.toast.send(.talkBackKeyChanged("⌃T"))
      #expect(app.keyInstalls == 2)
    }

    @Test func theWindowHasFollowedWhenTheParentActs() {
      let app = makeApp()
      let found = LockIsolated<[Bool]>([])
      app.whileActing = { [weak app] _ in
        guard let app else { return }
        let windowHasFollowed = app.shown == app.toast.state
        found.withValue { $0.append(windowHasFollowed) }
      }
      app.toast.send(.show(first, exchange: [], arrival: .asked))
      app.toast.send(.answerButtonTapped(.dismissed))
      #expect(found.value == [true], "the parent acted ahead of the window")
    }

    @Test func whatIsDelegatedWhileTheParentActsWaitsForItToReturn() {
      let app = makeApp()
      let order = LockIsolated<[String]>([])
      app.whileActing = { [weak app, second] suggestion in
        guard let app else { return }
        order.withValue { $0.append("begins \(suggestion.id)") }
        if suggestion.id == 1 {
          app.toast.send(.show(second, exchange: [], arrival: .asked))
          app.toast.send(.answerButtonTapped(.dismissed))
        }
        order.withValue { $0.append("ends \(suggestion.id)") }
      }
      app.toast.send(.show(first, exchange: [], arrival: .asked))
      app.toast.send(.answerButtonTapped(.dismissed))
      #expect(order.value == ["begins 1", "ends 1", "begins 2", "ends 2"])
    }

    @Test func aFollowsOwnSendIsFollowedAfterItAndNeverInsideIt() {
      let app = makeApp()
      let depth = LockIsolated<[Int]>([])
      let inside = LockIsolated(0)
      app.toast.follow { [weak app] in
        guard let app else { return }
        inside.withValue { $0 += 1 }
        depth.withValue { $0.append(inside.value) }
        if app.toast.suggestion != nil, !app.toast.suggestionHovered {
          app.toast.send(.hoverChanged(true))
        }
        inside.withValue { $0 -= 1 }
      }
      app.toast.send(.show(first, exchange: [], arrival: .asked))
      #expect(app.toast.suggestionHovered, "the window has yet to follow")
      let windowHasFollowed = app.shown == app.toast.state
      #expect(windowHasFollowed)
      #expect(depth.value.allSatisfy { $0 == 1 })
    }
  }
}
