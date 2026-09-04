// FILE: CodexMessagePersistence.swift
// Purpose: Adapts timeline persistence to the encrypted incremental GRDB cache.
// Layer: Service Persistence
// Exports: CodexMessagePersistence
// Depends on: CodexDerivedCache, CodexMessage

import Foundation

nonisolated struct CodexMessagePersistence {
    private let cache = CodexDerivedCache.shared

    func load(
        macDeviceId: String? = nil
    ) -> [String: [CodexMessage]] {
        cache.loadInitialMessages(macDeviceId: macDeviceId)
    }

    func load(threadId: String, macDeviceId: String? = nil) -> [CodexMessage] {
        cache.loadMessages(threadId: threadId, macDeviceId: macDeviceId)
    }

    func loadAll(macDeviceId: String? = nil) -> [String: [CodexMessage]] {
        cache.loadAllMessages(macDeviceId: macDeviceId)
    }

    func save(_ value: [String: [CodexMessage]], macDeviceId: String? = nil) {
        cache.saveMessages(value, macDeviceId: macDeviceId)
    }

    func delete(macDeviceId: String?) {
        cache.deleteMessages(macDeviceId: macDeviceId)
    }
}
