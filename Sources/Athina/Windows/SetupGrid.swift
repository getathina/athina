import AppKit
import AthinaCore
import SwiftUI

/// The grid every page of the Setup window is laid out on: the grouped
/// form's own, which the model page's form and every Settings pane already
/// draw, so the four pages share one set of edges.
///
/// A card sits `margin` in from the window's edge, and every word, a section
/// title, a row, a paragraph or the footnote under a card, sits `inset` inside
/// the card's edge, where the form puts a section's header, rows and footer. A
/// row's icon is centred in one column, `iconColumn` wide, on the row's first
/// line, and the hero icon's visible body is flush with the cards' edges.
enum SetupGrid {
  /// The window's edge to a card's edge, and to the hero icon's body.
  static let margin: CGFloat = 20
  /// A card's edge to its title, rows, paragraphs and footnote.
  static let inset: CGFloat = 10
  /// A group box pads its content this much itself, so a card's content adds
  /// only the rest of `inset`.
  static let groupBoxPadding: CGFloat = 6
  /// What a card's content adds to the group box's own padding.
  static let cardPadding: CGFloat = inset - groupBoxPadding
  /// The column a row's icon is centred in: wide enough for the menu bar
  /// mark, the widest of them (23.5 pt), so none reaches past it.
  static let iconColumn: CGFloat = 24
  /// One body line, which a row's icon is centred on.
  static let iconHeight: CGFloat = 16
  /// A row's icon column to its words.
  static let iconToText: CGFloat = 10
  /// The hero icon's body, and the column it takes.
  static let heroIcon: CGFloat = 64
  /// The hero icon's column to the heading beside it.
  static let heroToText: CGFloat = 14
  /// Between a page's hero and its first card, and between cards.
  static let sectionSpacing: CGFloat = 16
  /// Between the rows of a card.
  static let rowSpacing: CGFloat = 10
}

/// A page's hero: its icon in the first column, its heading and a summary
/// beside it.
struct SetupHero<Summary: View>: View {
  enum Icon {
    /// The app icon as Finder draws it, its body flush with the cards' edges.
    case app
    /// A symbol, filling the icon column as the app icon's body does.
    case symbol(String)
  }

  let icon: Icon
  let title: String
  @ViewBuilder let summary: Summary

  var body: some View {
    HStack(alignment: .top, spacing: SetupGrid.heroToText) {
      // A symbol narrower than the column, such as a key, keeps to its
      // leading edge, on the cards' edge, rather than floating in the middle.
      iconView
        .frame(width: SetupGrid.heroIcon, height: SetupGrid.heroIcon, alignment: .leading)
        .accessibilityHidden(true)
      VStack(alignment: .leading, spacing: 4) {
        Text(title)
          .font(.title2.weight(.semibold))
          .fixedSize(horizontal: false, vertical: true)
          .accessibilityAddTraits(.isHeader)
        summary
          .fixedSize(horizontal: false, vertical: true)
      }
    }
  }

  @ViewBuilder private var iconView: some View {
    switch icon {
    case .app:
      // Icon services draws the icon on the standard 1024-unit canvas with
      // its body in the middle 824, so the image is drawn larger than the
      // column and pulled in by the margin, and the body alone fills the
      // column, its edge on the cards' edge.
      let drawn = SetupGrid.heroIcon * 1024 / 824
      let overflow = (drawn - SetupGrid.heroIcon) / 2
      Image(nsImage: NSWorkspace.shared.icon(forFile: Bundle.main.bundlePath))
        .resizable()
        .frame(width: drawn, height: drawn)
        .padding(-overflow)
    case .symbol(let name):
      Image(systemName: name)
        .resizable()
        .scaledToFit()
        .foregroundStyle(.tint)
    }
  }
}

/// A titled card: a group box whose content sits `SetupGrid.inset` inside
/// its edge, under the title the group box draws there.
struct SetupCard<Content: View>: View {
  let title: String
  @ViewBuilder let content: Content

  var body: some View {
    GroupBox {
      content
        .padding(SetupGrid.cardPadding)
        .frame(maxWidth: .infinity, alignment: .leading)
    } label: {
      Text(title)
        .accessibilityAddTraits(.isHeader)
    }
  }
}

/// One row of a card: an icon in the icon column, centred on the first line
/// of the words beside it.
struct SetupRow: View {
  enum Icon {
    /// A symbol, in the secondary label colour.
    case symbol(String)
    /// The menu bar mark, as it looks in the menu bar.
    case mark(MenuBarMark)
  }

  let icon: Icon
  let text: String

  var body: some View {
    HStack(alignment: .top, spacing: SetupGrid.iconToText) {
      SetupRowIcon(icon: icon)
        .foregroundStyle(.secondary)
      Text(text)
        .fixedSize(horizontal: false, vertical: true)
    }
  }
}

/// A row's icon, centred in the icon column at the height of one body line.
///
/// A row's first line and its icon then share a centre whatever the icon. A
/// symbol takes the foreground style it is given, and so does the mark, a
/// template image.
struct SetupRowIcon: View {
  let icon: SetupRow.Icon

  var body: some View {
    Group {
      switch icon {
      case .symbol(let name):
        Image(systemName: name)
          .imageScale(.large)
      case .mark(let mark):
        MenuBarLabelImage(mark: mark)
      }
    }
    .frame(width: SetupGrid.iconColumn, height: SetupGrid.iconHeight)
    .accessibilityHidden(true)
  }
}

/// A footnote under a card, on the card's own inset like the form's footers.
struct SetupFootnote: View {
  let text: String
  var secondary = false

  var body: some View {
    Text(text)
      .font(.callout)
      .foregroundStyle(secondary ? AnyShapeStyle(.secondary) : AnyShapeStyle(.primary))
      .fixedSize(horizontal: false, vertical: true)
      .padding(.horizontal, SetupGrid.inset)
  }
}
