import AppKit
import AthinaCore
import ComposableArchitecture
import CoreGraphics
import Foundation

/// The toast's lifecycle: a suggestion shown, counted down, held, answered and
/// taken down, and the notes shown in it or in its place.
///
/// It decides and the app draws: `ToastView` over the store, and
/// `ToastController` following `State.panel` and what the state says to watch.
/// Each countdown is `ToastCountdown`'s, waited out on the one clock. An answer
/// that starts here goes to the parent as `Action.Delegate.answered`, since
/// recording it, snoozing and what else comes down with the toast are the
/// parent's; one that starts with the parent reaches here as `Action.answered`,
/// the expiry of a suggestion it is replacing included.
@Reducer
public struct ToastFeature {
  /// A short line for the person, inside the toast or on its own.
  public struct Note: Equatable, Sendable {
    /// What it says.
    public var text: String
    /// Whether it stays until the next click rather than timing out, as one
    /// that names a next step does, or until the next key press while the
    /// sensing mode lets a note notice one.
    public var untilClicked: Bool

    /// Creates a note, by default one that clears itself once there has been
    /// time to read it.
    public init(_ text: String, untilClicked: Bool = false) {
      self.text = text
      self.untilClicked = untilClicked
    }
  }

  /// How a suggestion came to be shown.
  public enum Arrival: Equatable, Sendable {
    /// The person did not ask for it, so VoiceOver hears it after what it is
    /// saying rather than over it; with no `expiresAfter` it waits to be
    /// answered or closed.
    case unasked(expiresAfter: TimeInterval?)
    /// The person asked for it, as Show Last Suggestion does: VoiceOver says
    /// it at once and it stays until answered or closed.
    case asked
  }

  /// What the panel has been asked to do, each counted, since being asked
  /// again, as a note shown over a note asks, changes nothing else.
  public struct Panel: Equatable, Sendable {
    /// Times it was asked on screen with new content, placed at once.
    public var presented = 0
    /// Times it was asked off screen.
    public var orderedOut = 0
    /// Times it was asked above anything shown since, such as a callout.
    public var raised = 0
    /// Times it was asked to watch for a key afresh, by each note that waits
    /// for one, inside the toast too.
    public var waitingNotes = 0

    /// Creates a panel that has been asked nothing.
    public init() {}

    /// Whether key presses are to be watched afresh, so that whether other
    /// apps' can be heard is looked at again.
    ///
    /// - Parameter done: What had been asked when they were last looked at.
    /// - Returns: Whether the monitors are to be installed again.
    public func looksAgainForKeys(since done: Panel) -> Bool {
      presented != done.presented || waitingNotes != done.waitingNotes
    }
  }

  /// What the toast shows and what it is waiting for.
  @ObservableState
  public struct State: Equatable {
    /// The suggestion on screen, if any.
    public var suggestion: Suggestion?
    /// Whether its explanation shows.
    public var expanded: Bool
    /// The talk-back exchange about it, oldest first.
    public var exchange: [FollowUp]
    /// Whose API the exchange's questions went to.
    public var provider = ModelProvider.anthropic
    /// What push-to-talk is doing.
    ///
    /// While the person is talking back, no click, timeout or hover takes the
    /// toast down.
    public var talkBack: TalkBackState
    /// The note on screen, if any.
    public var note: Note?
    /// The talk-back hotkey, shown in the button bar once it is set and voice
    /// is usable.
    public var talkBackKey: String?
    /// What the callout outlines for the suggestion, while it is up: the
    /// callout draws no words of its own.
    public var outlined: String?

    /// What the panel has been asked to do.
    public var panel = Panel()
    /// Where the person dragged the panel to, its top-left corner, until the
    /// next suggestion.
    public var movedTopLeft: CGPoint?
    /// The suggestion's time on screen.
    public var countdown = ToastCountdown()
    /// The note's time on screen.
    public var noteCountdown = ToastCountdown()
    /// Whether the pointer is over the panel.
    ///
    /// An ordered-out panel is not told the pointer left it, so the pointer is
    /// taken to be off it until it comes over again.
    public var pointerOverPanel = false
    /// Whether the pointer came over the toast since the suggestion was shown,
    /// and has not left: kept through an exchange, so a countdown given back
    /// afterwards does not run under it.
    public var suggestionHovered = false
    /// What Athina is sensing, which says whether a waiting note may notice
    /// key presses.
    public var sensingMode = SensingMode.stopped
    /// Whether VoiceOver has been told once where the answers are.
    public var saidWhereAnswersAre = false

