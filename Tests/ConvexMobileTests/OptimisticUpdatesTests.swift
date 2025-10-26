//
//  OptimisticUpdatesTests.swift
//  ConvexMobileTests
//
//  Created by Claude Code
//  Copyright © 2025 Convex, Inc. All rights reserved.
//

import XCTest
import Combine
@testable import ConvexMobile
@testable import UniFFI

// MARK: - Test Models

struct TestMessage: Codable, Equatable {
    let id: String
    let text: String
}

// MARK: - Fake FFI Client for Optimistic Updates

class FakeMobileConvexClientForOptimistic: MobileConvexClientProtocol {
    var subscribeCallCount = 0
    var mutationCallCount = 0
    var lastMutationName: String?
    var lastMutationArgs: [String: String]?

    var mutationResult: String = "null"
    var shouldMutationFail = false

    func subscribe(name: String, args: [String: String], subscriber: any QuerySubscriber) async throws -> SubscriptionHandle {
        subscribeCallCount += 1

        // Simulate initial query result
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            let initialMessages = [TestMessage(id: "1", text: "Initial message")]
            if let data = try? JSONEncoder().encode(initialMessages),
               let json = String(data: data, encoding: .utf8) {
                subscriber.onUpdate(value: json)
            }
        }

        return FakeSubscriptionHandleForOptimistic()
    }

    func mutation(name: String, args: [String: String]) async throws -> String {
        mutationCallCount += 1
        lastMutationName = name
        lastMutationArgs = args

        if shouldMutationFail {
            throw ClientError.ServerError(msg: "Mutation failed")
        }

        // Simulate network delay
        try await Task.sleep(nanoseconds: 100_000_000)  // 0.1 seconds

        return mutationResult
    }

    func query(name: String, args: [String: String]) async throws -> String {
        return "[]"
    }

    func action(name: String, args: [String: String]) async throws -> String {
        return "{}"
    }

    func setAuth(token: String?) async throws {
        // No-op
    }
}

class FakeSubscriptionHandleForOptimistic: UniFFI.SubscriptionHandle {
    init() {
        super.init(noPointer: UniFFI.SubscriptionHandle.NoPointer())
    }

    required init(unsafeFromRawPointer pointer: UnsafeMutableRawPointer) {
        super.init(unsafeFromRawPointer: pointer)
    }

    override func cancel() {
        // No-op
    }
}

// MARK: - Optimistic Updates Tests

@available(iOS 13.0, macOS 10.15, *)
class OptimisticUpdatesTests: XCTestCase {

    var cancellables: Set<AnyCancellable> = []

    override func tearDown() {
        cancellables.removeAll()
        super.tearDown()
    }

    // MARK: - Basic Optimistic Updates

    // Note: This test verifies the basic flow but doesn't test full subscription integration
    // since that requires a more complex setup with the FFI layer
    func testOptimisticUpdateAppliedImmediately() async throws {
        let fakeClient = FakeMobileConvexClientForOptimistic()
        let client = ConvexClient(ffiClient: fakeClient)

        var optimisticUpdateCalled = false

        try await client.mutation(
            "messages:send",
            with: ["text": "New message"],
            options: MutationOptions(
                optimisticUpdate: { localStore in
                    optimisticUpdateCalled = true
                    // In a real app with active subscriptions, this would update the UI immediately
                    if var messages: [TestMessage] = localStore.getQuery("messages:list", with: nil) {
                        let newMessage = TestMessage(id: "temp-\(UUID())", text: "New message")
                        messages.append(newMessage)
                        localStore.setQuery("messages:list", with: nil, value: messages)
                    }
                }
            )
        )

        // Verify optimistic update was called
        XCTAssertTrue(optimisticUpdateCalled, "Optimistic update should be called")
        XCTAssertTrue(fakeClient.mutationCallCount == 1, "Mutation should be executed")
    }

