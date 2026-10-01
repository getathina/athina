import AppKit
import AthinaCore
import Foundation
import SwiftUI

/// The Setup window's permissions page.
///
/// It explains each permission before anything is asked: no system prompt
/// appears until the person chooses a permission's button, which then asks or
/// opens its System Settings pane.
struct PermissionsPage: View {
  @Environment(AppState.self)
  private var state

  var body: some View {
    VStack(alignment: .leading, spacing: SetupGrid.sectionSpacing) {
      SetupHero(icon: .symbol("eye.circle.fill"), title: "Athina needs two permissions") {
        Text(
          """
          Athina watches what you are doing so it can understand your work. What it sees stays \
          on this Mac, for as long as you choose. It sends to \
          \(state.settings.mentor.provider.name) only, and only after you save an API key.
          """
        )
      }

      GroupBox(
        content: {
          PermissionRows(permissions: Permission.required)
        },
        label: {
          Text("Required to watch")
            .accessibilityAddTraits(.isHeader)
        }
      )

      GroupBox(
        content: {
          PermissionRows(permissions: Permission.optional)
        },
        label: {
          VStack(alignment: .leading, spacing: 2) {
            Text("Optional, for talking back")
              .accessibilityAddTraits(.isHeader)
            Text(
              """
              Hold the talk-back shortcut, set in General settings, to answer or ask about a \
              suggestion by voice. Everything else works without these.
              """
            )
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
          }
        }
      )

      SetupFootnote(
        text:
          """
          Idle detection needs no permission. If a permission you turned on in System Settings \
          still shows as not granted after a few seconds, quit and reopen Athina.
          """,
        secondary: true
      )
    }
    .task {
      guard !Snapshots.isActive else { return }
      AppState.log.notice(
        """
        permissions page shown, granted: screen \(state.permissions.screenRecording) \
        accessibility \(state.permissions.accessibility) microphone \
        \(state.permissions.microphone) speech \(state.permissions.speechRecognition)
        """
      )
      // Grants made in System Settings do not notify apps; poll while visible.
      while !Task.isCancelled {
        state.refreshPermissions()
        try? await Task.sleep(until: .now + .seconds(1), clock: .continuous)
      }
    }
    .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification))
    { _ in
      state.refreshPermissions()
    }
  }
}

/// Permissions listed one per row, with a separator between rows.
private struct PermissionRows: View {
  @Environment(AppState.self)
  private var state

  let permissions: [Permission]

  var body: some View {
    VStack(spacing: 0) {
      ForEach(permissions) { permission in
        PermissionRow(permission: permission, granted: state.permissions.isGranted(permission))
          // The window polls while the person grants it in System Settings;
          // a VoiceOver user coming back hears that it worked.
          .onChange(of: state.permissions.isGranted(permission)) { was, granted in
            if granted, !was { Announce.post("\(permission.title) granted") }
          }
        if permission != permissions.last {
          // Between the words' edges, as the form's row separators are.
          Divider()
            .padding(.horizontal, SetupGrid.cardPadding)
        }
      }
    }
  }
}

private struct PermissionRow: View {
  @Environment(AppState.self)
  private var state

  let permission: Permission
  let granted: Bool

  private var action: PermissionAction {
    state.permissionAction(for: permission)
  }

  var body: some View {
    // The icon sits on the title line, as every row icon in the window does;
    // the button is centred on the whole row.
    HStack(spacing: SetupGrid.iconToText) {
      HStack(alignment: .top, spacing: SetupGrid.iconToText) {
        SetupRowIcon(icon: .symbol(symbol))
          .foregroundStyle(
            granted ? AnyShapeStyle(StatusTint.good.color) : AnyShapeStyle(.secondary)
          )
        VStack(alignment: .leading, spacing: 4) {
          HStack(spacing: 8) {
            Text(permission.title)
              .font(.headline)
            PermissionBadge(granted: granted)
          }
          Text(permission.purpose)
            .fixedSize(horizontal: false, vertical: true)
        }
      }
      .frame(maxWidth: .infinity, alignment: .leading)
      switch action {
      case .none:
        EmptyView()
      case .request:
        Button("Request Access…") { state.perform(action, for: permission) }
          .accessibilityHint("Shows the system's request for \(permission.title).")
      case .openSystemSettings:
        Button("Open System Settings…") { state.perform(action, for: permission) }
          .accessibilityHint("Opens the \(permission.title) list in Privacy & Security settings.")
      }
    }
    .padding(.vertical, 10)
    .padding(.horizontal, SetupGrid.cardPadding)
    .accessibilityElement(children: .contain)
  }

  private var symbol: String {
    switch permission {
    case .screenRecording: "rectangle.dashed.badge.record"
    case .accessibility: "accessibility"
    case .microphone: "mic"
    case .speechRecognition: "waveform"
    }
  }
}

/// Granted or not, as a badge.
struct PermissionBadge: View {
  let granted: Bool

  var body: some View {
    StatusBadge(text: granted ? "Granted" : "Not granted", status: granted ? .good : .attention)
  }
}
