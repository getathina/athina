import CoreGraphics
import Foundation

// The seams between the sensing loop and the Mac: what `SensingPipeline` reads,
// each behind a protocol so a test can hand it fakes that capture nothing. The
// Mac's own conform here, except `FocusTracker`, which conforms where it is
// declared.

/// Captures the screen the person is working on.
public protocol ScreenCapturing: Sendable {
  /// Captures the display showing the window at `windowFrame`, or the main
  /// display without one, its longest edge at most `maxDimension` pixels.
  func capture(windowFrame: CGRect?, maxDimension: Int) async throws -> CapturedFrame
}

/// Recognizes the text in a captured frame.
public protocol TextRecognizing: Sendable {
  /// Returns the blocks of text in `frame`, read at `level`.
  func recognize(_ frame: CapturedFrame, level: OCRLevel) async throws -> [TextBlock]
}

/// Follows which app, window, and element have the focus.
///
/// It is isolated to `AXActor`, as Accessibility is, so calls reach it in the
/// order they were made.
@AXActor
public protocol FocusTracking: Sendable {
  /// Replaces the bundle ids of the apps that are read no further than their
  /// name.
  func updateExcluded(_ bundleIDs: Set<String>)
  /// Sets what is called with each change of focus, or removes it when nil.
  func setOnChange(_ handler: (@Sendable (FocusChange) -> Void)?)
  /// Starts following the focus.
  func start()
  /// Stops following the focus.
  func stop()
  /// Follows the app in front as the Accessibility grant now allows.
  func refreshObserver()
  /// The app in front right now, which can be ahead of the focus last tracked.
  func frontmostApplication() -> (pid: pid_t, bundleID: String?)?
  /// Reads the tracked app's focus fresh, or nil when no app is tracked.
  func readCurrent() -> FocusContext?
}

/// Reads how long ago the last input was, in real time whatever clock the
/// pipeline runs on.
public protocol InputActivityReading: Sendable {
  /// Returns the real seconds since the last input event of any kind.
  func secondsSinceLastInput() -> TimeInterval
  /// Returns the real uptime, from which those seconds place that event, so a
  /// new event can be told from a reading that only jittered.
  func systemUptime() -> TimeInterval
}

/// Reads which permissions are granted, without asking for any.
public protocol PermissionReading: Sendable {
  /// Returns which permissions are granted right now.
  func current() -> PermissionStatus
}

extension ScreenCapturer: ScreenCapturing {}

extension TextRecognizer: TextRecognizing {}

/// This Mac's input, as `InputActivity` reads it.
public struct SystemInputActivity: InputActivityReading {
  /// Creates a reader of this Mac's input.
  public init() {}

  /// Returns the real seconds since the last input event in this login session.
  public func secondsSinceLastInput() -> TimeInterval {
    InputActivity.secondsSinceLastInput()
  }

  /// Returns this Mac's uptime.
  public func systemUptime() -> TimeInterval {
    ProcessInfo.processInfo.systemUptime
  }
}

/// This Mac's permissions, as `PermissionProbe` reads them.
public struct SystemPermissions: PermissionReading {
  /// Creates a reader of this Mac's permissions.
  public init() {}

  /// Returns which permissions macOS has granted Athina right now.
  public func current() -> PermissionStatus {
    PermissionProbe.current()
  }
}
