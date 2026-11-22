import AthinaFeatures
import ComposableArchitecture

/// The features' parent while `AppState` is still the app's root.
///
/// It scopes each ported feature and forwards what a feature delegates to
/// `AppState`, which calls the actors and changes the settings, so no feature
/// does, as the send that brought it returns (`HostedParent`). The root store
/// replaces it.
@Reducer
struct Hosted {
  /// What the features delegate to `AppState`.
  enum Delegate: Sendable {
    case toast(ToastFeature.Action.Delegate)
  }

  @ObservableState
  struct State: Equatable {
    var toast = ToastFeature.State()
  }

  enum Action {
    case toast(ToastFeature.Action)
  }

  let parent: HostedParent<Delegate>

  var body: some ReducerOf<Self> {
    Scope(\.toast, action: \.toast) {
      ToastFeature()
    }
    Reduce { _, action in
      switch action {
      case .toast(.delegate(let delegate)):
        return parent.forward(.toast(delegate))
      case .toast:
        return .none
      }
    }
  }
}
