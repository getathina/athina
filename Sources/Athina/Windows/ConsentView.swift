import AppKit
import AthinaCore
import SwiftUI

/// The Setup window's consent page: the first thing a launch shows until the
/// person allows Athina to watch and send (`Consent`), ahead of any permission.
///
/// It says who receives what, what stays on this Mac and for how long, and how
/// the menu bar shows that Athina is watching; the window's footer asks
/// (`SetupView`). Nothing is sensed or sent before Allow; Not Now leaves
/// Athina doing nothing, with Allow Watching in its menu and Settings >
/// Privacy as the way back.
///
/// It asks about the provider chosen in Settings > Models, naming the company
/// that receives what is sent and the terms it is handled under, so choosing
/// another provider opens it again (`SensingSettings.hasConsent`).
struct ConsentPage: View {
  @Environment(AppState.self) private var state

  private var disclosure: ConsentDisclosure {
    ConsentDisclosure(for: state.settings.mentor.provider)
  }

  var body: some View {
    VStack(alignment: .leading, spacing: SetupGrid.sectionSpacing) {
      SetupHero(icon: .app, title: disclosure.title) {
        Text(disclosure.summary)
      }

      SetupCard(title: disclosure.sentHeading) {
        VStack(alignment: .leading, spacing: SetupGrid.rowSpacing) {
          SetupRow(
            icon: .symbol("text.viewfinder"),
            text:
              "The text on your screen, read on this Mac, and the names of the app and window in front. With Accessibility access, also the text of the field you are working in."
          )
          SetupRow(
            icon: .symbol("photo"),
            text: "The latest screenshot, unless you turn that off in Models settings."
          )
          SetupRow(
            icon: .symbol("list.bullet.rectangle"),
            text:
              "A summary of your recent activity, your answers to its suggestions, Athina's own notes on what you are working toward, and the contexts you declare."
          )
          SetupRow(
            icon: .symbol("bubble.left"),
            text:
              "Questions you ask about a suggestion. Spoken ones are turned into text on this Mac; the audio is never sent or kept."
          )
          Text(disclosure.destination)
            .font(.callout)
            .fixedSize(horizontal: false, vertical: true)
        }
      }

      SetupCard(title: "What stays on this Mac") {
        SetupRow(icon: .symbol("book.closed"), text: retentionText)
      }

      SetupCard(title: "How to tell Athina is watching") {
        VStack(alignment: .leading, spacing: SetupGrid.rowSpacing) {
          SetupRow(
            icon: .mark(.watching),
            text: "While Athina watches, the eyes in the menu bar are open."
          )
          SetupRow(icon: .mark(.paused), text: pausedText)
        }
      }

      SetupFootnote(
        text:
          "You can withdraw this at any time in Privacy settings, and Athina stops capturing and sending at once."
      )
    }
  }

  /// What the shut eyes mean, and how to pause, with the pause shortcut
  /// when the person has one.
  private var pausedText: String {
    let pause =
      state.settings.pauseShortcut.map { "from its menu or with \($0.displayString)" }
      ?? "from its menu"
    return
      "While it is paused or not allowed to watch, its eyes are shut. Pause it at any time \(pause)."
  }

  /// What the journal keeps, from the settings in force, so the window
  /// never promises a retention the person has changed.
  private var retentionText: String {
    let settings = state.settings
    return
      "A journal of what Athina sees: screenshots for \(Formatting.spelledDuration(settings.thumbnailRetention)), text and events for \(Formatting.spelledDuration(settings.textRetention)), up to \(Formatting.bytes(settings.journalSizeCapBytes)) in all. Change this or clear the journal at any time in Privacy settings."
  }
}
