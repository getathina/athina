import Combine
import ComposableArchitecture

/// The features' parent, and where what follows from a send is done: all of
/// it by the time that send returns.
///
/// First every window that follows the store catches up, so none is drawn
/// behind its state, then VoiceOver is told what was announced, so a window
/// is up before it is spoken of, and then `receive` gets what was delegated,
/// each in the order it was sent. None of it waits for a later turn of the
/// run loop or the main queue: work already queued would come in between, and
/// would find the window and the parent as they were.
///
/// A delegate action cannot be acted on while the send that brought it is
/// still being processed, since acting sends again, so it waits for that send
/// and no longer. What `receive` sends is followed and announced as it
/// returns, so before what `receive` does next, and what that delegates is
/// handed over once `receive` has returned, never inside it.
@MainActor
public final class HostedParent<Delegate: Sendable> {
  /// Acts on one delegate action; nil until the app starts.
  public var receive: ((Delegate) -> Void)?
  private var waiting: [Delegate] = []
  private var delivering = false
  private var followers: [@MainActor () -> Void] = []
  private var announcements: [@MainActor () -> Void] = []
  private var catchingUp = false
  private var sentWhileCatchingUp = false

  /// Creates a parent that nothing has been delegated to.
  public init() {}

  /// The effect that queues `delegate` as the send that brought it starts it,
  /// to be handed over as that send returns.
  ///
  /// - Parameter delegate: What was delegated.
  /// - Returns: The effect, which sends no action.
  nonisolated public func forward<Action>(_ delegate: Delegate) -> Effect<Action> {
    .publisher {
      Deferred {
        // A store starts its effects on the main actor.
        MainActor.assumeIsolated { self.waiting.append(delegate) }
        return Empty<Action, Never>()
      }
    }
  }

  /// Hands over everything waiting, in order.
  private func deliver() {
    guard !delivering, let receive else { return }
    delivering = true
    defer { delivering = false }
    while !waiting.isEmpty {
      receive(waiting.removeFirst())
    }
  }
}

/// What a `HostedStore` needs of its parent, whatever is delegated to it.
@MainActor
protocol SendFollowing: AnyObject, Sendable {
  /// Has `apply` follow the store, from now on.
  func follow(_ apply: @escaping @MainActor () -> Void)
  /// Has `announce` wait until the windows have followed the send under way.
  func announceOnceFollowed(_ announce: @escaping @MainActor () -> Void)
  /// Does what follows from the send that has just returned.
  func sendReturned()
}

extension HostedParent: SendFollowing {
  func follow(_ apply: @escaping @MainActor () -> Void) {
    followers.append(apply)
    sendReturned()
  }

  func announceOnceFollowed(_ announce: @escaping @MainActor () -> Void) {
    announcements.append(announce)
  }

  func sendReturned() {
    // A send of a follower's, or from an announcement, is followed once that
    // has returned, and before anything more is announced.
    guard !catchingUp else {
      sentWhileCatchingUp = true
      return
    }
    catchingUp = true
    repeat {
      sentWhileCatchingUp = false
      for follower in followers { follower() }
      while !sentWhileCatchingUp, !announcements.isEmpty {
        announcements.removeFirst()()
      }
    } while sentWhileCatchingUp
    catchingUp = false
    deliver()
  }
}

/// A store under a `HostedParent`, whose every send is followed before it
/// returns.
///
/// It is all a view or a controller holds of the store, so neither can send
/// past the parent. An effect's own send does not come through here: the
/// effect calls `\.sendReturned` straight after it.
@MainActor
@dynamicMemberLookup
public struct HostedStore<State: ObservableState, Action> {
  private let store: Store<State, Action>
  private let parent: any SendFollowing

