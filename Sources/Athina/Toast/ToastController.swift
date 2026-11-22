import AppKit
import ApplicationServices
import AthinaCore
import AthinaFeatures
import CoreGraphics
import Foundation
import SwiftUI

/// Owns the floating suggestion panel: a non-activating window that never takes
/// keyboard focus, placed under the menu bar at the top right of the screen the
/// user is working on.
///
/// What the toast shows and when is `ToastFeature`'s. This hosts `ToastView`
/// over its store and follows it as each send returns (`HostedParent`),
/// presenting, ordering out and raising the panel as `ToastFeature.State.panel`
/// asks and watching clicks and key presses while the state says to; what
/// those and a drag see goes back as actions.
/// With no suggestion up the panel can show a short note instead, for a
/// talk-back key press that has nothing to reply to or an answer's consequence.
///
/// Because the panel never becomes key, VoiceOver hears about it through
/// announcements, and the menu bar menu offers its answers to the keyboard.
/// A person may drag it off what it covers, and it stays where they put it
/// until the next suggestion (`ToastPlacement`).
@MainActor
final class ToastController {
  static let width: CGFloat = 380
  /// The panel is the toast plus a point on each side, so the glass edge is
  /// never clipped by the window.
  static let panelWidth: CGFloat = width + 2
  static let margin: CGFloat = 12
  /// The panel's title while it shows a suggestion, which VoiceOver reads and
  /// the control API finds the toast by.
  static let suggestionTitle = "Athina suggestion"
  /// The panel's title while it shows only a note.
  static let noteTitle = "Athina note"

  private let store: HostedStoreOf<ToastFeature>
  private var panel: NSPanel?
  private var hosting: NSHostingView<ToastPanelRoot>?
  /// What the state asked of the panel that has been done.
  private var panelDone = ToastFeature.Panel()
  private var outsideClickMonitors: [Any] = []
  /// Watch for any key going down while a note that names a next step is up
  /// and the sensing mode allows it, and only then.
  private var keyPressMonitors: [Any] = []
  /// Set when the person starts dragging the panel, so the move that follows
  /// is told apart from the panel's own placement.
  private var movedByPerson = false
  private var moveObservers: [NSObjectProtocol] = []
  /// Whether clicks outside Athina's own windows reach the toast.
  ///
  /// A hermetic run's never do, so whoever is using the Mac cannot dismiss a
  /// toast they cannot see; the control API's `outside-click` stands in.
  private let watchesOtherApps: Bool

  init(store: HostedStoreOf<ToastFeature>, watchesOtherApps: Bool = true) {
    self.store = store
    self.watchesOtherApps = watchesOtherApps
  }

  /// Follows the store from now on.
  ///
  /// A sample's never starts, so it draws no panel and watches nothing.
  func start() {
    store.follow { [weak self] in self?.followStore() }
  }

  /// Does what the state has asked of the panel since this last ran, and
  /// watches what it says to watch.
  ///
  /// It runs as each send returns, before what the send announces, before the
  /// parent acts on it and before anything is drawn.
  private func followStore() {
    let asked = store.panel
    let isUp = store.isUp
    let watchesClicks = store.watchesClicks
    let watchesKeyPresses = store.watchesKeyPresses

    if asked.orderedOut != panelDone.orderedOut {
      panel?.orderOut(nil)
    }
    if asked.looksAgainForKeys(since: panelDone) {
      // Each note looks again at whether other apps' key presses can be heard.
      stopWatchingForKeyPresses()
    }
    if asked.presented != panelDone.presented, isUp {
      present()
    }
    if asked.raised != panelDone.raised {
      bringToFront()
    }
    panelDone = asked

    if watchesClicks {
      startWatchingForOutsideClicks()
    } else {
      stopWatchingForOutsideClicks()
    }
    if watchesKeyPresses {
      startWatchingForKeyPresses()
    } else {
      stopWatchingForKeyPresses()
    }
  }

