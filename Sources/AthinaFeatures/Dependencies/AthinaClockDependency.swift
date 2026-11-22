import AthinaCore
import ComposableArchitecture

extension DependencyValues {
  /// The one clock every feature reads: the dates it stamps and compares, every
  /// wait, the time the Mac has been awake, and the rate real seconds pass at.
  ///
  /// The app sets it once at launch, before any feature runs, to the clock its
  /// `ClockMode` made, so a replay's faster clock moves every feature with the
  /// rest of the app. It has no test value: a test injects an `AdjustableClock`
  /// it advances, and one that injects none fails rather than waiting on real
  /// time. No feature reads `\.continuousClock`, `\.date` or `Date()`, which
  /// would split Athina's time in two.
  public var athinaClock: any AthinaClock {
    get { self[AthinaClockKey.self] }
    set { self[AthinaClockKey.self] = newValue }
  }
}

private enum AthinaClockKey: DependencyKey {
  static let liveValue: any AthinaClock = SystemClock()
}
