// The Swift Programming Language
// https://docs.swift.org/swift-book

import Combine
import Foundation
@_exported import UniFFI

/// A client API for interacting with a Convex backend.
///
/// Handles marshalling of data between calling code and the
/// [convex-mobile](https://github.com/get-convex/convex-mobile) and
/// [convex-rs](https://github.com/get-convex/convex-rs) native libraries.
///
/// Consumers of this client should use Swift's ``Decodable``  protocol for handling data received from the
/// Convex backend.
public class ConvexClient {
  let ffiClient: UniFFI.MobileConvexClientProtocol
  fileprivate let webSocketStateAdapter = WebSocketStateAdapter()

  /// Creates a new instance of ``ConvexClient``.
  ///
  /// - Parameters:
  ///   - deploymentUrl: The Convex backend URL to connect to; find it in the [dashboard](https://dashboard.convex.dev) Settings for your project
  public init(deploymentUrl: String) {
    self.ffiClient = UniFFI.MobileConvexClient(
      deploymentUrl: deploymentUrl, clientId: "swift-\(convexMobileVersion)", webSocketStateSubscriber: webSocketStateAdapter)
  }

  init(ffiClient: UniFFI.MobileConvexClientProtocol) {
    self.ffiClient = ffiClient
  }

  /// Subscribes to the query with the given `name` and converts data from the subscription into an
  /// ``AnyPublisher<T, ClientError>``.
  ///
  /// The upstream Convex subscription will be canceled if whatever is subscribed to returned publisher
  /// stops listening.
  ///
  /// - Parameters:
  ///   - name: A value in "module:query_name"  format that will be used when calling the backend
  ///   - args: An optional ``Dictionary`` of arguments to be sent to the backend query function
  ///   - output: The type of data that will be returned in the Publisher, as a convenience to callers
  ///             where the type can't be easily inferred.
  public func subscribe<T: Decodable>(
    to name: String, with args: [String: ConvexEncodable?]? = nil, yielding output: T.Type? = nil
  ) -> AnyPublisher<T, ClientError> {
    // There are two steps to producing the final Publisher in this method.
    // 1. Subscribe to the data from Convex and publish the subscription handle
    // 2. Feed the subscription handle into the Convex data Publisher so it can cancel the upstream
    //    subscription when downstream subscribers are done consuming data

    // This Publisher will ultimately publish the data received from Convex.
    let convexPublisher = PassthroughSubject<T, ClientError>()
    let adapter = SubscriptionAdapter<T>(publisher: convexPublisher)

    // This Publisher is responsible for initializing the Convex subscription and returning a handle
    // to the upstream (Convex) subscription.
    let initializationPublisher = Future<SubscriptionHandle, ClientError> {
      result in
      Task {
        do {
          let subscriptionHandle = try await self.ffiClient.subscribe(
            name: name,
            args: args?.mapValues({ v in
              try v?.convexEncode() ?? "null"
            }) ?? [:], subscriber: adapter)
          result(.success(subscriptionHandle))
        } catch {
          result(.failure(ClientError.InternalError(msg: error.localizedDescription)))
        }
      }
    }

    // The final Publisher takes the handle from the initial Convex subscription and supplies it to
    // the data publisher so it can cancel the upstream subscription when consumers are no longer
    // listening for data.
    return initializationPublisher.flatMap({ subscriptionHandle in
      convexPublisher.handleEvents(receiveCancel: {
        subscriptionHandle.cancel()
      })
    })
    .eraseToAnyPublisher()
  }

  /// Executes the mutation with the given `name` and `args` and returns the result.
  ///
  /// For mutations that don't return a value, prefer calling the version of this method that doesn't return a value.
  ///
  /// - Parameters:
  ///   - name: A value in "module:mutation_name"  format that will be used when calling the backend
  ///   - args: An optional ``Dictionary`` of arguments to be sent to the backend mutation function
  public func mutation<T: Decodable>(_ name: String, with args: [String: ConvexEncodable?]? = nil)
    async throws -> T
  {
    try await callForResult(name: name, args: args, remoteCall: ffiClient.mutation)
  }

  /// Executes the mutation with the given `name` and `args` without returning a result.
  ///
  /// For mutations that return a value, prefer calling the version of this method that returns a ``Decodable`` value.
  ///
  /// - Parameters:
  ///   - name: A value in "module:mutation_name"  format that will be used when calling the backend
  ///   - args: An optional ``Dictionary`` of arguments to be sent to the backend mutation function
  public func mutation(_ name: String, with args: [String: ConvexEncodable?]? = nil)
    async throws
  {
    let _: String? = try await mutation(name, with: args)
  }

  /// Executes the action with the given `name` and `args` and returns the result.
  ///
  /// For actions that don't return a value, prefer calling the version of this method that doesn't return a value.
  ///
  /// - Parameters:
  ///   - name: A value in "module:mutation_name"  format that will be used when calling the backend
  ///   - args: An optional ``Dictionary`` of arguments to be sent to the backend mutation function
  public func action<T: Decodable>(_ name: String, with args: [String: ConvexEncodable?]? = nil)
    async throws -> T
  {
    return try await callForResult(name: name, args: args, remoteCall: ffiClient.action)
  }

