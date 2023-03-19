//
//  BindingTests.swift
//  
//
//  Created by Gordon Brander on 9/21/22.
//

import XCTest
import SwiftUI
@testable import ObservableStore

@MainActor
final class BindingTests: XCTestCase {
    enum Action: Hashable {
        case setText(String)
    }
    
    struct Model: ModelProtocol {
        var text = ""
        var edits: Int = 0
        
        static func update(
            state: Model,
            action: Action,
            environment: Void
        ) -> Update<Model> {
            switch action {
            case .setText(let text):
                var model = state
                model.text = text
                model.edits = model.edits + 1
                return Update(state: model)
            }
        }
    }
    
    struct SimpleView: View {
        @Binding var text: String
        
        var body: some View {
            Text(text)
        }
    }
    
    /// Test creating binding for an address
    func testBinding() throws {
        let store = Store(
            state: Model(),
            environment: ()
        )
        
        let binding = Binding(
            get: { store.state.text },
            send: store.send,
            tag: Action.setText
        )
        
        let view = SimpleView(text: binding)
        
        view.text = "Foo"
        view.text = "Bar"
        
        XCTAssertEqual(
            store.state.text,
            "Bar"
        )
        XCTAssertEqual(
            store.state.edits,
            2
        )
    }
    
    /// Test creating binding for an address
    func testBindingMethod() throws {
        let store = Store(
            state: Model(),
            environment: ()
        )

        let binding = store.binding(
            get: \.text,
            tag: Action.setText
        )

        let view = SimpleView(text: binding)

        view.text = "Foo"
        view.text = "Bar"

        XCTAssertEqual(
            store.state.text,
            "Bar"
        )
        XCTAssertEqual(
            store.state.edits,
            2
        )
    }
}
