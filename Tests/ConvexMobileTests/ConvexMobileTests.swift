import XCTest

@testable import ConvexMobile
@testable import UniFFI

final class ConvexMobileTests: XCTestCase {
  func testSubscribeResult() async throws {
    let expectation = self.expectation(description: "subscribe")
    var error: ClientError?
    var result: Message?
    let client = ConvexMobile.ConvexClient(ffiClient: FakeMobileConvexClient())

    let cancellationHandle = try await client.subscribe(name: "foo").sink(
      receiveCompletion: { completion in
        switch completion {
        case .finished:
          break
        case .failure(let clientError):
          error = clientError
          break
        }
      },
      receiveValue: { (value: Message) in
        result = value
        expectation.fulfill()
      })

    await fulfillment(of: [expectation], timeout: 10)

    XCTAssertEqual(result!.id, "the_id")
    XCTAssertEqual(result!.val, 42)
    XCTAssertEqual(error, nil)
  }

  func testMissingSubscribeArgs() async throws {
    let expectation = self.expectation(description: "subscribe")
    let fakeFfiClient = FakeMobileConvexClient()
    let client = ConvexMobile.ConvexClient(ffiClient: fakeFfiClient)

    let cancellationHandle = try await client.subscribe(name: "foo").sink(
      receiveCompletion: { completion in
        switch completion {
        case .finished:
          break
        case .failure(let clientError):
          break
        }
      },
      receiveValue: { (value: Message) in
        expectation.fulfill()
      })

    await fulfillment(of: [expectation], timeout: 10)

    XCTAssertEqual(fakeFfiClient.subscriptionArgs, [:])
  }

  func testPopulatedSubscribeArgs() async throws {
    let expectation = self.expectation(description: "subscribe")
    let fakeFfiClient = FakeMobileConvexClient()
    let client = ConvexMobile.ConvexClient(ffiClient: fakeFfiClient)

    let cancellationHandle = try await client.subscribe(
      name: "foo",
      args: [
        "aString": "bar", "aDouble": 42.0, "anInt": 42, "aNil": nil,
        "aDict": ["sub1": 1.0, "nested": ["ohmy": true]],
      ]
    ).sink(
      receiveCompletion: { completion in
        switch completion {
        case .finished:
          break
        case .failure(let clientError):
          break
        }
      },
      receiveValue: { (value: Message) in
        expectation.fulfill()
      })

    await fulfillment(of: [expectation], timeout: 10)

    XCTAssertEqual(fakeFfiClient.subscriptionArgs["aString"], "\"bar\"")
    XCTAssertEqual(fakeFfiClient.subscriptionArgs["aDouble"], "42")
    XCTAssertEqual(fakeFfiClient.subscriptionArgs["anInt"], "{\"$integer\":\"KgAAAAAAAAA=\"}")
    XCTAssertEqual(fakeFfiClient.subscriptionArgs["aNil"], "null")
    XCTAssertEqual(
      fakeFfiClient.subscriptionArgs["aDict"], "{\"sub1\":1,\"nested\":{\"ohmy\":true}}")

  }

  func testSubscribeCancellation() async throws {
    let expectation = self.expectation(description: "subscribe")
    var error: ClientError?
    let ffiClient = FakeMobileConvexClient()
    let client = ConvexMobile.ConvexClient(ffiClient: ffiClient)

    let cancellationHandle = try await client.subscribe(name: "foo").sink(
      receiveCompletion: { completion in
        switch completion {
        case .finished:
          break
        case .failure(let clientError):
          error = clientError
          break
        }
      },
      receiveValue: { (value: Message) in
        expectation.fulfill()
      })

    await fulfillment(of: [expectation], timeout: 10)
    cancellationHandle.cancel()

    XCTAssertEqual(ffiClient.cancellationCount, 1)
    XCTAssertEqual(error, nil)
  }

  func testMutationRoundTrip() async throws {
    let fakeFfiClient = FakeMobileConvexClient()
    let client = ConvexMobile.ConvexClient(ffiClient: fakeFfiClient)

    let message: Message = try await client.mutation(name: "foo", args: ["anInt": 101])

    XCTAssertEqual(message.id, "the_id")
    XCTAssertEqual(message.val, 101)

  }
}

class FakeMobileConvexClient: UniFFI.MobileConvexClientProtocol {
  var cancellationCount = 0
  var subscriptionArgs: [String: String] = [:]
  func action(name: String, args: [String: String]) async throws -> String {
    return "foo"
  }

  func mutation(name: String, args: [String: String]) async throws -> String {
    let receivedConvexInt = args["anInt"]!
    return "{\"_id\": \"the_id\", \"val\": \(receivedConvexInt), \"extra\": null}"
  }

  func query(name: String, args: [String: String]) async throws -> String {
    return "foo"
  }

  func setAuth(token: String?) async throws {

  }

  func subscribe(name: String, args: [String: String], subscriber: any UniFFI.QuerySubscriber)
    async throws -> UniFFI.SubscriptionHandle
  {
    subscriptionArgs = args
    let _ = Task {
      try await Task.sleep(nanoseconds: UInt64(0.05 * 1_000_000_000))
      subscriber.onUpdate(
        value: "{\"_id\": \"the_id\", \"val\": {\"$integer\":\"KgAAAAAAAAA=\"}, \"extra\": null}")
    }
    return FakeSubscriptionHandle(client: self)
  }

}

class FakeSubscriptionHandle: UniFFI.SubscriptionHandle {
  let client: FakeMobileConvexClient
  init(client: FakeMobileConvexClient) {
    self.client = client
    super.init(noPointer: UniFFI.SubscriptionHandle.NoPointer())
  }

  required init(unsafeFromRawPointer pointer: UnsafeMutableRawPointer) {
    fatalError("init(unsafeFromRawPointer:) has not been implemented")
  }

  override func cancel() {
    self.client.cancellationCount += 1
  }
}

struct Message: Decodable {
  let id: String
  @ConvexInt
  var val: Int

  enum CodingKeys: String, CodingKey {
    case id = "_id"
    case val
  }
}
