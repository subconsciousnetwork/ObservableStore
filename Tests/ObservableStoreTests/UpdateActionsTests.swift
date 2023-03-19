//
//  UpdateActionsTests.swift
//
//  Created by Gordon Brander on 9/14/22.
//

import XCTest
import ObservableStore
import Combine
import os

@MainActor
class UpdateActionsTests: XCTestCase {
    enum TestAction {
        case message(String)
        case increment
        case setText(String)
        case delayedText(text: String, delay: Double)
        case delayedIncrement(delay: Double)
        case combo
    }

    struct TestEnvironment {
        let logger = Logger()

        func delay<Action>(
            succeed: Action,
            fail: Action,
            for duration: Duration
        ) async -> Action {
            do {
                try await Task.sleep(for: duration)
                return succeed
            } catch {
                return fail
            }
        }
    }

    struct TestModel: ModelProtocol {
        typealias Action = TestAction
        typealias Environment = TestEnvironment

        var count = 0
        var text = ""

        static func update(
            state: TestModel,
            action: TestAction,
            environment: Environment
        ) -> Update<TestModel> {
            switch action {
            case .message(let message):
                environment.logger.log("\(message)")
                return Update(state: state)
            case .increment:
                var model = state
                model.count = model.count + 1
                return Update(state: model, animation: .default)
            case .setText(let text):
                var model = state
                model.text = text
                return Update(state: model)
            case let .delayedText(text, delay):
                let fx = Effect {
                    await environment.delay(
                        succeed: Action.setText(text),
                        fail: Action.message(".delayedText failed"),
                        for: .seconds(delay)
                    )
                }
                return Update(state: state, effect: fx)
            case let .delayedIncrement(delay):
                let fx = Effect {
                    await environment.delay(
                        succeed: Action.increment,
                        fail: Action.message(".delayedIncrement failed"),
                        for: .seconds(delay)
                    )
                }
                return Update(state: state, effect: fx)
            case .combo:
                return update(
                    state: state,
                    actions: [
                        .increment,
                        .increment,
                        .delayedIncrement(delay: 0.02),
                        .delayedText(text: "Test", delay: 0.01),
                        .increment
                    ],
                    environment: environment
                )
            }
        }
    }

    func testUpdateActions() throws {
        let store = Store(
            state: TestModel(),
            environment: TestEnvironment()
        )
        store.send(.combo)
        let expectation = XCTestExpectation(
            description: "Autofocus sets editor focus"
        )
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            XCTAssertEqual(
                store.state.count,
                4,
                "All increments run. Fx merged."
            )
            XCTAssertEqual(
                store.state.text,
                "Test",
                "Text set"
            )
            expectation.fulfill()
        }
        wait(for: [expectation], timeout: 0.2)
    }

    func testUpdateActionsTransaction() throws {
        let next = TestModel.update(
            state: TestModel(),
            actions: [
                .increment,
                .increment,
                .setText("Foo"),
                .increment,
            ],
            environment: TestEnvironment()
        )
        XCTAssertNotNil(next.transaction, "Last transaction wins")
    }
}
