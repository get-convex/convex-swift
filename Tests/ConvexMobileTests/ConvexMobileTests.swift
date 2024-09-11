import XCTest

@testable import ConvexMobile
@testable import UniFFI

final class ConvexMobileTests: XCTestCase {
  func testSubscribe() async throws {
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

  func testCancellation() async throws {
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
}

class FakeMobileConvexClient: UniFFI.MobileConvexClientProtocol {
  var cancellationCount = 0
  func action(name: String, args: [String: String]) async throws -> String {
    return "foo"
  }

  func mutation(name: String, args: [String: String]) async throws -> String {
    return "foo"
  }

  func query(name: String, args: [String: String]) async throws -> String {
    return "foo"
  }

  func setAuth(token: String?) async throws {

  }

  func subscribe(name: String, args: [String: String], subscriber: any UniFFI.QuerySubscriber)
    async throws -> UniFFI.SubscriptionHandle
  {
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
