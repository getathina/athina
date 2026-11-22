import CoreGraphics
import Foundation
import Testing

@testable import AthinaCore

private typealias App = FakeDesktop.App
private typealias Window = FakeDesktop.Window

private let athina = App("com.example.athina", pid: 10)
private let otherAthina = App("com.example.athina", pid: 11)
private let editor = App(FakeWindow.editor.bundleID, pid: FakeWindow.editor.pid)
private let browser = App(FakeWindow.browser.bundleID, pid: FakeWindow.browser.pid)
private let vault = App(FakeWindow.vault.bundleID, pid: FakeWindow.vault.pid)
private let vaultInOtherCase = App("com.Example.VAULT", pid: 304)
private let notes = App("com.example.vault-notes", pid: 404)
private let dock = App("com.apple.dock", pid: 20)
private let windowServer = App("", pid: 21)
private let unbundled = App("", pid: 505)

private let editorWindow = Window(app: editor, text: "editor draft")
private let browserWindow = Window(app: browser, text: "browser results")
private let vaultWindow = Window(app: vault, text: "vault recovery phrase")

/// Screenshots on a fake desktop: what an excluded app leaves of itself in one,
/// and what stays.
@Suite(.timeLimit(.minutes(1)))
struct CaptureExclusionTests {
  private func capture(
    _ desktop: FakeDesktop,
    ownBundleID: String? = athina.bundleIdentifier,
    windowFrame: CGRect? = FakeWindow.frame,
    excluding excluded: Set<String> = [vault.bundleIdentifier]
  ) async throws -> CapturedFrame {
    let capturer = ScreenCapturer(
      source: desktop,
      ownPID: athina.processID,
      ownBundleID: ownBundleID
    )
    return try await capturer.capture(
      windowFrame: windowFrame,
      maxDimension: 1280,
      excluding: excluded
    )
  }

  // MARK: Excluded apps

  /// The focused window's frame is all a capture is told of the app in front,
  /// so it holds whichever window that is, or none.
  @Test(arguments: [FakeWindow.frame, CGRect(x: 1000, y: 300, width: 500, height: 600), nil])
  func noWindowOfAnExcludedAppIsInTheImage(windowFrame: CGRect?) async throws {
    let desktop = FakeDesktop(windows: [
      editorWindow,
      vaultWindow,
      Window(app: vault, text: "vault second window"),
    ])
    let frame = try await capture(desktop, windowFrame: windowFrame)
    #expect(desktop.texts(in: frame.image) == ["editor draft"])
  }

  @Test func exclusionIgnoresTheCaseOfABundleIdentifier() async throws {
    let desktop = FakeDesktop(windows: [
      editorWindow,
      Window(app: vaultInOtherCase, text: "vault recovery phrase"),
    ])
    let frame = try await capture(desktop)
    #expect(desktop.texts(in: frame.image) == ["editor draft"])
  }

  @Test func aNewWindowOfAListedExcludedAppIsNotInTheImage() async throws {
    let desktop = FakeDesktop(windows: [editorWindow], running: [vault])
    desktop.appearAfterList(vaultWindow)
    let frame = try await capture(desktop)
    #expect(desktop.texts(in: frame.image) == ["editor draft"])
  }

  @Test func anExcludedAppThatAppearsAfterTheListIsNotInTheImage() async throws {
    let desktop = FakeDesktop(windows: [editorWindow])
    desktop.appearAfterList(vaultWindow)
    let frame = try await capture(desktop)
    #expect(desktop.texts(in: frame.image) == ["editor draft"])
  }

  @Test func anyAppThatAppearsAfterTheListWaitsForTheNextScreenshot() async throws {
    let desktop = FakeDesktop(windows: [editorWindow])
    desktop.appearAfterList(browserWindow)
    let first = try await capture(desktop)
    #expect(desktop.texts(in: first.image) == ["editor draft"])
    let next = try await capture(desktop)
    #expect(desktop.texts(in: next.image) == ["editor draft", "browser results"])
  }

