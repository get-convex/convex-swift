// The Swift Programming Language
// https://docs.swift.org/swift-book

import Combine
import Foundation
@_exported import UniFFI

// MARK: - JWT Helper

/// Helper struct to decode JWT tokens and extract expiration information
private struct JWTDecoder {
  /// Decodes a JWT token and returns the expiration date if available
  static func extractExpiration(from token: String) -> Date? {
    let segments = token.components(separatedBy: ".")
    guard segments.count >= 2 else {
      return nil
    }

    let payloadSegment = segments[1]
    // Add padding if needed for base64 decoding
    var base64 = payloadSegment
      .replacingOccurrences(of: "-", with: "+")
      .replacingOccurrences(of: "_", with: "/")

    let paddingLength = (4 - base64.count % 4) % 4
    base64 += String(repeating: "=", count: paddingLength)

    guard let payloadData = Data(base64Encoded: base64),
          let json = try? JSONSerialization.jsonObject(with: payloadData) as? [String: Any],
          let exp = json["exp"] as? TimeInterval else {
      return nil
    }

    return Date(timeIntervalSince1970: exp)
  }
}

// MARK: - Token Refresh Manager

/// Manages automatic token refresh for authenticated Convex clients.
///
/// This class monitors JWT token expiration and automatically refreshes tokens
/// before they expire, preventing authentication errors.
class TokenRefreshManager<T> {
  private let authProvider: any AuthProvider<T>
  private let onTokenRefreshed: (String) async throws -> Void
  private let onRefreshFailed: (Error) -> Void
  private var refreshTimer: AnyCancellable?
  private var currentAuthData: T?
  private let refreshLeewaySeconds: TimeInterval
  private let maxRetries: Int
  private let baseRetryDelay: TimeInterval
  private var isRefreshing = false

  /// Creates a new token refresh manager.
  ///
  /// - Parameters:
  ///   - authProvider: The authentication provider to use for token refresh
  ///   - refreshLeewaySeconds: How many seconds before expiration to refresh the token (default: 60)
  ///   - onTokenRefreshed: Callback when a new token is available
  ///   - onRefreshFailed: Callback when token refresh fails
  ///   - maxRetries: Maximum number of retry attempts for transient errors (default: 3)
  ///   - baseRetryDelay: Base delay between retries in seconds (default: 2, uses exponential backoff)
  init(
    authProvider: any AuthProvider<T>,
    refreshLeewaySeconds: TimeInterval = 60,
    onTokenRefreshed: @escaping (String) async throws -> Void,
    onRefreshFailed: @escaping (Error) -> Void,
    maxRetries: Int = 3,
    baseRetryDelay: TimeInterval = 2
  ) {
    self.authProvider = authProvider
    self.refreshLeewaySeconds = refreshLeewaySeconds
    self.onTokenRefreshed = onTokenRefreshed
    self.onRefreshFailed = onRefreshFailed
    self.maxRetries = maxRetries
    self.baseRetryDelay = baseRetryDelay
  }

  /// Classifies errors as transient (retryable) or permanent (requires logout).
  ///
  /// Transient errors include network issues that may resolve on retry:
  /// - TLS errors (certificate validation, handshake failures)
  /// - Connection timeouts
  /// - Network unreachable
  ///
  /// Permanent errors include authentication failures:
  /// - Invalid credentials
  /// - Expired refresh tokens
  /// - Server rejections (401, 403)
  private func isTransientError(_ error: Error) -> Bool {
    let nsError = error as NSError

    // Network-related errors (NSURLErrorDomain)
    if nsError.domain == NSURLErrorDomain {
      switch nsError.code {
      case NSURLErrorTimedOut,
           NSURLErrorCannotConnectToHost,
           NSURLErrorNetworkConnectionLost,
           NSURLErrorNotConnectedToInternet,
           NSURLErrorSecureConnectionFailed,
           NSURLErrorServerCertificateUntrusted,
           NSURLErrorServerCertificateHasUnknownRoot,
           NSURLErrorServerCertificateNotYetValid,
           -1200:  // SSL/TLS error
        return true
      default:
        return false
      }
    }

    // Check for kCFErrorDomainCFNetwork errors (TLS errors)
    if nsError.domain == "kCFErrorDomainCFNetwork" || nsError.domain == String(kCFErrorDomainCFNetwork) {
      // TLS/SSL errors like -9816, -9819, etc.
      return abs(nsError.code) >= 9800 && abs(nsError.code) <= 9900
    }

    // Authentication-specific errors should NOT be retried
    // These are handled by checking the error type in performRefresh
    return false
  }

