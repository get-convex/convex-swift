//
//  IntegrationTests.swift
//  ConvexMobile
//
//  Created by Christian Wyglendowski on 10/1/24.
//

import Combine
import ConvexMobile
import Testing

private let deploymentUrl = "https://curious-lynx-309.convex.cloud"

@Suite(.serialized) struct Test {
  init() async throws {
    let client = ConvexClient(deploymentUrl: deploymentUrl)
    try await client.mutation(name: "messages:clearAll")
  }

  @Test func test_empty_subscribe() async throws {
    let client = ConvexClient(deploymentUrl: deploymentUrl)
    let s: AnyPublisher<[Message]?, ClientError> = client.subscribe(name: "messages:list")
    var received = 0
    for await messages in s.replaceError(with: nil).first().values {
      #expect(messages! == [])
      received += 1
    }
    #expect(received == 1)
  }

  @Test func test_convex_error_in_subscription() async throws {
    let client = ConvexClient(deploymentUrl: deploymentUrl)
    let s: AnyPublisher<[Message]?, ClientError> = client.subscribe(
      name: "messages:list", args: ["forceError": true])
    await #expect(throws: ClientError.ConvexError(data: "\"forced error data\"")) {
      for try await _ in s.first().values {}
    }
  }

  @Test func test_convex_error_in_action() async throws {
    let client = ConvexClient(deploymentUrl: deploymentUrl)
    await #expect(throws: ClientError.ConvexError(data: "\"forced error data\"")) {
      try await client.action(name: "messages:forceActionError")
    }
  }

  @Test func test_convex_error_in_mutation() async throws {
    let client = ConvexClient(deploymentUrl: deploymentUrl)
    await #expect(throws: ClientError.ConvexError(data: "\"forced error data\"")) {
      try await client.mutation(name: "messages:forceMutationError")
    }
  }

  @Test func send_and_receive_one_message() async throws {
    let clientA = ConvexClient(deploymentUrl: deploymentUrl)
    let clientB = ConvexClient(deploymentUrl: deploymentUrl)

    let messagesA: AnyPublisher<[Message]?, ClientError> = clientA.subscribe(name: "messages:list")

    try await clientB.mutation(
      name: "messages:send", args: ["author": "Client B", "body": "Test 123"])

    var received = 0
    for await messages in messagesA.replaceError(with: nil).first().values {
      #expect(messages! == [Message(author: "Client B", body: "Test 123")])
      received += 1
    }
    #expect(received == 1)
  }

  @Test func send_and_receive_multiple_messages() async throws {
    let clientA = ConvexClient(deploymentUrl: deploymentUrl)
    let clientB = ConvexClient(deploymentUrl: deploymentUrl)

    let messagesA: AnyPublisher<[Message]?, ClientError> = clientA.subscribe(name: "messages:list")

    var receivedMessages: [[Message]] = []

    let receiveTask = Task {
      for await messages in messagesA.replaceError(with: nil).output(in: 0...3).values {
        receivedMessages.append(messages ?? [])
      }
    }

    Task {
      for i in 1...3 {
        try await clientB.mutation(
          name: "messages:send", args: ["author": "Client B", "body": "Message \(i)"])
      }
    }

    await receiveTask.value

    #expect(receivedMessages.count == 4)
    #expect(receivedMessages[0] == [])
    #expect(receivedMessages[1] == [Message(author: "Client B", body: "Message 1")])
    #expect(
      receivedMessages[2] == [
        Message(author: "Client B", body: "Message 1"),
        Message(author: "Client B", body: "Message 2"),
      ])
    #expect(
      receivedMessages[3] == [
        Message(author: "Client B", body: "Message 1"),
        Message(author: "Client B", body: "Message 2"),
        Message(author: "Client B", body: "Message 3"),
      ])
  }

  @Test func can_round_trip_max_value_args() async throws {
    let client = ConvexClient(deploymentUrl: deploymentUrl)
    let maxValues = NumericValues(
      anInt64: Int64.max, aFloat64: Double.greatestFiniteMagnitude,
      jsNumber: Double.greatestFiniteMagnitude, anInt32: Int32.max,
      aFloat32: Float32.greatestFiniteMagnitude)

    let result: NumericValues = try await client.action(
      name: "messages:echoValidatedArgs", args: maxValues.toArgs())

    #expect(result == maxValues)
  }

  @Test func can_round_trip_special_floats() async throws {
    let client = ConvexClient(deploymentUrl: deploymentUrl)
    let specialFloats = SpecialFloats()
    let result: SpecialFloats = try await client.action(
      name: "messages:echoArgs", args: specialFloats.toArgs())

    #expect(result.f32Nan.isNaN)
    #expect(result.f32NegInf == specialFloats.f32NegInf)
    #expect(result.f32PosInf == specialFloats.f32PosInf)
    #expect(result.f64Nan.isNaN)
    #expect(result.f64NegInf == specialFloats.f64NegInf)
    #expect(result.f64PosInf == specialFloats.f64PosInf)
  }

  @Test func can_receive_numbers() async throws {
    let client = ConvexClient(deploymentUrl: deploymentUrl)
    let result: NumericValues = try await client.action(name: "messages:numbers")
    let expected = NumericValues(
      anInt64: 100, aFloat64: 100.0, jsNumber: 100.0, anInt32: 100, aFloat32: 100.0)
    #expect(result == expected)
    #expect(result.aPlainInt == 100)
  }

  @Test func can_receive_null_and_missing_float64_values() async throws {
    let client = ConvexClient(deploymentUrl: deploymentUrl)
    let result: NullableFloats = try await client.action(
      name: "messages:echoArgs", args: ["aNullableDouble": nil])
    #expect(result == NullableFloats())
  }
}

