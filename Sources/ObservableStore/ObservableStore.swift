//
//  Store.swift
//
//  Created by Gordon Brander on 9/15/21.

import Foundation
import Combine
import SwiftUI
import os

/// Fx is a publisher that publishes actions and never fails.
public typealias Fx<Action> = AnyPublisher<Action, Never>

/// A model is an equatable type that knows how to create
/// state `Updates` for itself via a static update function.
public protocol ModelProtocol: Equatable {
    associatedtype Action
    associatedtype Environment

    associatedtype UpdateType: UpdateProtocol where
        UpdateType.Model == Self,
        UpdateType.Action == Self.Action

    static func update(
        state: Self,
        action: Action,
        environment: Environment
    ) -> UpdateType
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
    ) -> UpdateType {
        actions.reduce(
            UpdateType(state: state),
            { result, action in
                let next = update(
                    state: result.state,
                    action: action,
                    environment: environment
                )
                return UpdateType(
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
    ) -> UpdateType {
        // If getter returns nil (as in case of a list item that no longer
        // exists), do nothing.
        guard let inner = get(state) else {
            return UpdateType(state: state)
        }
        let next = ViewModel.update(
            state: inner,
            action: viewAction,
            environment: environment
        )
        return UpdateType(
            state: set(state, next.state),
            fx: next.fx.map(tag).eraseToAnyPublisher(),
            transaction: next.transaction
        )
    }
}

/// `UpdateProtocol` represents a state change, together with an `Fx` publisher,
/// and an optional `Transaction`.
public protocol UpdateProtocol {
    associatedtype Model
    associatedtype Action
    
    init(
        state: Model,
        fx: Fx<Action>,
        transaction: Transaction?
    )

    var state: Model { get set }
    var fx: Fx<Action> { get set }
    var transaction: Transaction? { get set }
}

extension UpdateProtocol {
    public init(state: Model, animation: Animation? = nil) {
        self.init(
            state: state,
            fx: Empty(completeImmediately: true).eraseToAnyPublisher(),
            transaction: Transaction(animation: animation)
        )
    }
    
    public init(
        state: Model,
        fx: Fx<Action>,
        animation: Animation? = nil
    ) {
        self.init(
            state: state,
            fx: fx,
            transaction: Transaction(animation: animation)
        )
    }
    
    /// Merge existing fx together with new fx.
    /// - Returns a new `Update`
    public func mergeFx(_ fx: Fx<Action>) -> Self {
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

/// Concrete implementation of `UpdateProtocol`.
/// Update represents a state change, together with an `Fx` publisher,
/// and an optional `Transaction`.
public struct Update<Model: ModelProtocol>: UpdateProtocol {
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
        fx: Fx<Model.Action>,
        transaction: Transaction?
    ) {
        self.state = state
        self.fx = fx
        self.transaction = transaction
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
    /// Cancellable for fx subscription.
    private var cancelFx: AnyCancellable?
    
    /// Private for all actions sent to the store.
    private var _actions = PassthroughSubject<Model.Action, Never>()
    
    /// Publisher for all actions sent to the store.
    public var actions: AnyPublisher<Model.Action, Never> {
        _actions.eraseToAnyPublisher()
    }
    
    /// Source publisher for batches of fx modeled as publishers.
    private var _fxBatches = PassthroughSubject<Fx<Model.Action>, Never>()
    
    /// `fx` represents a flat stream of actions from all fx publishers.
    private var fx: AnyPublisher<Model.Action, Never> {
        _fxBatches
            .flatMap({ publisher in publisher })
            .receive(on: DispatchQueue.main)
            .eraseToAnyPublisher()
    }
    
    /// Publisher for updates performed on state
    private var _updates = PassthroughSubject<Model.UpdateType, Never>()

    /// Publisher for updates performed on state.
    /// `updates` is guaranteed to fire after the state has changed.
    public var updates: AnyPublisher<Model.UpdateType, Never> {
        _updates.eraseToAnyPublisher()
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

    /// Logger to log actions sent to store.
    private var logger: Logger
    /// Should log?
    var loggingEnabled: Bool

    public init(
        state: Model,
        environment: Model.Environment,
        loggingEnabled: Bool = false,
        logger: Logger? = nil
    ) {
        self.state = state
        self.environment = environment
        self.loggingEnabled = loggingEnabled
        self.logger = logger ?? Logger(
            subsystem: "ObservableStore",
            category: "Store"
        )

        self.cancelFx = self.fx
            .sink(receiveValue: { [weak self] action in
                self?.send(action)
            })
    }

    /// Initialize with a closure that receives environment.
    /// Useful for initializing model properties from environment, and for
    /// kicking off actions once at store creation.
    public convenience init(
        create: (Model.Environment) -> Update<Model>,
        environment: Model.Environment,
        loggingEnabled: Bool = false,
        logger: Logger? = nil
    ) {
        let update = create(environment)
        self.init(
            state: update.state,
            environment: environment,
            loggingEnabled: loggingEnabled,
            logger: logger
        )
        self.subscribe(to: update.fx)
    }

    /// Initialize and send an initial action to the store.
    /// Useful when performing actions once and only once upon creation
    /// of the store.
    public convenience init(
        state: Model,
        action: Model.Action,
        environment: Model.Environment,
        loggingEnabled: Bool = false,
        logger: Logger? = nil
    ) {
        self.init(
            state: state,
            environment: environment,
            loggingEnabled: loggingEnabled,
            logger: logger
        )
        self.send(action)
    }

    /// Subscribe to a publisher of actions, send the actions it publishes
    /// to the store.
    public func subscribe(to fx: Fx<Model.Action>) {
        self._fxBatches.send(fx)
    }

    /// Send an action to the store to update state and generate effects.
    /// Any effects generated are fed back into the store.
    ///
    /// Note: SwiftUI requires that all UI changes happen on main thread.
    /// `send(_:)` is run *synchronously*. It is up to you to guarantee it is
    /// run on main thread when SwiftUI is being used.
    public func send(_ action: Model.Action) {
        if loggingEnabled {
            let actionString = String(describing: action)
            logger.log("Action: \(actionString, privacy: .public)")
        }

        // Dispatch action before state change
        _actions.send(action)

        // Create next state update
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

        // Run effects
        self.subscribe(to: next.fx)

        // Dispatch update after state change
        self._updates.send(next)
    }
}

/// Create a ViewStore, a scoped view over a store.
/// ViewStore is conceptually like a SwiftUI Binding. However, instead of
/// offering get/set for some source-of-truth, it offers a StoreProtocol.
///
/// Using ViewStore, you can create self-contained views that work with their
/// own domain
public struct ViewStore<ViewModel: ModelProtocol>: StoreProtocol {
    /// `_get` reads some source of truth dynamically, using a closure.
    ///
    /// NOTE: We've found this to be important for some corner cases in
    /// SwiftUI components, where capturing the state by value may produce
    /// unexpected issues. Examples are input fields and NavigationStack,
    /// which both expect a Binding to a state (which dynamically reads
    /// the value using a closure). Using the same approach as Binding
    /// offers the most reliable results.
    private var _get: () -> ViewModel
    private var _send: (ViewModel.Action) -> Void

    /// Initialize a ViewStore from a `get` closure and a `send` closure.
    /// These closures read from a parent store to provide a type-erased
    /// view over the store that only exposes domain-specific
    /// model and actions.
    public init(
        get: @escaping () -> ViewModel,
        send: @escaping (ViewModel.Action) -> Void
    ) {
        self._get = get
        self._send = send
    }

    public var state: ViewModel {
        self._get()
    }

    public func send(_ action: ViewModel.Action) {
        self._send(action)
    }
}

extension ViewStore {
    /// Initialize a ViewStore from a Store, using a `get` and `tag` closure.
    public init<Store: StoreProtocol>(
        store: Store,
        get: @escaping (Store.Model) -> ViewModel,
        tag: @escaping (ViewModel.Action) -> Store.Model.Action
    ) {
        self.init(
            get: { get(store.state) },
            send: { action in store.send(tag(action)) }
        )
    }
}

extension StoreProtocol {
    /// Create a viewStore from a StoreProtocol
    public func viewStore<ViewModel: ModelProtocol>(
        get: @escaping (Self.Model) -> ViewModel,
        tag: @escaping (ViewModel.Action) -> Self.Model.Action
    ) -> ViewStore<ViewModel> {
        ViewStore(
            store: self,
            get: get,
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

public protocol KeyedCursorProtocol {
    associatedtype Key
    associatedtype Model: ModelProtocol
    associatedtype ViewModel: ModelProtocol

    /// Get an inner state from an outer state
    static func get(state: Model, key: Key) -> ViewModel?

    /// Set an inner state on an outer state, returning an outer state
    static func set(state: Model, inner: ViewModel, key: Key) -> Model

    /// Tag an inner action, transforming it into an outer action
    static func tag(action: ViewModel.Action, key: Key) -> Model.Action
}

extension KeyedCursorProtocol {
    /// Update an inner state within an outer state through a keyed cursor.
    /// This cursor type is useful when looking up children in dynamic lists
    /// such as arrays or dictionaries.
    ///
    /// - `state` the outer state
    /// - `action` the inner action
    /// - `environment` the environment for the update function
    /// - `key` a key uniquely representing this model in the parent domain
    /// - Returns an update for a new outer state or nil
    public static func update(
        state: Model,
        action viewAction: ViewModel.Action,
        environment viewEnvironment: ViewModel.Environment,
        key: Key
    ) -> Update<Model>? {
        guard let viewModel = get(state: state, key: key) else {
            return nil
        }
        let next = ViewModel.update(
            state: viewModel,
            action: viewAction,
            environment: viewEnvironment
        )
        return Update(
            state: set(state: state, inner: next.state, key: key),
            fx: next.fx
                .map({ viewAction in Self.tag(action: viewAction, key: key) })
                .eraseToAnyPublisher(),
            transaction: next.transaction
        )
    }

    /// Update an inner state within an outer state through a keyed cursor.
    /// This cursor type is useful when looking up children in dynamic lists
    /// such as arrays or dictionaries.
    ///
    /// This version of update always returns an `Update`. If the child model
    /// cannot be found at key, then it returns an update for the same state
    /// (noop), effectively ignoring the action.
    ///
    /// - `state` the outer state
    /// - `action` the inner action
    /// - `environment` the environment for the update function
    /// - `key` a key uniquely representing this model in the parent domain
    /// - Returns an update for a new outer state or nil
    public static func update(
        state: Model,
        action viewAction: ViewModel.Action,
        environment viewEnvironment: ViewModel.Environment,
        key: Key
    ) -> Update<Model> {
        guard let next = update(
            state: state,
            action: viewAction,
            environment: viewEnvironment,
            key: key
        ) else {
            return Update(state: state)
        }
        return next
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

/// Create a Combine Future from an async closure that never fails.
/// Async actions are run in a task and fulfil the future's promise.
///
/// This convenience init makes it easy to bridge async/await to Combine.
/// You can call `.eraseToAnyPublisher()` on the resulting future to make it
/// an `Fx`.
public extension Future where Failure == Never {
    convenience init(
        priority: TaskPriority? = nil,
        operation: @escaping () async -> Output
    ) {
        self.init { promise in
            Task(priority: priority) {
                let value = await operation()
                promise(.success(value))
            }
        }
    }
}

/// Create a Combine Future from an async closure that never fails.
/// Async actions are run in a detached task and fulfil the future's promise.
///
/// This convenience init makes it easy to bridge async/await to Combine.
/// You can call `.eraseToAnyPublisher()` on the resulting future to make it
/// an `Fx`.
public extension Future where Failure == Never {
    static func detached(
        priority: TaskPriority? = nil,
        operation: @escaping () async -> Output
    ) -> Self {
        self.init { promise in
            Task.detached(priority: priority) {
                let value = await operation()
                promise(.success(value))
            }
        }
    }
}

/// Create a Combine Future from a throwing async closure.
/// Async actions are run in a task and fulfil the future's promise.
public extension Future where Failure == Error {
    convenience init(
        priority: TaskPriority? = nil,
        operation: @escaping () async throws -> Output
    ) {
        self.init { promise in
            Task(priority: priority) {
                do {
                    let value = try await operation()
                    promise(.success(value))
                } catch {
                    promise(.failure(error))
                }
            }
        }
    }
}

/// Create a Combine Future from a throwing async closure.
/// Async actions are run in a detached task and fulfil the future's promise.
public extension Future where Failure == Error {
    static func detached(
        priority: TaskPriority? = nil,
        operation: @escaping () async throws -> Output
    ) -> Self {
        self.init { promise in
            Task.detached(priority: priority) {
                do {
                    let value = try await operation()
                    promise(.success(value))
                } catch {
                    promise(.failure(error))
                }
            }
        }
    }
}