  /// Starts monitoring the token for expiration and scheduling refresh.
  ///
  /// - Parameter authData: The current authentication data containing the token
  func startMonitoring(authData: T) {
    stopMonitoring()
    currentAuthData = authData

    let token = authProvider.extractIdToken(from: authData)
    guard let expirationDate = JWTDecoder.extractExpiration(from: token) else {
      #if DEBUG
      print("[TokenRefresh] ⚠️ Cannot monitor token - no expiration date found")
      #endif
      return
    }

    let timeUntilExpiration = expirationDate.timeIntervalSinceNow
    let timeUntilRefresh = max(0, timeUntilExpiration - refreshLeewaySeconds)

    #if DEBUG
    print("[TokenRefresh] Token expires in \(Int(timeUntilExpiration))s, will refresh in \(Int(timeUntilRefresh))s")
    #endif

    if timeUntilRefresh <= 0 {
      // Token already expired or about to expire
      // Add a delay to allow network to stabilize after reconnection
      // This prevents TLS errors when refreshing immediately after network comes back
      let networkStabilizationDelay: TimeInterval = 3.0

      #if DEBUG
      print("[TokenRefresh] Token expired/expiring, waiting \(Int(networkStabilizationDelay))s for network to stabilize...")
      #endif

      Task { [weak self] in
        try? await Task.sleep(nanoseconds: UInt64(networkStabilizationDelay * 1_000_000_000))
        await self?.performRefreshWithRetry()
      }
      return
    }

    // Use Timer instead of Task.sleep for reliability in iOS Simulator
    refreshTimer = Timer.publish(every: timeUntilRefresh, on: .main, in: .common)
      .autoconnect()
      .first()
      .sink { [weak self] _ in
        Task {
          await self?.performRefreshWithRetry()
        }
      }
  }

  /// Stops monitoring and cancels any pending refresh.
  func stopMonitoring() {
    refreshTimer?.cancel()
    refreshTimer = nil
    currentAuthData = nil
    isRefreshing = false
  }

  /// Performs token refresh with automatic retry for transient errors.
  ///
  /// This method implements an exponential backoff retry strategy for transient network errors
  /// while immediately failing for permanent authentication errors.
  private func performRefreshWithRetry(retryAttempt: Int = 0) async {
    guard let authData = currentAuthData else {
      return
    }

    // Prevent concurrent refresh attempts
    guard !isRefreshing else {
      #if DEBUG
      print("[TokenRefresh] ⚠️ Refresh already in progress, skipping")
      #endif
      return
    }

    isRefreshing = true
    defer { isRefreshing = false }

    do {
      let newAuthData = try await authProvider.refreshToken(from: authData)
      let newToken = authProvider.extractIdToken(from: newAuthData)

      // Update the stored auth data
      currentAuthData = newAuthData

      // Notify the client about the new token
      try await onTokenRefreshed(newToken)

      #if DEBUG
      print("[TokenRefresh] ✅ Token refreshed successfully" + (retryAttempt > 0 ? " (after \(retryAttempt) retries)" : ""))
      #endif

      // Schedule next refresh
      startMonitoring(authData: newAuthData)
    } catch AuthProviderError.refreshNotSupported {
      // Provider doesn't support refresh - this is okay, don't retry
      #if DEBUG
      print("[TokenRefresh] ℹ️ Provider doesn't support token refresh")
      #endif
    } catch {
      let isTransient = isTransientError(error)

      #if DEBUG
      print("[TokenRefresh] ❌ Token refresh failed (\(isTransient ? "transient" : "permanent") error): \(error)")
      #endif

      // Retry transient errors with exponential backoff
      if isTransient && retryAttempt < maxRetries {
        let delay = baseRetryDelay * pow(2.0, Double(retryAttempt))

        #if DEBUG
        print("[TokenRefresh] 🔄 Retrying in \(Int(delay))s (attempt \(retryAttempt + 1)/\(maxRetries))...")
        #endif

        isRefreshing = false  // Allow retry
        try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))

        await performRefreshWithRetry(retryAttempt: retryAttempt + 1)
      } else {
        // Permanent error or max retries exceeded - notify failure
        if retryAttempt >= maxRetries {
          #if DEBUG
          print("[TokenRefresh] ❌ Max retries (\(maxRetries)) exceeded, logging out user")
          #endif
        } else {
          #if DEBUG
          print("[TokenRefresh] ❌ Permanent authentication error, logging out user")
          #endif
        }
        onRefreshFailed(error)
      }
    }
  }
}

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

  /// Creates a new instance of ``ConvexClient``.
  ///
  /// - Parameters:
  ///   - deploymentUrl: The Convex backend URL to connect to; find it in the [dashboard](https://dashboard.convex.dev) Settings for your project
  public init(deploymentUrl: String) {
    self.ffiClient = UniFFI.MobileConvexClient(
      deploymentUrl: deploymentUrl, clientId: "swift-\(convexMobileVersion)")
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

    // This Publisher will ultimated publish the data received from Convex.
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
    return try! JSONDecoder().decode(T.self, from: Data(rawResult.utf8))
  }

  typealias RemoteCall = (String, [String: String]) async throws -> String
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

/// Errors that can occur during authentication operations.
public enum AuthProviderError: Error {
  /// The authentication provider does not support token refresh.
  ///
  /// This is thrown by the default implementation of ``AuthProvider/refreshToken(from:)``.
  /// Providers that support token refresh should override this method.
  case refreshNotSupported

  /// The token has expired and cannot be refreshed.
  case tokenExpired