  /// Orders the toast above anything shown since, such as a callout.
  private func bringToFront() {
    guard let panel, panel.isVisible else { return }
    panel.orderFrontRegardless()
  }

  // MARK: Key presses

  /// The next key press anywhere takes down a note that waits for one, while
  /// Athina is allowed to watch and is watching
  /// (`ToastPlacement.noticesKeyPresses(in:)`); before Allow, while paused,
  /// with an excluded app in front or in any other mode no key is watched at
  /// all, and only a click takes the note down.
  ///
  /// Only that a key went down, and not by auto-repeat, is used, never which
  /// key: the event is not otherwise read, and nothing of it is logged or
  /// kept. Key presses in other apps reach Athina only with the Accessibility
  /// access it already asks for, which a global key-down monitor needs and
  /// which asks for nothing more, never Input Monitoring; without it, or in a
  /// hermetic run, which listens to nothing outside itself, only presses in
  /// Athina's own windows count, and a click still takes the note down. The
  /// monitors exist only while such a note is up and the mode allows them.
  private func startWatchingForKeyPresses() {
    guard keyPressMonitors.isEmpty else { return }
    if watchesOtherApps, AXIsProcessTrusted(),
      let global = NSEvent.addGlobalMonitorForEvents(
        matching: .keyDown,
        handler: { [weak self] event in
          let repeated = event.isARepeat
          MainActor.assumeIsolated { self?.keyWentDown(repeated: repeated) }
        }
      )
    {
      keyPressMonitors.append(global)
    }
    if let local = NSEvent.addLocalMonitorForEvents(
      matching: .keyDown,
      handler: { [weak self] event in
        MainActor.assumeIsolated { self?.keyWentDown(repeated: event.isARepeat) }
        return event
      }
    ) {
      keyPressMonitors.append(local)
    }
  }

  private func stopWatchingForKeyPresses() {
    for monitor in keyPressMonitors { NSEvent.removeMonitor(monitor) }
    keyPressMonitors.removeAll()
  }

  /// A key went down; the reducer is told only whether it repeats.
  private func keyWentDown(repeated: Bool) {
    store.send(.keyDown(isRepeat: repeated))
  }

  private func present() {
    let panel = panel ?? makePanel()
    // A window that zooms in is motion; with Reduce Motion it just appears.
    panel.animationBehavior =
      NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? .none : .utilityWindow
    // The screen the pointer is on, but in a hermetic run, which reads
    // nothing of the person's input, always the main one.
    let mouse = watchesOtherApps ? NSEvent.mouseLocation : nil
    let screen =
      NSScreen.screens.first { mouse.map($0.frame.contains) ?? false } ?? NSScreen.main
      ?? NSScreen.screens.first
    panel.title =
      store.suggestion == nil ? ToastController.noteTitle : ToastController.suggestionTitle
    // New content appears at once; only the same toast growing or shrinking
    // is animated (`relayout`).
    let kept = store.movedTopLeft != nil
    place(panel, on: kept ? panel.screen ?? screen : screen, animated: false)
    panel.orderFrontRegardless()
  }

  // MARK: Outside clicks

  /// A mouse-down anywhere but the toast or Athina's menu bar item dismisses it
  /// (`ToastClick`).
  ///
  /// The global monitor sees clicks in other apps, on the desktop, and on the
  /// menu bar, which carry no window of ours; the local one sees clicks in
  /// Athina's own windows and passes every event through, so an event aimed at
  /// the toast's own panel keeps it up and its buttons still work. A click
  /// inside the menu bar item's frame, whichever monitor sees it, opens the
  /// menu that answers the toast. Only mouse-down is watched, so scrolling,
  /// typing, and moving the pointer leave the toast alone. Neither monitor
  /// makes the panel key or activates the app.
  private func startWatchingForOutsideClicks() {
    guard outsideClickMonitors.isEmpty else { return }
    let clicks: NSEvent.EventTypeMask = [.leftMouseDown, .rightMouseDown, .otherMouseDown]
    if watchesOtherApps,
      let global = NSEvent.addGlobalMonitorForEvents(
        matching: clicks,
        handler: { [weak self] event in
          MainActor.assumeIsolated { self?.handleClick(event) }
        }
      )
    {
      outsideClickMonitors.append(global)
    }
    if let local = NSEvent.addLocalMonitorForEvents(
      matching: clicks,
      handler: { [weak self] event in
        MainActor.assumeIsolated { self?.handleClick(event) }
        return event
      }
    ) {
      outsideClickMonitors.append(local)
    }
  }

