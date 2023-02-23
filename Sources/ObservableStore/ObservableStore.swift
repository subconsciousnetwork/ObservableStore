//
//  Store.swift
//
//  Created by Gordon Brander on 9/15/21.

import Foundation
import Combine
import SwiftUI

/// Fx is a publisher that publishes actions and never fails.
public typealias Fx<Action> = AnyPublisher<Action, Never>

/// A model is an equatable type that knows how to create
/// state `Updates` for itself via a static update function.
public protocol ModelProtocol: Equatable {
    associatedtype Action
    associatedtype Environment

    static func update(
        state: Self,
        action: Action,
        environment: Environment
    ) -> Update<Self>
}

extension ModelProtocol {
    /// Update state through a sequence of actions, merging fx.
    /// - State updates happen immediately
    /// - Fx are merged
    /// - Last transaction wins
    /// This function is useful for composing actions, or when dispatching
    /// actions down to multiple child components.
    /// - Returns an Update that is the result of sequencing actions
    public static func update(
        state: Self,
        actions: [Action],
        environment: Environment
    ) -> Update<Self> {
        actions.reduce(
            Update(state: state),
            { result, action in
                let next = update(
                    state: result.state,
                    action: action,
                    environment: environment
                )
                return Update(
                    state: next.state,
                    fx: result.fx.merge(with: next.fx).eraseToAnyPublisher(),
                    transaction: next.transaction
                )
            }
        )
    }
}

extension ModelProtocol {
    /// Update a child state within a parent state.
    /// This update offers a convenient way to call child update functions
    /// from the parent domain, and get parent-domain states and actions
    /// back from it.
    ///
    /// - `get` gets the child's state
    /// - `set` sets the child's state within the parent state
    /// - `tag` tags child actions, turning them into parent actions
    /// - `state` the outer state
    /// - `action` the inner action
    /// - `environment` the environment for the update function
    /// - Returns a new outer state
    public static func update<ViewModel: ModelProtocol>(
        get: (Self) -> ViewModel?,
        set: (Self, ViewModel) -> Self,
        tag: @escaping (ViewModel.Action) -> Self.Action,
        state: Self,
        action viewAction: ViewModel.Action,
        environment: ViewModel.Environment
    ) -> Update<Self> {
        // If getter returns nil (as in case of a list item that no longer
        // exists), do nothing.
        guard let inner = get(state) else {
            return Update(state: state)
        }
        let next = ViewModel.update(
            state: inner,
            action: viewAction,
            environment: environment
        )
        return Update(
            state: set(state, next.state),
            fx: next.fx.map(tag).eraseToAnyPublisher(),
            transaction: next.transaction
        )
    }
}

/// Update represents a state change, together with an `Fx` publisher,
/// and an optional `Transaction`.
public struct Update<Model: ModelProtocol> {
    /// `State` for this update
    public var state: Model
    /// `Fx` for this update.
    /// Default is an `Empty` publisher (no effects)
    public var fx: Fx<Model.Action>
    /// The transaction that should be set during this update.
    /// Store uses this value to set the transaction while updating state,
    /// allowing you to drive explicit animations from your update function.
    /// If left `nil`, store will defer to the global transaction
    /// for this state update.
    /// See https://developer.apple.com/documentation/swiftui/transaction
    public var transaction: Transaction?

    public init(
        state: Model,
        fx: Fx<Model.Action> = Empty(completeImmediately: true)
            .eraseToAnyPublisher(),
        transaction: Transaction? = nil
    ) {
        self.state = state
        self.fx = fx
        self.transaction = transaction
    }

    /// Merge existing fx together with new fx.
    /// - Returns a new `Update`
    public func mergeFx(_ fx: Fx<Model.Action>) -> Update<Model> {
        var this = self
        this.fx = self.fx.merge(with: fx).eraseToAnyPublisher()
        return this
    }

