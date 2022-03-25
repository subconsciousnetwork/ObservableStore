//
//  Store.swift
//
//  Created by Gordon Brander on 9/15/21.

import Foundation
import Combine
import SwiftUI

/// Fx is a publisher that publishes actions and never fails.
public typealias Fx<Action> = AnyPublisher<Action, Never>

/// Update represents a `State` change, together with an `Fx` publisher,
/// and an optional `Transaction`.
public struct Update<State, Action>
where State: Equatable {
    /// `State` for this update
    public var state: State
    /// `Fx` for this update.
    /// Default is an `Empty` publisher (no effects)
    public var fx: Fx<Action>
    /// The transaction that should be set during this update.
    /// Store uses this value to set the transaction while updating state,
    /// allowing you to drive explicit animations from your update function.
    /// If left `nil`, store will defer to the global transaction
    /// for this state update.
    /// See https://developer.apple.com/documentation/swiftui/transaction
    public var transaction: Transaction?

    public init(
        state: State,
        fx: Fx<Action> = Empty(completeImmediately: true)
            .eraseToAnyPublisher(),
        transaction: Transaction? = nil
    ) {
        self.state = state
        self.fx = fx
        self.transaction = transaction
    }

    /// Set fx for this update
    /// This will replace any existing fx for the update.
    /// - Returns a new `Update`
    func fx(_ fx: Fx<Action>) -> Update<State, Action> {
        var this = self
        this.fx = fx
        return this
    }

    /// Merge existing fx in this update with new fx.
    /// The resulting update will contain an fx publisher
    /// - Returns a new `Update`
    func mergeFx(_ fx: Fx<Action>) -> Update<State, Action> {
        var this = self
        this.fx = self.fx.merge(with: fx).eraseToAnyPublisher()
        return this
    }

    /// Set transaction for this update
    /// - Returns a new `Update`
    public func transaction(_ transaction: Transaction) -> Self {
        var this = self
        this.transaction = transaction
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

    /// Pipe a state through another update function.
    /// Allows you to compose multiple update functions together through
    /// method chaining.
    ///
    /// - Updates state,
    /// - Merges `fx`.
    /// - Replaces `transaction` with new `Update` transaction.
    ///
    /// - Returns a new `Update`
    public func pipe(
        _ through: (State) -> Self
    ) -> Self {
        let next = through(self.state)
        let fx = self.fx.merge(with: next.fx).eraseToAnyPublisher()
        return Update(
            state: next.state,
            fx: fx,
            transaction: next.transaction
        )
    }
}

/// Store is a source of truth for a state.
///
/// Store is an `ObservableObject`. You can use it in a view via
/// `@ObservedObject` or `@StateObject` to power view rendering.
///
/// Store has a `@Published` `state` (typically a struct).
/// All updates and effects to this state happen through actions
/// sent to `store.send`.
///
/// Store is meant to be used as part of a single app-wide, or
/// major-view-wide component. Store deliberately does not solve for nested
/// components or nested stores. Following Elm, deeply nested components
/// are avoided. Instead, an app should use a single store, or perhaps one
/// store per major view. Components should not have to communicate with
/// each other. If nested components do have to communicate, it is
/// probably a sign they should be the same component with a shared store.
///
/// Instead of decomposing an app into components, we decompose the app into
/// views that share the same store and actions. Sub-views should be either
/// stateless, consuming bare properties of `store.state`, or take bindings,
/// which can be created with `store.binding`.
///
/// See https://guide.elm-lang.org/architecture/
/// and https://guide.elm-lang.org/webapps/structure.html
/// for more about this approach.
public final class Store<State, Environment, Action>: ObservableObject
where State: Equatable {
    /// Stores cancellables by ID
    private(set) var cancellables: [UUID: AnyCancellable] = [:]
    /// Current state.
    /// All writes to state happen through actions sent to `Store.send`.
    @Published public private(set) var state: State
    /// Update function for state
    public var update: (
        State,
        Environment,
        Action
    ) -> Update<State, Action>
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
    public var environment: Environment

    public init(
        update: @escaping (
            State,
            Environment,
            Action
        ) -> Update<State, Action>,
        state: State,
        environment: Environment
    ) {
        self.update = update
        self.state = state
        self.environment = environment
    }

    /// Create a binding that can update the store.
    /// Sets send actions to the store, rather than setting values directly.
    /// Optional `animation` parameter allows you to trigger an animation
    /// for binding sets.
    public func binding<Value>(
        get: @escaping (State) -> Value,
        tag: @escaping (Value) -> Action,
        animation: Animation? = nil
    ) -> Binding<Value> {
        Binding(
            get: { get(self.state) },
            set: { value in
                withAnimation(animation) {
                    self.send(action: tag(value))
                }
            }
        )
    }

    /// Subscribe to a publisher of actions, piping them through to
    /// the store.
    ///
    /// Holds on to the cancellable until publisher completes.
    /// When publisher completes, removes cancellable.
    public func subscribe(fx: Fx<Action>) {
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
                options: .init(qos: .userInteractive)
            )
            .sink(
                receiveCompletion: { [weak self] _ in
                    self?.cancellables.removeValue(forKey: id)
                },
                receiveValue: { [weak self] action in
                    self?.send(action: action)
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
    public func send(action: Action) {
        // Generate next state and effect
        let next = update(self.state, self.environment, action)
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
        self.subscribe(fx: next.fx)
    }
}
