//
//  OptimisticUpdates.swift
//  ConvexMobile
//
//  Created by Claude Code
//  Copyright © 2025 Convex, Inc. All rights reserved.
//

import Foundation

/// Protocol for accessing and modifying query results during optimistic updates.
///
/// An `OptimisticLocalStore` provides a view into the current query cache, allowing
/// mutation handlers to read existing query results and update them optimistically
/// before the server responds.
///
/// Example usage:
/// ```swift
/// try await client.mutation(
///     "messages:send",
///     with: ["text": "Hello"],
///     options: MutationOptions(
///         optimisticUpdate: { localStore in
///             // Read current messages
///             if let messages: [Message] = localStore.getQuery("messages:list") {
///                 // Add optimistic message
///                 let newMessage = Message(id: "temp-\(UUID())", text: "Hello")
///                 localStore.setQuery("messages:list", value: messages + [newMessage])
///             }
///         }
///     )
/// )
/// ```
public protocol OptimisticLocalStore {
    /// Retrieves the current result for a specific query.
    ///
    /// - Parameters:
    ///   - name: The query name in format "module:functionName"
    ///   - args: Optional query arguments
    /// - Returns: The decoded query result, or `nil` if the query is not subscribed or is loading
    func getQuery<T: Decodable>(_ name: String, with args: [String: ConvexEncodable?]?) -> T?

    /// Retrieves all variants of a query with different arguments.
    ///
    /// Useful for updating multiple pages of a paginated list or multiple filtered views.
    ///
    /// Example:
    /// ```swift
    /// // Get all pages of messages
    /// let allPages = localStore.getAllQueries("messages:list")
    /// for page in allPages {
    ///     if var messages = page.value as? [Message] {
    ///         messages.append(newMessage)
    ///         localStore.setQuery("messages:list", with: page.args, value: messages)
    ///     }
    /// }
    /// ```
    ///
    /// - Parameter name: The query name in format "module:functionName"
    /// - Returns: Array of (args, value) tuples for all subscribed variants of this query
    func getAllQueries<T: Decodable>(_ name: String) -> [(args: [String: ConvexEncodable?]?, value: T?)]

    /// Updates a query result optimistically.
    ///
    /// The update is immediately visible to all subscribers of this query.
    /// When the mutation completes, the optimistic update is automatically rolled back
    /// and replaced with the server's authoritative state.
    ///
    /// **Important:** Setting `value` to `nil` will make the query appear as "loading"
    /// to subscribers. This can be useful to show loading states during mutations.
    ///
    /// **Note:** Always create new arrays/objects instead of mutating existing values:
    /// ```swift
    /// // ✅ Correct: Create new array
    /// let updated = existing + [newItem]
    /// localStore.setQuery("messages:list", value: updated)
    ///
    /// // ❌ Wrong: Mutating existing array corrupts cache
    /// existing.append(newItem)
    /// localStore.setQuery("messages:list", value: existing)
    /// ```
    ///
    /// - Parameters:
    ///   - name: The query name in format "module:functionName"
    ///   - args: Optional query arguments (must match a subscribed query)
    ///   - value: The new query result, or `nil` to show loading state
    func setQuery<T: Encodable>(_ name: String, with args: [String: ConvexEncodable?]?, value: T?)
}

/// Options for customizing mutation behavior.
public struct MutationOptions {
    /// Optional closure to perform optimistic updates before the mutation completes.
    ///
    /// The closure receives an `OptimisticLocalStore` that can be used to read and modify
    /// query results. Changes are immediately visible to all subscribers.
    ///
    /// When the mutation completes (success or failure), the optimistic update is
    /// automatically rolled back and replaced with the server's state.
    ///
    /// **Important:** The closure must be synchronous. Do not use `await` or perform
    /// async operations inside the optimistic update.
    ///
    /// Example:
    /// ```swift
    /// MutationOptions(
    ///     optimisticUpdate: { localStore in
    ///         if let todos: [Todo] = localStore.getQuery("todos:list") {
    ///             let newTodo = Todo(id: "temp", text: "New item", done: false)
    ///             localStore.setQuery("todos:list", value: todos + [newTodo])
    ///         }
    ///     }
    /// )
    /// ```
    public let optimisticUpdate: ((OptimisticLocalStore) -> Void)?

    /// Creates mutation options with an optional optimistic update.
    ///
    /// - Parameter optimisticUpdate: Closure to perform optimistic updates
    public init(optimisticUpdate: ((OptimisticLocalStore) -> Void)? = nil) {
        self.optimisticUpdate = optimisticUpdate
    }
}

/// Type alias for the optimistic update closure.
///
/// - Parameter localStore: Store for reading and modifying query results
public typealias OptimisticUpdate = (OptimisticLocalStore) -> Void