  private func stopWatchingForOutsideClicks() {
    for monitor in outsideClickMonitors { NSEvent.removeMonitor(monitor) }
    outsideClickMonitors.removeAll()
  }

  private func handleClick(_ event: NSEvent) {
    let location =
      event.window.map { $0.convertPoint(toScreen: event.locationInWindow) }
      ?? event.locationInWindow
    handleClick(at: location, onToast: event.window != nil && event.window === panel)
  }

  private func handleClick(at location: CGPoint, onToast: Bool) {
    guard let panel, panel.isVisible else { return }
    let click = ToastClick(
      onToast: onToast,
      location: location,
      menuBarItems: NSApp.windows.filter(\.holdsStatusBarButton).map(\.frame)
    )
    store.send(.mouseDown(click))
  }

  /// A mouse-down outside Athina's windows at `location`, in screen
  /// coordinates, as the global monitor reports one: how the control API's
  /// `outside-click` reaches a hermetic run's toast, which watches no other
  /// app.
  ///
  /// True when the toast was up to hear it, whatever it made of it.
  @discardableResult
  func outsideClick(at location: CGPoint) -> Bool {
    guard panel?.isVisible == true, store.watchesClicks else { return false }
    handleClick(at: location, onToast: false)
    return true
  }

  /// Re-fits the panel after its content changed size (expand, collapse, a
  /// transcript growing), keeping its top edge where it is.
  private func relayout() {
    guard let panel, panel.isVisible else { return }
    place(panel, on: panel.screen ?? NSScreen.main, animated: true)
  }

  /// Tells a move the person made by dragging the panel from the panel's own
  /// placement: only a drag sends `willMove` first.
  private func watchForMoves(of panel: NSPanel) {
    let center = NotificationCenter.default
    moveObservers = [
      center.addObserver(forName: NSWindow.willMoveNotification, object: panel, queue: .main) {
        [weak self] _ in
        MainActor.assumeIsolated { self?.movedByPerson = true }
      },
      center.addObserver(forName: NSWindow.didMoveNotification, object: panel, queue: .main) {
        [weak self] _ in
        MainActor.assumeIsolated {
          guard let self, self.movedByPerson, let panel = self.panel else { return }
          self.store.send(.dragged(topLeft: CGPoint(x: panel.frame.minX, y: panel.frame.maxY)))
        }
      },
    ]
  }

  private func makePanel() -> NSPanel {
    let panel = NSPanel(
      contentRect: CGRect(x: 0, y: 0, width: ToastController.panelWidth, height: 120),
      styleMask: [.nonactivatingPanel, .fullSizeContentView, .borderless],
      backing: .buffered,
      defer: false
    )
    panel.isFloatingPanel = true
    panel.level = .statusBar
    panel.hidesOnDeactivate = false
    panel.isReleasedWhenClosed = false
    panel.collectionBehavior = [
      .canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle,
    ]
    panel.isOpaque = false
    panel.backgroundColor = .clear
    panel.hasShadow = true
    panel.becomesKeyOnlyIfNeeded = true
    panel.isMovableByWindowBackground = true
    // The title a person never sees, since the panel has no title bar;
    // VoiceOver reads it, and the control API finds the panel by it.
    panel.title = ToastController.suggestionTitle
    panel.setAccessibilitySubrole(.floatingWindow)
    watchForMoves(of: panel)

    let view = ToastView(
      store: store,
      onSizeChange: { [weak self] in
        self?.relayout()
      }
    )
    let hosting = NSHostingView(rootView: ToastPanelRoot(toast: view))
    hosting.sizingOptions = [.intrinsicContentSize]
    panel.contentView = hosting
    self.hosting = hosting
    self.panel = panel
    return panel
  }

