import XCTest

@testable import ConvexMobile
@testable import UniFFI

final class ConvexMobileTests: XCTestCase {
  func testSubscribeResult() async throws {
    let expectation = self.expectation(description: "subscribe")
    var error: ClientError?
    var result: Message?
    let client = ConvexMobile.ConvexClient(ffiClient: FakeMobileConvexClient())

    let cancellationHandle = client.subscribe(to: "foo").sink(
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
    XCTAssertNil(error)
  }

  func testSubscribeCanTrimDupeVals() async throws {
    let receivedSomething = self.expectation(description: "subscribe")
    let donePublishing = self.expectation(description: "done_publishing")
    var error: ClientError?
    var result: [Message] = []
    let client = ConvexMobile.ConvexClient(
      ffiClient: FakeMobileConvexClient(resultPublished: donePublishing))

    let cancellationHandle = client.subscribe(to: "dupeVals")
      .removeDuplicates()
      .sink(
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
          result.append(value)
          if result.count == 1 {
            receivedSomething.fulfill()
          }
        })

    await fulfillment(of: [donePublishing, receivedSomething], timeout: 10)

    XCTAssertEqual(result.count, 1)
    XCTAssertNil(error)
  }

  func testSubscribeOptionalResultWithPresentVal() async throws {
    let expectation = self.expectation(description: "subscribe")
    var error: ClientError?
    var result: MessageWithOptionalVal?
    let client = ConvexMobile.ConvexClient(ffiClient: FakeMobileConvexClient())

    let cancellationHandle = client.subscribe(to: "foo").sink(
      receiveCompletion: { completion in
        switch completion {
        case .finished:
          break
        case .failure(let clientError):
          error = clientError
          break
        }
      },
      receiveValue: { (value: MessageWithOptionalVal?) in
        result = value
        expectation.fulfill()
      })

    await fulfillment(of: [expectation], timeout: 10)

    XCTAssertEqual(result!.id, "the_id")
    XCTAssertEqual(result!.val, 42)
    XCTAssertNil(error)
  }

  func testSubscribeOptionalResultWithNullVal() async throws {
    let expectation = self.expectation(description: "subscribe")
    var error: ClientError?
    var result: MessageWithOptionalVal?
    let client = ConvexMobile.ConvexClient(ffiClient: FakeMobileConvexClient())

    let cancellationHandle = client.subscribe(to: "nullVal").sink(
      receiveCompletion: { completion in
        switch completion {
        case .finished:
          break
        case .failure(let clientError):
          error = clientError
          break
        }
      },
      receiveValue: { (value: MessageWithOptionalVal?) in
        result = value
        expectation.fulfill()
      })

    await fulfillment(of: [expectation], timeout: 10)

    XCTAssertEqual(result!.id, "the_id")
    XCTAssertEqual(result!.val, nil)
    XCTAssertNil(error)
  }

  func testSubscribeOptionalResultWithMissingVal() async throws {
    let expectation = self.expectation(description: "subscribe")
    var error: ClientError?
    var result: MessageWithOptionalVal?
    let client = ConvexMobile.ConvexClient(ffiClient: FakeMobileConvexClient())

    let cancellationHandle = client.subscribe(to: "missingVal").sink(
      receiveCompletion: { completion in
        switch completion {
        case .finished:
          break
        case .failure(let clientError):
          error = clientError
          break
        }
      },
      receiveValue: { (value: MessageWithOptionalVal?) in
        result = value
        expectation.fulfill()
      })

    await fulfillment(of: [expectation], timeout: 10)

    XCTAssertEqual(result!.id, "the_id")
    XCTAssertEqual(result!.val, nil)
    XCTAssertNil(error)
  }

