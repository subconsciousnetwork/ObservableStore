import XCTest
import Combine
import SwiftUI
@testable import ObservableStore

final class ObservableStoreTests: XCTestCase {
    /// App state
    struct AppModel: ModelProtocol {
        enum Action: Hashable {
            case increment
            case delayIncrement(Double)
            case setCount(Int)
            case setEditor(Editor)
            case createEmptyFxThatCompletesImmediately
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
            case .createEmptyFxThatCompletesImmediately:
                let fx: Fx<Action> = Empty(completeImmediately: true)
                    .eraseToAnyPublisher()
                return Update(state: state, fx: fx)
            }
        }
        
        struct Editor: Hashable {
            struct Input: Hashable {
                var text: String = ""
                var isFocused: Bool = true
            }
            var input = Input()
        }
        
        var count = 0
        var editor = Editor()
    }
    
    struct SimpleCountView: View {
        @Binding var count: Int
        
        var body: some View {
            Text("Count: \(count)")
        }
    }
    
    var cancellables = Set<AnyCancellable>()
    
    override func setUp() {
        // Empty cancellables
        self.cancellables = Set()
    }
    
    func testStateAdvance() throws {
        let store = Store(
            state: AppModel(),
            environment: AppModel.Environment()
        )
        
        store.send(.increment)
        
        DispatchQueue.main.async {
            XCTAssertEqual(store.state.count, 1, "state is advanced")
        }
    }

    /// Tests that the immediately-completing empty Fx used as the default for
    /// updates get removed from the cancellables array.
    ///
    /// Failure to remove immediately-completing fx would cause a memory leak.
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
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            XCTAssertEqual(
                store.cancellables.count,
                0,
                "cancellables removed when publisher completes"
            )
            expectation.fulfill()
        }
        wait(for: [expectation], timeout: 0.2)
    }

    /// Tests that immediately-completing Fx get removed from the cancellables.
    ///
    /// array. Failure to remove immediately-completing fx would cause a
    /// memory leak.
    ///
    /// When you don't specify fx for an update, we default to
    /// an immediately-completing `Empty` publisher, so this test is
    /// technically the same as the one above. The difference is that it
    /// does not rely on an implementation detail of `Update` but instead
    /// tests this behavior directly, in case the implementation were to
    /// change somehow.
    func testEmptyFxThatCompleteImmiedatelyRemovedOnComplete() {
        let store = Store(
            state: AppModel(),
            environment: AppModel.Environment()
        )
        store.send(.createEmptyFxThatCompletesImmediately)
        store.send(.createEmptyFxThatCompletesImmediately)
        store.send(.createEmptyFxThatCompletesImmediately)
        let expectation = XCTestExpectation(
            description: "cancellable removed when publisher completes"
        )
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            XCTAssertEqual(
                store.cancellables.count,
                0,
                "cancellables removed when publisher completes"
            )
            expectation.fulfill()
        }
        wait(for: [expectation], timeout: 0.2)
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

    func testPublishedPropertyFires() throws {
        let store = Store(
            state: AppModel(),
            environment: AppModel.Environment()
        )
        
        var count = 0
        store.$state
            .sink(receiveValue: { _ in
                count = count + 1
            })
            .store(in: &cancellables)
        
        store.send(.increment)
        store.send(.increment)
        store.send(.increment)
        
        let expectation = XCTestExpectation(
            description: "publisher fires when state changes"
        )
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            XCTAssertEqual(
                count,
                4,
                "publisher fires when state changes"
            )
            expectation.fulfill()
        }
        wait(for: [expectation], timeout: 1)
    }
    
    func testStateOnlySetWhenNotEqual() {
        let store = Store(
            state: AppModel(),
            environment: AppModel.Environment()
        )
        
        var count = 0
        store.$state
            .sink(receiveValue: { _ in
                count = count + 1
            })
            .store(in: &cancellables)
        
        store.send(.setCount(10))
        store.send(.setCount(10))
        store.send(.setCount(10))
        store.send(.setCount(10))
        
        let expectation = XCTestExpectation(
            description: "publisher does not fire when state does not change"
        )
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            // Publisher should fire twice: once for initial state,
            // once for state change.
            XCTAssertEqual(
                count,
                2,
                "publisher does not fire when state does not change"
            )
            expectation.fulfill()
        }
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
    
    func testCreateInit() throws {
        let store = Store(
            create: { environment in
                let model = AppModel(count: 1)
                let fx = Just(AppModel.Action.increment).eraseToAnyPublisher()
                return Update(state: model, fx: fx)
            },
            environment: AppModel.Environment()
        )
        let expectation = XCTestExpectation(
            description: "Sent fx"
        )
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            // Publisher should fire twice: once for initial state,
            // once for state change.
            XCTAssertEqual(
                store.state.count,
                2,
                "Sent fx"
            )
            expectation.fulfill()
        }
        wait(for: [expectation], timeout: 1)
    }

    func testActionsPublisher() throws {
        let store = Store(
            state: AppModel(),
            environment: AppModel.Environment()
        )

        var actions: [AppModel.Action] = []
        store.actions
            .sink(receiveValue: { action in
                actions.append(action)
            })
            .store(in: &cancellables)
        
        store.send(.setCount(1))
        store.send(.setCount(2))
        store.send(.setCount(3))
        
        let expectation = XCTestExpectation(
            description: "actions publisher fires for every action"
        )

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            // Publisher should fire twice: once for initial state,
            // once for state change.
            XCTAssertEqual(
                actions,
                [
                    .setCount(1),
                    .setCount(2),
                    .setCount(3)
                ],
                "publisher does not fire when state does not change"
            )
            expectation.fulfill()
        }
        wait(for: [expectation], timeout: 1)
    }
}
