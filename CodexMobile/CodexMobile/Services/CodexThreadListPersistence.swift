// FILE: CodexThreadListPersistence.swift
// Purpose: Adapts sidebar persistence to the encrypted incremental GRDB cache.
// Layer: Service Persistence
// Exports: CodexThreadListPersistence
// Depends on: CodexDerivedCache, CodexThread

import Foundation

nonisolated struct CodexThreadListPersistence {
    private let cache = CodexDerivedCache.shared

    func load(macDeviceId: String? = nil, includeLegacyFallback _: Bool = false) -> [CodexThread] {
        cache.loadThreads(macDeviceId: macDeviceId)
    }

    func save(
        _ value: [CodexThread],
        macDeviceId: String? = nil,
        pinnedThreadIDs: Set<String> = [],
        activeThreadID: String? = nil
    ) {
        cache.saveThreads(
            value,
            macDeviceId: macDeviceId,
            pinnedThreadIDs: pinnedThreadIDs,
            activeThreadID: activeThreadID
        )
    }

    func delete(macDeviceId: String?) {
        cache.deleteThreads(macDeviceId: macDeviceId)
    }
}
