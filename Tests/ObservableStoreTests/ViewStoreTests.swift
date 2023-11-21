//
//  ViewStoreTests.swift
//
//
//  Created by Gordon Brander on 9/21/22.
//

import XCTest
import SwiftUI
@testable import ObservableStore

final class ViewStoreTests: XCTestCase {
    enum ParentAction: Hashable {
        case child(ChildAction)
        case setText(String)
    }
    
    struct ParentModel: ModelProtocol {
        var child = ChildModel(text: "")
        var edits: Int = 0
        
        static func update(
            state: ParentModel,
            action: ParentAction,
            environment: Void
        ) -> Update<ParentModel> {
            switch action {
            case .child(let action):
                return update(
                    get: ParentChildCursor.default.get,
                    set: ParentChildCursor.default.set,
                    tag: ParentChildCursor.default.tag,
                    state: state,
                    action: action,
                    environment: ()
                )
            case .setText(let text):
                var next = update(
                    get: ParentChildCursor.default.get,
                    set: ParentChildCursor.default.set,
                    tag: ParentChildCursor.default.tag,
                    state: state,
                    action: .setText(text),
                    environment: ()
                )
                next.state.edits = next.state.edits + 1
                return next
            }
        }
    }
    
    enum ChildAction: Hashable {
        case setText(String)
    }
    
    struct ChildModel: ModelProtocol {
        var text: String
        
        static func update(
            state: ChildModel,
            action: ChildAction,
            environment: Void
        ) -> Update<ChildModel> {
            switch action {
            case .setText(let string):
                var model = state
                model.text = string
                return Update(state: model)
                    .animation(.default)
            }
        }
    }
    
    struct ParentChildCursor {
        static let `default` = ParentChildCursor()
        
        func get(_ state: ParentModel) -> ChildModel {
            state.child
        }
        
        func set(_ state: ParentModel, _ inner: ChildModel) -> ParentModel {
            var model = state
            model.child = inner
            return model
        }
        
        func tag(_ action: ChildAction) -> ParentAction {
            switch action {
            case .setText(let string):
                return .setText(string)
            }
        }
    }
    
    /// Test creating binding for an address
    func testViewStore() async throws {
        let store = Store(
            state: ParentModel(),
            environment: ()
        )
        
        let viewStore = ViewStore(
            store: store,
            get: ParentChildCursor.default.get,
            tag: ParentChildCursor.default.tag
        )
        
        viewStore.send(.setText("Foo"))
        
        try await Task.sleep(for: .seconds(0.1))

        XCTAssertEqual(
            store.state.child.text,
            "Foo"
        )
        XCTAssertEqual(
            store.state.edits,
            1
        )
    }
    
    /// Test creating binding for an address
    func testViewStoreMethod() async throws {
        let store = Store(
            state: ParentModel(),
            environment: ()
        )
        
        let viewStore = store.viewStore(
            get: \.child,
            tag: ParentChildCursor.default.tag
        )
        
        viewStore.send(.setText("Foo"))
        
        try await Task.sleep(for: .seconds(0.1))
        
        XCTAssertEqual(
            store.state.child.text,
            "Foo"
        )
        XCTAssertEqual(
            store.state.edits,
            1
        )
    }
}
