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
    async throws
    -> AnyPublisher<T, ClientError>
  {
    let publisher = PassthroughSubject<T, ClientError>()
    let adapter = SubscriptionAdapter<T>(publisher: publisher)
    let cancellationHandle = try await ffiClient.subscribe(
      name: name,
      args: args?.mapValues({ v in
        try v?.convexEncode() ?? "null"
      }) ?? [:], subscriber: adapter)
    return publisher.handleEvents(receiveCancel: {
      cancellationHandle.cancel()
    })
    .eraseToAnyPublisher()
  }

  public func mutation<T: Decodable>(name: String, args: [String: ConvexEncodable?]? = nil)
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
extension [String: ConvexEncodable]: ConvexEncodable {
  public func convexEncode() throws -> String {
    var kvPairs: [String] = []
    try self.forEach { (key: String, value: any ConvexEncodable) in
      let encodedValue = try value.convexEncode()
      kvPairs.append("\"\(key)\":\(encodedValue)")
    }
    return "{\(kvPairs.joined(separator: ","))}"
  }
}