    /// Whether there is anything for the panel to show.
    public var isUp: Bool { suggestion != nil || note != nil }

    /// Whether mouse-downs are watched: while a suggestion is up, and while a
    /// note waits for a click.
    public var watchesClicks: Bool { suggestion != nil || note?.untilClicked == true }

    /// Whether key presses are watched: only while a note waits and Athina is
    /// allowed to watch and is watching (`ToastPlacement.noticesKeyPresses(in:)`).
    public var watchesKeyPresses: Bool {
      note?.untilClicked == true && ToastPlacement.noticesKeyPresses(in: sensingMode)
    }

    /// Creates a toast, by default one showing nothing; the arguments are what
    /// it draws, for a sample.
    public init(
      suggestion: Suggestion? = nil,
      expanded: Bool = false,
      exchange: [FollowUp] = [],
      talkBack: TalkBackState = .idle,
      note: Note? = nil,
      talkBackKey: String? = nil,
      outlined: String? = nil
    ) {
      self.suggestion = suggestion
      self.expanded = expanded
      self.exchange = exchange
      self.talkBack = talkBack
      self.note = note
      self.talkBackKey = talkBackKey
      self.outlined = outlined
    }
  }

  /// What happens to the toast.
  public enum Action: Sendable {
    /// Tell Me More, or Show Less once it is expanded, was clicked.
    case expandButtonTapped
    /// Close, Not Now or Never for This was clicked.
    case answerButtonTapped(SuggestionFeedback)
    /// The pointer came over the panel or left it.
    case hoverChanged(Bool)
    /// A mouse button went down while clicks were watched.
    case mouseDown(ToastClick)
    /// A key went down while key presses were watched; never which key.
    case keyDown(isRepeat: Bool)
    /// The person dragged the panel, its top-left corner now here.
    case dragged(topLeft: CGPoint)

    /// Show a suggestion, or bring the one on screen to the front with its
    /// countdown off.
    ///
    /// Precondition: no other suggestion is on screen. The parent answers the
    /// one it replaces first (`answered`), so that one and what goes with it
    /// are down before this one is up.
    case show(Suggestion, exchange: [FollowUp], arrival: Arrival)
    /// The suggestion was answered somewhere other than the toast: the menu,
    /// the Suggestions window, a spoken reply, or the app ending it, as it
    /// does one it is about to replace.
    case answered(suggestionID: Int64, SuggestionFeedback)
    /// Show the explanation, and have VoiceOver say it at once.
    case expand
    /// Order the panel above anything shown since.
    case raise
    /// Show a note.
    case showNote(Note)
    /// The person began talking back: the countdown stops, keeping what it had
    /// left.
    case talkBackBegan
    /// What push-to-talk is doing changed.
    case talkBackChanged(TalkBackState)
    /// A talk-back press ended, leaving the toast doing what the outcome says.
    case pressEnded(suggestionID: Int64, TalkBackPress.Outcome)
    /// The exchange changed, its questions gone to the provider's API.
    case exchangeChanged([FollowUp], provider: ModelProvider)
    /// The talk-back hotkey to show changed.
    case talkBackKeyChanged(String?)
    /// The callout outlines something, or nothing any more.
    case outlinedChanged(String?)
    /// A callout was drawn for the suggestion, as journaled.
    case calloutNoted(Suggestion)
    /// What Athina is sensing changed.
    case sensingModeChanged(SensingMode)

    /// The suggestion's countdown reached the deadline it was waited out for.
    case countdownEnded(deadline: Date)
    /// The note's countdown reached the deadline it was waited out for.
    case noteCountdownEnded(deadline: Date)

    /// What the parent is asked to act on.
    case delegate(Delegate)