  /// Top right of the screen, just under the menu bar, or where the person
  /// dragged it (`ToastPlacement`).
  ///
  /// The width is the toast's fixed width; only the height comes from the
  /// content, and a degenerate reading mid-update (SwiftUI can report zero
  /// while it re-lays out) keeps the frame it had, so the panel never jumps off
  /// the edge of the screen while its content changes. Asked to animate, a
  /// panel already up grows or shrinks in a short animation from its top edge,
  /// its content pinned there; with Reduce Motion, or in a hermetic run, which
  /// nobody sees and whose clicks must not land mid-animation, it changes size
  /// at once.
  private func place(_ panel: NSPanel, on screen: NSScreen?, animated: Bool) {
    guard let screen else { return }
    panel.contentView?.layoutSubtreeIfNeeded()
    let fitted = panel.contentView?.fittingSize ?? .zero
    guard fitted.height >= 40 else { return }
    let frame = ToastPlacement.frame(
      size: CGSize(width: ToastController.panelWidth, height: fitted.height),
      visible: screen.visibleFrame,
      margin: ToastController.margin,
      movedTopLeft: store.movedTopLeft
    )
    movedByPerson = false
    guard frame != panel.frame else { return }
    if animated, watchesOtherApps, panel.isVisible,
      !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    {
      NSAnimationContext.runAnimationGroup { context in
        context.duration = 0.2
        context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        panel.animator().setFrame(frame, display: true)
      }
    } else {
      panel.setFrame(frame, display: true)
    }
  }
}

extension NSWindow {
  /// True for a menu bar item's window, the only kind that holds a status
  /// bar button. `NSApp.windows` lists only Athina's own, so its frame is
  /// Athina's item, as tall as the menu bar.
  fileprivate var holdsStatusBarButton: Bool {
    var views = contentView.map { [$0] } ?? []
    while let view = views.popLast() {
      if view is NSStatusBarButton { return true }
      views.append(contentsOf: view.subviews)
    }
    return false
  }
}

/// The toast as the panel holds it: pinned to the panel's top edge, so while
/// the panel grows or shrinks around it the content stays still under the
/// pointer.
struct ToastPanelRoot: View {
  let toast: ToastView

  var body: some View {
    toast.frame(maxHeight: .infinity, alignment: .top)
  }
}

/// The toast on its Liquid Glass surface.
///
/// Its corners are concentric with the small capsule buttons inset from its
/// bottom corners, the way system glass containers relate to the controls
/// inside them.
struct ToastView: View {
  /// Space between the glass edge and the content.
  static let inset: CGFloat = 14
  /// Half the height of a small push button, whose capsule sits `inset`
  /// in from the corner.
  static let cornerRadius: CGFloat = inset + 10

  let store: HostedStoreOf<ToastFeature>
  var onSizeChange: @MainActor @Sendable () -> Void = {}

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      if let suggestion = store.suggestion {
        ToastContent(
          suggestion: suggestion,
          expanded: store.expanded,
          exchange: store.exchange,
          provider: store.provider,
          talkBack: store.talkBack,
          note: store.note?.text,
          talkBackKey: store.talkBackKey,
          outlined: store.outlined,
          onToggle: {
            store.send(.expandButtonTapped)
          },
          onAction: { feedback in
            store.send(.answerButtonTapped(feedback))
          }
        )
      } else if let note = store.note {
        ToastNote(text: note.text)
      }
    }
    .frame(width: ToastController.width)
    .glassEffect(.regular, in: .rect(cornerRadius: ToastView.cornerRadius))
    .padding(1)
    .onHover { hovering in
      store.send(.hoverChanged(hovering))
    }
    .onGeometryChange(
      for: CGSize.self,
      of: { proxy in
        proxy.size
      },
      action: { _ in
        onSizeChange()
      }
    )
  }
}

