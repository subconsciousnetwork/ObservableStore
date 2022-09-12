import XCTest
import Combine
import SwiftUI
@testable import ObservableStore

final class ObservableStoreTests: XCTestCase {
    /// App state
    struct AppModel: ModelProtocol {
        enum Action {
            case increment
            case delayIncrement(Double)
            case setCount(Int)
            case setEditor(Editor)
        }

        /// Services like API methods go here
        struct Environment {
            func delayIncrement(
                seconds: Double
            ) -> AnyPublisher<Action, Never> {
                Just(Action.increment)
                    .delay(
                        for: .seconds(seconds),
                        scheduler: DispatchQueue.main
                    )
                    .eraseToAnyPublisher()
            }
        }

        /// State update function
        static func update(
            state: AppModel,
            action: Action,
            environment: Environment
        ) -> Update<AppModel> {
            switch action {
            case .increment:
                var model = state
                model.count = model.count + 1
                return Update(state: model)
            case .delayIncrement(let seconds):
                return Update(
                    state: state,
                    fx: environment.delayIncrement(seconds: seconds)
                )
            case .setCount(let count):
                var model = state
                model.count = count
                return Update(state: model)
            case .setEditor(let editor):
                var model = state
                model.editor = editor
                return Update(state: model)
            }
        }

        struct Editor: Equatable {
            struct Input: Equatable {
                var text: String = ""
                var isFocused: Bool = true
            }
            var input = Input()
        }

        var count = 0
        var editor = Editor()
    }

    var cancellables = Set<AnyCancellable>()

    override func setUp() {
        // Empty cancellables
        self.cancellables = Set()
    }

    func testPublishedPropertyFires() throws {
        let store = Store(
            state: AppModel(),
            environment: AppModel.Environment()
        )

        var count = 0
        store.objectWillChange
            .sink(receiveValue: { _ in
                count = count + 1
            })
            .store(in: &cancellables)

        store.send(.increment)
        store.send(.increment)
        store.send(.increment)

        let expectation = XCTestExpectation(
            description: "cancellable removed when publisher completes"
        )
        DispatchQueue.main.async {
            XCTAssertEqual(
                count,
                3,
                "publisher fires when state changes"
            )
            expectation.fulfill()
        }
        wait(for: [expectation], timeout: 0.1)
    }

    func testPublishedPropertyNoFireForSameState() throws {
        let store = Store(
            state: AppModel(),
            environment: AppModel.Environment()
        )

        var count = 0
        store.objectWillChange
            .sink(receiveValue: { _ in
                count = count + 1
            })
            .store(in: &cancellables)

        store.send(.setCount(1))
        store.send(.setCount(1))
        store.send(.setCount(1))

        let expectation = XCTestExpectation(
            description: "cancellable removed when publisher completes"
        )
        DispatchQueue.main.async {
            XCTAssertEqual(
                count,
                1,
                "publisher does not fire when state does not change"
            )
            expectation.fulfill()
        }
        wait(for: [expectation], timeout: 0.1)
    }

    func testStateAdvance() throws {
        let store = Store(
            state: AppModel(),
            environment: AppModel.Environment()
        )

        store.send(.increment)
        XCTAssertEqual(store.state.count, 1, "state is advanced")
    }

    func testBinding() throws {
        let store = Store(
            state: AppModel(),
            environment: AppModel.Environment()
        )
        let binding = Binding(
            store: store,
            get: \.count,
            tag: AppModel.Action.setCount
        )
        binding.wrappedValue = 2
        XCTAssertEqual(store.state.count, 2, "binding sends action")
    }

    func testDeepBinding() throws {
        let store = Store(
            state: AppModel(),
            environment: AppModel.Environment()
        )
        let binding = Binding(
            store: store,
            get: \.editor,
            tag: AppModel.Action.setEditor
        )
        .input
        .text
        binding.wrappedValue = "floop"
        XCTAssertEqual(
            store.state.editor.input.text,
            "floop",
            "specialized binding sets deep property"
        )
    }

