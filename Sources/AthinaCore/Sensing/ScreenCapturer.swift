import CoreGraphics
import Foundation
import ScreenCaptureKit

/// A downscaled capture of one display.
public struct CapturedFrame: @unchecked Sendable {
  /// The captured image, its longest edge at most the requested maximum,
  /// without the cursor, Athina's own windows or an excluded app's.
  public let image: CGImage
  /// The display the frame was captured from.
  public let displayID: CGDirectDisplayID
  /// The display's bounds in global display coordinates.
  public let screenRect: CGRect
}

/// Why a screen capture failed.
public enum ScreenCaptureError: Error, CustomStringConvertible {
  case noDisplays
  case nothingToCapture
  case captureFailed(String)

  /// A short message saying what went wrong, for the cadence status's last
  /// error.
  public var description: String {
    switch self {
    case .noDisplays: "no displays available to capture"
    case .nothingToCapture: "no app is listed whose windows may be captured"
    case .captureFailed(let message): message
    }
  }
}

/// An app as ScreenCaptureKit lists it.
protocol CapturableApplication {
  var processID: pid_t { get }
  var bundleIdentifier: String { get }
}

/// A display as ScreenCaptureKit lists it.
protocol CapturableDisplay {
  var displayID: CGDirectDisplayID { get }
  var frame: CGRect { get }
}

extension SCRunningApplication: CapturableApplication {}
extension SCDisplay: CapturableDisplay {}

/// What `ScreenCapturer` asks of ScreenCaptureKit, so a test can stand a drawn
/// desktop in for it and capture nothing.
protocol ScreenshotSource: Sendable {
  associatedtype Display: CapturableDisplay
  associatedtype Application: CapturableApplication

  /// Returns the displays and every app with a window, on screen or off.
  func content() async throws -> (displays: [Display], applications: [Application])

  /// Returns an image of `display` with no window but those of `applications`
  /// and the menu bar.
  func screenshot(
    of display: Display,
    showingOnly applications: [Application],
    size: CGSize
  ) async throws -> CGImage
}

/// ScreenCaptureKit itself.
struct ScreenCaptureKitSource: ScreenshotSource {
  /// What shows where no window does.
  ///
  /// The default is clear, black in a JPEG, where the menu bar's text would be
  /// lost whenever it is dark. It is a constant because the configuration does
  /// not retain its color.
  private static let uncovered = CGColor(srgbRed: 0.5, green: 0.5, blue: 0.5, alpha: 1)

  func content() async throws -> (displays: [SCDisplay], applications: [SCRunningApplication]) {
    // Off-screen and desktop windows count too, for an app the list leaves out
    // is left out of the screenshot, whoever draws the desktop included.
    let content = try await SCShareableContent.excludingDesktopWindows(
      false,
      onScreenWindowsOnly: false
    )
    return (content.displays, content.applications)
  }

  func screenshot(
    of display: SCDisplay,
    showingOnly applications: [SCRunningApplication],
    size: CGSize
  ) async throws -> CGImage {
    // Naming the apps to show means no app the list lacks can be shown, one
    // that appeared after it was fetched included. The filter follows a listed
    // app's new windows, child and pop-up ones too.
    let filter = SCContentFilter(
      display: display,
      including: applications,
      exceptingWindows: []
    )
    filter.includeMenuBar = true
    let configuration = SCStreamConfiguration()
    configuration.width = Int(size.width)
    configuration.height = Int(size.height)
    configuration.showsCursor = false
    configuration.captureResolution = .automatic
    configuration.pixelFormat = kCVPixelFormatType_32BGRA
    configuration.backgroundColor = Self.uncovered
    return try await SCScreenshotManager.captureImage(
      contentFilter: filter,
      configuration: configuration
    )
  }
}