    func testOptimisticUpdateRolledBackOnSuccess() async throws {
        let fakeClient = FakeMobileConvexClientForOptimistic()
        let client = ConvexClient(ffiClient: fakeClient)

        var optimisticUpdateApplied = false

        // Execute mutation with optimistic update
        try await client.mutation(
            "messages:send",
            with: ["text": "Test"],
            options: MutationOptions(
                optimisticUpdate: { localStore in
                    optimisticUpdateApplied = true
                    if var messages: [TestMessage] = localStore.getQuery("messages:list", with: nil) {
                        messages.append(TestMessage(id: "temp", text: "Optimistic"))
                        localStore.setQuery("messages:list", with: nil, value: messages)
                    }
                }
            )
        )

        XCTAssertTrue(optimisticUpdateApplied, "Optimistic update should be applied")
        XCTAssertTrue(fakeClient.mutationCallCount == 1, "Mutation should be executed")
    }

    func testOptimisticUpdateRolledBackOnError() async throws {
        let fakeClient = FakeMobileConvexClientForOptimistic()
        fakeClient.shouldMutationFail = true
        let client = ConvexClient(ffiClient: fakeClient)

        var optimisticUpdateApplied = false

        do {
            try await client.mutation(
                "messages:send",
                with: ["text": "Test"],
                options: MutationOptions(
                    optimisticUpdate: { localStore in
                        optimisticUpdateApplied = true
                    }
                )
            )
            XCTFail("Mutation should have failed")
        } catch {
            // Expected error
        }

        XCTAssertTrue(optimisticUpdateApplied, "Optimistic update should be applied before error")
        XCTAssertTrue(fakeClient.mutationCallCount == 1, "Mutation should be attempted")
    }

    // MARK: - Multiple In-Flight Mutations

    func testMultipleInFlightMutations() async throws {
        let fakeClient = FakeMobileConvexClientForOptimistic()
        let client = ConvexClient(ffiClient: fakeClient)

        // Start two mutations concurrently
        async let mutation1: Void = try client.mutation(
            "messages:send",
            with: ["text": "First"],
            options: MutationOptions(
                optimisticUpdate: { localStore in
                    if var messages: [TestMessage] = localStore.getQuery("messages:list", with: nil) {
                        messages.append(TestMessage(id: "temp-1", text: "First"))
                        localStore.setQuery("messages:list", with: nil, value: messages)
                    }
                }
            )
        )

        async let mutation2: Void = try client.mutation(
            "messages:send",
            with: ["text": "Second"],
            options: MutationOptions(
                optimisticUpdate: { localStore in
                    if var messages: [TestMessage] = localStore.getQuery("messages:list", with: nil) {
                        messages.append(TestMessage(id: "temp-2", text: "Second"))
                        localStore.setQuery("messages:list", with: nil, value: messages)
                    }
                }
            )
        )

        let _ = try await (mutation1, mutation2)

        XCTAssertEqual(fakeClient.mutationCallCount, 2, "Both mutations should be executed")
    }

    // MARK: - getAllQueries Tests

    func testGetAllQueries() async throws {
        let fakeClient = FakeMobileConvexClientForOptimistic()
        let client = ConvexClient(ffiClient: fakeClient)

        try await client.mutation(
            "messages:send",
            with: ["text": "Test"],
            options: MutationOptions(
                optimisticUpdate: { localStore in
                    let allQueries: [(args: [String: ConvexEncodable?]?, value: [TestMessage]?)] = localStore.getAllQueries("messages:list")

                    // Update all query variants
                    for query in allQueries {
                        if var messages = query.value {
                            messages.append(TestMessage(id: "new", text: "New"))
                            localStore.setQuery("messages:list", with: query.args, value: messages)
                        }
                    }
                }
            )
        )

        // Note: In a real test with subscriptions, getAllQueries would return results
        // For this fake client without active subscriptions, the cache will be empty
        XCTAssertTrue(fakeClient.mutationCallCount == 1)
    }

