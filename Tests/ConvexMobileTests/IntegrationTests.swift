//
//  Test.swift
//  ConvexMobile
//
//  Created by Christian Wyglendowski on 10/1/24.
//

import Combine
import ConvexMobile
import Testing

private let deploymentUrl = "https://curious-lynx-309.convex.cloud"

struct Test {
  init() async throws {
    let client = ConvexClient(deploymentUrl: deploymentUrl)
    try await client.mutation(name: "messages:clearAll")
  }

  @Test func test_empty_subscribe() async throws {
    let client = ConvexClient(deploymentUrl: deploymentUrl)
    let s: AnyPublisher<[Message]?, ClientError> = client.subscribe(name: "messages:list")
    var found = 0
    for await messages in s.replaceError(with: nil).first().values {
      #expect(messages! == [])
      found += 1
    }
    #expect(found == 1)
  }

  @Test func test_convex_error_in_subscription() async throws {
    let client = ConvexClient(deploymentUrl: deploymentUrl)
    let s: AnyPublisher<[Message]?, ClientError> = client.subscribe(
      name: "messages:list", args: ["forceError": true])
    await #expect(throws: ClientError.ConvexError(data: "\"forced error data\"")) {
      for try await _ in s.first().values {}
    }
  }

}

private struct Message: Decodable, Equatable {
  let author: String
  let body: String
}