/// Captures the display containing the focused window with ScreenCaptureKit,
/// showing only the apps it may: none that is excluded, and not Athina, so the
/// debug panel never captures itself.
public actor ScreenCapturer {
  private let source: any ScreenshotSource
  private let ownPID: pid_t
  private let ownBundleID: String?

  /// Creates a capturer.
  public init() {
    self.init(
      source: ScreenCaptureKitSource(),
      ownPID: ProcessInfo.processInfo.processIdentifier,
      ownBundleID: Bundle.main.bundleIdentifier
    )
  }

  /// Creates a capturer over `source` for the Athina with `ownPID` and `ownBundleID`.
  init(source: any ScreenshotSource, ownPID: pid_t, ownBundleID: String?) {
    self.source = source
    self.ownPID = ownPID
    self.ownBundleID = ownBundleID
  }

  /// Captures the display the focused window overlaps most, or the main
  /// display when there is no window frame or it overlaps none, showing only
  /// apps that were listed for this capture, are not excluded, and are not
  /// Athina.
  ///
  /// - Parameters:
  ///   - windowFrame: The focused window's frame in global display
  ///     coordinates, or nil when it is not known.
  ///   - maxDimension: The most pixels the captured image's longest edge
  ///     may have.
  ///   - excludedBundleIDs: The lowercase bundle identifiers of the apps
  ///     none of whose windows may be in the image.
  /// - Returns: The downscaled frame and the display it came from.
  /// - Throws: `ScreenCaptureError` when there is no display, no app may be
  ///   shown, or the capture fails, and ScreenCaptureKit's own error when the
  ///   list of displays and apps cannot be fetched.
  public func capture(
    windowFrame: CGRect?,
    maxDimension: Int,
    excluding excludedBundleIDs: Set<String>
  ) async throws -> CapturedFrame {
    // A filter can match an app by its bundle identifier, so another copy of
    // Athina in the list would show this one's windows too.
    var hidden = excludedBundleIDs
    if let ownBundleID { hidden.insert(ownBundleID.lowercased()) }
    return try await Self.capture(
      from: source,
      windowFrame: windowFrame,
      maxDimension: maxDimension,
      hidingBundleIDs: hidden,
      hidingPID: ownPID
    )
  }

  /// Outside the actor, as what ScreenCaptureKit lists is not `Sendable`.
  private static func capture<Source: ScreenshotSource>(
    from source: Source,
    windowFrame: CGRect?,
    maxDimension: Int,
    hidingBundleIDs hidden: Set<String>,
    hidingPID hiddenPID: pid_t
  ) async throws -> CapturedFrame {
    // The list is fetched for every capture, never cached: an app that came up
    // since a cached fetch would be missing from the screenshot.
    let (displays, applications) = try await source.content()
    guard let display = display(for: windowFrame, in: displays) else {
      throw ScreenCaptureError.noDisplays
    }
    let shown = applications.filter { app in
      app.processID != hiddenPID
        && !ExcludedApps.matches(bundleID: app.bundleIdentifier, excluded: hidden)
    }
    // Never a filter that names nothing, which could stand for the whole display.
    guard !shown.isEmpty else { throw ScreenCaptureError.nothingToCapture }
    let size = FrameImaging.boundedSize(for: display.frame.size, maxDimension: maxDimension)
    do {
      let image = try await source.screenshot(of: display, showingOnly: shown, size: size)
      return CapturedFrame(image: image, displayID: display.displayID, screenRect: display.frame)
    } catch {
      throw ScreenCaptureError.captureFailed(error.localizedDescription)
    }
  }

  /// Picks the display overlapping the window most, falling back to the main display.
  static func display<Display: CapturableDisplay>(
    for windowFrame: CGRect?,
    in displays: [Display]
  ) -> Display? {
    guard !displays.isEmpty else { return nil }
    if let windowFrame {
      let best = displays.max { a, b in
        a.frame.intersection(windowFrame).area < b.frame.intersection(windowFrame).area
      }
      if let best, best.frame.intersection(windowFrame).area > 0 {
        return best
      }
    }
    let mainID = CGMainDisplayID()
    return displays.first { $0.displayID == mainID } ?? displays.first
  }
}

extension CGRect {
  var area: CGFloat {
    isNull || isEmpty ? 0 : width * height
  }
}