  func testMissingSubscribeArgs() async throws {
    let expectation = self.expectation(description: "subscribe")
    let fakeFfiClient = FakeMobileConvexClient()
    let client = ConvexMobile.ConvexClient(ffiClient: fakeFfiClient)

    let cancellationHandle = try client.subscribe(to: "foo").sink(
      receiveCompletion: { completion in
        switch completion {
        case .finished:
          break
        case .failure:
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

    let cancellationHandle = client.subscribe(
      to: "foo",
      with: [
        "aString": "bar", "aDouble": 42.0, "anInt": 42, "aNil": nil,
        "aDict": ["sub1": 1.0, "nested": ["ohmy": true]], "aList": [true, false, true, nil],
      ]
    ).sink(
      receiveCompletion: { completion in
        switch completion {
        case .finished:
          break
        case .failure:
          break
        }
      }) {
        (value: Message) in
        expectation.fulfill()
      }

    await fulfillment(of: [expectation], timeout: 10)

    XCTAssertEqual(fakeFfiClient.subscriptionArgs["aString"], "\"bar\"")
    XCTAssertEqual(fakeFfiClient.subscriptionArgs["aDouble"], "42")
    XCTAssertEqual(fakeFfiClient.subscriptionArgs["anInt"], "{\"$integer\":\"KgAAAAAAAAA=\"}")
    XCTAssertEqual(fakeFfiClient.subscriptionArgs["aNil"], "null")
    XCTAssertEqual(
      fakeFfiClient.subscriptionArgs["aDict"], "{\"nested\":{\"ohmy\":true},\"sub1\":1}")
    XCTAssertEqual(fakeFfiClient.subscriptionArgs["aList"], "[true,false,true,null]")

  }

  func testSubscribeCancellation() async throws {
    let expectation = self.expectation(description: "subscribe")
    var error: ClientError?
    let ffiClient = FakeMobileConvexClient()
    let client = ConvexMobile.ConvexClient(ffiClient: ffiClient)

    let cancellationHandle = client.subscribe(to: "foo").sink(
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
    XCTAssertNil(error)
  }

  func testMutationRoundTrip() async throws {
    let fakeFfiClient = FakeMobileConvexClient()
    let client = ConvexMobile.ConvexClient(ffiClient: fakeFfiClient)

    let message: Message = try await client.mutation("foo", with: ["anInt": 101])

    XCTAssertEqual(message.id, "the_id")
    XCTAssertEqual(message.val, 101)
  }

  func testVoidMutation() async throws {
    let fakeFfiClient = FakeMobileConvexClient()
    let client = ConvexMobile.ConvexClient(ffiClient: fakeFfiClient)

    try await client.mutation("nullResult")

    XCTAssertEqual(fakeFfiClient.mutationCalls, ["nullResult"])
  }

  func testActionRoundTrip() async throws {
    let fakeFfiClient = FakeMobileConvexClient()
    let client = ConvexMobile.ConvexClient(ffiClient: fakeFfiClient)

    let message: Message = try await client.action("foo", with: ["anInt": Int.max])

    XCTAssertEqual(message.id, "the_id")
    XCTAssertEqual(message.val, Int.max)
  }

  func testVoidAction() async throws {
    let fakeFfiClient = FakeMobileConvexClient()
    let client = ConvexMobile.ConvexClient(ffiClient: fakeFfiClient)

    try await client.action("nullResult")

    XCTAssertEqual(fakeFfiClient.actionCalls, ["nullResult"])
  }

  func testLoginSetsAuthOnFfiClient() async throws {
    let fakeFfiClient = FakeMobileConvexClient()
    let client = ConvexMobile.ConvexClientWithAuth(
      ffiClient: fakeFfiClient, authProvider: FakeAuthProvider())

    let result = await client.login()

    XCTAssertEqual(try result.get(), FakeAuthProvider.CREDENTIALS)
    XCTAssertEqual(fakeFfiClient.auth, "extracted: \(FakeAuthProvider.CREDENTIALS)")
  }

  func testLoginFromCacheSetsAuthOnFfiClient() async throws {
    let fakeFfiClient = FakeMobileConvexClient()
    let client = ConvexMobile.ConvexClientWithAuth(
      ffiClient: fakeFfiClient, authProvider: FakeAuthProvider())

    let result = await client.loginFromCache()

    XCTAssertEqual(try result.get(), FakeAuthProvider.CREDENTIALS)
    XCTAssertEqual(fakeFfiClient.auth, "extracted: \(FakeAuthProvider.CREDENTIALS)")
  }

  func testLogoutClearsAuthOnFfiClient() async throws {
    let fakeFfiClient = FakeMobileConvexClient(initialAuth: "some auth")
    let client = ConvexMobile.ConvexClientWithAuth(
      ffiClient: fakeFfiClient, authProvider: FakeAuthProvider())

    await client.logout()

    XCTAssertEqual(fakeFfiClient.auth, nil)
  }

  func testLoginUpdatesAuthState() async throws {
    let expectation = self.expectation(description: "authState")
    var credentials: String?
    let client = ConvexMobile.ConvexClientWithAuth(
      ffiClient: FakeMobileConvexClient(), authProvider: FakeAuthProvider())

    let cancellationHandle = client.authState.sink(
      receiveValue: { (value: AuthState<String>) in
        if case .authenticated(let creds) = value {
          credentials = creds
          expectation.fulfill()
        }
      })

    let result = await client.login()

    await fulfillment(of: [expectation], timeout: 10)

    XCTAssertEqual(try result.get(), FakeAuthProvider.CREDENTIALS)
    XCTAssertEqual(credentials, FakeAuthProvider.CREDENTIALS)
  }

  // MARK: - Token Refresh Tests

  func testProviderWithoutRefreshSupport() async throws {
    // Test that providers without refresh support don't cause issues
    let providerWithoutRefresh = FakeAuthProviderWithoutRefresh()
    let client = ConvexMobile.ConvexClientWithAuth(
      ffiClient: FakeMobileConvexClient(), authProvider: providerWithoutRefresh)

    let result = await client.login()

    // Should login successfully even without refresh support
    XCTAssertEqual(try result.get(), FakeAuthProviderWithoutRefresh.CREDENTIALS)

    // Attempting to refresh should throw refreshNotSupported
    do {
      _ = try await providerWithoutRefresh.refreshToken(from: FakeAuthProviderWithoutRefresh.CREDENTIALS)
      XCTFail("Should have thrown refreshNotSupported error")
    } catch AuthProviderError.refreshNotSupported {
      // Expected error
      XCTAssertTrue(true)
    } catch {
      XCTFail("Unexpected error: \(error)")
    }
  }

  func testProviderWithRefreshSupport() async throws {
    let provider = FakeRefreshableAuthProvider()
    let ffiClient = FakeMobileConvexClient()
    let client = ConvexMobile.ConvexClientWithAuth(
      ffiClient: ffiClient, authProvider: provider)

    _ = await client.login()

    // Verify refresh works
    let refreshedCreds = try await provider.refreshToken(from: "old_token")
    XCTAssertEqual(refreshedCreds, "refreshed_token")
    XCTAssertEqual(provider.refreshCallCount, 1)
  }

  func testRefreshTokenExtractsNewIdToken() async throws {
    let provider = FakeRefreshableAuthProvider()
    let newCreds = try await provider.refreshToken(from: "old_token")
    let idToken = provider.extractIdToken(from: newCreds)

    XCTAssertEqual(idToken, "extracted: refreshed_token")
  }
}

class FakeMobileConvexClient: UniFFI.MobileConvexClientProtocol {
  var cancellationCount = 0
  var subscriptionArgs: [String: String] = [:]
  var mutationCalls: [String] = []
  var actionCalls: [String] = []
  var auth: String? = nil
  var resultPublished: XCTestExpectation?

  init(initialAuth: String? = nil, resultPublished: XCTestExpectation? = nil) {
    self.auth = initialAuth
    self.resultPublished = resultPublished
  }

  func action(name: String, args: [String: String]) async throws -> String {
    actionCalls.append(name)
    if name == "nullResult" {
      return "null"
    }
    let receivedConvexInt = args["anInt"]!
    return "{\"_id\": \"the_id\", \"val\": \(receivedConvexInt), \"extra\": null}"
  }

  func mutation(name: String, args: [String: String]) async throws -> String {
    mutationCalls.append(name)
    if name == "nullResult" {
      return "null"
    }
    let receivedConvexInt = args["anInt"]!
    return "{\"_id\": \"the_id\", \"val\": \(receivedConvexInt), \"extra\": null}"
  }

  func query(name: String, args: [String: String]) async throws -> String {
    return "foo"
  }

  func setAuth(token: String?) async throws {
    auth = token
  }

  func subscribe(name: String, args: [String: String], subscriber: any UniFFI.QuerySubscriber)
    async throws -> UniFFI.SubscriptionHandle
  {
    subscriptionArgs = args
    let _ = Task {
      try await Task.sleep(nanoseconds: UInt64(0.05 * 1_000_000_000))
      if name == "missingVal" {
        subscriber.onUpdate(
          value: "{\"_id\": \"the_id\", \"extra\": null}")
      } else if name == "nullVal" {
        subscriber.onUpdate(
          value: "{\"_id\": \"the_id\", \"val\": null, \"extra\": null}")
      } else {
        subscriber.onUpdate(
          value: "{\"_id\": \"the_id\", \"val\": {\"$integer\":\"KgAAAAAAAAA=\"}, \"extra\": null}")
        if name == "dupeVals" {
          subscriber.onUpdate(
            value:
              "{\"_id\": \"the_id\", \"val\": {\"$integer\":\"KgAAAAAAAAA=\"}, \"extra\": null}")
        }
      }
      resultPublished?.fulfill()

    }
    return FakeSubscriptionHandle(client: self)
  }

}

class FakeAuthProvider: AuthProvider {
  static let CREDENTIALS = "credentials, yo"

  func loginFromCache() async throws -> String {
    return FakeAuthProvider.CREDENTIALS
  }

  func login() async throws -> String {
    return FakeAuthProvider.CREDENTIALS
  }

  func logout() async throws {

  }

  func extractIdToken(from authResult: String) -> String {
    return "extracted: \(authResult)"
  }

  func refreshToken(from authResult: String) async throws -> String {
    // In a real implementation, this would call the auth provider's refresh endpoint
    return authResult
  }
}

// Provider that doesn't override refreshToken - uses default implementation
class FakeAuthProviderWithoutRefresh: AuthProvider {
  static let CREDENTIALS = "creds_without_refresh"

  func loginFromCache() async throws -> String {
    return FakeAuthProviderWithoutRefresh.CREDENTIALS
  }

  func login() async throws -> String {
    return FakeAuthProviderWithoutRefresh.CREDENTIALS
  }

  func logout() async throws {

  }

  func extractIdToken(from authResult: String) -> String {
    return "extracted: \(authResult)"
  }

  // Note: refreshToken not implemented - will use default implementation that throws
}

// Provider that implements refresh with tracking
class FakeRefreshableAuthProvider: AuthProvider {
  static let CREDENTIALS = "initial_token"
  var refreshCallCount = 0

  func loginFromCache() async throws -> String {
    return FakeRefreshableAuthProvider.CREDENTIALS
  }

  func login() async throws -> String {
    return FakeRefreshableAuthProvider.CREDENTIALS
  }

  func logout() async throws {

  }

  func extractIdToken(from authResult: String) -> String {
    return "extracted: \(authResult)"
  }

  func refreshToken(from authResult: String) async throws -> String {
    refreshCallCount += 1
    return "refreshed_token"
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

private struct MessageWithOptionalVal: Decodable {
  let id: String
  @OptionalConvexInt
  var val: Int? = nil

  enum CodingKeys: String, CodingKey {
    case id = "_id"
    case val
  }
}

private struct Message: Decodable, Equatable {
  let id: String
  @ConvexInt
  var val: Int

  enum CodingKeys: String, CodingKey {
    case id = "_id"
    case val
  }
}