/// A line on its own, for a key press with nothing to reply to.
struct ToastNote: View {
  let text: String

  var body: some View {
    Label(
      title: {
        Text(text)
          .fixedSize(horizontal: false, vertical: true)
      },
      icon: {
        Image(systemName: "mic.slash")
          .foregroundStyle(.secondary)
      }
    )
    .font(.callout)
    .frame(maxWidth: .infinity, alignment: .leading)
    .padding(ToastView.inset)
  }
}

/// The toast body, also used by snapshots.
///
/// The header and body sit on top, the explanation grows between them and the
/// button bar when expanded (scrolling past a sensible height), the talk-back
/// exchange and listening row sit under that, and the button bar is pinned to
/// the bottom edge with the same three buttons in every state.
struct ToastContent: View {
  static let explanationMaxHeight: CGFloat = 300
  static let exchangeMaxHeight: CGFloat = 220

  let suggestion: Suggestion
  let expanded: Bool
  var exchange: [FollowUp] = []
  var provider: ModelProvider = .anthropic
  var talkBack: TalkBackState = .idle
  var note: String?
  var talkBackKey: String?
  /// What the callout on screen outlines, while it is up.
  var outlined: String?
  let onToggle: () -> Void
  let onAction: (SuggestionFeedback) -> Void

  private let inset = ToastView.inset

  /// The kind of note this suggestion is shown as.
  private var kind: NoteKind { NoteKind(suggestion.category) }

  /// The model's own category and the app, which the header line's hover and
  /// VoiceOver say in full; the line itself shows the kind of note.
  private var source: String { "\(suggestion.category.label) in \(suggestion.appName)" }

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      VStack(alignment: .leading, spacing: 8) {
        HStack(alignment: .top, spacing: 12) {
          // The kind's tile, beside its name in words, so a kind is never
          // told by colour alone; the callout carries the same tile.
          KindTile(kind: kind)
            .padding(.top, 1)
          VStack(alignment: .leading, spacing: 2) {
            Text("\(kind.label) · \(suggestion.appName)")
              .font(.subheadline)
              .foregroundStyle(.secondary)
              .lineLimit(1)
              // A long app name is cut on screen; the whole line, with the
              // model's own category, is a hover away.
              .help("Athina · \(source)")
              .accessibilityLabel("Athina, \(kind.label), \(source)")
            Text(suggestion.title)
              .font(.title3.weight(.semibold))
              .fixedSize(horizontal: false, vertical: true)
              .accessibilityAddTraits(.isHeader)
          }
          Spacer(minLength: 0)
          Button(
            action: {
              onAction(.dismissed)
            },
            label: {
              Label("Close", systemImage: "xmark")
                .labelStyle(.iconOnly)
            }
          )
          .buttonStyle(.bordered)
          .buttonBorderShape(.circle)
          .controlSize(.small)
          .help("Close")
          .accessibilityIdentifier("toast.close")
        }
        Text(suggestion.body)
          .font(.body)
          .fixedSize(horizontal: false, vertical: true)
        if let outlined {
          Label("Showing on screen: \(outlined)", systemImage: "scope")
            .font(.subheadline)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityIdentifier("toast.outlined")
        }
      }
      .padding(inset)

