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
                return ParentChildCursor.update(
                    state: state,
                    action: action,
                    environment: ()
                )
            case let .keyedChild(action, key):
                return KeyedParentChildCursor.update(
                    state: state,
                    action: action,
                    environment: (),
                    key: key
                )
            case .setText(let text):
                var next = ParentChildCursor.update(
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
    
    struct ParentChildCursor: CursorProtocol {
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
    
    struct KeyedParentChildCursor: KeyedCursorProtocol {
        static func get(state: ParentModel, key: String) -> ChildModel? {
            state.keyedChildren[key]
        }
        
        static func set(
            state: ParentModel,
            inner: ChildModel,
            key: String
        ) -> ParentModel {
            var model = state
            model.keyedChildren[key] = inner
            return model
        }
        
        static func tag(action: ChildAction, key: String) -> ParentAction {
            .keyedChild(action: action, key: key)
        }
    }
    
    func testForward() throws {
        let store = Store(
            state: ParentModel(),
            environment: ()
        )
        
        let send = Address.forward(
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
        let update = ParentChildCursor.update(
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
        let update: Update<ParentModel> = KeyedParentChildCursor.update(
            state: ParentModel(
                keyedChildren: [
                    "a": ChildModel(text: "A"),
                    "b": ChildModel(text: "B"),
                    "c": ChildModel(text: "C"),
                ]
            ),
            action: .setText("Foo"),
            environment: (),
            key: "a"
        )
        XCTAssertNotNil(
            update.transaction,
            "Transaction is preserved by cursor"
        )
    }
}