  /// Executes the action with the given `name` and `args` without returning a result.
  ///
  /// For actions that return a value, prefer calling the version of this method that returns a ``Decodable`` value.
  ///
  /// - Parameters:
  ///   - name: A value in "module:mutation_name"  format that will be used when calling the backend
  ///   - args: An optional ``Dictionary`` of arguments to be sent to the backend mutation function
  public func action(_ name: String, with args: [String: ConvexEncodable?]? = nil)
    async throws
  {
    let _: String? = try await action(name, with: args)
  }

  /// Common handler for `action` and `mutation` calls.
  ///
  /// To the client code, both work in a very similar fashion where remote code is invoked and a result is returned. This handler takes care of
  /// encoding the arguments and decoding the result, whether the call is an `action` or `mutation`.
  func callForResult<T: Decodable>(
    name: String, args: [String: ConvexEncodable?]? = nil, remoteCall: RemoteCall
  )
    async throws -> T
  {
    let rawResult = try await remoteCall(
      name,
      args?.mapValues({ v in
        try v?.convexEncode() ?? "null"
      }) ?? [:])
    return try JSONDecoder().decode(T.self, from: Data(rawResult.utf8))
  }

  typealias RemoteCall = (String, [String: String]) async throws -> String
  
  public func watchWebSocketState() -> AnyPublisher<WebSocketState, Never> {
    return webSocketStateAdapter.newPublisher()
  }
}

/// Authentication states that can be experienced when using an ``AuthProvider`` with
/// ``ConvexClientWithAuth``.
public enum AuthState<T> {
  /// Represents an authenticated user.
  ///
  /// Contains authentication data from the associated ``AuthProvider``.
  case authenticated(T)
  /// Represents an unauthenticated user.
  case unauthenticated
  /// Represents an ongoing authentication attempt.
  case loading
}

/// An authentication provider, used with ``ConvexClientWithAuth``.
///
/// The generic type `T` is the data returned by the provider upon a successful authentication attempt.
public protocol AuthProvider<T> {
  associatedtype T

  /// Trigger a login flow, which might launch a new UI/screen.
  ///
  /// - Parameter onIdToken: A callback to invoke with a fresh JWT ID token. The auth provider should store
  ///   this callback and invoke it whenever a new token is available (e.g., on token refresh).
  ///   Call with `nil` if the session becomes invalid (e.g., token refresh fails).
  func login(onIdToken: @Sendable @escaping (String?) -> Void) async throws -> T

  /// Trigger a logout flow, which might launch a new UI/screen.
  func logout() async throws

  /// Trigger a cached, UI-less re-authentication using stored credentials from a previous ``login()``.
  ///
  /// For OAuth providers, this is a good place to check token validity and perform a refresh if necessary
  /// before returning the auth data as``T``.
  ///
  /// - Parameter onIdToken: A callback to invoke with a fresh JWT ID token. The auth provider should store
  ///   this callback and invoke it whenever a new token is available (e.g., on token refresh).
  ///   Call with `nil` if the session becomes invalid (e.g., token refresh fails).
  func loginFromCache(onIdToken: @Sendable @escaping (String?) -> Void)
    async throws -> T

  /// Extracts a [JWT ID token](https://openid.net/specs/openid-connect-core-1_0.html#IDToken)
  /// from the `authResult`.
  func extractIdToken(from authResult: T) -> String
}

/// A bridge that adapts the push-based `onIdToken` model to the pull-based `AuthTokenProvider`
/// callback model used by the Rust client.
///
/// Caches the latest pushed token so that the Rust client can pull it if needed.
private actor AuthTokenProviderBridge: AuthTokenProvider {
  private var cachedToken: String?
  private var getValidToken: () async throws -> String?

  init(token: String?, getValidToken: @escaping () async throws -> String?) {
    self.cachedToken = token
    self.getValidToken = getValidToken
  }

  func fetchToken(forceRefresh: Bool) async throws -> String? {
    // Note: it's actually not required to treat this as a "force refresh". The
    // `getValidToken` function just needs to ensure that it's valid, which means
    // it can be an existing token that was previously cached elsewhere by the
    // `AuthProvider`.
    if forceRefresh, let freshToken = try? await getValidToken() {
      cachedToken = freshToken
    }
    return cachedToken
  }

  func updateToken(_ token: String?) {
    cachedToken = token
  }
}

/// Like ``ConvexClient``, but supports integration with an authentication provider via ``AuthProvider``.
///
/// The generic parameter `T` matches the type of data returned by the ``AuthProvider`` upon successful
/// authentication.
public class ConvexClientWithAuth<T>: ConvexClient {
  private let authPublisher = CurrentValueSubject<AuthState<T>, Never>(AuthState.unauthenticated)
  private let authProvider: any AuthProvider<T>
  private var authBridge: AuthTokenProviderBridge?