      if expanded {
        Divider()
          .padding(.horizontal, inset)
        FittedScrollView(maxHeight: ToastContent.explanationMaxHeight) {
          Text(suggestion.explanation)
            .font(.callout)
            .textSelection(.enabled)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, inset)
            .padding(.vertical, 10)
        }
      }

      if !exchange.isEmpty || talkBack != .idle {
        Divider()
          .padding(.horizontal, inset)
        FittedScrollView(maxHeight: ToastContent.exchangeMaxHeight, anchor: .bottom) {
          // One grid for the whole exchange, so the speaker column is as wide
          // as its widest word rather than a fixed width.
          Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 8, verticalSpacing: 8) {
            ForEach(exchange) { entry in
              ExchangeEntry(entry: entry, provider: provider)
            }
            switch talkBack {
            case .idle:
              EmptyView()
            case .listening(let partial):
              ListeningRow(partial: partial)
            case .waiting(let question):
              ThinkingRow(
                question: question,
                status: "Your question is next, once Athina finishes what it is asking."
              )
            case .thinking(let question):
              ThinkingRow(question: question, status: "Asking the mentor…")
            }
          }
          .frame(maxWidth: .infinity, alignment: .leading)
          .padding(.horizontal, inset)
          .padding(.vertical, 10)
        }
      }

      if let note {
        Label(note, systemImage: "info.circle")
          .font(.callout)
          .fixedSize(horizontal: false, vertical: true)
          .padding(.horizontal, inset)
          .padding(.bottom, 8)
      }

      HStack(spacing: 8) {
        // The one prominent button, drawn by its own style: the panel is
        // never key, and the system's prominent styles draw a button in a
        // window that is not key in the inactive grey, or faded.
        Button(expanded ? "Show Less" : "Tell Me More", action: onToggle)
          .buttonStyle(ToastProminentButtonStyle())
          .accessibilityIdentifier("toast.tellMeMore")
        Button("Not Now") { onAction(.notNow) }
          .help(notNowConsequence)
          .accessibilityHint(notNowConsequence)
          .accessibilityIdentifier("toast.notNow")
        Button("Never for This") { onAction(.never) }
          .help(neverConsequence)
          .accessibilityHint(neverConsequence)
          .accessibilityIdentifier("toast.never")
        Spacer(minLength: 4)
        if let talkBackKey {
          Label(talkBackKey, systemImage: "mic")
            .font(.caption)
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .help("Hold \(talkBackKey) to talk back")
            .accessibilityLabel("Hold \(talkBackKey) to talk back")
        }
      }
      .buttonStyle(.bordered)
      .controlSize(.small)
      .padding([.horizontal, .bottom], inset)
      .padding(.top, expanded || !exchange.isEmpty || talkBack != .idle || note != nil ? 10 : 0)
    }
  }

  private var notNowConsequence: String {
    """
    Hides \(suggestion.category.label.lowercased()) suggestions in \(suggestion.appName) \
    for a while
    """
  }

  private var neverConsequence: String {
    "Stops \(suggestion.category.label.lowercased()) suggestions in \(suggestion.appName)"
  }
}

/// The toast's prominent button: the accent capsule a small prominent push
/// button draws in an active window, drawn the same whether or not the panel
/// is key, beside small bordered buttons of the same height.
struct ToastProminentButtonStyle: ButtonStyle {
  @Environment(\.isEnabled)
  private var isEnabled

  @Environment(\.colorSchemeContrast)
  private var contrast

  func makeBody(configuration: Configuration) -> some View {
    configuration.label
      .font(.subheadline)
      .foregroundStyle(.white)
      .lineLimit(1)
      .padding(.horizontal, 10)
      .frame(minHeight: 20)
      .background(
        Capsule().fill(Color.accentColor.opacity(configuration.isPressed ? 0.75 : 1))
      )
      .overlay {
        if contrast == .increased {
          Capsule().strokeBorder(.primary.opacity(0.5))
        }
      }
      .opacity(isEnabled ? 1 : 0.5)
      .contentShape(Capsule())
  }
}

