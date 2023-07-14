//
//  ObservableStore2.swift
//
//
//  Created by Gordon Brander on 7/14/23.
//

import Foundation
import Observation
import Combine

public protocol ModelProtocol2 {
    associatedtype Action
    associatedtype Environment

    mutating func update(
        action: Action,
        environment: Environment
    ) -> AnyPublisher<Action, Never>
}

@Observable public final class ObservableStore2<Model: ModelProtocol2> {
    @ObservationIgnored
    private(set) var cancellables: [UUID: AnyCancellable] = [:]
    
    @ObservationIgnored
    public var environment: Model.Environment
    
    public var state: Model
    
    public init(
        state: Model,
        environment: Model.Environment
    ) {
        self.state = state
        self.environment = environment
    }
    
    public func subscribe(to fx: AnyPublisher<Model.Action, Never>) {
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

    public func send(_ action: Model.Action) {
        // Mutate state and generate effects
        let fx = self.state.update(
            action: action,
            environment: self.environment
        )
        // Run effects
        self.subscribe(to: fx)
    }
}
