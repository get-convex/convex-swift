//
//  OptimisticQueryCache.swift
//  ConvexMobile
//
//  Created by Claude Code
//  Copyright © 2025 Convex, Inc. All rights reserved.
//

import Foundation
import Combine

/// Type alias for mutation request IDs.
typealias MutationID = Int64

/// A unique identifier for a query based on its name and arguments.
///
/// Two queries with the same name and arguments will have the same token,
/// allowing the cache to identify when optimistic updates should affect the same query.
struct QueryToken: Hashable, CustomStringConvertible {
    let name: String
    let args: [String: ConvexEncodable?]?

    var description: String {
        if let args = args, !args.isEmpty {
            // Create stable JSON representation for args
            let sortedKeys = args.keys.sorted()
            let argsStr = sortedKeys.compactMap { key in
                guard let value = args[key] else { return "\"\(key)\":null" }
                if let encoded = try? value?.convexEncode() {
                    return "\"\(key)\":\(encoded)"
                }
                return nil
            }.joined(separator: ",")
            return "\(name)#{\(argsStr)}"
        } else {
            return "\(name)#{}"
        }
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(description)
    }

    static func == (lhs: QueryToken, rhs: QueryToken) -> Bool {
        lhs.description == rhs.description
    }
}

/// Represents a cached query result with type-erased value.
struct QueryResult {
    let name: String
    let args: [String: ConvexEncodable?]?

    /// The query result value. `nil` represents a loading state.
    /// Stored as JSON string for type safety and serialization.
    let jsonValue: String?

    init(name: String, args: [String: ConvexEncodable?]?, jsonValue: String?) {
        self.name = name
        self.args = args
        self.jsonValue = jsonValue
    }
}

/// An optimistic update entry in the pending updates stack.
struct OptimisticUpdateEntry {
    let mutationID: MutationID
    let update: OptimisticUpdate
}

/// Thread-safe cache for query results with optimistic update support.
///
/// This cache maintains:
/// 1. Server query results (authoritative state)
/// 2. A stack of pending optimistic updates
/// 3. The current combined state (server + optimistic updates)
///
/// When mutations complete, their optimistic updates are removed and remaining
/// updates are replayed on top of the new server state.
final class OptimisticQueryCache {
    // Thread safety
    private let queue = DispatchQueue(label: "com.convex.optimisticCache", attributes: .concurrent)

    // Server state (authoritative)
    private var serverQueryResults: [QueryToken: QueryResult] = [:]

    // Combined state (server + optimistic updates)
    private var queryResults: [QueryToken: QueryResult] = [:]

    // Stack of pending optimistic updates
    private var pendingUpdates: [OptimisticUpdateEntry] = []

    // Mutation ID counter
    private var nextMutationID: MutationID = 0

    // MARK: - Public API

    /// Applies an optimistic update and returns the affected query tokens.
    ///
    /// - Parameter update: The optimistic update closure
    /// - Returns: Set of query tokens that were modified by this update
    func applyOptimisticUpdate(_ update: @escaping OptimisticUpdate) -> (mutationID: MutationID, changedQueries: Set<QueryToken>) {
        queue.sync(flags: .barrier) {
            let mutationID = self.nextMutationID
            self.nextMutationID += 1

            // Create local store implementation that tracks changes
            let localStore = OptimisticLocalStoreImpl(queryResults: &self.queryResults)

            // Apply the update
            update(localStore)

            // Track which mutation this update belongs to
            let entry = OptimisticUpdateEntry(mutationID: mutationID, update: update)
            self.pendingUpdates.append(entry)

            return (mutationID, localStore.modifiedQueries)
        }
    }

    /// Updates server query results and drops completed mutations' optimistic updates.
    ///
    /// Remaining optimistic updates are replayed on top of the new server state.
    ///
    /// - Parameters:
    ///   - serverResults: New authoritative query results from server
    ///   - completedMutations: Set of mutation IDs that have completed
    /// - Returns: Set of query tokens that changed
    func ingestServerResults(
        _ serverResults: [QueryToken: QueryResult],
        completedMutations: Set<MutationID>
    ) -> Set<QueryToken> {
        queue.sync(flags: .barrier) {
            // Update server state
            self.serverQueryResults = serverResults

            // Remove completed mutations from pending updates
            self.pendingUpdates.removeAll { completedMutations.contains($0.mutationID) }

            // Start with server state
            var newQueryResults = serverResults
            var allModifiedQueries = Set<QueryToken>()

            // Replay remaining optimistic updates
            for entry in self.pendingUpdates {
                let localStore = OptimisticLocalStoreImpl(queryResults: &newQueryResults)
                entry.update(localStore)
                allModifiedQueries.formUnion(localStore.modifiedQueries)
            }

            // Find what changed from old state to new state
            var changedQueries = Set<QueryToken>()

            // Check for added or modified queries
            for (token, newResult) in newQueryResults {
                if let oldResult = self.queryResults[token] {
                    // Query existed before - check if value changed
                    if newResult.jsonValue != oldResult.jsonValue {
                        changedQueries.insert(token)
                    }
                } else {
                    // New query
                    changedQueries.insert(token)
                }
            }

            // Check for removed queries
            for (token, _) in self.queryResults {
                if newQueryResults[token] == nil {
                    changedQueries.insert(token)
                }
            }

            self.queryResults = newQueryResults

            return changedQueries
        }
    }

