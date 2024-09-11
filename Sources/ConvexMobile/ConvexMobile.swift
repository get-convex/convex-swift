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

  public func subscribe<T: Decodable>(name: String) async throws -> AnyPublisher<T, ClientError> {
    let publisher = PassthroughSubject<T, ClientError>()
    let adapter = SubscriptionAdapter<T>(publisher: publisher)
    let cancellationHandle = try await ffiClient.subscribe(
      name: name, args: [:], subscriber: adapter)
    return publisher.handleEvents(receiveCancel: {
      cancellationHandle.cancel()
    })
    .eraseToAnyPublisher()
  }
}

class SubscriptionAdapter<T: Decodable>: QuerySubscriber {
  typealias Publisher = PassthroughSubject<T, ClientError>

  let publisher: Publisher

  init(publisher: Publisher) {
    self.publisher = publisher
  }

  func onError(message: String, value: String?) {

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