    func testEmptyFxRemovedOnComplete() {
        let store = Store(
            state: AppModel(),
            environment: AppModel.Environment()
        )
        store.send(.increment)
        store.send(.increment)
        store.send(.increment)
        let expectation = XCTestExpectation(
            description: "cancellable removed when publisher completes"
        )
        DispatchQueue.main.async {
            XCTAssertEqual(
                store.cancellables.count,
                0,
                "cancellables removed when publisher completes"
            )
            expectation.fulfill()
        }
        wait(for: [expectation], timeout: 0.1)
    }

    func testAsyncFxRemovedOnComplete() {
        let store = Store(
            state: AppModel(),
            environment: AppModel.Environment()
        )
        store.send(.delayIncrement(0.1))
        store.send(.delayIncrement(0.2))
        let expectation = XCTestExpectation(
            description: "cancellable removed when publisher completes"
        )
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            XCTAssertEqual(
                store.cancellables.count,
                0,
                "cancellables removed when publisher completes"
            )
            expectation.fulfill()
        }
        wait(for: [expectation], timeout: 0.5)
    }

    func testStateOnlySetWhenNotEqual() {
        let store = Store(
            state: AppModel(),
            environment: AppModel.Environment()
        )

        let expectation = XCTestExpectation(
            description: "check that equal states are not set"
        )

        var stateFires = 0
        store.$state
            .timeout(.seconds(0.1), scheduler: DispatchQueue.main)
            .sink(
                receiveCompletion: { value in
                    XCTAssertEqual(
                        stateFires,
                        2,
                        "Equal states are not set. $state only fires for new states."
                    )
                    expectation.fulfill()
                },
                receiveValue: { value in
                    stateFires = stateFires + 1
                }
            )
            .store(in: &self.cancellables)
        store.send(.setCount(10))
        store.send(.setCount(10))
        store.send(.setCount(10))
        store.send(.setCount(10))

        wait(for: [expectation], timeout: 0.2)
    }

    /// Definition for app to test updates
    struct TestUpdateMergeFxState: ModelProtocol {
        enum Action {
            case setTitleAndSubtitleViaMergeFx(
                title: String,
                subtitle: String
            )
            case setTitle(String)
            case setSubtitle(String)
        }

        struct Environment {}

        /// Update function for Fx tests (below)
        static func update(
            state: Self,
            action: Action,
            environment: Environment
        ) -> Update<Self> {
            switch action {
            case .setTitle(let title):
                var model = state
                model.title = title
                return Update(state: model)
            case .setSubtitle(let subtitle):
                var model = state
                model.subtitle = subtitle
                return Update(state: model)
            case .setTitleAndSubtitleViaMergeFx(let title, let subtitle):
                let a = Just(Action.setTitle(title))
                    .eraseToAnyPublisher()
                let b = Just(Action.setSubtitle(subtitle))
                    .eraseToAnyPublisher()
                return Update(
                    state: state,
                    fx: a
                )
                .mergeFx(b)
            }
        }

        var title: String = ""
        var subtitle: String = ""
    }
    
    func testUpdateMergeFx() {
        let store = Store(
            state: TestUpdateMergeFxState(),
            environment: TestUpdateMergeFxState.Environment()
        )
        store.send(
            .setTitleAndSubtitleViaMergeFx(
                title: "title",
                subtitle: "subtitle"
            )
        )

        let expectation = XCTestExpectation(
            description: "check that update fx are merged"
        )

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            XCTAssertEqual(
                store.state.title,
                "title",
                "title set"
            )
            XCTAssertEqual(
                store.state.subtitle,
                "subtitle",
                "subtitle set"
            )
            expectation.fulfill()
        }
        wait(for: [expectation], timeout: 0.2)
    }
}