    /// What the toast tells its parent.
    @CasePathable
    public enum Delegate: Equatable, Sendable {
      /// The suggestion was answered at the toast or timed out; any answer but
      /// Tell Me More has already taken it down.
      case answered(Suggestion, SuggestionFeedback)
    }
  }

  private enum CancelID {
    case countdown
    case noteCountdown
  }

  @Dependency(\.announcer) var announcer
  @Dependency(\.athinaClock) var clock
  @Dependency(\.sendReturned) var sendReturned

  /// Creates the feature.
  public init() {}

  /// What each action changes and the effects it starts.
  public var body: some ReducerOf<Self> {
    Reduce { state, action in
      switch action {
      case .expandButtonTapped:
        guard state.suggestion != nil else { return .none }
        state.expanded.toggle()
        // Expanding reports "tell me more", which the parent records once per
        // suggestion; folding is only a view change.
        return state.expanded ? answerHere(&state, with: .tellMeMore) : .none

      case .answerButtonTapped(let feedback):
        return answerHere(&state, with: feedback)

      case .hoverChanged(let hovering):
        state.pointerOverPanel = hovering
        state.suggestionHovered = hovering
        return .merge(
          holdNote(&state, whileHovering: hovering),
          holdSuggestion(&state, whileHovering: hovering)
        )

      case .mouseDown(let click):
        guard state.suggestion != nil else {
          // A note that waits for the next click, wherever it lands.
          return state.note?.untilClicked == true ? takeDownNote(&state) : .none
        }
        guard click.dismissesToast(talkBack: state.talkBack) else { return .none }
        return answerHere(&state, with: .dismissed)

      case .keyDown(let isRepeat):
        // A key held since before the note came up, such as the talk-back
        // shortcut that brought it, repeats rather than going down again.
        guard state.watchesKeyPresses, !isRepeat else { return .none }
        return takeDownNote(&state)

      case .dragged(let topLeft):
        state.movedTopLeft = topLeft
        return .none

      case .show(let suggestion, let exchange, let arrival):
        return show(&state, suggestion, exchange: exchange, arrival: arrival)

      case .answered(let suggestionID, let feedback):
        guard state.suggestion?.id == suggestionID else { return .none }
        return answer(&state, with: feedback)

      case .expand:
        state.expanded = true
        guard let suggestion = state.suggestion else { return .none }
        return announcer.announce(suggestion.explanation, priority: .high)

      case .raise:
        state.panel.raised += 1
        return .none

      case .showNote(let note):
        return show(&state, note)

      case .talkBackBegan:
        state.countdown.hold(at: clock.date)
        return .cancel(id: CancelID.countdown)

      case .talkBackChanged(let talkBack):
        return changeTalkBack(&state, to: talkBack)

      case .pressEnded(let suggestionID, let outcome):
        return endPress(&state, about: suggestionID, leaving: outcome)

      case .exchangeChanged(let exchange, let provider):
        return changeExchange(&state, to: exchange, provider: provider)

      case .talkBackKeyChanged(let key):
        state.talkBackKey = key
        return .none

      case .outlinedChanged(let outlined):
        state.outlined = outlined
        return .none

      case .calloutNoted(let updated):
        guard state.suggestion?.id == updated.id else { return .none }
        state.suggestion?.calloutShown = updated.calloutShown
        return .none

      case .sensingModeChanged(let mode):
        state.sensingMode = mode
        return .none

      case .countdownEnded(let deadline):
        // Still this countdown: not held, cancelled, or run again meanwhile.
        guard state.countdown.deadline == deadline else { return .none }
        return answerHere(&state, with: .expired)

      case .noteCountdownEnded(let deadline):
        guard state.noteCountdown.deadline == deadline else { return .none }
        return takeDownNote(&state)

      case .delegate:
        return .none
      }
    }
  }

  // MARK: The suggestion

