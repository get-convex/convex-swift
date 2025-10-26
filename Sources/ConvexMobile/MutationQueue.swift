//
//  MutationQueue.swift
//  ConvexMobile
//
//  Created by Claude Code
//  Copyright © 2025 Convex, Inc. All rights reserved.
//

import Foundation

/// Represents a queued mutation waiting to be sent to the server.
struct QueuedMutation: Codable {
    let id: UUID
    let name: String
    let args: [String: String]?  // Pre-encoded args
    let timestamp: Date
    let optimisticUpdate: String?  // Serialized closure (not supported, placeholder for future)

    init(id: UUID = UUID(), name: String, args: [String: String]?, timestamp: Date = Date()) {
        self.id = id
        self.name = name
        self.args = args
        self.timestamp = timestamp
        self.optimisticUpdate = nil
    }
}

/// Manages a queue of mutations for offline support.
///
/// When the network is unavailable, mutations can be queued and automatically
/// retried when connectivity is restored. The queue can optionally persist
/// mutations to disk for reliability across app restarts.
final class MutationQueue {
    // Thread safety
    private let queue = DispatchQueue(label: "com.convex.mutationQueue", attributes: .concurrent)

    // In-memory queue
    private var pendingMutations: [QueuedMutation] = []

    // Persistence key
    private let persistenceKey = "com.convex.mutationQueue.pending"

    // Processing state
    private var isProcessing = false

    // Configuration
    private let shouldPersist: Bool
    private let maxQueueSize: Int

    /// Creates a new mutation queue.
    ///
    /// - Parameters:
    ///   - shouldPersist: Whether to persist the queue to UserDefaults (default: true)
    ///   - maxQueueSize: Maximum number of mutations to queue (default: 100)
    init(shouldPersist: Bool = true, maxQueueSize: Int = 100) {
        self.shouldPersist = shouldPersist
        self.maxQueueSize = maxQueueSize

        if shouldPersist {
            loadFromPersistence()
        }
    }

    /// Enqueues a mutation to be sent later.
    ///
    /// - Parameters:
    ///   - name: The mutation name
    ///   - args: The encoded mutation arguments
    /// - Returns: The queued mutation ID
    func enqueue(name: String, args: [String: String]?) -> UUID {
        queue.sync(flags: .barrier) {
            let mutation = QueuedMutation(name: name, args: args)
            pendingMutations.append(mutation)

            // Enforce max queue size
            if pendingMutations.count > maxQueueSize {
                #if DEBUG
                print("[MutationQueue] ⚠️ Queue size exceeded, dropping oldest mutation")
                #endif
                pendingMutations.removeFirst()
            }

            if shouldPersist {
                saveToPersistence()
            }

            #if DEBUG
            print("[MutationQueue] ✅ Enqueued mutation '\(name)' (queue size: \(pendingMutations.count))")
            #endif

            return mutation.id
        }
    }

    /// Processes all pending mutations.
    ///
    /// This method attempts to send all queued mutations to the server.
    /// Failed mutations remain in the queue for retry.
    ///
    /// - Parameter executor: Closure that executes a mutation and returns success/failure
    func processQueue(executor: @escaping (String, [String: String]?) async throws -> Void) async {
        // Prevent concurrent processing
        let shouldProcess = queue.sync(flags: .barrier) { () -> Bool in
            guard !isProcessing else { return false }
            isProcessing = true
            return true
        }

        guard shouldProcess else {
            #if DEBUG
            print("[MutationQueue] ℹ️ Already processing queue, skipping")
            #endif
            return
        }

        defer {
            queue.sync(flags: .barrier) {
                isProcessing = false
            }
        }

        #if DEBUG
        let queueSize = queue.sync { pendingMutations.count }
        print("[MutationQueue] 🔄 Processing \(queueSize) pending mutation(s)...")
        #endif

        var processedMutations: [UUID] = []

        // Get snapshot of current queue
        let mutations = queue.sync { pendingMutations }

        for mutation in mutations {
            do {
                // Try to execute the mutation
                try await executor(mutation.name, mutation.args)

                // Success - mark for removal
                processedMutations.append(mutation.id)

                #if DEBUG
                print("[MutationQueue] ✅ Executed queued mutation '\(mutation.name)'")
                #endif
            } catch {
                // Failed - leave in queue for retry
                #if DEBUG
                print("[MutationQueue] ❌ Failed to execute '\(mutation.name)': \(error)")
                #endif
            }
        }

        // Remove successfully processed mutations
        if !processedMutations.isEmpty {
            queue.sync(flags: .barrier) {
                pendingMutations.removeAll { processedMutations.contains($0.id) }

                if shouldPersist {
                    saveToPersistence()
                }

                #if DEBUG
                print("[MutationQueue] 🎉 Processed \(processedMutations.count) mutation(s), \(pendingMutations.count) remaining")
                #endif
            }
        }
    }

    /// Returns the number of pending mutations.
    var count: Int {
        queue.sync { pendingMutations.count }
    }

    /// Returns whether the queue is empty.
    var isEmpty: Bool {
        queue.sync { pendingMutations.isEmpty }
    }

    /// Clears all pending mutations.
    func clear() {
        queue.sync(flags: .barrier) {
            pendingMutations.removeAll()

            if shouldPersist {
                UserDefaults.standard.removeObject(forKey: persistenceKey)
            }

            #if DEBUG
            print("[MutationQueue] 🗑️ Queue cleared")
            #endif
        }
    }

    // MARK: - Persistence

    private func saveToPersistence() {
        guard let data = try? JSONEncoder().encode(pendingMutations) else {
            #if DEBUG
            print("[MutationQueue] ⚠️ Failed to encode queue for persistence")
            #endif
            return
        }

        UserDefaults.standard.set(data, forKey: persistenceKey)

        #if DEBUG
        print("[MutationQueue] 💾 Saved queue to persistence (\(pendingMutations.count) mutations)")
        #endif
    }

    private func loadFromPersistence() {
        guard let data = UserDefaults.standard.data(forKey: persistenceKey),
              let mutations = try? JSONDecoder().decode([QueuedMutation].self, from: data) else {
            return
        }

        pendingMutations = mutations

        #if DEBUG
        print("[MutationQueue] 📂 Loaded \(mutations.count) mutation(s) from persistence")
        #endif
    }
}