private struct Message: Decodable, Equatable {
  let author: String
  let body: String
}

private struct NumericValues: Decodable, Equatable {
  @ConvexInt
  var anInt64: Int64
  @ConvexFloat
  var aFloat64: Float64
  @ConvexFloat
  var jsNumber: Double
  @ConvexInt
  var anInt32: Int32
  @ConvexFloat
  var aFloat32: Float32

  enum CodingKeys: String, CodingKey {
    case anInt64
    case aFloat64
    case jsNumber = "aPlainInt"
    case anInt32
    case aFloat32
  }

  func toArgs() -> [String: ConvexEncodable] {
    [
      "anInt64": anInt64,
      "aFloat64": aFloat64,
      "aPlainInt": jsNumber,
      "anInt32": anInt32,
      "aFloat32": aFloat32,
    ]
  }

  // Expose the JavaScript number value as an Int.
  var aPlainInt: Int {
    Int(jsNumber)
  }
}

private struct SpecialFloats: Decodable, Equatable {
  @ConvexFloat
  var f64Nan: Float64 = Float64.nan
  @ConvexFloat
  var f64NegInf: Double = -Double.infinity
  @ConvexFloat
  var f64PosInf: Double = Double.infinity
  @ConvexFloat
  var f32Nan: Float32 = Float32.nan
  @ConvexFloat
  var f32NegInf: Float32 = -Float32.infinity
  @ConvexFloat
  var f32PosInf: Float = Float.infinity

  func toArgs() -> [String: ConvexEncodable] {
    [
      "f64Nan": f64Nan,
      "f64NegInf": f64NegInf,
      "f64PosInf": f64PosInf,
      "f32Nan": f32Nan,
      "f32NegInf": f32NegInf,
      "f32PosInf": f32PosInf,
    ]
  }
}

private struct NullableFloats: Decodable, Equatable {
  @OptionalConvexFloat
  var aNullableDouble: Double?
  @OptionalConvexFloat
  var aMissingDouble: Double?
}