  /// Creates the root store under `parent`.
  ///
  /// - Parameters:
  ///   - initialState: The state it starts with.
  ///   - parent: What follows its sends.
  ///   - reducer: The root's reducer.
  ///   - prepare: Sets the dependencies it needs beyond the live ones.
  public init<R: Reducer<State, Action>, Delegate: Sendable>(
    initialState: State,
    parent: HostedParent<Delegate>,
    @ReducerBuilder<State, Action> reducer: () -> R,
    withDependencies prepare: @escaping (inout DependencyValues) -> Void = { _ in }
  ) {
    self.parent = parent
    store = Store(
      initialState: initialState,
      reducer: reducer,
      withDependencies: {
        prepare(&$0)
        $0.sendReturned = { parent.sendReturned() }
        $0.announceOnceFollowed = { parent.announceOnceFollowed($0) }
      }
    )
  }

  private init(store: Store<State, Action>, parent: any SendFollowing) {
    self.store = store
    self.parent = parent
  }

  /// The state, observed by what reads it as a store's is.
  public var state: State { store.state }

  /// One value of the state, observed as `state` is.
  public subscript<Value>(dynamicMember keyPath: KeyPath<State, Value>) -> Value {
    store.state[keyPath: keyPath]
  }

  /// Sends `action`; by the time this returns the windows have followed, it
  /// has been announced and the parent has acted on what it delegated.
  ///
  /// One a follower sends has all that as the follower returns, and one the
  /// parent sends is acted on as the parent returns.
  public func send(_ action: Action) {
    store.send(action)
    parent.sendReturned()
  }

  /// Runs `apply` now and as each send returns from now on, before anything is
  /// announced and before the parent acts: how a controller that owns a window
  /// follows.
  ///
  /// - Parameter apply: Reads the state and brings the window up to it. It is
  ///   kept as long as the parent is, so it holds its owner weakly.
  public func follow(_ apply: @escaping @MainActor () -> Void) {
    parent.follow(apply)
  }

  /// The store of one child's domain, under the same parent.
  ///
  /// - Parameters:
  ///   - state: The child's state.
  ///   - action: The child's actions.
  /// - Returns: The child's store.
  public func scope<ChildState: ObservableState, ChildAction>(
    _ state: KeyPath<State, ChildState>,
    action: CaseKeyPath<Action, ChildAction>
  ) -> HostedStore<ChildState, ChildAction> {
    HostedStore<ChildState, ChildAction>(store: store.scope(state, action: action), parent: parent)
  }
}

/// A `HostedStore` of a reducer's domain, as `StoreOf` is of a `Store`.
public typealias HostedStoreOf<R: Reducer> = HostedStore<R.State, R.Action>
where R.State: ObservableState

private enum SendReturnedKey: DependencyKey {
  static var liveValue: @MainActor @Sendable () -> Void { {} }
  static var testValue: @MainActor @Sendable () -> Void { {} }
}

private enum AnnounceOnceFollowedKey: DependencyKey {
  static var liveValue: @MainActor @Sendable (@escaping @MainActor () -> Void) -> Void {
    { $0() }
  }
  static var testValue: @MainActor @Sendable (@escaping @MainActor () -> Void) -> Void {
    { $0() }
  }
}

extension DependencyValues {
  /// What an announcement waits on, so it is made once the windows have
  /// followed its send (`HostedParent`).
  ///
  /// A `HostedStore` sets it; in a store with no parent it is made at once.
  var announceOnceFollowed: @MainActor @Sendable (@escaping @MainActor () -> Void) -> Void {
    get { self[AnnounceOnceFollowedKey.self] }
    set { self[AnnounceOnceFollowedKey.self] = newValue }
  }

  /// What an effect calls straight after each send it makes, so that send is
  /// followed as a view's is (`HostedParent`).
  ///
  /// A `HostedStore` sets it; in a store with no parent nothing follows.
  var sendReturned: @MainActor @Sendable () -> Void {
    get { self[SendReturnedKey.self] }
    set { self[SendReturnedKey.self] = newValue }
  }
}