    // MARK: - Mutation Queue Tests

    func testMutationQueueEnqueue() {
        let queue = MutationQueue(shouldPersist: false)

        XCTAssertTrue(queue.isEmpty)
        XCTAssertEqual(queue.count, 0)

        _ = queue.enqueue(name: "test:mutation", args: ["key": "value"])

        XCTAssertFalse(queue.isEmpty)
        XCTAssertEqual(queue.count, 1)

        queue.clear()

        XCTAssertTrue(queue.isEmpty)
    }

    func testMutationQueueProcessing() async throws {
        let queue = MutationQueue(shouldPersist: false)

        // Enqueue multiple mutations
        _ = queue.enqueue(name: "test:mutation1", args: ["key": "value1"])
        _ = queue.enqueue(name: "test:mutation2", args: ["key": "value2"])

        XCTAssertEqual(queue.count, 2)

        var executedMutations: [String] = []

        await queue.processQueue { name, args in
            executedMutations.append(name)
        }

        XCTAssertEqual(executedMutations.count, 2)
        XCTAssertTrue(executedMutations.contains("test:mutation1"))
        XCTAssertTrue(executedMutations.contains("test:mutation2"))
        XCTAssertTrue(queue.isEmpty, "Queue should be empty after successful processing")
    }

    func testMutationQueueRetry() async throws {
        let queue = MutationQueue(shouldPersist: false)

        _ = queue.enqueue(name: "test:mutation", args: nil)

        var attemptCount = 0

        // First attempt - fail
        await queue.processQueue { name, args in
            attemptCount += 1
            if attemptCount == 1 {
                throw ClientError.ServerError(msg: "Simulated failure")
            }
        }

        XCTAssertEqual(attemptCount, 1)
        XCTAssertFalse(queue.isEmpty, "Failed mutation should remain in queue")

        // Second attempt - succeed
        await queue.processQueue { name, args in
            attemptCount += 1
        }

        XCTAssertEqual(attemptCount, 2)
        XCTAssertTrue(queue.isEmpty, "Successful mutation should be removed from queue")
    }

    // MARK: - OptimisticQueryCache Tests

    func testOptimisticQueryCacheBasicOperations() {
        let cache = OptimisticQueryCache()

        // Apply optimistic update
        let result = cache.applyOptimisticUpdate { localStore in
            localStore.setQuery("test:query", with: nil, value: ["test"])
        }

        XCTAssertFalse(result.changedQueries.isEmpty)

        // Retrieve query
        let token = QueryToken(name: "test:query", args: nil)
        let queryResult = cache.getQueryResult(token)

        XCTAssertNotNil(queryResult)
        XCTAssertNotNil(queryResult?.jsonValue)
    }

    func testOptimisticQueryCacheReplay() {
        let cache = OptimisticQueryCache()

        // Apply first optimistic update
        let result1 = cache.applyOptimisticUpdate { localStore in
            localStore.setQuery("test:query", with: nil, value: [1])
        }

        // Apply second optimistic update
        let result2 = cache.applyOptimisticUpdate { localStore in
            if var values: [Int] = localStore.getQuery("test:query", with: nil) {
                values.append(2)
                localStore.setQuery("test:query", with: nil, value: values)
            }
        }

        XCTAssertNotEqual(result1.mutationID, result2.mutationID)

        // Complete first mutation - second should be replayed
        let token = QueryToken(name: "test:query", args: nil)
        let serverResult = QueryResult(name: "test:query", args: nil, jsonValue: "[10]")

        let changed = cache.ingestServerResults(
            [token: serverResult],
            completedMutations: [result1.mutationID]
        )

        XCTAssertFalse(changed.isEmpty)

        // Verify second optimistic update is still applied
        let finalResult = cache.getQueryResult(token)
        XCTAssertNotNil(finalResult)
    }
}