  /// An empty list of apps to show could be read as no filter at all.
  @Test func nothingIsCapturedWhenNoListedAppMayBeShown() async throws {
    let desktop = FakeDesktop(windows: [vaultWindow, Window(app: athina, text: "athina toast")])
    await #expect(throws: ScreenCaptureError.self) {
      _ = try await capture(desktop)
    }
    #expect(desktop.screenshotCount == 0)
  }

  // MARK: Athina's own windows

  @Test func athinasOwnWindowsStayOut() async throws {
    let desktop = FakeDesktop(windows: [editorWindow, Window(app: athina, text: "athina toast")])
    let frame = try await capture(desktop)
    #expect(desktop.texts(in: frame.image) == ["editor draft"])
  }

  @Test func anAthinaWindowThatAppearsAfterTheListStaysOut() async throws {
    let desktop = FakeDesktop(windows: [editorWindow])
    desktop.appearAfterList(Window(app: athina, text: "athina toast"))
    let frame = try await capture(desktop)
    #expect(desktop.texts(in: frame.image) == ["editor draft"])
  }

  /// A second copy has the same bundle identifier, so listing it could show
  /// this copy's windows too.
  @Test func anotherCopyOfAthinaDoesNotLetThisOnesWindowsIn() async throws {
    let desktop = FakeDesktop(windows: [
      editorWindow,
      Window(app: otherAthina, text: "other athina panel"),
    ])
    desktop.appearAfterList(Window(app: athina, text: "athina toast"))
    let frame = try await capture(desktop)
    #expect(desktop.texts(in: frame.image) == ["editor draft"])
  }

  @Test(arguments: [nil, ""])
  func athinaWithoutABundleIdentifierLeavesOutOnlyItself(ownBundleID: String?) async throws {
    let desktop = FakeDesktop(windows: [
      Window(app: unbundled, text: "unbundled tool"),
      Window(app: App("", pid: athina.processID), text: "athina toast"),
    ])
    let frame = try await capture(desktop, ownBundleID: ownBundleID)
    #expect(desktop.texts(in: frame.image) == ["unbundled tool"])
  }

  // MARK: Everything else

  @Test func everyOtherAppsWindowsStay() async throws {
    let desktop = FakeDesktop(windows: [
      Window(app: windowServer, text: "backdrop"),
      Window(app: dock, text: "dock"),
      editorWindow,
      vaultWindow,
      browserWindow,
      Window(app: notes, text: "notes on the vault"),
      Window(app: unbundled, text: "unbundled tool"),
    ])
    let frame = try await capture(desktop)
    #expect(
      desktop.texts(in: frame.image)
        == [
          "backdrop", "dock", "editor draft", "browser results", "notes on the vault",
          "unbundled tool",
        ]
    )
  }

  @Test func aNewWindowOfAListedAppIsInTheImage() async throws {
    let desktop = FakeDesktop(windows: [editorWindow], running: [browser])
    desktop.appearAfterList(Window(app: editor, text: "editor sheet"))
    desktop.appearAfterList(browserWindow)
    let frame = try await capture(desktop)
    #expect(
      desktop.texts(in: frame.image) == ["editor draft", "editor sheet", "browser results"]
    )
  }

  @Test func nothingExcludedLeavesOutOnlyAthina() async throws {
    let desktop = FakeDesktop(windows: [
      editorWindow,
      vaultWindow,
      Window(app: athina, text: "athina toast"),
    ])
    let frame = try await capture(desktop, excluding: [])
    #expect(desktop.texts(in: frame.image) == ["editor draft", "vault recovery phrase"])
  }

  @Test func theDisplayTheFocusedWindowOverlapsMostIsCaptured() async throws {
    let desktop = FakeDesktop(
      displays: [FakeDesktop.left, FakeDesktop.right],
      windows: [
        editorWindow,
        Window(app: browser, text: "browser results", display: FakeDesktop.right),
        Window(app: vault, text: "vault recovery phrase", display: FakeDesktop.right),
      ]
    )
    let mostlyRight = CGRect(x: 1500, y: 100, width: 900, height: 600)
    let frame = try await capture(desktop, windowFrame: mostlyRight)
    #expect(frame.displayID == FakeDesktop.right.displayID)
    #expect(frame.screenRect == FakeDesktop.right.frame)
    #expect(frame.image.width == 1280 && frame.image.height == 800)
    #expect(desktop.texts(in: frame.image) == ["browser results"])
  }

  // MARK: From the screen to a request

  /// How an excluded app's window comes to be on the display beside the app in
  /// front.
  fileprivate enum Arrival: CaseIterable {
    case behindTheAppInFront
    case afterTheList
    case leftBehindOnTheSwitchBack
  }

  /// The sensing pipeline and the mentor loop as the app joins them, over the
  /// real capturer on a fake desktop.
  @Test(arguments: Arrival.allCases)
  fileprivate func nothingOfAnExcludedAppsWindowIsRecognizedSavedOrSent(
    arrival: Arrival
  ) async throws {
    let startsInFront = arrival == .leftBehindOnTheSwitchBack
    let run = try await SensingRun(
      window: startsInFront ? .vault : .editor,
      harness: DesktopPipelineHarness.self
    )
    let desktop = try #require(run.loop as? DesktopPipelineHarness).desktop
    switch arrival {
    case .behindTheAppInFront, .leftBehindOnTheSwitchBack:
      desktop.show(vaultWindow)
    case .afterTheList:
      desktop.appearAfterList(vaultWindow)
    }
    await run.launch()
    await run.advance(to: 0.5)
    if startsInFront {
      #expect(desktop.screenshotCount == 0)
      await run.turn { await run.focus.activate(.editor) }
      await run.advance(to: 1.5)
    }
    let observation = try #require(await run.observations().first)

    #expect(observation.textBlocks.map(\.text) == ["editor draft"])
    let saved = try #require(await run.journal.thumbnail(observationID: observation.id))
    #expect(desktop.texts(inJPEG: saved) == ["editor draft"])

    let clock = AdjustableClock(startingAt: run.clock.date)
    let client = ScriptedClaudeClient(clock: clock)
    await client.enqueue(json: #"{"worth_a_look": true, "reason": "Repeated edits"}"#)
    await client.enqueue(json: #"{"reason": "Nothing stands out", "suggestion": null}"#)
    let mentor = await MentorLoopTests.Harness(journal: run.journal, client: client, clock: clock)
    var sensed = observation
    sensed.frame.jpeg = saved
    await mentor.observe(sensed, expectCalls: 2)

    let sent = await client.sent
    #expect(sent.map(\.call.kind).prefix(2) == ["triage", "mentor"])
    for call in sent {
      for block in call.request.messages.flatMap(\.content) {
        switch block {
        case .text(let text):
          #expect(text.contains("editor draft"))
          #expect(!text.contains("vault recovery phrase"))
        case .image(_, let base64):
          let jpeg = try #require(Data(base64Encoded: base64))
          #expect(desktop.texts(inJPEG: jpeg) == ["editor draft"])
        }
      }
    }
    #expect(sent.contains { $0.request.imageByteCount > 0 })
    await mentor.stop()
    await run.end()
  }

  @Test func anExclusionAddedWhileWatchingHoldsFromTheNextScreenshot() async throws {
    let run = try await SensingRun(harness: DesktopPipelineHarness.self)
    let desktop = try #require(run.loop as? DesktopPipelineHarness).desktop
    desktop.show(browserWindow)
    await run.launch()
    await run.advance(to: 0.5)

    var settings = run.settings
    settings.excludedBundleIDs.append(browser.bundleIdentifier)
    await run.turn { await run.loop.updateSettings(settings) }
    run.elapse(to: 2)
    await run.turn { await run.loop.captureNow() }
    await run.advance(to: 3)

    let read = try await run.observations().map { $0.textBlocks.map(\.text) }
    #expect(read.first == ["editor draft", "browser results"])
    #expect(read.last == ["editor draft"])
    await run.end()
  }
}

/// The sensing pipeline over a world of fakes, with the real capturer on a
/// fake desktop and a recognizer that reads that desktop's pixels.
private struct DesktopPipelineHarness: SensingHarness {
  let desktop: FakeDesktop
  private let pipeline: SensingPipeline

  init(world: SensingWorld, settings: SensingSettings, source: SensingSource) {
    desktop = FakeDesktop(windows: [editorWindow])
    pipeline = SensingPipeline(
      settings: settings,
      journal: world.journal,
      capturer: ScreenCapturer(
        source: desktop,
        ownPID: athina.processID,
        ownBundleID: athina.bundleIdentifier
      ),
      recognizer: DesktopRecognizer(desktop: desktop),
      tracker: world.focus,
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
