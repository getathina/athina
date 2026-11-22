import CoreGraphics
import Foundation
import ImageIO
import Synchronization

@testable import AthinaCore

/// A desktop of windows standing in for ScreenCaptureKit, which a screenshot
/// draws through the filter it is given and nothing captures.
///
/// A list of apps is read as broadly as a filter could: an app with a bundle
/// identifier stands for every process with that identifier, and one without
/// for its process alone.
final class FakeDesktop: ScreenshotSource {
  struct Display: CapturableDisplay, Sendable {
    let displayID: CGDirectDisplayID
    let frame: CGRect
  }

  struct App: CapturableApplication, Sendable {
    let processID: pid_t
    let bundleIdentifier: String

    init(_ bundleIdentifier: String, pid: pid_t) {
      self.bundleIdentifier = bundleIdentifier
      processID = pid
    }
  }

  struct Window: Sendable {
    let app: App
    let text: String
    var display = FakeDesktop.left
  }

  static let left = Display(
    displayID: 7001,
    frame: CGRect(x: 0, y: 0, width: 1600, height: 1000)
  )
  static let right = Display(
    displayID: 7002,
    frame: CGRect(x: 1600, y: 0, width: 1280, height: 800)
  )
  /// How many windows a frame has room for, each in a column of its own.
  private static let columns = 16

  private struct State {
    var windows: [Window]
    var running: [App]
    var appearing: [Window] = []
    var screenshots = 0
  }

  private let state: Mutex<State>
  private let displays: [Display]

  /// A desktop showing `windows`, with `running` the apps that have none on
  /// screen but are listed.
  init(
    displays: [Display] = [FakeDesktop.left],
    windows: [Window],
    running: [App] = []
  ) {
    self.displays = displays
    state = Mutex(State(windows: windows, running: running))
  }

  var screenshotCount: Int { state.withLock { $0.screenshots } }

  /// Puts `window` on screen now.
  func show(_ window: Window) {
    state.withLock { $0.windows.append(window) }
  }

  /// Puts `window` on screen after the next list is fetched and before its
  /// screenshot is taken.
  func appearAfterList(_ window: Window) {
    state.withLock { $0.appearing.append(window) }
  }

  // MARK: ScreenshotSource

  func content() async throws -> (displays: [Display], applications: [App]) {
    let applications = state.withLock { state in
      var seen = Set<pid_t>()
      let listed = (state.windows.map(\.app) + state.running).filter {
        seen.insert($0.processID).inserted
      }
      state.windows += state.appearing
      state.appearing = []
      return listed
    }
    return (displays, applications)
  }

  func screenshot(
    of display: Display,
    showingOnly applications: [App],
    size: CGSize
  ) async throws -> CGImage {
    try draw(display, size: size) { app in applications.contains { Self.stands($0, for: app) } }
  }

  private static func stands(_ listed: App, for app: App) -> Bool {
    listed.bundleIdentifier.isEmpty
      ? listed.processID == app.processID
      : listed.bundleIdentifier == app.bundleIdentifier
  }

  // MARK: What is in a frame

  /// Draws each window the filter `shows` as a white column of its own on black.
  private func draw(_ display: Display, size: CGSize, shows: (App) -> Bool) throws -> CGImage {
    let windows = state.withLock { state in
      state.screenshots += 1
      return state.windows
    }
    precondition(windows.count <= Self.columns, "a frame has a column for each window")
    let width = Int(size.width)
    let height = Int(size.height)
    guard let context = Self.grayContext(width: width, height: height) else {
      throw ScreenCaptureError.captureFailed("the fake desktop could not be drawn")
    }
    context.setFillColor(gray: 0, alpha: 1)
    context.fill(CGRect(x: 0, y: 0, width: width, height: height))
    context.setFillColor(gray: 1, alpha: 1)
    let columnWidth = CGFloat(width) / CGFloat(Self.columns)
    for (column, window) in windows.enumerated()
    where window.display.displayID == display.displayID && shows(window.app) {
      context.fill(
        CGRect(x: CGFloat(column) * columnWidth, y: 0, width: columnWidth, height: CGFloat(height))
      )
    }
    guard let image = context.makeImage() else {
      throw ScreenCaptureError.captureFailed("the fake desktop could not be drawn")
    }
    return image
  }

  /// The text of each window that can be seen in `image`, read from its pixels
  /// alone.
  func texts(in image: CGImage) -> [String] {
    guard let context = Self.grayContext(width: Self.columns, height: 1) else { return [] }
    context.interpolationQuality = .medium
    context.draw(image, in: CGRect(x: 0, y: 0, width: Self.columns, height: 1))
    guard let data = context.data else { return [] }
    let pixels = withExtendedLifetime(context) {
      Array(UnsafeRawBufferPointer(start: data, count: Self.columns))
    }
    let windows = state.withLock { $0.windows }
    return windows.enumerated().compactMap { column, window in
      pixels[column] > 127 ? window.text : nil
    }
  }

  /// The text of each window that can be seen in a saved or sent JPEG.
  func texts(inJPEG data: Data) -> [String]? {
    guard
      let source = CGImageSourceCreateWithData(data as CFData, nil),
      let image = CGImageSourceCreateImageAtIndex(source, 0, nil)
    else { return nil }
    return texts(in: image)
  }

  private static func grayContext(width: Int, height: Int) -> CGContext? {
    CGContext(
      data: nil,
      width: width,
      height: height,
      bitsPerComponent: 8,
      bytesPerRow: width,
      space: CGColorSpaceCreateDeviceGray(),
      bitmapInfo: CGImageAlphaInfo.none.rawValue
    )
  }
}

/// Text recognition that reads a fake desktop's windows from the frame's pixels.
struct DesktopRecognizer: TextRecognizing {
  let desktop: FakeDesktop

  func recognize(_ frame: CapturedFrame, level: OCRLevel) async throws -> [TextBlock] {
    desktop.texts(in: frame.image).enumerated().map { line, text in
      let rect = CGRect(x: 0, y: CGFloat(line) * 20, width: 400, height: 16)
      return TextBlock(text: text, confidence: 1, imageRect: rect, screenRect: rect)
    }
  }
}