    /// Set explicit animation for this update.
    /// Sets new transaction with specified animation.
    /// - Returns a new `Update`
    public func animation(_ animation: Animation? = .default) -> Self {
        var this = self
        this.transaction = Transaction(animation: animation)
        return this
    }
}

/// A store is any type that can
/// - get a state
/// - send actions
public protocol StoreProtocol {
    associatedtype Model: ModelProtocol

    var state: Model { get }

    func send(_ action: Model.Action) -> Void
}

/// Store is a source of truth for a state.
///
/// Store is an `ObservableObject`. You can use it in a view via
/// `@ObservedObject` or `@StateObject` to power view rendering.
///
/// Store has a `@Published` `state` (typically a struct).
/// All updates and effects to this state happen through actions
/// sent to `store.send`.
public final class Store<Model>: ObservableObject, StoreProtocol
where Model: ModelProtocol
{
    /// Stores cancellables by ID
    private(set) var cancellables: [UUID: AnyCancellable] = [:]
    /// Private for all actions sent to the store.
    private var _actions: PassthroughSubject<Model.Action, Never>
    /// Publisher for all actions sent to the store.
    public var actions: AnyPublisher<Model.Action, Never> {
        _actions.eraseToAnyPublisher()
    }
    /// Current state.
    /// All writes to state happen through actions sent to `Store.send`.
    @Published public private(set) var state: Model
    /// Environment, which typically holds references to outside information,
    /// such as API methods.
    ///
    /// This is also a good place to put long-lived services, such as keyboard
    /// listeners, since its lifetime will match the lifetime of the Store.
    ///
    /// Tip: if you need to publish external events to the store, such as
    /// keyboard events, consider publishing them via a Combine Publisher on
    /// the environment. You can subscribe to the publisher in `update`, for
    /// example, by firing an action `onAppear`, then mapping the environment
    /// publisher to an `fx` and returning it as part of an `Update`.
    /// Store will hold on to the resulting `fx` publisher until it completes,
    /// which in the case of long-lived services, could be until the
    /// app is stopped.
    public var environment: Model.Environment

    public init(
        state: Model,
        environment: Model.Environment
    ) {
        self.state = state
        self.environment = environment
        self._actions = PassthroughSubject<Model.Action, Never>()
    }

    /// Initialize and send an initial action to the store.
    /// Useful when performing actions once and only once upon creation
    /// of the store.
    public convenience init(
        state: Model,
        action: Model.Action,
        environment: Model.Environment
    ) {
        self.init(state: state, environment: environment)
        self.send(action)
    }

    /// Subscribe to a publisher of actions, piping them through to
    /// the store.
    ///
    /// Holds on to the cancellable until publisher completes.
    /// When publisher completes, removes cancellable.
    public func subscribe(to fx: Fx<Model.Action>) {
        // Create a UUID for the cancellable.
        // Store cancellable in dictionary by UUID.
        // Remove cancellable from dictionary upon effect completion.
        // This retains the effect pipeline for as long as it takes to complete
        // the effect, and then removes it, so we don't have a cancellables
        // memory leak.
        let id = UUID()

        // Receive Fx on main thread. This does two important things:
        //
        // First, SwiftUI requires that any state mutations that would change
        // views happen on the main thread. Receiving on main ensures that
        // all fx-driven state transitions happen on main, even if the
        // publisher is off-main-thread.
        //
        // Second, if we didn't schedule receive on main, it would be possible
        // for publishers to complete immediately, causing receiveCompletion
        // to attempt to remove the publisher from `cancellables` before
        // it is added. By scheduling to receive publisher on main,
        // we force publisher to complete on next tick, ensuring that it
        // is always first added, then removed from `cancellables`.
        let cancellable = fx
            .receive(
                on: DispatchQueue.main,
                options: .init(qos: .default)
            )
            .sink(
                receiveCompletion: { [weak self] _ in
                    self?.cancellables.removeValue(forKey: id)
                },
                receiveValue: { [weak self] action in
                    self?.send(action)
                }
            )
        self.cancellables[id] = cancellable
    }

    /// Send an action to the store to update state and generate effects.
    /// Any effects generated are fed back into the store.
    ///
    /// Note: SwiftUI requires that all UI changes happen on main thread.
    /// We run effects as-given, without forcing them on to main thread.
    /// This means that main-thread effects will be run immediately, enabling
    /// you to drive things like withAnimation via actions.
    /// However it also means that publishers which run off-main-thread MUST
    /// make sure that they join the main thread (e.g. with
    /// `.receive(on: DispatchQueue.main)`).
    public func send(_ action: Model.Action) {
        /// Broadcast action to any outside subscribers
        self._actions.send(action)
        // Generate next state and effect
        let next = Model.update(
            state: self.state,
            action: action,
            environment: self.environment
        )
        // Set `state` if changed.
        //
        // Mutating state (a `@Published` property) will fire `objectWillChange`
        // and cause any views that subscribe to store to re-evaluate
        // their body property.
        //
        // If no change has occurred, we avoid setting the property
        // so that body does not need to be reevaluated.
        if self.state != next.state {
            // If transaction is specified by update, set state with
            // that transaction.
            //
            // Otherwise, if transaction is nil, just set state, and
            // defer to global transaction.
            if let transaction = next.transaction {
                withTransaction(transaction) {
                    self.state = next.state
                }
            } else {
                self.state = next.state
            }
        }
        // Run effect
        self.subscribe(to: next.fx)
    }
}

