// FILE: CodexDerivedCache.swift
// Purpose: Stores encrypted, Mac-scoped thread metadata and timeline items in an incremental SQLite cache.
// Layer: Service Persistence
// Exports: CodexDerivedCache, CodexDerivedCacheSyncState, CodexDerivedCacheUsage
// Depends on: CryptoKit, Foundation, GRDB, OSLog

import CryptoKit
import Foundation
import GRDB
import OSLog

nonisolated struct CodexDerivedCacheSyncState: Equatable, Sendable {
    let initialized: Bool
    let revision: Int64
    let acknowledgedRevision: Int64
}

nonisolated struct CodexDerivedCacheUsage: Equatable, Sendable {
    let usedBytes: Int64
    let limitBytes: Int64
    let protectedContentExceedsLimit: Bool
}

nonisolated final class CodexDerivedCache: @unchecked Sendable {
    static let shared = CodexDerivedCache()
    static let defaultLimitBytes: Int64 = 1_073_741_824
    static let initialItemLimit = 80

    private let queue: DatabaseQueue
    private let encoder: JSONEncoder
    private let decoder = JSONDecoder()
    private let encryptionKeyProvider: @Sendable () throws -> SymmetricKey
    private let stableIndexProvider: @Sendable (String) -> String
    private let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "cn.syggu.remodex",
        category: "derived-cache"
    )

    init(
        databaseURL: URL? = nil,
        encryptionKeyProvider: @escaping @Sendable () throws -> SymmetricKey = {
            CodexLocalPersistenceKeyProvider.historyKey()
        },
        stableIndexProvider: @escaping @Sendable (String) -> String = {
            CodexLocalPersistenceKeyProvider.stableIndex(for: $0)
        }
    ) {
        encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .millisecondsSince1970
        self.encryptionKeyProvider = encryptionKeyProvider
        self.stableIndexProvider = stableIndexProvider

        let databaseURL = databaseURL ?? Self.databaseURL()
        do {
            queue = try Self.openDatabase(at: databaseURL)
        } catch {
            Self.quarantineDatabase(at: databaseURL, reason: error)
            do {
                queue = try Self.openDatabase(at: databaseURL)
            } catch {
                fatalError("无法创建 Remodex 派生缓存：\(error.localizedDescription)")
            }
        }
    }

    func loadThreads(macDeviceId: String?) -> [CodexThread] {
        let macID = index(macDeviceId ?? "local")
        do {
            return try queue.read { db in
                let rows = try Row.fetchAll(
                    db,
                    sql: """
                    SELECT payload
                    FROM cache_thread
                    WHERE mac_id = ?
                    ORDER BY updated_at DESC, thread_id ASC
                    """,
                    arguments: [macID]
                )
                return rows.compactMap { row in
                    decode(CodexThread.self, encrypted: row["payload"])
                }
            }
        } catch {
            logger.error("读取任务目录缓存失败 mac=\(macID, privacy: .public) error=\(error.localizedDescription, privacy: .public)")
            return []
        }
    }

    func saveThreads(
        _ threads: [CodexThread],
        macDeviceId: String?,
        pinnedThreadIDs: Set<String> = [],
        activeThreadID: String? = nil
    ) {
        let macID = index(macDeviceId ?? "local")
        let now = Date().timeIntervalSince1970
        do {
            try queue.write { db in
                try writeThreads(
                    db,
                    threads: threads,
                    macID: macID,
                    pinnedThreadIDs: pinnedThreadIDs,
                    activeThreadID: activeThreadID,
                    deleteMissing: true,
                    now: now
                )
            }
            _ = pruneIfNeeded(limitBytes: Self.defaultLimitBytes)
        } catch {
            logger.error("写入任务目录缓存失败 mac=\(macID, privacy: .public) error=\(error.localizedDescription, privacy: .public)")
        }
    }

    func loadInitialMessages(macDeviceId: String?) -> [String: [CodexMessage]] {
        loadMessages(macDeviceId: macDeviceId, threadId: nil, activeOnly: true)
    }

    func loadMessages(threadId: String, macDeviceId: String?) -> [CodexMessage] {
        loadMessages(macDeviceId: macDeviceId, threadId: threadId, activeOnly: false)[threadId] ?? []
    }

    func loadAllMessages(macDeviceId: String?) -> [String: [CodexMessage]] {
        loadMessages(macDeviceId: macDeviceId, threadId: nil, activeOnly: false)
    }

    private func loadMessages(
        macDeviceId: String?,
        threadId: String?,
        activeOnly: Bool
    ) -> [String: [CodexMessage]] {
        let macID = index(macDeviceId ?? "local")
        do {
            return try queue.write { db in
                let filterSQL: String
                var arguments: StatementArguments = [macID]
                if let threadId {
                    filterSQL = "AND i.thread_id = ?"
                    arguments += [index(threadId)]
                } else if activeOnly {
                    filterSQL = "AND t.is_active = 1"
                } else {
                    filterSQL = ""
                }
                arguments += [Self.initialItemLimit]
                let rows = try Row.fetchAll(
                    db,
                    sql: """
                    WITH recent AS (
                        SELECT i.payload, i.thread_id, i.ordinal,
                               ROW_NUMBER() OVER (
                                   PARTITION BY i.thread_id
                                   ORDER BY i.ordinal DESC, i.item_id DESC
                               ) AS row_number
                        FROM cache_item i
                        JOIN cache_thread t
                          ON t.mac_id = i.mac_id AND t.thread_id = i.thread_id
                        WHERE i.mac_id = ?
                          \(filterSQL)
                    )
                    SELECT payload
                    FROM recent
                    WHERE row_number <= ?
                    ORDER BY thread_id ASC, ordinal ASC
                    """,
                    arguments: arguments
                )
                var result: [String: [CodexMessage]] = [:]
                for row in rows {
                    guard let message = decode(CodexMessage.self, encrypted: row["payload"]) else {
                        continue
                    }
                    result[message.threadId, default: []].append(message)
                }
                try db.execute(
                    sql: "UPDATE cache_mac SET last_access = ? WHERE mac_id = ?",
                    arguments: [Date().timeIntervalSince1970, macID]
                )
                if let threadId {
                    let threadID = index(threadId)
                    let now = Date().timeIntervalSince1970
                    try db.execute(
                        sql: "UPDATE cache_thread SET last_access = ? WHERE mac_id = ? AND thread_id = ?",
                        arguments: [now, macID, threadID]
                    )
                    try db.execute(
                        sql: "UPDATE cache_item SET last_access = ? WHERE mac_id = ? AND thread_id = ?",
                        arguments: [now, macID, threadID]
                    )
                }
                return result
            }
        } catch {
            logger.error("读取消息缓存失败 mac=\(macID, privacy: .public) error=\(error.localizedDescription, privacy: .public)")
            return [:]
        }
    }

    func saveMessages(_ messagesByThread: [String: [CodexMessage]], macDeviceId: String?) {
        let macID = index(macDeviceId ?? "local")
        let now = Date().timeIntervalSince1970
        do {
            try queue.write { db in
                try writeMessages(
                    db,
                    messagesByThread: messagesByThread,
                    macID: macID,
                    deleteMissingThreads: false,
                    replaceProvidedThreads: false,
                    now: now
                )
            }
            _ = pruneIfNeeded(limitBytes: Self.defaultLimitBytes)
        } catch {
            logger.error("写入消息缓存失败 mac=\(macID, privacy: .public) error=\(error.localizedDescription, privacy: .public)")
        }
    }

    func delete(macDeviceId: String?) {
        let macID = index(macDeviceId ?? "local")
        do {
            try queue.write { db in
                try db.execute(sql: "DELETE FROM cache_mac WHERE mac_id = ?", arguments: [macID])
            }
        } catch {
            logger.error("删除派生缓存失败 mac=\(macID, privacy: .public) error=\(error.localizedDescription, privacy: .public)")
        }
    }

    func deleteThreads(macDeviceId: String?) {
        deleteRows(in: "cache_thread", macDeviceId: macDeviceId)
    }

    func deleteMessages(macDeviceId: String?) {
        let macID = index(macDeviceId ?? "local")
        do {
            try queue.write { db in
                try db.execute(sql: "DELETE FROM cache_item WHERE mac_id = ?", arguments: [macID])
                try db.execute(sql: "DELETE FROM cache_turn WHERE mac_id = ?", arguments: [macID])
            }
        } catch {
            logger.error("删除消息派生缓存失败 mac=\(macID, privacy: .public) error=\(error.localizedDescription, privacy: .public)")
        }
    }

    func syncState(macDeviceId: String?, scope: String) -> CodexDerivedCacheSyncState {
        let macID = index(macDeviceId ?? "local")
        let scopeID = index(scope)
        do {
            return try queue.read { db in
                guard let row = try Row.fetchOne(
                    db,
                    sql: "SELECT revision, ack_revision FROM cache_sync_state WHERE mac_id = ? AND scope_id = ?",
                    arguments: [macID, scopeID]
                ) else {
                    return CodexDerivedCacheSyncState(initialized: false, revision: 0, acknowledgedRevision: 0)
                }
                return CodexDerivedCacheSyncState(
                    initialized: true,
                    revision: row["revision"],
                    acknowledgedRevision: row["ack_revision"]
                )
            }
        } catch {
            logger.error("读取同步游标失败 mac=\(macID, privacy: .public) scope=\(scopeID, privacy: .public) error=\(error.localizedDescription, privacy: .public)")
            return CodexDerivedCacheSyncState(initialized: false, revision: 0, acknowledgedRevision: 0)
        }
    }

    func commitSyncState(
        macDeviceId: String?,
        scope: String,
        revision: Int64,
        acknowledgedRevision: Int64
    ) throws {
        let macID = index(macDeviceId ?? "local")
        let scopeID = index(scope)
        try queue.write { db in
            try writeSyncState(
                db,
                macID: macID,
                scopeID: scopeID,
                revision: revision,
                acknowledgedRevision: acknowledgedRevision,
                now: Date().timeIntervalSince1970
            )
        }
    }

    func commitCatalogSnapshot(
        threads: [CodexThread],
        macDeviceId: String?,
        pinnedThreadIDs: Set<String>,
        activeThreadID: String?,
        revision: Int64,
        acknowledgedRevision: Int64
    ) throws {
        let macID = index(macDeviceId ?? "local")
        let now = Date().timeIntervalSince1970
        try queue.write { db in
            try ensureRevisionIsMonotonic(
                db,
                macID: macID,
                scopeID: index("catalog"),
                proposedRevision: revision
            )
            try writeThreads(
                db,
                threads: threads,
                macID: macID,
                pinnedThreadIDs: pinnedThreadIDs,
                activeThreadID: activeThreadID,
                deleteMissing: true,
                now: now
            )
            try writeSyncState(
                db,
                macID: macID,
                scopeID: index("catalog"),
                revision: revision,
                acknowledgedRevision: acknowledgedRevision,
                now: now
            )
        }
        _ = pruneIfNeeded(limitBytes: Self.defaultLimitBytes)
    }

    func commitThreadSnapshot(
        thread: CodexThread?,
        messages: [CodexMessage],
        threadId: String,
        macDeviceId: String?,
        isPinned: Bool,
        isActive: Bool,
        replaceMessages: Bool,
        revision: Int64,
        acknowledgedRevision: Int64
    ) throws {
        let macID = index(macDeviceId ?? "local")
        let now = Date().timeIntervalSince1970
        try queue.write { db in
            try ensureRevisionIsMonotonic(
                db,
                macID: macID,
                scopeID: index("thread:\(threadId)"),
                proposedRevision: revision
            )
            if let thread {
                try writeThreads(
                    db,
                    threads: [thread],
                    macID: macID,
                    pinnedThreadIDs: isPinned ? [threadId] : [],
                    activeThreadID: isActive ? threadId : nil,
                    deleteMissing: false,
                    now: now
                )
            }
            try writeMessages(
                db,
                messagesByThread: [threadId: messages],
                macID: macID,
                deleteMissingThreads: false,
                replaceProvidedThreads: replaceMessages,
                now: now
            )
            try writeSyncState(
                db,
                macID: macID,
                scopeID: index("thread:\(threadId)"),
                revision: revision,
                acknowledgedRevision: acknowledgedRevision,
                now: now
            )
        }
        _ = pruneIfNeeded(limitBytes: Self.defaultLimitBytes)
    }

    @discardableResult
    func pruneIfNeeded(limitBytes: Int64) -> CodexDerivedCacheUsage {
        do {
            return try queue.write { db in
                var usedBytes = try logicalDatabaseBytes(db)
                guard usedBytes > limitBytes else {
                    return CodexDerivedCacheUsage(
                        usedBytes: usedBytes,
                        limitBytes: limitBytes,
                        protectedContentExceedsLimit: false
                    )
                }

                let removableRows = try Row.fetchAll(
                    db,
                    sql: """
                    SELECT i.mac_id, i.thread_id, i.item_id, i.payload, i.has_attachment
                    FROM cache_item i
                    LEFT JOIN cache_thread t
                      ON t.mac_id = i.mac_id AND t.thread_id = i.thread_id
                    WHERE COALESCE(t.is_pinned, 0) = 0
                      AND COALESCE(t.is_active, 0) = 0
                      AND i.turn_id NOT IN (
                          SELECT turn_id FROM cache_turn rt
                          WHERE rt.mac_id = i.mac_id AND rt.thread_id = i.thread_id
                          ORDER BY rt.ordinal DESC LIMIT 5
                      )
                    ORDER BY i.has_attachment DESC, i.last_access ASC, i.updated_at ASC
                    """
                )

                for row in removableRows where usedBytes > limitBytes {
                    let macID: String = row["mac_id"]
                    let threadID: String = row["thread_id"]
                    let itemID: String = row["item_id"]
                    let hasAttachment: Bool = row["has_attachment"]
                    if hasAttachment,
                       var message = decode(CodexMessage.self, encrypted: row["payload"]) {
                        message.attachments = []
                        if let payload = encodeAndEncrypt(message) {
                            try db.execute(
                                sql: """
                                UPDATE cache_item
                                SET payload = ?, has_attachment = 0
                                WHERE mac_id = ? AND thread_id = ? AND item_id = ?
                                """,
                                arguments: [payload, macID, threadID, itemID]
                            )
                        }
                        usedBytes = try logicalDatabaseBytes(db)
                    }
                    if usedBytes > limitBytes {
                        try db.execute(
                            sql: "DELETE FROM cache_item WHERE mac_id = ? AND thread_id = ? AND item_id = ?",
                            arguments: [macID, threadID, itemID]
                        )
                    }
                    usedBytes = try logicalDatabaseBytes(db)
                }

                try db.execute(
                    sql: """
                    DELETE FROM cache_turn
                    WHERE NOT EXISTS (
                        SELECT 1 FROM cache_item i
                        WHERE i.mac_id = cache_turn.mac_id
                          AND i.thread_id = cache_turn.thread_id
                          AND i.turn_id = cache_turn.turn_id
                    )
                    """
                )
                usedBytes = try logicalDatabaseBytes(db)
                let exceeds = usedBytes > limitBytes
                if exceeds {
                    logger.warning("受保护缓存已超过上限 usedBytes=\(usedBytes, privacy: .public) limitBytes=\(limitBytes, privacy: .public)")
                }
                return CodexDerivedCacheUsage(
                    usedBytes: usedBytes,
                    limitBytes: limitBytes,
                    protectedContentExceedsLimit: exceeds
                )
            }
        } catch {
            logger.error("清理派生缓存失败 error=\(error.localizedDescription, privacy: .public)")
            return CodexDerivedCacheUsage(
                usedBytes: 0,
                limitBytes: limitBytes,
                protectedContentExceedsLimit: false
            )
        }
    }

    private func sanitized(_ message: CodexMessage) -> CodexMessage {
        var value = message
        if !message.attachments.isEmpty {
            let preservePayload = message.deliveryState == .pending
            value.attachments = message.attachments.map {
                $0.sanitizedForStorage(preservingPayloadDataURL: preservePayload)
            }
        }
        if var review = message.autoApprovalReview {
            review.persistedActionSummary = review.actionSummary
            review.action = .null
            if review.status == .denied,
               !review.retryApproved,
               review.retryUnavailableReason == nil {
                review.retryUnavailableReason = CodexAutoApprovalReview.liveSessionRetryUnavailableReason
            }
            value.autoApprovalReview = review
        }
        return value
    }

    private func encodeAndEncrypt<Value: Encodable>(_ value: Value) -> Data? {
        guard let plaintext = try? encoder.encode(value),
              let sealed = try? AES.GCM.seal(
                  plaintext,
                  using: encryptionKeyProvider()
              ) else {
            return nil
        }
        return sealed.combined
    }

    private func decode<Value: Decodable>(_ type: Value.Type, encrypted: Data) -> Value? {
        guard let box = try? AES.GCM.SealedBox(combined: encrypted),
              let plaintext = try? AES.GCM.open(
                  box,
                  using: encryptionKeyProvider()
              ) else {
            return nil
        }
        return try? decoder.decode(type, from: plaintext)
    }

    private func index(_ value: String) -> String {
        stableIndexProvider(value)
    }

    private func ensureRevisionIsMonotonic(
        _ db: Database,
        macID: String,
        scopeID: String,
        proposedRevision: Int64
    ) throws {
        let currentRevision = try Int64.fetchOne(
            db,
            sql: "SELECT revision FROM cache_sync_state WHERE mac_id = ? AND scope_id = ?",
            arguments: [macID, scopeID]
        ) ?? 0
        guard proposedRevision >= currentRevision else {
            throw CacheError.revisionRegression(current: currentRevision, proposed: proposedRevision)
        }
    }

    private func writeThreads(
        _ db: Database,
        threads: [CodexThread],
        macID: String,
        pinnedThreadIDs: Set<String>,
        activeThreadID: String?,
        deleteMissing: Bool,
        now: TimeInterval
    ) throws {
        try upsertMac(db, macID: macID, now: now)
        let incomingIDs = Set(threads.map { index($0.id) })
        let existingIDs = deleteMissing
            ? try String.fetchAll(
                db,
                sql: "SELECT thread_id FROM cache_thread WHERE mac_id = ?",
                arguments: [macID]
            )
            : []

        if deleteMissing || activeThreadID != nil {
            try db.execute(
                sql: "UPDATE cache_thread SET is_active = 0 WHERE mac_id = ?",
                arguments: [macID]
            )
        }

        for thread in threads {
            let threadID = index(thread.id)
            guard let payload = encodeAndEncrypt(thread) else {
                throw CacheError.encoding("任务 \(threadID)")
            }
            try db.execute(
                sql: """
                INSERT INTO cache_thread
                    (mac_id, thread_id, payload, updated_at, last_access, is_pinned, is_active)
                VALUES (?, ?, ?, ?, ?, ?, ?)
                ON CONFLICT(mac_id, thread_id) DO UPDATE SET
                    payload = excluded.payload,
                    updated_at = excluded.updated_at,
                    last_access = excluded.last_access,
                    is_pinned = excluded.is_pinned,
                    is_active = excluded.is_active
                """,
                arguments: [
                    macID,
                    threadID,
                    payload,
                    thread.updatedAt?.timeIntervalSince1970 ?? now,
                    now,
                    pinnedThreadIDs.contains(thread.id),
                    activeThreadID == thread.id,
                ]
            )
        }

        for staleID in existingIDs where !incomingIDs.contains(staleID) {
            try db.execute(
                sql: "DELETE FROM cache_thread WHERE mac_id = ? AND thread_id = ?",
                arguments: [macID, staleID]
            )
        }
    }

    private func writeMessages(
        _ db: Database,
        messagesByThread: [String: [CodexMessage]],
        macID: String,
        deleteMissingThreads: Bool,
        replaceProvidedThreads: Bool,
        now: TimeInterval
    ) throws {
        try upsertMac(db, macID: macID, now: now)
        let incomingThreadIDs = Set(messagesByThread.keys.map(index))
        let existingThreadIDs = deleteMissingThreads
            ? try String.fetchAll(
                db,
                sql: "SELECT DISTINCT thread_id FROM cache_item WHERE mac_id = ?",
                arguments: [macID]
            )
            : []

        for (threadIDValue, messages) in messagesByThread {
            let threadID = index(threadIDValue)
            var incomingItemIDs: Set<String> = []

            guard let placeholderPayload = encodeAndEncrypt(CodexThread(id: threadIDValue)) else {
                throw CacheError.encoding("任务 \(threadID)")
            }
            try db.execute(
                sql: """
                INSERT OR IGNORE INTO cache_thread
                    (mac_id, thread_id, payload, updated_at, last_access, is_pinned, is_active)
                VALUES (?, ?, ?, ?, ?, 0, 0)
                """,
                arguments: [macID, threadID, placeholderPayload, now, now]
            )

            for (ordinal, message) in messages.enumerated() {
                let rawTurnID = message.turnId ?? "turn:\(message.id)"
                let turnID = index(rawTurnID)
                let rawItemID = message.itemId ?? message.sourceItemKey ?? message.id
                let itemID = index(rawItemID)
                incomingItemIDs.insert(itemID)

                guard let payload = encodeAndEncrypt(sanitized(message)) else {
                    throw CacheError.encoding("消息 \(itemID)")
                }
                try db.execute(
                    sql: """
                    INSERT INTO cache_turn
                        (mac_id, thread_id, turn_id, ordinal, updated_at, last_access)
                    VALUES (?, ?, ?, ?, ?, ?)
                    ON CONFLICT(mac_id, thread_id, turn_id) DO UPDATE SET
                        ordinal = MIN(cache_turn.ordinal, excluded.ordinal),
                        updated_at = excluded.updated_at,
                        last_access = excluded.last_access
                    """,
                    arguments: [macID, threadID, turnID, ordinal, now, now]
                )
                try db.execute(
                    sql: """
                    INSERT INTO cache_item
                        (mac_id, thread_id, turn_id, item_id, ordinal, payload,
                         has_attachment, updated_at, last_access)
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
                    ON CONFLICT(mac_id, thread_id, item_id) DO UPDATE SET
                        turn_id = excluded.turn_id,
                        ordinal = excluded.ordinal,
                        payload = excluded.payload,
                        has_attachment = excluded.has_attachment,
                        updated_at = excluded.updated_at,
                        last_access = excluded.last_access
                    """,
                    arguments: [
                        macID,
                        threadID,
                        turnID,
                        itemID,
                        ordinal,
                        payload,
                        !message.attachments.isEmpty,
                        message.createdAt.timeIntervalSince1970,
                        now,
                    ]
                )
            }

            if replaceProvidedThreads {
                let existingItemIDs = try String.fetchAll(
                    db,
                    sql: "SELECT item_id FROM cache_item WHERE mac_id = ? AND thread_id = ?",
                    arguments: [macID, threadID]
                )
                for staleID in existingItemIDs where !incomingItemIDs.contains(staleID) {
                    try db.execute(
                        sql: "DELETE FROM cache_item WHERE mac_id = ? AND thread_id = ? AND item_id = ?",
                        arguments: [macID, threadID, staleID]
                    )
                }
            }
            try db.execute(
                sql: """
                DELETE FROM cache_turn
                WHERE mac_id = ? AND thread_id = ?
                  AND NOT EXISTS (
                      SELECT 1 FROM cache_item i
                      WHERE i.mac_id = cache_turn.mac_id
                        AND i.thread_id = cache_turn.thread_id
                        AND i.turn_id = cache_turn.turn_id
                  )
                """,
                arguments: [macID, threadID]
            )
        }

        for staleThreadID in existingThreadIDs where !incomingThreadIDs.contains(staleThreadID) {
            try db.execute(
                sql: "DELETE FROM cache_item WHERE mac_id = ? AND thread_id = ?",
                arguments: [macID, staleThreadID]
            )
            try db.execute(
                sql: "DELETE FROM cache_turn WHERE mac_id = ? AND thread_id = ?",
                arguments: [macID, staleThreadID]
            )
        }
    }

    private func writeSyncState(
        _ db: Database,
        macID: String,
        scopeID: String,
        revision: Int64,
        acknowledgedRevision: Int64,
        now: TimeInterval
    ) throws {
        try upsertMac(db, macID: macID, now: now)
        try db.execute(
            sql: """
            INSERT INTO cache_sync_state (mac_id, scope_id, revision, ack_revision, updated_at)
            VALUES (?, ?, ?, ?, ?)
            ON CONFLICT(mac_id, scope_id) DO UPDATE SET
                revision = MAX(cache_sync_state.revision, excluded.revision),
                ack_revision = MAX(cache_sync_state.ack_revision, excluded.ack_revision),
                updated_at = excluded.updated_at
            """,
            arguments: [macID, scopeID, revision, acknowledgedRevision, now]
        )
    }

    private func upsertMac(_ db: Database, macID: String, now: TimeInterval) throws {
        try db.execute(
            sql: """
            INSERT INTO cache_mac (mac_id, last_access)
            VALUES (?, ?)
            ON CONFLICT(mac_id) DO UPDATE SET last_access = excluded.last_access
            """,
            arguments: [macID, now]
        )
    }

    private func deleteRows(in table: String, macDeviceId: String?) {
        let allowedTables = ["cache_thread"]
        precondition(allowedTables.contains(table))
        let macID = index(macDeviceId ?? "local")
        do {
            try queue.write { db in
                try db.execute(sql: "DELETE FROM \(table) WHERE mac_id = ?", arguments: [macID])
            }
        } catch {
            logger.error("删除派生缓存失败 mac=\(macID, privacy: .public) table=\(table, privacy: .public) error=\(error.localizedDescription, privacy: .public)")
        }
    }

    private func logicalDatabaseBytes(_ db: Database) throws -> Int64 {
        let pageCount = try Int64.fetchOne(db, sql: "PRAGMA page_count") ?? 0
        let freePages = try Int64.fetchOne(db, sql: "PRAGMA freelist_count") ?? 0
        let pageSize = try Int64.fetchOne(db, sql: "PRAGMA page_size") ?? 0
        return max(0, pageCount - freePages) * pageSize
    }

    private static func databaseURL() -> URL {
        let manager = FileManager.default
        let base = manager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? manager.temporaryDirectory
        let directory = base
            .appendingPathComponent(Bundle.main.bundleIdentifier ?? "cn.syggu.remodex", isDirectory: true)
            .appendingPathComponent("cache", isDirectory: true)
        try? manager.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appendingPathComponent("derived-v1.sqlite", isDirectory: false)
    }

    private static func openDatabase(at url: URL) throws -> DatabaseQueue {
        var configuration = Configuration()
        configuration.busyMode = .timeout(5)
        configuration.prepareDatabase { db in
            try db.execute(sql: "PRAGMA foreign_keys = ON")
            try db.execute(sql: "PRAGMA journal_mode = WAL")
            try db.execute(sql: "PRAGMA synchronous = NORMAL")
        }
        let queue = try DatabaseQueue(path: url.path, configuration: configuration)
        var migrator = DatabaseMigrator()
        migrator.registerMigration("derived-cache-v1") { db in
            try db.create(table: "cache_mac") { table in
                table.column("mac_id", .text).primaryKey()
                table.column("last_access", .double).notNull()
            }
            try db.create(table: "cache_thread") { table in
                table.column("mac_id", .text).notNull()
                    .references("cache_mac", onDelete: .cascade)
                table.column("thread_id", .text).notNull()
                table.column("payload", .blob).notNull()
                table.column("updated_at", .double).notNull()
                table.column("last_access", .double).notNull()
                table.column("is_pinned", .boolean).notNull().defaults(to: false)
                table.column("is_active", .boolean).notNull().defaults(to: false)
                table.primaryKey(["mac_id", "thread_id"])
            }
            try db.create(table: "cache_turn") { table in
                table.column("mac_id", .text).notNull()
                table.column("thread_id", .text).notNull()
                table.column("turn_id", .text).notNull()
                table.column("ordinal", .integer).notNull()
                table.column("updated_at", .double).notNull()
                table.column("last_access", .double).notNull()
                table.primaryKey(["mac_id", "thread_id", "turn_id"])
                table.foreignKey(
                    ["mac_id", "thread_id"],
                    references: "cache_thread",
                    columns: ["mac_id", "thread_id"],
                    onDelete: .cascade
                )
            }
            try db.create(table: "cache_item") { table in
                table.column("mac_id", .text).notNull()
                table.column("thread_id", .text).notNull()
                table.column("turn_id", .text).notNull()
                table.column("item_id", .text).notNull()
                table.column("ordinal", .integer).notNull()
                table.column("payload", .blob).notNull()
                table.column("has_attachment", .boolean).notNull().defaults(to: false)
                table.column("updated_at", .double).notNull()
                table.column("last_access", .double).notNull()
                table.primaryKey(["mac_id", "thread_id", "item_id"])
                table.foreignKey(
                    ["mac_id", "thread_id", "turn_id"],
                    references: "cache_turn",
                    columns: ["mac_id", "thread_id", "turn_id"],
                    onDelete: .cascade
                )
            }
            try db.create(table: "cache_sync_state") { table in
                table.column("mac_id", .text).notNull()
                    .references("cache_mac", onDelete: .cascade)
                table.column("scope_id", .text).notNull()
                table.column("revision", .integer).notNull().defaults(to: 0)
                table.column("ack_revision", .integer).notNull().defaults(to: 0)
                table.column("updated_at", .double).notNull()
                table.primaryKey(["mac_id", "scope_id"])
            }
            try db.create(index: "cache_thread_lru", on: "cache_thread", columns: ["last_access"])
            try db.create(index: "cache_turn_order", on: "cache_turn", columns: ["mac_id", "thread_id", "ordinal"])
            try db.create(index: "cache_item_order", on: "cache_item", columns: ["mac_id", "thread_id", "ordinal"])
            try db.create(index: "cache_item_lru", on: "cache_item", columns: ["last_access", "updated_at"])
        }
        try migrator.migrate(queue)
        return queue
    }

    private static func quarantineDatabase(at url: URL, reason: Error) {
        let manager = FileManager.default
        let timestamp = Int(Date().timeIntervalSince1970)
        for suffix in ["", "-wal", "-shm"] {
            let source = URL(fileURLWithPath: url.path + suffix)
            guard manager.fileExists(atPath: source.path) else { continue }
            let destination = source.deletingLastPathComponent().appendingPathComponent(
                "derived-v1-corrupt-\(timestamp)\(suffix).sqlite"
            )
            try? manager.moveItem(at: source, to: destination)
        }
        Logger(
            subsystem: Bundle.main.bundleIdentifier ?? "cn.syggu.remodex",
            category: "derived-cache"
        ).error("派生缓存损坏，已隔离并重建 error=\(reason.localizedDescription, privacy: .public)")
    }

    private enum CacheError: LocalizedError {
        case encoding(String)
        case revisionRegression(current: Int64, proposed: Int64)

        var errorDescription: String? {
            switch self {
            case .encoding(let object):
                return L10n.format("无法编码派生缓存对象：%@", object)
            case .revisionRegression(let current, let proposed):
                return L10n.format("同步 revision 回退：当前为 %@，收到 %@", String(current), String(proposed))
            }
        }
    }
}