/// A scroll view as tall as its content up to `maxHeight`, then scrolling.
///
/// A plain `ScrollView` inside a panel that sizes to fit keeps whatever height
/// it had, so an answer that arrives later would be cut off instead of growing
/// the toast.
private struct FittedScrollView<Content: View>: View {
  let maxHeight: CGFloat
  var anchor: UnitPoint = .top
  @ViewBuilder let content: Content
  @State private var contentHeight: CGFloat = 0

  var body: some View {
    ScrollView {
      content
        .onGeometryChange(
          for: CGFloat.self,
          of: { proxy in
            proxy.size.height
          },
          action: { height in
            contentHeight = height
          }
        )
    }
    .defaultScrollAnchor(anchor)
    .scrollDisabled(contentHeight <= maxHeight)
    .frame(height: min(max(contentHeight, 1), maxHeight))
  }
}

/// One question and its answer in the toast's exchange area, as two rows of
/// the exchange's grid.
struct ExchangeEntry: View {
  let entry: FollowUp
  /// Whose API the question went to.
  let provider: ModelProvider

  var body: some View {
    ExchangeLine(speaker: "You", text: entry.question, secondary: true)
    if let answer = entry.answer {
      ExchangeLine(speaker: "Athina", text: answer, secondary: false)
    } else {
      // The code's own words stay a hover away, for a bug report.
      ExchangeLine(
        speaker: "Athina",
        text: ToastFeature.failure(entry, provider: provider),
        secondary: true
      )
      .help(entry.error ?? "")
    }
  }
}

/// A speaker and what they said, as a row of the exchange's grid, whose first
/// column sizes to its widest speaker.
private struct ExchangeLine: View {
  let speaker: String
  let text: String
  let secondary: Bool

  var body: some View {
    GridRow {
      Text(speaker)
        .font(.caption.weight(.semibold))
        .foregroundStyle(.secondary)
        .gridColumnAlignment(.trailing)
      Text(text)
        .font(.callout)
        .foregroundStyle(secondary ? AnyShapeStyle(.secondary) : AnyShapeStyle(.primary))
        .textSelection(.enabled)
        .fixedSize(horizontal: false, vertical: true)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
    .accessibilityElement(children: .combine)
  }
}

/// The key is held: a pulsing microphone and the transcript so far, as a row
/// of the exchange's grid.
struct ListeningRow: View {
  let partial: String

  @Environment(\.drawsStill)
  private var drawsStill

  @Environment(\.accessibilityReduceMotion)
  private var reduceMotion

  var body: some View {
    GridRow {
      Image(systemName: "mic.fill")
        .font(.callout)
        .foregroundStyle(StatusTint.active.color)
        // With Reduce Motion the microphone holds still; the word beside it
        // says it is listening.
        .symbolEffect(.pulse, options: .repeating, isActive: !drawsStill && !reduceMotion)
        .gridColumnAlignment(.trailing)
        .accessibilityHidden(true)
      VStack(alignment: .leading, spacing: 2) {
        Text("Listening…")
          .font(.callout.weight(.medium))
        Text(
          partial.isEmpty
            ? "Say \"tell me more,\" \"not now,\" or \"never for this,\" or ask a question."
            : partial
        )
        .font(.callout)
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
      }
      .frame(maxWidth: .infinity, alignment: .leading)
    }
    .accessibilityElement(children: .combine)
  }
}

/// The key was released and the question is with the mentor model, or
/// waiting for its current call to return, as rows of the exchange's grid.
struct ThinkingRow: View {
  let question: String
  let status: String

  var body: some View {
    ExchangeLine(speaker: "You", text: question, secondary: true)
    GridRow(alignment: .center) {
      ProgressView()
        .controlSize(.small)
        .gridColumnAlignment(.trailing)
        .accessibilityHidden(true)
      Text(status)
        .font(.callout)
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
    }
  }
}
