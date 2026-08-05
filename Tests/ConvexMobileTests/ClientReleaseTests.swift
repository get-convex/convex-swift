import XCTest

@testable import ConvexMobile
@testable import UniFFI

/// Proves a discarded client can actually be freed, i.e. that the auth wiring
/// does not retain the FFI client once the app drops its references.
///
/// The real-world failure this guards against: the token handler created in
/// `onIdTokenHandler` used to capture `ffiClient` strongly. That handler is
/// captured by the `AuthTokenProviderBridge`'s refresh closure, and the Rust
/// core stores the bridge when it is passed to `setAuthCallback`: a retain
/// cycle across the FFI boundary. Since the `ffiClient` proxy's deinit is what
/// frees the Rust client, the cycle kept every discarded client's Rust core
/// (its own tokio runtime + established websocket) alive until process exit.
/// An app that recreated clients to recover from wedged connections leaked one
/// server-side websocket per recreate (41 observed in a single macOS session).
///
/// `FakeMobileConvexClient` stores the provider passed to `setAuthCallback`
/// strongly, exactly like the Rust core does, so the cycle is reproducible
/// entirely in Swift.
final class ClientReleaseTests: XCTestCase {

  /// The original leak: the client is discarded while the fake (like the Rust
  /// core) still holds the bridge. The handler's weak `ffiClient` capture is
  /// the only thing preventing the cycle.
  func testFFIClientReleasedAfterLoginWithoutClose() async throws {
    var fake: FakeMobileConvexClient? = FakeMobileConvexClient()
    weak var weakFake = fake
    var client: ConvexClientWithAuth<String>? = ConvexClientWithAuth(
      ffiClient: fake!, authProvider: FakeAuthProvider())

    let result = await client!.login()
    XCTAssertNotNil(try? result.get())
    XCTAssertNotNil(fake!.authProvider, "login should install the auth bridge")

    client = nil
    fake = nil
    // Let the handler's fire-and-forget Tasks (spawned during login) drain;
    // they hold a transient strong reference while running.
    try await Task.sleep(nanoseconds: 200_000_000)

    XCTAssertNil(
      weakFake,
      "FFI client is retained after all references were dropped: the bridge -> "
        + "token handler -> ffiClient retain cycle is back, and every discarded "
        + "real client will leak its Rust core + websocket")
  }
}