  /// A publisher that updates with the current ``AuthState`` of this client instance.
  public let authState: AnyPublisher<AuthState<T>, Never>

  /// Creates a new instance of ``ConvexClientWithAuth``.
  ///
  /// - Parameters:
  ///   - deploymentUrl: The Convex backend URL to connect to; find it in the [dashboard](https://dashboard.convex.dev) Settings for your project
  ///   - authProvider: An instance that will handle the actual authentication duties.
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

  /// Triggers a UI driven login flow and updates the ``authState``.
  ///
  /// The ``authState`` is set to ``AuthState.loading`` immediately upon calling this method and
  /// will change to either ``AuthState.authenticated`` or ``AuthState.unauthenticated``
  /// depending on the result.
  public func login() async -> Result<T, Error> {
    await login(strategy: authProvider.login)
  }

  /// Triggers a cached, UI-less re-authentication flow using previously stored credentials and updates the
  /// ``authState``.
  ///
  /// If no credentials were previously stored, or if there is an error reusing stored credentials, the resulting
  /// ``authState`` willl be ``AuthState.unauthenticated``. If supported by the ``AuthProvider``,
  /// a call to ``login()`` should store another set of credentials upon successful authentication.
  ///
  /// The ``authState`` is set to ``AuthState.loading`` immediately upon calling this method and
  /// will change to either ``AuthState.authenticated`` or ``AuthState.unauthenticated``
  /// depending on the result.
  public func loginFromCache() async -> Result<T, Error> {
    await login(strategy: authProvider.loginFromCache)
  }

  /// Triggers a logout flow and updates the ``authState``.
  ///
  /// The ``authState`` will change to ``AuthState.unauthenticated`` if logout is successful.
  public func logout() async {
    do {
      try await authProvider.logout()
      authBridge = nil
      try await ffiClient.setAuthCallback(provider: nil)
      authPublisher.send(AuthState.unauthenticated)
    } catch {
      dump(error)
    }
  }

  private func login(strategy: LoginStrategy) async -> Result<T, Error> {
    authPublisher.send(AuthState.loading)
    do {
      let idTokenHandler = onIdTokenHandler()
      let authData = try await strategy(idTokenHandler)
      let token = authProvider.extractIdToken(from: authData)
      let bridge = AuthTokenProviderBridge(
        token: token,
        getValidToken: {
          [authProvider, idTokenHandler] in
          let refreshData = try await authProvider.loginFromCache(
            onIdToken: idTokenHandler
          )
          return authProvider.extractIdToken(from: refreshData)
        }
      )
      authBridge = bridge
      try await ffiClient.setAuthCallback(provider: bridge)
      authPublisher.send(AuthState.authenticated(authData))
      return Result.success(authData)
    } catch {
      dump(error)
      authPublisher.send(AuthState.unauthenticated)
      return Result.failure(error)
    }
  }

  /// Creates a sendable handler for token updates from the auth provider.
  ///
  /// This handler is passed to the auth provider during login and should be called
  /// whenever a fresh token is available or when the session becomes invalid.
  private func onIdTokenHandler() -> @Sendable (String?) -> Void {
    { [ffiClient, authPublisher, weak self] token in
      Task {
        do {
          if let token {
            await self?.authBridge?.updateToken(token)
            if let bridge = self?.authBridge {
              try await ffiClient.setAuthCallback(provider: bridge)
            }
          } else {
            self?.authBridge = nil
            try await ffiClient.setAuthCallback(provider: nil)
            authPublisher.send(AuthState.unauthenticated)
          }
        } catch {
          dump(error)
          authPublisher.send(AuthState.unauthenticated)
        }
      }
    }
  }

  private typealias LoginStrategy = (@Sendable @escaping (String?) -> Void) async throws -> T
}

private class SubscriptionAdapter<T: Decodable>: QuerySubscriber {
  typealias Publisher = PassthroughSubject<T, ClientError>

  let publisher: Publisher

  init(publisher: Publisher) {
    self.publisher = publisher
  }

  func onError(message: String, value: String?) {
    let err: ClientError
    if let value {
      err = ClientError.ConvexError(data: value)
    } else {
      err = ClientError.ServerError(msg: message)
    }
    publisher.send(
      completion: Subscribers.Completion.failure(err))
  }

  func onUpdate(value: String) {
    do {
      publisher.send(try JSONDecoder().decode(Publisher.Output.self, from: Data(value.utf8)))
    } catch {
      publisher.send(
        completion: .failure(ClientError.InternalError(msg: error.localizedDescription)))
    }
  }
}

private class WebSocketStateAdapter: WebSocketStateSubscriber {
  private let subject = PassthroughSubject<WebSocketState, Never>()
  
  init() { }

  func onStateChange(state: UniFFI.WebSocketState) {
    subject.send(state)
  }
  
  func newPublisher() -> AnyPublisher<WebSocketState, Never> {
    return subject.eraseToAnyPublisher()
  }
}
