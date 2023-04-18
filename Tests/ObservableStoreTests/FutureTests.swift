//
//  FutureTests.swift
//  
//
//  Created by Gordon Brander on 4/18/23.
//

import XCTest
import Combine
@testable import ObservableStore

final class FutureTests: XCTestCase {
    var cancellables: Set<AnyCancellable> = Set()
    
    override func setUp() {
        // Put setup code here. This method is called before the invocation
        // of each test method in the class.
        
        // Clear cancellables from last test.
        cancellables = Set()
    }
    
    enum TestServiceError: Error {
        case interruptedByIntergalacticHighwayProject
    }
    
    actor TestService {
        func calculateMeaningOfLife() -> Int {
            return 42
        }
        
        func failToCalculateMeaningOfLife() throws -> Int {
            throw TestServiceError.interruptedByIntergalacticHighwayProject
        }
    }
    
    func testFutureAsyncExtension() throws {
        let service = TestService()
        
        let expectation = XCTestExpectation(
            description: "Future completes successfully"
        )
        
        Future {
            await service.calculateMeaningOfLife()
        }
        .sink(
            receiveCompletion: { completion in
                switch completion {
                case .finished:
                    expectation.fulfill()
                }
            },
            receiveValue: { value in
                XCTAssertEqual(value, 42)
            }
        )
        .store(in: &cancellables)
        
        wait(for: [expectation], timeout: 0.1)
    }
    
    func testFutureDetachedAsyncExtension() throws {
        let service = TestService()
        
        let expectation = XCTestExpectation(
            description: "Future completes successfully"
        )
        
        Future.detached {
            await service.calculateMeaningOfLife()
        }
        .sink(
            receiveCompletion: { completion in
                switch completion {
                case .finished:
                    expectation.fulfill()
                }
            },
            receiveValue: { value in
                XCTAssertEqual(value, 42)
            }
        )
        .store(in: &cancellables)
        
        wait(for: [expectation], timeout: 0.1)
    }
    
    func testFutureThrowingAsyncExtension() throws {
        let service = TestService()
        
        let expectation = XCTestExpectation(
            description: "Future fails (intentional)"
        )
        
        Future {
            try await service.failToCalculateMeaningOfLife()
        }
        .sink(
            receiveCompletion: { completion in
                switch completion {
                case .finished:
                    XCTFail("Future finished with success result, but should have finished with failure result of type error")
                case .failure:
                    expectation.fulfill()
                }
            },
            receiveValue: { value in
                XCTFail("Future should fail, and receiveValue should not be called")
            }
        )
        .store(in: &cancellables)
        
        wait(for: [expectation], timeout: 0.1)
    }
    
    func testFutureDetachedThrowingAsyncExtension() throws {
        let service = TestService()

        let expectation = XCTestExpectation(
            description: "Future fails (intentional)"
        )

        Future.detached {
            try await service.failToCalculateMeaningOfLife()
        }
        .sink(
            receiveCompletion: { completion in
                switch completion {
                case .finished:
                    XCTFail("Future finished with success result, but should have finished with failure result of type error")
                case .failure:
                    expectation.fulfill()
                }
            },
            receiveValue: { value in
                XCTFail("Future should fail, and receiveValue should not be called")
            }
        )
        .store(in: &cancellables)

        wait(for: [expectation], timeout: 0.1)
    }
}