    /// Retrieves the current result for a query, including optimistic updates.
    ///
    /// - Parameter token: The query token
    /// - Returns: The query result, or `nil` if not found
    func getQueryResult(_ token: QueryToken) -> QueryResult? {
        queue.sync {
            self.queryResults[token]
        }
    }

    /// Retrieves all queries with the given name.
    ///
    /// - Parameter name: The query name
    /// - Returns: Array of query results
    func getAllQueryResults(name: String) -> [QueryResult] {
        queue.sync {
            self.queryResults.values.filter { $0.name == name }
        }
    }

    /// Updates a server query result (e.g., when a new subscription arrives).
    ///
    /// - Parameters:
    ///   - token: The query token
    ///   - result: The new query result
    /// - Returns: True if the value changed
    func updateServerResult(_ token: QueryToken, result: QueryResult) -> Bool {
        queue.sync(flags: .barrier) {
            let oldValue = self.serverQueryResults[token]?.jsonValue
            self.serverQueryResults[token] = result

            // Recompute optimistic state
            var newQueryResults = self.serverQueryResults
            for entry in self.pendingUpdates {
                let localStore = OptimisticLocalStoreImpl(queryResults: &newQueryResults)
                entry.update(localStore)
            }

            let newValue = newQueryResults[token]?.jsonValue
            let changed = oldValue != newValue

            self.queryResults = newQueryResults

            return changed
        }
    }

    /// Clears all cached data.
    func clear() {
        queue.sync(flags: .barrier) {
            self.serverQueryResults.removeAll()
            self.queryResults.removeAll()
            self.pendingUpdates.removeAll()
        }
    }
}

// MARK: - OptimisticLocalStore Implementation

/// Internal implementation of OptimisticLocalStore that tracks modifications.
final class OptimisticLocalStoreImpl: OptimisticLocalStore {
    private var queryResults: UnsafeMutablePointer<[QueryToken: QueryResult]>
    private(set) var modifiedQueries: Set<QueryToken> = []

    init(queryResults: inout [QueryToken: QueryResult]) {
        self.queryResults = withUnsafeMutablePointer(to: &queryResults) { $0 }
    }

    func getQuery<T: Decodable>(_ name: String, with args: [String: ConvexEncodable?]? = nil) -> T? {
        let token = QueryToken(name: name, args: args)

        guard let result = queryResults.pointee[token],
              let jsonValue = result.jsonValue else {
            return nil
        }

        // Decode from JSON
        guard let data = jsonValue.data(using: .utf8) else {
            return nil
        }

        return try? JSONDecoder().decode(T.self, from: data)
    }

    func getAllQueries<T: Decodable>(_ name: String) -> [(args: [String: ConvexEncodable?]?, value: T?)] {
        let results = queryResults.pointee.values.filter { $0.name == name }

        return results.compactMap { result in
            let value: T?
            if let jsonValue = result.jsonValue,
               let data = jsonValue.data(using: .utf8) {
                value = try? JSONDecoder().decode(T.self, from: data)
            } else {
                value = nil
            }
            return (args: result.args, value: value)
        }
    }

    func setQuery<T: Encodable>(_ name: String, with args: [String: ConvexEncodable?]? = nil, value: T?) {
        let token = QueryToken(name: name, args: args)

        let jsonValue: String?
        if let value = value {
            // Encode to JSON
            if let data = try? JSONEncoder().encode(value),
               let string = String(data: data, encoding: .utf8) {
                jsonValue = string
            } else {
                // Encoding failed - treat as nil
                jsonValue = nil
            }
        } else {
            jsonValue = nil
        }

        let result = QueryResult(name: name, args: args, jsonValue: jsonValue)
        queryResults.pointee[token] = result
        modifiedQueries.insert(token)
    }
}
