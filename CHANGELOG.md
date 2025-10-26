# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [0.6.1] - 2025-10-26

### Fixed
- **Token Refresh Stability**: Fixed users being logged out after network reconnections
  - Added retry logic with exponential backoff (3 retries: 2s, 4s, 8s delays)
  - Smart error classification distinguishes transient network errors from permanent auth failures
  - Network-aware delay (3 seconds) after reconnection prevents TLS handshake failures
  - Prevents concurrent refresh attempts with lock mechanism
  - Transient errors (TLS -1200/-9816, timeouts, connection failures) now trigger automatic retry
  - Permanent errors (invalid credentials, expired tokens) immediately logout as before

### Changed
- `TokenRefreshManager` now includes `maxRetries` and `baseRetryDelay` configuration options
  - Default: 3 retries with 2-second base delay (exponential backoff)
  - Configurable for different use cases and network conditions

### Technical Details
- **Error Classification**: New `isTransientError()` method identifies retryable network issues
- **Network Stabilization**: 3-second delay before refresh when token expires during network reconnection
- **Exponential Backoff**: Retry delays increase as 2s → 4s → 8s for better recovery
- **Concurrency Safety**: `isRefreshing` flag prevents duplicate refresh attempts
- **Debug Logging**: Enhanced logs show retry attempts, error types, and delays

## [0.6.0] - 2025-10-25

### Added
- **Automatic JWT Token Refresh**: `ConvexClientWithAuth` now automatically refreshes JWT tokens before they expire
  - `TokenRefreshManager` monitors token expiration and refreshes 60 seconds before expiry
  - Proactive approach prevents authentication errors in long-running apps
  - Uses reliable Timer-based scheduling (fixes iOS Simulator Task.sleep issues)
- **AuthProviderError** enum for standardized authentication errors
  - `refreshNotSupported` - provider doesn't support token refresh (default)
  - `tokenExpired` - token has expired and cannot be refreshed
  - `refreshFailed(Error)` - token refresh failed with underlying error
- **Default implementation** for `AuthProvider.refreshToken(from:)`
  - Non-breaking change - existing providers continue to work
  - Override to enable automatic token refresh for your provider
  - See documentation for implementation examples

### Changed
- `AuthProvider` protocol now includes `refreshToken(from:)` method
  - Default implementation throws `AuthProviderError.refreshNotSupported`
  - Non-breaking: providers without refresh support continue to work normally
  - Providers can opt-in to automatic refresh by implementing this method

### Fixed
- Token expiration causing unexpected logouts in long-running apps
- iOS Simulator reliability issues with long-duration Task.sleep
- Users no longer need to re-authenticate after token expiry

### Migration Guide

**No changes required** for existing `AuthProvider` implementations. Apps will continue to work as before.

To enable automatic token refresh, implement the `refreshToken(from:)` method:

```swift
extension MyAuthProvider {
  public func refreshToken(from authResult: Credentials) async throws -> Credentials {
    // Call your refresh endpoint
    guard let refreshToken = authResult.refreshToken else {
      throw AuthProviderError.tokenExpired
    }
    return try await myAPI.refreshToken(refreshToken)
  }
}
```

## [0.5.6] - Previous Release

See git history for previous changes.