  /// Token refresh failed with an underlying error.
  case refreshFailed(Error)
}

/// An authentication provider, used with ``ConvexClientWithAuth``.
///
/// The generic type `T` is the data returned by the provider upon a successful authentication attempt.
public protocol AuthProvider<T> {
  associatedtype T

  /// Trigger a login flow, which might launch a new UI/screen.
  func login() async throws -> T
  /// Trigger a logout flow, which might launch a new UI/screen.
  func logout() async throws
  /// Trigger a cached, UI-less re-authentication ussing stored credentials from a previous ``login()``.
  func loginFromCache() async throws -> T
  /// Extracts a [JWT ID token](https://openid.net/specs/openid-connect-core-1_0.html#IDToken)
  /// from the `authResult`.
  func extractIdToken(from authResult: T) -> String
  /// Refreshes the authentication data to obtain a new token.
  ///
  /// This method is called automatically by the client when the current token is about to expire.
  /// The default implementation throws ``AuthProviderError/refreshNotSupported``.
  ///
  /// Override this method if your authentication provider supports token refresh.
  ///
  /// - Parameter authResult: The current authentication data.
  /// - Returns: New authentication data with a fresh token.
  /// - Throws: ``AuthProviderError/refreshNotSupported`` by default, or other errors during refresh.
  func refreshToken(from authResult: T) async throws -> T
}

/// Default implementation of ``AuthProvider`` optional methods.
extension AuthProvider {
  /// Default implementation that throws ``AuthProviderError/refreshNotSupported``.
  ///
  /// Override this method in your AuthProvider implementation to enable automatic token refresh.
  ///
  /// Example:
  /// ```swift
  /// extension MyAuthProvider {
  ///   public func refreshToken(from authResult: Credentials) async throws -> Credentials {
  ///     // Call your refresh endpoint
  ///     return try await myAPI.refreshToken(authResult.refreshToken)
  ///   }
  /// }
  /// ```
  public func refreshToken(from authResult: T) async throws -> T {
    throw AuthProviderError.refreshNotSupported
  }
}

/// Like ``ConvexClient``, but supports integration with an authentication provider via ``AuthProvider``.
///
/// The generic parameter `T` matches the type of data returned by the ``AuthProvider`` upon successful
/// authentication.
public class ConvexClientWithAuth<T>: ConvexClient {
  private let authPublisher = CurrentValueSubject<AuthState<T>, Never>(AuthState.unauthenticated)
  private let authProvider: any AuthProvider<T>
  private var tokenRefreshManager: TokenRefreshManager<T>?

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
    setupTokenRefreshManager()
  }

  init(ffiClient: MobileConvexClientProtocol, authProvider: any AuthProvider<T>) {
    self.authProvider = authProvider
    self.authState = authPublisher.eraseToAnyPublisher()
    super.init(ffiClient: ffiClient)
    setupTokenRefreshManager()
  }

  private func setupTokenRefreshManager() {
    tokenRefreshManager = TokenRefreshManager(
      authProvider: authProvider,
      refreshLeewaySeconds: 60,
      onTokenRefreshed: { [weak self] newToken in
        guard let self = self else { return }
        try await self.ffiClient.setAuth(token: newToken)
      },
      onRefreshFailed: { [weak self] error in
        guard let self = self else { return }
        #if DEBUG
        print("[TokenRefresh] ❌ Token refresh failed, logging out user: \(error)")
        #endif
        // Token refresh failed, log the user out
        Task {
          await self.logout()
        }
      }
    )
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
    #if DEBUG
    print("[ConvexClient] 🚪 Logging out...")
    #endif

    // Stop token refresh monitoring
    tokenRefreshManager?.stopMonitoring()

    do {
      try await authProvider.logout()
      try await ffiClient.setAuth(token: nil)
      authPublisher.send(AuthState.unauthenticated)

      #if DEBUG
      print("[ConvexClient] ✅ Logout successful")
      #endif
    } catch {
      #if DEBUG
      print("[ConvexClient] ❌ Logout failed: \(error)")
      #endif
      dump(error)
    }
  }

  private func login(strategy: LoginStrategy) async -> Result<T, Error> {
    authPublisher.send(AuthState.loading)
    do {
      let authData = try await strategy()

      #if DEBUG
      print("[ConvexClient] 🔐 Login successful, setting auth...")
      #endif

      try await ffiClient.setAuth(token: authProvider.extractIdToken(from: authData))

      #if DEBUG
      print("[ConvexClient] 🚀 Starting automatic token refresh monitoring...")
      #endif

      // Start monitoring token expiration for automatic refresh
      tokenRefreshManager?.startMonitoring(authData: authData)

      authPublisher.send(AuthState.authenticated(authData))
      return Result.success(authData)
    } catch {
      dump(error)
      authPublisher.send(AuthState.unauthenticated)
      return Result.failure(error)
    }
  }

  private typealias LoginStrategy = () async throws -> T
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
    publisher.send(try! JSONDecoder().decode(Publisher.Output.self, from: Data(value.utf8)))
  }

}
