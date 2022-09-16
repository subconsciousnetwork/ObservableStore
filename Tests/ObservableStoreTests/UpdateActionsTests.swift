//
//  UpdateActionsTests.swift
//
//  Created by Gordon Brander on 9/14/22.
//

import XCTest
import ObservableStore
import Combine

class UpdateActionsTests: XCTestCase {
    enum TestAction {
        case increment
        case setText(String)
        case delayedText(text: String, delay: Double)
        case delayedIncrement(delay: Double)
        case combo
    }

    struct TestModel: ModelProtocol {
        typealias Action = TestAction
        typealias Environment = Void

        var count = 0
        var text = ""

        static func update(
            state: TestModel,
            action: TestAction,
            environment: Void
        ) -> Update<TestModel> {
            switch action {
            case .increment:
                var model = state
                model.count = model.count + 1
                return Update(state: model)
                    .animation(.default)
            case .setText(let text):
                var model = state
                model.text = text
                return Update(state: model)
            case let .delayedText(text, delay):
                let fx: Fx<Action> = Just(
                    Action.setText(text)
                )
                .delay(for: .seconds(delay), scheduler: DispatchQueue.main)
                .eraseToAnyPublisher()
                return Update(state: state, fx: fx)
            case let .delayedIncrement(delay):
                let fx: Fx<Action> = Just(
                    Action.increment
                )
                .delay(for: .seconds(delay), scheduler: DispatchQueue.main)
                .eraseToAnyPublisher()
                return Update(state: state, fx: fx)
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
            environment: ()
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
            environment: ()
        )
        XCTAssertNotNil(next.transaction, "Last transaction wins")
    }
}
