// The Swift Programming Language
// https://docs.swift.org/swift-book

import Combine
import Foundation
@_exported import UniFFI

public class ConvexClient {
  let ffiClient: UniFFI.MobileConvexClientProtocol

  public init(deploymentUrl: String) {
    self.ffiClient = UniFFI.MobileConvexClient(deploymentUrl: deploymentUrl)
  }

  init(ffiClient: UniFFI.MobileConvexClientProtocol) {
    self.ffiClient = ffiClient
  }

  public func subscribe<T: Decodable>(name: String, args: [String: ConvexEncodable?]? = nil)
    throws
    -> AnyPublisher<T, ClientError>
  {
    let publisher = PassthroughSubject<T, ClientError>()
    let adapter = SubscriptionAdapter<T>(publisher: publisher)
    let cancelPublisher = Future<SubscriptionHandle, ClientError> {
      promise in
      Task {
        do {
          let cancellationHandle = try await self.ffiClient.subscribe(
            name: name,
            args: args?.mapValues({ v in
              try v?.convexEncode() ?? "null"
            }) ?? [:], subscriber: adapter)
          promise(.success(cancellationHandle))
        } catch {
          promise(.failure(ClientError.InternalError(msg: error.localizedDescription)))
        }
      }
    }
    return cancelPublisher.flatMap({ subscriptionHandle in
      publisher.handleEvents(receiveCancel: {
        subscriptionHandle.cancel()
      })
    })
    .eraseToAnyPublisher()
  }

  public func mutation<T: Decodable>(name: String, args: [String: ConvexEncodable?]? = nil)
    async throws -> T
  {
    return try await mutationForResult(name: name, args: args)
  }

  public func mutation(name: String, args: [String: ConvexEncodable?]? = nil)
    async throws
  {
    let _: String? = try await mutationForResult(name: name, args: args)
  }

  func mutationForResult<T: Decodable>(
    name: String, args: [String: ConvexEncodable?]? = nil
  )
    async throws -> T
  {
    let rawResult = try await ffiClient.mutation(
      name: name,
      args: args?.mapValues({ v in
        try v?.convexEncode() ?? "null"
      }) ?? [:])
    return try! JSONDecoder().decode(T.self, from: Data(rawResult.utf8))
  }
}

public enum AuthState<T> {
  case authenticated(T)
  case unauthenticated
  case loading
}

public protocol AuthProvider<T> {
  associatedtype T

  func login() async throws -> T
  func logout() async throws
  func loginFromCache() async throws -> T
  func extractIdToken(authResult: T) -> String
}

public class ConvexClientWithAuth<T>: ConvexClient {
  private let authPublisher = CurrentValueSubject<AuthState<T>, Never>(AuthState.unauthenticated)
  public let authState: AnyPublisher<AuthState<T>, Never>
  private let authProvider: any AuthProvider<T>

  public init(deploymentUrl: String, authProvider: any AuthProvider<T>) {
    self.authProvider = authProvider
    self.authState = authPublisher.eraseToAnyPublisher()
    super.init(deploymentUrl: deploymentUrl)
  }

  init(ffiClient: MobileConvexClientProtocol, authProvider: any AuthProvider<T>) {
    self.authProvider = authProvider
    self.authState = authPublisher.eraseToAnyPublisher()
    super.init(ffiClient: ffiClient)
  }

  public func login() async {
    await login(strategy: authProvider.login)
  }

  public func loginFromCache() async {
    await login(strategy: authProvider.loginFromCache)
  }

  public func logout() async {
    do {
      try await authProvider.logout()
      try await ffiClient.setAuth(token: nil)
      authPublisher.send(AuthState.unauthenticated)
    } catch {
      dump(error)
    }
  }

  private func login(strategy: LoginStrategy) async {
    authPublisher.send(AuthState.loading)
    do {
      let result = try await strategy()
      try await ffiClient.setAuth(token: authProvider.extractIdToken(authResult: result))
      authPublisher.send(AuthState.authenticated(result))
    } catch {
      dump(error)
      authPublisher.send(AuthState.unauthenticated)
    }
  }

  private typealias LoginStrategy = () async throws -> T
}

class SubscriptionAdapter<T: Decodable>: QuerySubscriber {
  typealias Publisher = PassthroughSubject<T, ClientError>

  let publisher: Publisher

  init(publisher: Publisher) {
    self.publisher = publisher
  }

  func onError(message: String, value: String?) {
    let err: ClientError
    if value != nil {
      err = ClientError.ConvexError(data: value!)
    } else {
      err = ClientError.ServerError(msg: message)
    }
    publisher.send(
      completion: Subscribers.Completion.failure(err))
  }

  func onUpdate(value: String) {
    publisher.send(try! JSONDecoder().decode(Publisher.Output.self, from: Data(value.utf8)))
  }

}

@propertyWrapper
public struct ConvexInt<IntegerType: FixedWidthInteger>: Decodable {
  public var wrappedValue: IntegerType

  public init(wrappedValue: IntegerType) {
    self.wrappedValue = wrappedValue
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: ConvexTypeKey.self)
    let b64int = try container.decode(String.self, forKey: .integer)
    self.wrappedValue = Data(base64Encoded: b64int)!.withUnsafeBytes({
      (rawPtr: UnsafeRawBufferPointer) in
      return rawPtr.load(as: IntegerType.self)
    })
  }

  enum ConvexTypeKey: String, CodingKey {
    case integer = "$integer"
  }
}

struct ConvexBase64Int: Decodable {
  let integer: String

  enum ConvexTypeKey: String, CodingKey {
    case integer = "$integer"
  }
}

public protocol ConvexEncodable {
  func convexEncode() throws -> String
}

extension ConvexEncodable where Self: FixedWidthInteger, Self: Encodable {
  public func convexEncode() throws -> String {
    let data = withUnsafeBytes(of: self) { Data($0) }
    return String(
      decoding: try JSONEncoder().encode(["$integer": data.base64EncodedString()]), as: UTF8.self)
  }
}

extension ConvexEncodable where Self: Encodable {
  public func convexEncode() throws -> String {
    return String(decoding: try JSONEncoder().encode(self), as: UTF8.self)
  }
}

extension Int: ConvexEncodable {}
extension Double: ConvexEncodable {}
extension Bool: ConvexEncodable {}
extension String: ConvexEncodable {}
extension [String: ConvexEncodable?]: ConvexEncodable {
  public func convexEncode() throws -> String {
    var kvPairs: [String] = []
    for key in self.keys.sorted() {
      let value = self[key]
      let encodedValue = try value??.convexEncode() ?? "null"
      kvPairs.append("\"\(key)\":\(encodedValue)")
    }
    return "{\(kvPairs.joined(separator: ","))}"
  }
}
extension [ConvexEncodable?]: ConvexEncodable {
  public func convexEncode() throws -> String {
    var encodedValues: [String] = []
    for value in self {
      encodedValues.append(try value?.convexEncode() ?? "null")
    }
    return "[\(encodedValues.joined(separator: ","))]"
  }
}
