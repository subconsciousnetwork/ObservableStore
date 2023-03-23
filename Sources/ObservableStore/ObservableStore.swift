//
//  Store.swift
//
//  Created by Gordon Brander on 9/15/21.

import Foundation
import Combine
import SwiftUI

/// An effect can be run to produce an async `Action`, and never fails.
/// It's conceptually like a lazy `Task` which does not decide its eventual
/// actor context.
public struct Effect<Action: Sendable> {
    public var run: () async -> Action
    
    public init(_ run: @escaping () async -> Action) {
        self.run = run
    }

    public func map<ViewAction>(
        _ transform: @escaping (Action) -> ViewAction
    ) -> Effect<ViewAction> {
        Effect<ViewAction> {
            await transform(self.run())
        }
    }
}

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
    /// Update state through a sequence of actions, merging effects.
    /// - State updates happen immediately
    /// - Effects are merged
    /// - Last transaction wins
    /// This function is useful for composing actions, or when dispatching
    /// actions down to multiple child components.
    /// - Returns an Update that is the result of sequencing actions
    public static func update(
        state: Self,
        actions: [Action],
        environment: Environment
    ) -> Update<Self> {
        var result = Update(state: state)
        for action in actions {
            let next = update(
                state: result.state,
                action: action,
                environment: environment
            )
            result.state = next.state
            result.effects.append(contentsOf: next.effects)
            result.transaction = next.transaction
        }
        return result
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
            effects: next.effects.map({ effect in effect.map(tag) }),
            transaction: next.transaction
        )
    }
}

/// Update represents a state change, together with effects, and an
/// optional transaction.
public struct Update<Model: ModelProtocol> {
    /// `State` for this update
    public var state: Model
    /// Effects for this update.
    public var effects: [Effect<Model.Action>]
    /// The transaction that should be set during this update.
    /// Store uses this value to set the transaction while updating state,
    /// allowing you to drive explicit animations from your update function.
    /// If left `nil`, store will defer to the global transaction
    /// for this state update.
    /// See https://developer.apple.com/documentation/swiftui/transaction
    public var transaction: Transaction?

    public init(
        state: Model,
        effects: [Effect<Model.Action>],
        transaction: Transaction? = nil
    ) {
        self.state = state
        self.effects = effects
        self.transaction = transaction
    }

    public init(
        state: Model,
        effect: Effect<Model.Action>,
        animation: Animation? = nil
    ) {
        self.state = state
        self.effects = [effect]
        self.transaction = Transaction(animation: animation)
    }

    public init(
        state: Model,
        animation: Animation? = nil
    ) {
        self.state = state
        self.effects = []
        self.transaction = Transaction(animation: animation)
    }

    /// Merge existing effects together with a new effect.
    /// - Returns a new `Update`
    public func mergeEffect(
        _ effect: Effect<Model.Action>
    ) -> Update<Model> {
        var this = self
        this.effects.append(effect)
        return this
    }
    
    /// Merge existing effects together with new effects.
    /// - Returns a new `Update`
    public func mergeEffects(
        _ effects: [Effect<Model.Action>]
    ) -> Update<Model> {
        var this = self
        this.effects.append(contentsOf: effects)
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

    @MainActor var state: Model { get }

    @MainActor func send(_ action: Model.Action) -> Void
}

/// Store is a source of truth for a state.
///
/// Store is an `ObservableObject`. You can use it in a view via
/// `@ObservedObject` or `@StateObject` to power view rendering.
///
/// Store has a `@Published` `state` (typically a struct).
/// All updates and effects to this state happen through actions
/// sent to `store.send`.
@MainActor
public final class Store<Model>: ObservableObject, StoreProtocol
where Model: ModelProtocol
{
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

    /// Run an effect and send result back to store.
    nonisolated public func run(_ effect: Effect<Model.Action>) {
        Task.detached {
            await self.send(effect.run())
        }
    }

    /// Send an action to the store to update state and generate effects.
    /// Any effects generated are fed back into the store.
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
        for effect in next.effects {
            self.run(effect)
        }
    }
}

@MainActor
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

    public init<Action>(
        state: ViewModel,
        send: @MainActor @escaping (Action) -> Void,
        tag: @escaping (ViewModel.Action) -> Action
    ) {
        self.init(
            state: state,
            send: { action in send(tag(action)) }
        )
    }

    public func send(_ action: ViewModel.Action) {
        self._send(action)
    }
}

extension StoreProtocol {
    /// Create a viewStore from a StoreProtocol
    @MainActor
    public func viewStore<ViewModel: ModelProtocol>(
        get: (Self.Model) -> ViewModel,
        tag:  @escaping (ViewModel.Action) -> Self.Model.Action
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
    @MainActor
    public static func forward<Action, ViewAction>(
        send: @MainActor @escaping (Action) -> Void,
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
    @MainActor
    public func binding<Value>(
        get: @escaping (Self.Model) -> Value,
        tag: @escaping (Value) -> Self.Model.Action
    ) -> Binding<Value> {
        Binding(
            get: { get(self.state) },
            set: { value in self.send(tag(value)) }
        )
    }
}
