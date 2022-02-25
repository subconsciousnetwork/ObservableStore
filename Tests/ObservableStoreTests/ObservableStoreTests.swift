import XCTest
@testable import ObservableStore

final class ObservableStoreTests: XCTestCase {
    enum AppAction {
        case increment
        case setCount(Int)
    }

    /// Services like API methods go here
    struct AppEnvironment {
    }

    /// App state
    struct AppState: Equatable {
        var count = 0

        /// State update function
        static func update(
            state: AppState,
            environment: AppEnvironment,
            action: AppAction
        ) -> Update<AppState, AppAction> {
            switch action {
            case .increment:
                var model = state
                model.count = model.count + 1
                return Update(state: model)
            case .setCount(let count):
                var model = state
                model.count = count
                return Update(state: model)
            }
        }
    }

    func testStateAdvance() throws {
        let store = Store(
            update: AppState.update,
            state: AppState(),
            environment: AppEnvironment()
        )

        store.send(action: .increment)
        XCTAssertEqual(store.state.count, 1, "state is advanced")
    }

    func testBinding() throws {
        let store = Store(
            update: AppState.update,
            state: AppState(),
            environment: AppEnvironment()
        )
        let binding = store.binding(
            get: \.count,
            tag: AppAction.setCount
        )
        binding.wrappedValue = 2
        XCTAssertEqual(store.state.count, 2, "binding sends action")
    }
}