  private func show(
    _ state: inout State,
    _ suggestion: Suggestion,
    exchange: [FollowUp],
    arrival: Arrival
  ) -> Effect<Action> {
    if state.suggestion?.id == suggestion.id {
      state.panel.raised += 1
      return stopCountdown(&state)
    }
    var effects = [clearNote(&state), stopCountdown(&state)]
    state.suggestionHovered = false
    state.movedTopLeft = nil
    state.suggestion = suggestion
    state.expanded = false
    state.exchange = exchange
    state.talkBack = .idle
    state.panel.presented += 1

    var announcement = Self.announcement(for: suggestion)
    if !state.saidWhereAnswersAre {
      state.saidWhereAnswersAre = true
      announcement += " Answer it from the Athina menu."
    }
    let priority: NSAccessibilityPriorityLevel = arrival == .asked ? .high : .medium
    effects.append(announcer.announce(announcement, priority: priority))
    if case .unasked(let timeout?) = arrival {
      effects.append(startCountdown(&state, for: timeout))
    }
    return .merge(effects)
  }

  /// An answer that started at the toast, which the parent has to hear of.
  private func answerHere(
    _ state: inout State,
    with feedback: SuggestionFeedback
  ) -> Effect<Action> {
    guard let suggestion = state.suggestion else { return .none }
    return .merge(
      answer(&state, with: feedback),
      .send(.delegate(.answered(suggestion, feedback)))
    )
  }

  /// Every answer stops the countdown, and every one but Tell Me More takes
  /// the toast down.
  private func answer(_ state: inout State, with feedback: SuggestionFeedback) -> Effect<Action> {
    feedback == .tellMeMore ? stopCountdown(&state) : takeDown(&state)
  }

  private func takeDown(_ state: inout State) -> Effect<Action> {
    state.outlined = nil
    state.suggestion = nil
    state.exchange = []
    state.talkBack = .idle
    orderOut(&state)
    return .merge(stopCountdown(&state), clearNote(&state))
  }

  /// The countdown holds while the pointer is over the toast and resumes with
  /// what it had left when it leaves, except during an exchange.
  private func holdSuggestion(_ state: inout State, whileHovering: Bool) -> Effect<Action> {
    guard state.suggestion != nil, !state.talkBack.keepsToastUp else { return .none }
    if whileHovering {
      guard state.countdown.deadline != nil else { return .none }
      state.countdown.hold(at: clock.date)
      return .cancel(id: CancelID.countdown)
    }
    guard let remaining = state.countdown.held else { return .none }
    return startCountdown(&state, for: remaining)
  }

  private func startCountdown(_ state: inout State, for timeout: TimeInterval) -> Effect<Action> {
    // An exchange in progress keeps the toast up; nothing schedules its end.
    guard !state.talkBack.keepsToastUp else { return .none }
    state.countdown.run(for: timeout, from: clock.date)
    guard let deadline = state.countdown.deadline else { return .none }
    return .mainTask { [clock, sendReturned] send in
      do {
        try await clock.sleep(untilDate: deadline)
      } catch {
        // Cancelled: held, taken down, or run again first.
        return
      }
      send(.countdownEnded(deadline: deadline))
      sendReturned()
    }
    .cancellable(id: CancelID.countdown, cancelInFlight: true)
  }

  private func stopCountdown(_ state: inout State) -> Effect<Action> {
    state.countdown.cancel()
    return .cancel(id: CancelID.countdown)
  }

  // MARK: Notes

  private func show(_ state: inout State, _ note: Note) -> Effect<Action> {
    var effects = [clearNote(&state)]
    state.note = note
    if state.suggestion == nil {
      state.panel.presented += 1
    }
    if note.untilClicked {
      state.panel.waitingNotes += 1
    }
    effects.append(announcer.announce(note.text))
    if !note.untilClicked {
      let duration = ToastPlacement.noteDuration(for: note.text)
      if state.pointerOverPanel {
        state.noteCountdown.run(for: duration, from: clock.date)
        state.noteCountdown.hold(at: clock.date)
      } else {
        effects.append(startNoteCountdown(&state, for: duration))
      }
    }
    return .merge(effects)
  }

