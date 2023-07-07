//
//  ViewStoreTests.swift
//  
//
//  Created by Gordon Brander on 9/12/22.
//

import XCTest
import Combine
import SwiftUI
@testable import ObservableStore

class ComponentMappingTests: XCTestCase {
    enum ParentAction: Hashable {
        case child(ChildAction)
        case keyedChild(action: ChildAction, key: String)
        case setText(String)
    }
    
    struct ParentModel: ModelProtocol {
        var child = ChildModel(text: "")
        var keyedChildren: [String: ChildModel] = [:]
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
            case let .keyedChild(action, key):
                let cursor = KeyedParentChildCursor(key: key)
                return update(
                    get: cursor.get,
                    set: cursor.set,
                    tag: cursor.tag,
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
        
        func get(_ state: ParentModel) -> ChildModel? {
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
    
    struct KeyedParentChildCursor {
        let key: String

        func get(_ state: ParentModel) -> ChildModel? {
            state.keyedChildren[key]
        }
        
        func set(
            _ state: ParentModel,
            _ inner: ChildModel
        ) -> ParentModel {
            var model = state
            model.keyedChildren[key] = inner
            return model
        }
        
        func tag(_ action: ChildAction) -> ParentAction {
            .keyedChild(action: action, key: key)
        }
    }
    
    @MainActor
    func testForward() throws {
        let store = Store(
            state: ParentModel(),
            environment: ()
        )
        
        let send = Address.forward(
            send: store.send,
            tag: ParentChildCursor.default.tag
        )
        
        send(.setText("Foo"))
        send(.setText("Bar"))
        
        XCTAssertEqual(
            store.state.child.text,
            "Bar"
        )
        XCTAssertEqual(
            store.state.edits,
            2
        )
    }
    
    @MainActor
    func testKeyedCursorUpdate() throws {
        let store = Store(
            state: ParentModel(
                keyedChildren: [
                    "a": ChildModel(text: "A"),
                    "b": ChildModel(text: "B"),
                    "c": ChildModel(text: "C"),
                ]
            ),
            environment: ()
        )
        store.send(.keyedChild(action: .setText("BBB"), key: "a"))
        store.send(.keyedChild(action: .setText("AAA"), key: "a"))
        XCTAssertEqual(
            store.state.keyedChildren["a"]?.text,
            "AAA",
            "KeyedCursor updates model at key"
        )
    }
    
    func testCursorUpdateTransaction() throws {
        let update = ParentModel.update(
            get: ParentChildCursor.default.get,
            set: ParentChildCursor.default.set,
            tag: ParentChildCursor.default.tag,
            state: ParentModel(),
            action: ChildAction.setText("Foo"),
            environment: ()
        )
        XCTAssertNotNil(
            update.transaction,
            "Transaction is preserved by cursor"
        )
    }
    
    @MainActor
    func testCursorUpdate() throws {
        let store = Store(
            state: ParentModel(),
            environment: ()
        )
        store.send(.setText("Woo"))
        store.send(.setText("Woo"))
        XCTAssertEqual(
            store.state.child.text,
            "Woo",
            "Cursor updates child model"
        )
        XCTAssertEqual(
            store.state.edits,
            2
        )
    }
    
    @MainActor
    func testKeyedCursorUpdateMissing() throws {
        let store = Store(
            state: ParentModel(
                keyedChildren: [
                    "a": ChildModel(text: "A"),
                    "b": ChildModel(text: "B"),
                    "c": ChildModel(text: "C"),
                ]
            ),
            environment: ()
        )
        store.send(.keyedChild(action: .setText("ZZZ"), key: "z"))
        XCTAssertEqual(
            store.state.keyedChildren.count,
            3,
            "KeyedCursor update does nothing if key is missing"
        )
        XCTAssertNil(
            store.state.keyedChildren["z"],
            "KeyedCursor update does nothing if key is missing"
        )
    }
    
    func testKeyedCursorUpdateTransaction() throws {
        let cursor = KeyedParentChildCursor(key: "a")
        let update = ParentModel.update(
            get: cursor.get,
            set: cursor.set,
            tag: cursor.tag,
            state: ParentModel(
                keyedChildren: [
                    "a": ChildModel(text: "A"),
                    "b": ChildModel(text: "B"),
                    "c": ChildModel(text: "C"),
                ]
            ),
            action: .setText("Foo"),
            environment: ()
        )
        XCTAssertNotNil(
            update.transaction,
            "Transaction is preserved by cursor"
        )
    }
}