public struct ViewStore<ViewModel: ModelProtocol>: StoreProtocol {
    private var _send: (ViewModel.Action) -> Void
    public var state: ViewModel

    public init(
        state: ViewModel,
        send: @escaping (ViewModel.Action) -> Void
    ) {
        self.state = state
        self._send = send
    }
        
    public func send(_ action: ViewModel.Action) {
        self._send(action)
    }
}

extension ViewStore {
    public init<Action>(
        state: ViewModel,
        send: @escaping (Action) -> Void,
        tag: @escaping (ViewModel.Action) -> Action
    ) {
        self.init(
            state: state,
            send: { action in send(tag(action)) }
        )
    }
}

extension StoreProtocol {
    /// Create a viewStore from a StoreProtocol
    func viewStore<ViewModel: ModelProtocol>(
        get: (Self.Model) -> ViewModel,
        tag: @escaping (ViewModel.Action) -> Self.Model.Action
    ) -> ViewStore<ViewModel> {
        ViewStore(
            state: get(self.state),
            send: self.send,
            tag: tag
        )
    }
}

public struct Address {
    /// Forward transform an address (send function) into a local address.
    /// View-scoped actions are tagged using `tag` before being forwarded to
    /// `send.`
    public static func forward<Action, ViewAction>(
        send: @escaping (Action) -> Void,
        tag: @escaping (ViewAction) -> Action
    ) -> (ViewAction) -> Void {
        { viewAction in send(tag(viewAction)) }
    }
}

extension Binding {
    /// Initialize a Binding from a store.
    /// - `get` reads the binding value.
    /// - `send` sends actions to some address.
    /// - `tag` tags the value, turning it into an action for `send`
    /// - Returns a binding suitable for use in a vanilla SwiftUI view.
    public init<Action>(
        get: @escaping () -> Value,
        send: @escaping (Action) -> Void,
        tag: @escaping (Value) -> Action
    ) {
        self.init(
            get: get,
            set: { value in send(tag(value)) }
        )
    }
}

extension StoreProtocol {
    func binding<Value>(
        get: @escaping (Self.Model) -> Value,
        tag: @escaping (Value) -> Self.Model.Action
    ) -> Binding<Value> {
        Binding(
            get: { get(self.state) },
            set: { value in self.send(tag(value)) }
        )
    }
}
