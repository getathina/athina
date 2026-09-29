import AppKit
import AthinaCore
import SwiftUI

/// The Setup window: consent, then the permissions, the model and what to
/// expect, one page at a time (`SetupState`, `SetupFlow`).
///
/// A first launch walks through the pages, with Back and Continue and a dot
/// for each page; the menu's Allow Watching… and Permissions… open one page on
/// its own, which closes once it is done with, as the consent and Permissions
/// windows did. The window is titled by its page, as Settings is by its pane.
struct SetupView: View {
  @Environment(AppState.self) private var state
  @Environment(\.dismiss) private var dismiss

  var body: some View {
    VStack(spacing: 0) {
      page
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
      Divider()
      footer
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
    }
    .frame(width: 600)
    .navigationTitle(state.setup.page.title)
    .onAppear { state.setupIsOpen = true }
    .onDisappear { state.setupIsOpen = false }
    .task {
      guard !Snapshots.isActive else { return }
      AppState.log.notice(
        """
        setup window opened on \(state.setup.page.rawValue, privacy: .public), \
        consent \(state.settings.hasConsent ? "given" : "not given", privacy: .public)
        """
      )
      // An accessory app's window opened at launch does not come forward on
      // its own, and this one must be the first thing seen.
      AppActivation.request()
    }
  }

  @ViewBuilder private var page: some View {
    switch state.setup.page {
    case .consent: ConsentPage()
    case .permissions: PermissionsPage()
    case .model: ModelPage()
    case .ready: ReadyPage()
    }
  }

  private var footer: some View {
    HStack(spacing: 8) {
      leading
      Spacer()
      trailing
    }
    .overlay {
      if state.setup.walksThrough {
        PageDots(step: SetupFlow.step(of: state.setup.page, hasModelPage: state.setup.hasModelPage))
      }
    }
  }

  @ViewBuilder private var leading: some View {
    if state.setup.page == .consent {
      Link("Privacy Policy", destination: Consent.privacyPolicyURL)
    } else if state.setup.walksThrough,
      let previous = SetupFlow.page(
        before: state.setup.page,
        hasModelPage: state.setup.hasModelPage
      )
    {
      Button("Back") { state.setup.page = previous }
        .accessibilityIdentifier("setup.back")
    }
  }

  @ViewBuilder private var trailing: some View {
    switch SetupFlow.footer(
      on: state.setup,
      hasConsent: state.settings.hasConsent,
      permissionsGranted: state.permissions.allGranted
    ) {
    case .answer:
      Button("Not Now") {
        state.declineConsent()
        dismiss()
      }
      .keyboardShortcut(.cancelAction)
      .accessibilityIdentifier("consent.notNow")
      Button("Allow") { allow() }
        .keyboardShortcut(.defaultAction)
        .accessibilityIdentifier("consent.allow")
    case .continue:
      Button("Continue") { advance() }
        .keyboardShortcut(.defaultAction)
        .accessibilityIdentifier("setup.continue")
    case .done:
      Button("Done") { dismiss() }
        .keyboardShortcut(.defaultAction)
        .accessibilityIdentifier("setup.done")
    case .notNow:
      Button("Not Now") { dismiss() }
        .keyboardShortcut(.defaultAction)
        .accessibilityIdentifier("setup.done")
    }
  }

  /// Allow, then whatever is still to set up, or the window closes when
  /// nothing is: permissions are asked about only once consent is given.
  private func allow() {
    state.allowConsent()
    if let next = SetupFlow.afterAllow(
      walksThrough: state.setup.walksThrough,
      permissionsGranted: state.permissions.allGranted,
      hasModelPage: state.setup.hasModelPage
    ) {
      state.setup.page = next
    } else {
      dismiss()
    }
  }

  private func advance() {
    if let next = SetupFlow.page(after: state.setup.page, hasModelPage: state.setup.hasModelPage) {
      state.setup.page = next
    } else {
      dismiss()
    }
  }
}

/// A dot for each page of a walk through, the current one filled.
private struct PageDots: View {
  let step: (number: Int, count: Int)

  var body: some View {
    HStack(spacing: 7) {
      ForEach(1...step.count, id: \.self) { each in
        Circle()
          .fill(each == step.number ? Color.primary.opacity(0.7) : Color.primary.opacity(0.2))
          .frame(width: 6, height: 6)
      }
    }
    .accessibilityElement(children: .ignore)
    .accessibilityLabel("Step \(step.number) of \(step.count)")
  }
}

/// The model page: which provider answers, its key, and what it may spend,
/// the same rows as Settings > Models.
struct ModelPage: View {
  @Environment(AppState.self) private var state

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      SetupHero(icon: .symbol("key.fill"), title: "Connect a model") {
        Text(
          """
          Athina asks the model you choose, with your own API key, and every call is billed \
          to your account. Nothing is sent until a key is saved, and spending stops at the \
          hourly limit.
          """
        )
      }
      Form {
        ProviderSection()
        SpendSection(limitOnly: true)
      }
      .formStyle(.grouped)
      // On the window's own background, as the other pages are; it scrolls
      // when a key's error or a replay's rows make it taller. The form draws
      // its cards `SetupGrid.margin` inside its own edge, so it reaches the
      // window's edges and its cards land on the page's.
      .scrollContentBackground(.hidden)
      .frame(height: 410)
      .padding(.horizontal, -SetupGrid.margin)
    }
  }
}

/// The last page of a walk through: what to expect once Athina watches.
struct ReadyPage: View {
  @Environment(AppState.self) private var state

  var body: some View {
    VStack(alignment: .leading, spacing: SetupGrid.sectionSpacing) {
      SetupHero(icon: .app, title: readiness.heading) {
        Text(
          """
          It stays quiet until it sees a faster way, a risk, or a dead end in what you are \
          doing. Then a note appears under the menu bar, with the reason.
          """
        )
      }

      if !readiness.isSetUp {
        VStack(alignment: .leading, spacing: 6) {
          ForEach(readiness.stillToDo, id: \.self) { line in
            StatusLabel(line, kind: .warning)
          }
        }
        .padding(.horizontal, SetupGrid.inset)
      }

      SetupCard(title: "In the menu bar") {
        VStack(alignment: .leading, spacing: SetupGrid.rowSpacing) {
          SetupRow(icon: .mark(.watching), text: "Eyes open: Athina is watching.")
          SetupRow(icon: .mark(.idle), text: "Eyes closed in a curve: you stepped away.")
          SetupRow(icon: .mark(.paused), text: "Eyes shut: paused, or not allowed to watch.")
        }
      }

      SetupCard(title: "Talking back") {
        Text(talkBack)
          .fixedSize(horizontal: false, vertical: true)
      }

      SetupFootnote(
        text: "Everything here can be changed in Settings, which the menu opens.",
        secondary: true
      )
    }
  }

  private var readiness: SetupReadiness {
    SetupReadiness(permissions: state.permissions, needsKey: state.needsAPIKey)
  }

  private var talkBack: String {
    if let key = state.settings.mentor.pushToTalkHotKey {
      "Hold \(key.displayString) and speak to answer a note or ask about it; let go to send."
    } else {
      "Set a talk-back shortcut in General settings to answer a note out loud."
    }
  }
}
