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

/// Update represents a state change, together with an `Fx` publisher,
/// and an optional `Transaction`.
public struct Update<Model>
where Model: ModelProtocol {
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
        _ through: (Model) -> Self
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

/// A store is any type that can
/// - get an equatable `state`
/// - `send` actions
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

        // Did fx complete immediately?
        // We use this flag to deal with a race condition where
        // an effect can complete before it is added to cancellables,
        // meaking receiveCompletion tries to clean it up before it is added.
        var didComplete = false
        let cancellable = fx
            .sink(
                receiveCompletion: { [weak self] _ in
                    didComplete = true
                    self?.cancellables.removeValue(forKey: id)
                },
                receiveValue: { [weak self] action in
                    self?.send(action)
                }
            )
        if !didComplete {
            self.cancellables[id] = cancellable
        }
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

/// A cursor provides a complete description of how to map from one component
/// domain to another.
public protocol CursorProtocol {
    associatedtype Model: ModelProtocol
    associatedtype ViewModel: ModelProtocol

    /// Get an inner state from an outer state
    static func get(state: Model) -> ViewModel

    /// Set an inner state on an outer state, returning an outer state
    static func set(state: Model, inner: ViewModel) -> Model

    /// Tag an inner action, transforming it into an outer action
    static func tag(_ action: ViewModel.Action) -> Model.Action
}

extension CursorProtocol {
    /// Update an outer state through a cursor.
    /// CursorProtocol.update offers a convenient way to call child
    /// update functions from the parent domain, and get parent-domain
    /// states and actions back from it.
    ///
    /// - `state` the outer state
    /// - `action` the inner action
    /// - `environment` the environment for the update function
    /// - Returns a new outer state
    public static func update(
        state: Model,
        action viewAction: ViewModel.Action,
        environment: ViewModel.Environment
    ) -> Update<Model> {
        let next = ViewModel.update(
            state: get(state: state),
            action: viewAction,
            environment: environment
        )
        return Update(
            state: set(state: state, inner: next.state),
            fx: next.fx.map(tag).eraseToAnyPublisher(),
            transaction: next.transaction
        )
    }
}

/// ViewStore is a local projection of a Store that can be passed down to
/// a child view.
//  NOTE: ViewStore works like Binding. It reads state at runtime using a
//  getter closure that you provide. It is important that we
//  read the state via a closure, like Binding does, rather than
//  storing the literal value as a property of the instance.
//  If you store the literal value as a property, you will have "liveness"
//  issues with the data in views, especially around things like text editors.
//  Letters entered out of order, old states showing up, etc.
//  I suspect this has something to do with either the guts of SwiftUI or the
//  guts of UIViewRepresentable.
//  2022-06-12 Gordon Brander
public struct ViewStore<ViewModel>: StoreProtocol
where ViewModel: ModelProtocol
{
    private let _get: () -> ViewModel
    private let _send: (ViewModel.Action) -> Void

    /// Initialize a ViewStore using a get and send closure.
    public init(
        get: @escaping () -> ViewModel,
        send: @escaping (ViewModel.Action) -> Void
    ) {
        self._get = get
        self._send = send
    }

    /// Get current state
    public var state: ViewModel { self._get() }

    /// Send an action
    public func send(_ action: ViewModel.Action) {
        self._send(action)
    }
}

extension ViewStore {
    /// Initialize a ViewStore from a store of some type, and a cursor.
    /// - Store can be any type conforming to `StoreProtocol`
    /// - Cursor can be any type conforming to `CursorProtocol`
    public init<Store, Cursor>(store: Store, cursor: Cursor.Type)
    where
        Store: StoreProtocol,
        Cursor: CursorProtocol,
        Store.Model == Cursor.Model,
        ViewModel == Cursor.ViewModel
    {
        self.init(
            get: { Cursor.get(state: store.state) },
            send: { action in store.send(Cursor.tag(action)) }
        )
    }
}

extension ViewStore {
    /// Create a ViewStore for a constant state that swallows actions.
    /// Convenience for view previews.
    public static func constant(
        state: ViewModel
    ) -> ViewStore<ViewModel> {
        ViewStore<ViewModel>(
            get: { state },
            send: { action in }
        )
    }
}

extension Binding {
    /// Initialize a Binding from a store.
    /// - `get` reads the store state to a binding value.
    /// - `tag` transforms the value into an action.
    /// - Returns a binding suitable for use in a vanilla SwiftUI view.
    public init<Store: StoreProtocol>(
        store: Store,
        get: @escaping (Store.Model) -> Value,
        tag: @escaping (Value) -> Store.Model.Action
    ) {
        self.init(
            get: { get(store.state) },
            set: { value in store.send(tag(value)) }
        )
    }
}
