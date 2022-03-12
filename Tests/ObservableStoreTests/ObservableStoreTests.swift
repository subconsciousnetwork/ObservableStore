import XCTest
@testable import ObservableStore

final class ObservableStoreTests: XCTestCase {
    /// App state
    struct AppState: Equatable {
        enum Action {
            case increment
            case setCount(Int)
            case setEditor(Editor)
        }

        /// Services like API methods go here
        struct Environment {
        }

        /// State update function
        static func update(
            state: Self,
            environment: Environment,
            action: Action
        ) -> Update<Self, Action> {
            switch action {
            case .increment:
                var model = state
                model.count = model.count + 1
                return Update(state: model)
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

    func testStateAdvance() throws {
        let store = Store(
            update: AppState.update,
            state: AppState(),
            environment: AppState.Environment()
        )

        store.send(action: .increment)
        XCTAssertEqual(store.state.count, 1, "state is advanced")
    }

    func testBinding() throws {
        let store = Store(
            update: AppState.update,
            state: AppState(),
            environment: AppState.Environment()
        )
        let binding = store.binding(
            get: \.count,
            tag: AppState.Action.setCount
        )
        binding.wrappedValue = 2
        XCTAssertEqual(store.state.count, 2, "binding sends action")
    }

    func testDeepBinding() throws {
        let store = Store(
            update: AppState.update,
            state: AppState(),
            environment: AppState.Environment()
        )
        let binding = store.binding(
            get: \.editor,
            tag: AppState.Action.setEditor
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
}
