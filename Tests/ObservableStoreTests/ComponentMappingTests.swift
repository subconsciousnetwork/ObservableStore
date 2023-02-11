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
                return Cursor.update(
                    get: ParentChildCursor.get,
                    set: ParentChildCursor.set,
                    tag: ParentChildCursor.tag,
                    state: state,
                    action: action,
                    environment: ()
                )
            case let .keyedChild(action, key):
                return Cursor.update(
                    get: KeyedParentChildCursor.getter(key: key),
                    set: KeyedParentChildCursor.setter(key: key),
                    tag: KeyedParentChildCursor.tagging(key: key),
                    state: state,
                    action: action,
                    environment: ()
                )
            case .setText(let text):
                var next = Cursor.update(
                    get: ParentChildCursor.get,
                    set: ParentChildCursor.set,
                    tag: ParentChildCursor.tag,
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
        static func get(state: ParentModel) -> ChildModel {
            state.child
        }
        
        static func set(state: ParentModel, inner: ChildModel) -> ParentModel {
            var model = state
            model.child = inner
            return model
        }
        
        static func tag(_ action: ChildAction) -> ParentAction {
            switch action {
            case .setText(let string):
                return .setText(string)
            }
        }
    }
    
    struct KeyedParentChildCursor {
        static func getter(key: String) -> (ParentModel) -> ChildModel? {
            { state in
                state.keyedChildren[key]
            }
        }
        
        static func setter(
            key: String
        ) -> (ParentModel, ChildModel) -> ParentModel {
            { state, inner in
                var model = state
                model.keyedChildren[key] = inner
                return model
            }
        }
        
        static func tagging(key: String) -> (ChildAction) -> ParentAction {
            { action in
                .keyedChild(action: action, key: key)
            }
        }
    }
    
    func testForward() throws {
        let store = Store(
            state: ParentModel(),
            environment: ()
        )
        
        let send = Cursor.forward(
            send: store.send,
            tag: ParentChildCursor.tag
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
        let update = Cursor.update(
            get: ParentChildCursor.get,
            set: ParentChildCursor.set,
            tag: ParentChildCursor.tag,
            state: ParentModel(),
            action: ChildAction.setText("Foo"),
            environment: ()
        )
        XCTAssertNotNil(
            update.transaction,
            "Transaction is preserved by cursor"
        )
    }
    
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
        let key = "a"
        let update: Update<ParentModel> = Cursor.update(
            get: KeyedParentChildCursor.getter(key: key),
            set: KeyedParentChildCursor.setter(key: key),
            tag: KeyedParentChildCursor.tagging(key: key),
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
