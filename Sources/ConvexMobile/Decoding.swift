//
//  Decoding.swift
//  ConvexMobile
//
//  Created by Christian Wyglendowski on 10/1/24.
//

import Foundation

@propertyWrapper
public struct ConvexInt<IntegerType: FixedWidthInteger>: Decodable, Equatable {
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

@propertyWrapper
public struct OptionalConvexInt<IntegerType: FixedWidthInteger>: Decodable, Equatable {
  public var wrappedValue: IntegerType?

  public init(wrappedValue: IntegerType?) {
    self.wrappedValue = wrappedValue
  }

  public init(from decoder: Decoder) throws {
    if let container = try? decoder.container(keyedBy: ConvexTypeKey.self) {
      let b64int = try container.decode(String.self, forKey: .integer)
      self.wrappedValue = Data(base64Encoded: b64int)!.withUnsafeBytes({
        (rawPtr: UnsafeRawBufferPointer) in
        return rawPtr.load(as: IntegerType.self)
      })
    }
  }

  enum ConvexTypeKey: String, CodingKey {
    case integer = "$integer"
  }
}

// This allows for decoding OptionalConvexInt when the associated key isn't present in the payload.
extension KeyedDecodingContainer {
  public func decode<T>(_ type: OptionalConvexInt<T>.Type, forKey key: Self.Key) throws
    -> OptionalConvexInt<T>
  {
    return try decodeIfPresent(type, forKey: key) ?? OptionalConvexInt(wrappedValue: nil)
  }
}
