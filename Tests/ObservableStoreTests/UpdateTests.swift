//
//  UpdateTests.swift
//  
//
//  Created by Gordon Brander on 4/10/23.
//

import XCTest
import SwiftUI
import Combine
@testable import ObservableStore

final class UpdateTests: XCTestCase {
    enum Action: Hashable {
        case a
        case b
        case c
    }

    struct Model: ModelProtocol {
        typealias Environment = Void
        var value: String = ""

        static func update(
            state: Self,
            action: Action,
            environment: Environment
        ) -> Update<Self> {
            switch action {
            case .a:
                var model = state
                model.value = "a"
                return Update(state: model)
            case .b:
                var model = state
                model.value = "b"
                return Update(state: model)
            case .c:
                var model = state
                model.value = "c"
                return Update(state: model)
            }
        }
    }

    /// This test does nothing except try all initializers so Swift
    /// will complain if any of our initializers are ambiguous.
    func testInitializers() {
        let _ = Update(state: Model())

        let _ = Update(state: Model(), animation: .default)

        let _ = Update(state: Model(), fx: Just(.c).eraseToAnyPublisher())

        let _ = Update(
            state: Model(),
            fx: Just(.c).eraseToAnyPublisher(),
            animation: .default
        )

        let future = Future {
            do {
                try await Task.sleep(nanoseconds: 1)
            } catch {
                return Action.a
            }
            return Action.b
        }

        let _ = Update(state: Model(), future: future)

        let _ = Update(state: Model(), future: future, animation: .default)

        XCTAssertTrue(true)
    }
}
