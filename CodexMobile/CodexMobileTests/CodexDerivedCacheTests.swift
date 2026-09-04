// FILE: CodexDerivedCacheTests.swift
// Purpose: Verifies incremental cache isolation, monotonic revisions, and reset replacement semantics.
// Layer: Unit Test
// Depends on: CryptoKit, Foundation, XCTest, CodexMobile

import CryptoKit
import Foundation
import XCTest
@testable import CodexMobile

final class CodexDerivedCacheTests: XCTestCase {
    func testInitialLoadDecryptsOnlyTheActiveThread() throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }
        let first = CodexThread(id: "thread-1")
        let second = CodexThread(id: "thread-2")

        fixture.cache.saveThreads(
            [first, second],
            macDeviceId: "mac-1",
            activeThreadID: first.id
        )
        fixture.cache.saveMessages(
            [
                first.id: [message(threadId: first.id, item: "first")],
                second.id: [message(threadId: second.id, item: "second")],
            ],
            macDeviceId: "mac-1"
        )

        let loaded = fixture.cache.loadInitialMessages(macDeviceId: "mac-1")
        XCTAssertEqual(Set(loaded.keys), [first.id])
        XCTAssertEqual(loaded[first.id]?.map(\.text), ["first"])
        XCTAssertEqual(fixture.cache.loadMessages(threadId: second.id, macDeviceId: "mac-1").map(\.text), ["second"])
    }

    func testLowerThreadRevisionRollsBackMessagesAndSyncStateTogether() throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }
        let thread = CodexThread(id: "thread-1")

        try fixture.cache.commitThreadSnapshot(
            thread: thread,
            messages: [message(threadId: thread.id, item: "accepted")],
            threadId: thread.id,
            macDeviceId: "mac-1",
            isPinned: false,
            isActive: true,
            replaceMessages: false,
            revision: 8,
            acknowledgedRevision: 7
        )

        XCTAssertThrowsError(
            try fixture.cache.commitThreadSnapshot(
                thread: thread,
                messages: [message(threadId: thread.id, item: "stale")],
                threadId: thread.id,
                macDeviceId: "mac-1",
                isPinned: false,
                isActive: true,
                replaceMessages: false,
                revision: 6,
                acknowledgedRevision: 6
            )
        )

        XCTAssertEqual(
            fixture.cache.syncState(macDeviceId: "mac-1", scope: "thread:\(thread.id)"),
            CodexDerivedCacheSyncState(initialized: true, revision: 8, acknowledgedRevision: 7)
        )
        XCTAssertEqual(
            fixture.cache.loadMessages(threadId: thread.id, macDeviceId: "mac-1").map(\.text),
            ["accepted"]
        )
    }

    func testCatalogCommitDoesNotDeleteThreadHistory() throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }
        let thread = CodexThread(id: "thread-1")
        fixture.cache.saveThreads([thread], macDeviceId: "mac-1", activeThreadID: thread.id)
        fixture.cache.saveMessages(
            [thread.id: [message(threadId: thread.id, item: "cached history")]],
            macDeviceId: "mac-1"
        )

        try fixture.cache.commitCatalogSnapshot(
            threads: [thread],
            macDeviceId: "mac-1",
            pinnedThreadIDs: [],
            activeThreadID: thread.id,
            revision: 3,
            acknowledgedRevision: 2
        )

        XCTAssertEqual(
            fixture.cache.loadMessages(threadId: thread.id, macDeviceId: "mac-1").map(\.text),
            ["cached history"]
        )
    }

    func testOnlyResetReplacesExistingThreadWindow() throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }
        let thread = CodexThread(id: "thread-1")
        let first = message(threadId: thread.id, item: "first", turnId: "turn-1")
        let second = message(threadId: thread.id, item: "second", turnId: "turn-2")

        try fixture.cache.commitThreadSnapshot(
            thread: thread,
            messages: [first],
            threadId: thread.id,
            macDeviceId: "mac-1",
            isPinned: false,
            isActive: true,
            replaceMessages: false,
            revision: 1,
            acknowledgedRevision: 0
        )
        try fixture.cache.commitThreadSnapshot(
            thread: thread,
            messages: [second],
            threadId: thread.id,
            macDeviceId: "mac-1",
            isPinned: false,
            isActive: true,
            replaceMessages: false,
            revision: 2,
            acknowledgedRevision: 1
        )
        XCTAssertEqual(
            Set(fixture.cache.loadMessages(threadId: thread.id, macDeviceId: "mac-1").map(\.text)),
            ["first", "second"]
        )

        try fixture.cache.commitThreadSnapshot(
            thread: thread,
            messages: [second],
            threadId: thread.id,
            macDeviceId: "mac-1",
            isPinned: false,
            isActive: true,
            replaceMessages: true,
            revision: 3,
            acknowledgedRevision: 2
        )
        XCTAssertEqual(
            fixture.cache.loadMessages(threadId: thread.id, macDeviceId: "mac-1").map(\.text),
            ["second"]
        )
    }

    func testCorruptedDerivedDatabaseIsQuarantinedAndRebuilt() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("remodex-cache-corrupt-tests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let databaseURL = root.appendingPathComponent("derived.sqlite")
        try Data("not a sqlite database".utf8).write(to: databaseURL)
        let key = SymmetricKey(data: Data(repeating: 0x42, count: 32))

        let cache = CodexDerivedCache(
            databaseURL: databaseURL,
            encryptionKeyProvider: { key },
            stableIndexProvider: { "idx-\($0)" }
        )
        let thread = CodexThread(id: "thread-after-rebuild")
        cache.saveThreads([thread], macDeviceId: "mac-1", activeThreadID: thread.id)

        XCTAssertEqual(cache.loadThreads(macDeviceId: "mac-1").map(\.id), [thread.id])
        let files = try FileManager.default.contentsOfDirectory(atPath: root.path)
        XCTAssertTrue(files.contains { $0.hasPrefix("derived-v1-corrupt-") })
    }

    func testLRUKeepsTheNewestFiveTurnsWhenTheLimitIsExceeded() throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }
        let thread = CodexThread(id: "thread-lru")
        fixture.cache.saveThreads([thread], macDeviceId: "mac-1")
        let messages = (1...6).map { index in
            message(threadId: thread.id, item: "item-\(index)", turnId: "turn-\(index)")
        }
        fixture.cache.saveMessages([thread.id: messages], macDeviceId: "mac-1")

        let usage = fixture.cache.pruneIfNeeded(limitBytes: 0)

        XCTAssertTrue(usage.protectedContentExceedsLimit)
        XCTAssertEqual(
            Set(fixture.cache.loadMessages(threadId: thread.id, macDeviceId: "mac-1").map(\.text)),
            Set((2...6).map { "item-\($0)" })
        )
    }

    private func makeFixture() throws -> (cache: CodexDerivedCache, cleanup: () -> Void) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("remodex-cache-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let key = SymmetricKey(data: Data(repeating: 0x42, count: 32))
        let cache = CodexDerivedCache(
            databaseURL: root.appendingPathComponent("derived.sqlite"),
            encryptionKeyProvider: { key },
            stableIndexProvider: { "idx-\($0)" }
        )
        return (cache, { try? FileManager.default.removeItem(at: root) })
    }

    private func message(threadId: String, item: String, turnId: String = "turn-1") -> CodexMessage {
        CodexMessage(
            threadId: threadId,
            role: .assistant,
            text: item,
            turnId: turnId,
            isStreaming: false
        )
    }
}
