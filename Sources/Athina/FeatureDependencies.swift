import AppKit
import AthinaCore
import AthinaFeatures
import ComposableArchitecture

/// The live values of the features' dependencies (AthinaFeatures) that only
/// the app can give.
enum FeatureDependencies {
  /// Gives the features the app's own clock, the one `ClockMode` made, so a
  /// replay's faster clock moves them too.
  ///
  /// Called once, at launch, before any feature reads a dependency.
  static func prepare(clock: any AthinaClock) {
    prepareDependencies { $0.athinaClock = clock }
  }
}

extension AnnouncerClient: DependencyKey {
  /// Posts through `Announce`, where every announcement goes, so a run serving
  /// the control API logs it too.
  public static let liveValue = AnnouncerClient { text, priority in
    Announce.post(text, priority: priority)
  }
}
