import Foundation
import Testing

@testable import AthinaCore

/// What ends the mentor loop's work on the screen.
private enum Stop: CaseIterable {
  case pause
  case pauseThenResume
  case withdrawalThenAllow
  case deleteEverything
}

private let yes = #"{"worth_a_look": true, "reason": "Repeated manual runs"}"#
private let no = #"{"worth_a_look": false, "reason": "Reading docs"}"#
private let silence = #"{"reason": "Nothing stands out", "suggestion": null}"#
private let suggestion =
  #"""
  {"reason": "Saw it", "suggestion": {"title": "Use --filter", "body": "Run one suite.", \#
  "explanation": "swift test --filter Name", "category": "shortcut", "confidence": 0.9}}
  """#

/// Long enough on the network that the next screen waiting behind the call is
/// due triage when it returns, and not yet stale.
private let callTime = Duration.seconds(25)

extension MentorHarness where Client == ScriptedClaudeClient {
  /// Does `stop` as the app does it to the loop.
  fileprivate func apply(_ stop: Stop) async throws {
    switch stop {
    case .pause:
      await setPaused(true)
    case .pauseThenResume:
      await setPaused(true)
      await setPaused(false)
    case .withdrawalThenAllow:
      await setConsented(false)
      await setConsented(true)
    case .deleteEverything:
      await journalWillClear()
      await resetUnderstanding()
      try await journal.clear(at: clock.date)
      await journalCleared()
    }
  }

  /// Sends `observation` and returns with its triage call on the network, the
  /// calls after it answering at once.
  fileprivate func startTriage(of observation: ActivityObservation) async {
    await client.setDelay(callTime)
    send(.observation(observation))
    await clock.waitForSleepers()
    await client.setDelay(.zero)
  }

  /// Returns once the loop has finished with everything sent to it so far.
  fileprivate func settle() async {
    send(.modeChanged(.idle))
    await waitUntil { $0.mode == .idle }
    send(.modeChanged(.watching))
    await waitUntil { $0.mode == .watching }
  }

  fileprivate func journaledSuggestion() async throws -> Suggestion {
    try await journal.record(
      Suggestion(
        timestamp: clock.date,
        bundleID: "com.apple.dt.Xcode",
        appName: "Xcode",
        windowTitle: "main.swift",
        category: .shortcut,
        title: "Use --filter",
        body: "Run one suite.",
        explanation: "swift test --filter Name",
        confidence: 0.9,
        observationID: nil,
        model: "claude-opus-5",
        promptVersion: MentorPrompts.version
      )
    )
  }

  fileprivate var sentKinds: [String] {
    get async { await client.sent.map(\.call.kind) }
  }
}

extension InFlightWorkTests {
  /// A model request in the making at Pause, a withdrawal or Delete Everything.
  struct Requests {
    @Test(arguments: Stop.allCases)
    fileprivate func aScreenQueuedBehindACallIsNotSent(stop: Stop) async throws {
      let h = try await MentorLoopTests.Harness()
      await h.client.enqueue(json: no)
      await h.client.enqueue(json: yes)
      let first = try await h.journal.record(Fixtures.observation(at: h.clock.date))
      await h.startTriage(of: first)
      let queued = try await h.journal.record(
        Fixtures.observation(at: h.clock.date, window: "queued", text: "queued screen")
      )
      h.send(.observation(queued))

      try await h.apply(stop)
      h.clock.advance(by: callTime)
      await h.settle()
      #expect(await h.sentKinds == ["triage"])
      await h.stop()
    }

    @Test(arguments: Stop.allCases)
    fileprivate func aTriageReturningAfterwardsLeadsToNoMentorCall(stop: Stop) async throws {
      let h = try await MentorLoopTests.Harness()
      await h.client.enqueue(json: yes)
      await h.client.enqueue(json: silence)
      await h.startTriage(of: try await h.journal.record(Fixtures.observation(at: h.clock.date)))

      try await h.apply(stop)
      h.clock.advance(by: callTime)
      await h.settle()
      #expect(await h.sentKinds == ["triage"])
      await h.stop()
    }

    @Test(arguments: Stop.allCases)
    fileprivate func aTriageReturningAfterwardsLeadsToNoRefresh(stop: Stop) async throws {
      var settings = MentorSettings()
      settings.understandingRefreshInterval = MentorSettings.refreshIntervalRange.lowerBound
      let h = try await MentorLoopTests.Harness(
        settings: settings,
        understanding: Self.understanding(age: 400),
        activeUse: 400
      )
      await h.client.enqueue(json: no)
      await h.startTriage(of: try await h.journal.record(Fixtures.observation(at: h.clock.date)))

      try await h.apply(stop)
      h.clock.advance(by: callTime)
      await h.settle()
      #expect(await h.sentKinds == ["triage"])
      await h.stop()
    }

    /// The gate passed, and the stop came while the request was being built.
    @Test(arguments: Stop.allCases)
    fileprivate func aRequestBeingBuiltIsNotSent(stop: Stop) async throws {
      let h = try await MentorLoopTests.Harness(understanding: Self.understanding(age: 10))
      await h.client.enqueue(json: no)
      let observation = try await h.journal.record(Fixtures.observation(at: h.clock.date))
      let blocked = await h.journal.holdStill()
      h.send(.observation(observation))
      // The gate records its decision before the request first reads the
      // journal, and publishes nothing until that read is done.
      while !Task.isCancelled, await h.currentStatus().lastGate?.observationID != observation.id {
        await Task.yield()
      }

      if stop == .deleteEverything {
        // The rest of the deletion waits on the journal.
        await h.journalWillClear()
      } else {
        try await h.apply(stop)
      }
      blocked.release()
      await h.settle()
      #expect(await h.sentKinds.isEmpty)
      await h.stop()
    }

    @Test(arguments: [Stop.withdrawalThenAllow, .deleteEverything])
    fileprivate func aQueuedScreenFeedsNoLaterRequest(stop: Stop) async throws {
      let h = try await MentorLoopTests.Harness()
      await h.client.enqueue(json: no)
      await h.startTriage(of: try await h.journal.record(Fixtures.observation(at: h.clock.date)))
      let queued = try await h.journal.record(
        Fixtures.observation(at: h.clock.date, window: "queued", text: "queued screen")
      )
      h.send(.observation(queued))
      try await h.apply(stop)
      h.clock.advance(by: callTime)
      await h.settle()

      h.clock.advance(by: .seconds(21))
      await h.client.enqueue(json: yes)
      await h.client.enqueue(json: silence)
      let fresh = try await h.journal.record(
        Fixtures.observation(at: h.clock.date, window: "fresh", text: "fresh screen")
      )
      h.send(.observation(fresh))
      await h.settle()

      let requests = await h.client.sent.dropFirst()
      #expect(requests.map(\.call.kind) == ["triage", "mentor"])
      let texts = requests.flatMap { sent in
        sent.request.messages.flatMap(\.content).compactMap { block -> String? in
          guard case .text(let text) = block else { return nil }
          return text
        }
      }
      #expect(texts.allSatisfy { !$0.contains("queued screen") })
      await h.stop()
    }

    @Test func aQuestionAskedOncePausedIsNotSent() async throws {
      let h = try await MentorLoopTests.Harness()
      let asked = try await h.journaledSuggestion()
      await h.setPaused(true)
      let followUp = await h.askFollowUp(about: asked, question: "why")
      #expect(followUp?.error == MentorScheduler.Hold.paused.label)
      #expect(await h.sentKinds.isEmpty)
      await h.stop()
    }

    @Test(arguments: Stop.allCases)
    fileprivate func aQuestionWaitingBehindACallIsNotSent(stop: Stop) async throws {
      let h = try await MentorLoopTests.Harness()
      await h.client.enqueue(json: no)
      let asked = try await h.journaledSuggestion()
      await h.startTriage(of: try await h.journal.record(Fixtures.observation(at: h.clock.date)))
      let waiting = Task { await h.askFollowUp(about: asked, question: "why") }
      await h.waitUntil { $0.pendingFollowUp != nil }

      try await h.apply(stop)
      h.clock.advance(by: callTime)
      _ = await waiting.value
      await h.settle()
      #expect(await h.sentKinds == ["triage"])
      await h.stop()
    }

    /// The question's turn came, and the stop with it.
    @Test(arguments: Stop.allCases)
    fileprivate func aQuestionBeingBuiltIsNotSent(stop: Stop) async throws {
      let h = try await MentorLoopTests.Harness()
      await h.client.enqueue(json: no)
      let asked = try await h.journaledSuggestion()
      await h.startTriage(of: try await h.journal.record(Fixtures.observation(at: h.clock.date)))
      let waiting = Task { await h.askFollowUp(about: asked, question: "why") }
      await h.waitUntil { $0.pendingFollowUp != nil }
      let blocked = await h.journal.holdStill()
      h.clock.advance(by: callTime)
      // Cleared as the question's turn comes, before it reads the journal.
      while !Task.isCancelled, await h.currentStatus().pendingFollowUp != nil {
        await Task.yield()
      }

      if stop == .deleteEverything {
        await h.journalWillClear()
      } else {
        try await h.apply(stop)
      }
      blocked.release()
      _ = await waiting.value
      await h.settle()
      #expect(await h.sentKinds == ["triage"])
      await h.stop()
    }

    @Test func pauseExpiresAHeldSuggestionAheadOfTheStream() async throws {
      let h = try await MentorLoopTests.Harness()
      await h.setTalkingBack(true)
      await h.client.enqueue(json: yes)
      await h.client.enqueue(json: suggestion)
      await h.observe(Fixtures.observation(id: 1, at: h.clock.date), expectCalls: 2)

      await h.setPaused(true)
      #expect(try await h.journal.recentSuggestions(limit: 1).first?.feedback == .expiredUnseen)
      await h.stop()
    }

    @Test(arguments: [false, true])
    func aSuggestionFinishedWhilePausedIsNotShown(talkingBack: Bool) async throws {
      let h = try await MentorLoopTests.Harness()
      if talkingBack { await h.setTalkingBack(true) }
      await h.client.setDelay(.seconds(1))
      await h.client.enqueue(json: yes)
      await h.client.enqueue(json: suggestion)
      h.send(.observation(Fixtures.observation(at: h.clock.date)))
      await h.clock.waitForSleepers()
      h.clock.advance(by: .seconds(1))
      await h.waitUntil { $0.inFlight == .mentor }
      await h.clock.waitForSleepers()

      await h.setPaused(true)
      h.clock.advance(by: .seconds(1))
      await h.waitUntil { $0.lastMentor != nil }
      await h.setTalkingBack(false)
      let events = await h.drain { event in
        switch event {
        case .suggestion, .feedback: true
        default: false
        }
      }
      guard case .feedback(let expired)? = events.last else {
        Issue.record("expected the suggestion to expire unseen")
        return
      }
      #expect(expired.feedback == .expiredUnseen)
      await h.stop()
    }

    @Test(arguments: Stop.allCases)
    fileprivate func testConnectionCarriesNoScreenAndStillWorks(stop: Stop) async throws {
      let h = try await MentorLoopTests.Harness()
      await h.client.enqueue(json: "OK", model: "scripted")
      try await h.apply(stop)
      #expect(await h.testConnection() == .success("scripted"))
      await h.stop()
    }

    @Test(arguments: [Stop.pauseThenResume, .withdrawalThenAllow, .deleteEverything])
    fileprivate func aScreenCapturedAfterwardsIsSentAsUsual(stop: Stop) async throws {
      let h = try await MentorLoopTests.Harness()
      await h.client.enqueue(json: no)
      try await h.apply(stop)
      h.clock.advance(by: .milliseconds(1))
      await h.observe(Fixtures.observation(id: 1, at: h.clock.date), expectCalls: 1)
      #expect(await h.sentKinds == ["triage"])
      await h.stop()
    }

    @Test func everyGateHoldsWhatCarriesTheScreen() {
      let scheduler = MentorScheduler(settings: MentorSettings())
      let now = MentorLoopTests.Harness.start
      let observation = Fixtures.observation(at: now)
      for hold in [MentorScheduler.Hold.paused, .interrupted] {
        let conditions = MentorScheduler.Conditions(
          mode: .watching,
          consented: true,
          hasAPIKey: true,
          paused: hold == .paused,
          interrupted: hold == .interrupted,
          nextHourStart: now + 3600
        )
        #expect(
          scheduler.triageGate(for: observation, conditions: conditions, now: now) == .hold(hold)
        )
        #expect(
          scheduler.mentorGate(
            triage: TriageVerdict(worthALook: true, reason: "x"),
            context: .notEnforced,
            conditions: conditions,
            now: now
          ) == .hold(.unavailable(hold))
        )
        #expect(
          scheduler.refreshGate(
            conditions: conditions,
            context: nil,
            period: RefreshPeriod(startedAt: now - 3600, activeUse: 3600, countedAt: now),
            lastActivityAt: now,
            now: now
          ) == .hold(.unavailable(hold))
        )
        #expect(scheduler.followUpGate(conditions: conditions) == .hold(hold))
        for tier in ModelTier.allCases {
          #expect(
            MentorScheduler.callGate(for: tier, conditions: conditions)
              == (tier == .test ? nil : hold)
          )
        }
        #expect(
          scheduler.publishGate(madeAt: now, conditions: conditions, now: now)
            == (hold == .paused ? .paused : .show)
        )
        #expect(
          UserFacing.followUpError(hold.label, provider: .anthropic)
            == UserFacing.sentence(for: hold)
        )
      }
    }

    private static func understanding(age: TimeInterval) -> UnderstandingRecord {
      UnderstandingRecord.first(
        content: Understanding(
          goals: [
            Understanding.Goal(goal: "ship the app", evidence: "the same files", confidence: 0.8)
          ],
          timeline: ["opened the editor"]
        ),
        at: MentorLoopTests.Harness.start.addingTimeInterval(-age),
        model: "claude-opus-5",
        source: .periodic,
        cost: 0.02,
        promptVersion: MentorPrompts.version
      )
    }
  }
}