  /// A note's time stands still while the pointer is over it, and runs on with
  /// what it had when it leaves.
  private func holdNote(_ state: inout State, whileHovering: Bool) -> Effect<Action> {
    guard let note = state.note, !note.untilClicked else { return .none }
    if whileHovering {
      state.noteCountdown.hold(at: clock.date)
      return .cancel(id: CancelID.noteCountdown)
    }
    guard let remaining = state.noteCountdown.held else { return .none }
    return startNoteCountdown(&state, for: remaining)
  }

  private func startNoteCountdown(
    _ state: inout State,
    for duration: TimeInterval
  ) -> Effect<Action> {
    state.noteCountdown.run(for: duration, from: clock.date)
    guard let deadline = state.noteCountdown.deadline else { return .none }
    return .mainTask { [clock, sendReturned] send in
      do {
        try await clock.sleep(untilDate: deadline)
      } catch {
        // Cancelled: held, cleared, or run again first.
        return
      }
      send(.noteCountdownEnded(deadline: deadline))
      sendReturned()
    }
    .cancellable(id: CancelID.noteCountdown, cancelInFlight: true)
  }

  private func clearNote(_ state: inout State) -> Effect<Action> {
    state.note = nil
    state.noteCountdown.cancel()
    return .cancel(id: CancelID.noteCountdown)
  }

  private func takeDownNote(_ state: inout State) -> Effect<Action> {
    if state.suggestion == nil {
      orderOut(&state)
    }
    return clearNote(&state)
  }

  private func orderOut(_ state: inout State) {
    state.panel.orderedOut += 1
    state.pointerOverPanel = false
  }

  // MARK: Talking back

  /// While the person talks back the toast is brought to the front so no
  /// window covers it, and VoiceOver hears each stage as it begins.
  private func changeTalkBack(_ state: inout State, to talkBack: TalkBackState) -> Effect<Action> {
    let previous = state.talkBack
    state.talkBack = talkBack
    if talkBack.keepsToastUp {
      state.panel.raised += 1
    }
    switch (previous, talkBack) {
    case (.listening, .listening), (.thinking, .thinking), (_, .idle), (_, .waiting):
      return .none
    case (_, .listening):
      return announcer.announce("Listening")
    case (_, .thinking):
      return announcer.announce("Asking the mentor")
    }
  }

  /// A press's end turns the countdown off without cancelling anything, since
  /// a sleep still waiting ends at the deadline it had and does nothing; one
  /// that came to nothing then gives back the countdown it interrupted, still
  /// held under the pointer.
  private func endPress(
    _ state: inout State,
    about suggestionID: Int64,
    leaving outcome: TalkBackPress.Outcome
  ) -> Effect<Action> {
    state.countdown.cancel()
    guard case .notAnExchange(let remaining?) = outcome, state.suggestion?.id == suggestionID
    else { return .none }
    if state.suggestionHovered {
      state.countdown.run(for: remaining, from: clock.date)
      state.countdown.hold(at: clock.date)
      return .none
    }
    return startCountdown(&state, for: remaining)
  }

  private func changeExchange(
    _ state: inout State,
    to exchange: [FollowUp],
    provider: ModelProvider
  ) -> Effect<Action> {
    let shown = state.exchange.last
    state.provider = provider
    state.exchange = exchange
    guard let latest = exchange.last, latest.id != shown?.id || latest.answer != shown?.answer
    else { return .none }
    let said =
      latest.answer.map { "Athina answered: \($0)" } ?? Self.failure(latest, provider: provider)
    return announcer.announce(said, priority: .high)
  }

  // MARK: Words

  /// What VoiceOver hears for a suggestion: what the header, title and body
  /// show.
  static func announcement(for suggestion: Suggestion) -> String {
    """
    Athina, \(suggestion.category.label) in \(suggestion.appName): \(suggestion.title). \
    \(suggestion.body)
    """
  }

  /// What the person reads, and VoiceOver hears, for a question that got no
  /// answer: why, in Athina's own words (`UserFacing`).
  ///
  /// - Parameters:
  ///   - entry: The question that got no answer.
  ///   - provider: Whose API it went to, which the sentence names.
  /// - Returns: The sentence.
  public static func failure(_ entry: FollowUp, provider: ModelProvider) -> String {
    UserFacing.followUpError(entry.error ?? "unknown error", provider: provider)
  }
}
