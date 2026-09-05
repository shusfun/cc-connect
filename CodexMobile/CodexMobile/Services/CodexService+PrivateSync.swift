// FILE: CodexService+PrivateSync.swift
// Purpose: Consumes the Bridge-owned revision journal without exposing sync metadata to Relay.
// Layer: Service
// Exports: private catalog and per-thread delta synchronization
// Depends on: CodexDerivedCache, CodexService transport and history reducers

import Foundation

extension CodexService {
    static let requiredPrivateSyncProtocolVersion = 1

    func ensurePrivateSyncProtocol() async throws {
        if privateSyncProtocolVersion == Self.requiredPrivateSyncProtocolVersion {
            return
        }
        if let privateSyncNegotiationTask {
            _ = try await privateSyncNegotiationTask.value
            return
        }

        let task = Task { @MainActor [weak self] () throws -> Int in
            guard let self else { throw CancellationError() }
            let response = try await self.sendRequest(method: "sync/hello", params: .object([:]))
            guard let result = response.result?.objectValue,
                  let version = self.syncRevision(result["protocolVersion"]),
                  version == Int64(Self.requiredPrivateSyncProtocolVersion),
                  result["capabilities"]?.objectValue?["catalogDelta"]?.boolValue == true,
                  result["capabilities"]?.objectValue?["threadDelta"]?.boolValue == true,
                  result["capabilities"]?.objectValue?["threadReset"]?.boolValue == true,
                  result["capabilities"]?.objectValue?["acknowledgements"]?.boolValue == true else {
                throw CodexServiceError.invalidResponse(
                    L10n.format("Bridge 不支持 Remodex 私有增量同步协议 v%@，请升级 Mac App。", String(describing: Self.requiredPrivateSyncProtocolVersion))
                )
            }

            let remoteMacID = result["macDeviceId"]?.stringValue?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if let expectedMacID = self.currentMacScopedPersistenceDeviceId,
               let remoteMacID,
               !remoteMacID.isEmpty,
               expectedMacID != remoteMacID {
                throw CodexServiceError.invalidResponse(L10n.string("Bridge 身份与当前已配对 Mac 不一致，请重新配对。"))
            }
            return Int(version)
        }
        privateSyncNegotiationTask = task
        do {
            let version = try await task.value
            privateSyncNegotiationTask = nil
            privateSyncProtocolVersion = version
        } catch {
            privateSyncNegotiationTask = nil
            privateSyncProtocolVersion = nil
            throw error
        }
    }

    @discardableResult
    func syncPrivateCatalog() async throws -> Bool {
        try await ensurePrivateSyncProtocol()
        let cache = CodexDerivedCache.shared
        let macID = currentMacScopedPersistenceDeviceId
        let state = cache.syncState(macDeviceId: macID, scope: "catalog")
        let response = try await sendRequest(
            method: "sync/catalog",
            params: .object(["catalogRevision": .integer(Int(state.revision))])
        )
        guard let result = response.result?.objectValue,
              let revision = syncRevision(result["revision"]),
              let upsertValues = result["upserts"]?.arrayValue,
              let tombstoneValues = result["tombstones"]?.arrayValue else {
            throw CodexServiceError.invalidResponse("sync/catalog 返回了无效响应。")
        }
        guard revision >= state.revision else {
            throw CodexServiceError.invalidResponse(
                "sync/catalog revision 回退：本地为 \(state.revision)，远端为 \(revision)。"
            )
        }

        let decodedUpserts = upsertValues.compactMap { decodeModel(CodexThread.self, from: $0) }
        guard decodedUpserts.count == upsertValues.count else {
            throw CodexServiceError.invalidResponse("sync/catalog 包含无法解析的任务。")
        }
        let tombstoneIDs = try tombstoneValues.map { value -> String in
            guard let threadID = value.objectValue?["threadId"]?.stringValue?
                .trimmingCharacters(in: .whitespacesAndNewlines),
                  !threadID.isEmpty else {
                throw CodexServiceError.invalidResponse("sync/catalog 包含无效 tombstone。")
            }
            return threadID
        }
        let isReset = result["reset"]?.boolValue == true
        let changed = isReset || !decodedUpserts.isEmpty || !tombstoneIDs.isEmpty

        if isReset {
            let authoritativeIDs = Set(decodedUpserts.map(\.id))
            let removedIDs = threads.map(\.id).filter { !authoritativeIDs.contains($0) }
            for threadID in removedIDs {
                removeThreadLocally(threadID, persistAsDeleted: false, persistMessages: false)
            }
        }
        for threadID in tombstoneIDs {
            removeThreadLocally(threadID, persistAsDeleted: false, persistMessages: false)
        }
        for thread in decodedUpserts {
            upsertThread(thread, treatAsServerState: true)
        }

        try cache.commitCatalogSnapshot(
            threads: threads,
            macDeviceId: macID,
            pinnedThreadIDs: Set(pinnedThreadIDs),
            activeThreadID: activeThreadId,
            revision: revision,
            acknowledgedRevision: state.acknowledgedRevision
        )
        try await acknowledgePrivateSync(catalogRevision: revision, threadRevisions: [:])
        try cache.commitSyncState(
            macDeviceId: macID,
            scope: "catalog",
            revision: revision,
            acknowledgedRevision: revision
        )
        lastIncrementalSyncAt = Date()
        return changed
    }

    @discardableResult
    func syncPrivateThread(threadId: String, forceReset: Bool = false) async throws -> Bool {
        try await ensurePrivateSyncProtocol()
        let cache = CodexDerivedCache.shared
        let macID = currentMacScopedPersistenceDeviceId
        let scope = "thread:\(threadId)"
        let state = cache.syncState(macDeviceId: macID, scope: scope)

        let response = try await sendRequest(
            method: "sync/thread/read",
            params: .object([
                "threadId": .string(threadId),
                "threadRevision": .integer(Int(state.revision)),
            ])
        )
        guard let result = response.result?.objectValue,
              let revision = syncRevision(result["revision"]),
              let events = result["events"]?.arrayValue else {
            throw CodexServiceError.invalidResponse("sync/thread/read 返回了无效响应。")
        }
        guard revision >= state.revision else {
            throw CodexServiceError.invalidResponse(
                "sync/thread/read revision 回退：本地为 \(state.revision)，远端为 \(revision)。"
            )
        }

        let requiresReset = forceReset || !state.initialized || result["resetRequired"]?.boolValue == true
        if requiresReset {
            try await resetPrivateThread(threadId: threadId, expectedRevision: revision)
            return true
        }

        for eventValue in events {
            guard let event = eventValue.objectValue,
                  let method = event["method"]?.stringValue,
                  !method.isEmpty else {
                throw CodexServiceError.invalidResponse("sync/thread/read 包含无效事件。")
            }
            handleNotification(method: normalizedIncomingMethodName(method), params: event["params"])
        }

        try cache.commitThreadSnapshot(
            thread: threads.first(where: { $0.id == threadId }),
            messages: messagesByThread[threadId] ?? [],
            threadId: threadId,
            macDeviceId: macID,
            isPinned: pinnedThreadIDs.contains(threadId),
            isActive: activeThreadId == threadId,
            replaceMessages: false,
            revision: revision,
            acknowledgedRevision: state.acknowledgedRevision
        )
        try await acknowledgePrivateSync(catalogRevision: nil, threadRevisions: [threadId: revision])
        try cache.commitSyncState(
            macDeviceId: macID,
            scope: scope,
            revision: revision,
            acknowledgedRevision: revision
        )
        lastIncrementalSyncAt = Date()
        return !events.isEmpty
    }

    private func resetPrivateThread(threadId: String, expectedRevision: Int64) async throws {
        let response = try await sendRequest(
            method: "sync/thread/reset",
            params: .object(["threadId": .string(threadId)])
        )
        guard let result = response.result?.objectValue,
              let revision = syncRevision(result["revision"]),
              revision >= expectedRevision else {
            throw CodexServiceError.invalidResponse("sync/thread/reset 返回了无效 revision。")
        }

        var threadObject = result["thread"]?.objectValue ?? ["id": .string(threadId)]
        if threadObject["turns"] == nil, let turns = result["turns"]?.arrayValue {
            threadObject["turns"] = .array(turns)
        }
        if let decodedThread = decodeModel(CodexThread.self, from: .object(threadObject)) {
            upsertThread(decodedThread, treatAsServerState: true)
        }

        let historyMessages = decodeMessagesFromThreadRead(threadId: threadId, threadObject: threadObject)
        let merged = mergeHistoryMessages(messagesByThread[threadId] ?? [], historyMessages)
        let terminalStates = decodeTurnTerminalStatesFromThreadRead(threadObject)
        let terminalStatesChanged = mergeHistoryTurnTerminalStates(
            threadId: threadId,
            terminalStatesByTurnID: terminalStates
        )
        if messagesByThread[threadId] != merged {
            messagesByThread[threadId] = merged
            noteMessagesChanged(for: threadId)
            registerSubagentThreads(from: historyMessages, parentThreadId: threadId)
            updateCurrentOutput(for: threadId)
            refreshThreadTimelineState(for: threadId)
        } else if terminalStatesChanged {
            refreshThreadTimelineState(for: threadId)
        }
        hydratedThreadIDs.insert(threadId)
        initialTurnsLoadedByThreadID.insert(threadId)
        if let beforeCursor = result["beforeCursor"] {
            updateOlderThreadHistoryCursorFromInitialPage(
                threadId: threadId,
                cursor: beforeCursor,
                isFreshInitialLoad: true
            )
        } else {
            markThreadLocalHistoryStartAuthoritative(threadId, clearRemoteCursor: true)
        }
        let cache = CodexDerivedCache.shared
        let macID = currentMacScopedPersistenceDeviceId
        let scope = "thread:\(threadId)"
        let previous = cache.syncState(macDeviceId: macID, scope: scope)
        try cache.commitThreadSnapshot(
            thread: threads.first(where: { $0.id == threadId }),
            messages: messagesByThread[threadId] ?? [],
            threadId: threadId,
            macDeviceId: macID,
            isPinned: pinnedThreadIDs.contains(threadId),
            isActive: activeThreadId == threadId,
            replaceMessages: true,
            revision: revision,
            acknowledgedRevision: previous.acknowledgedRevision
        )
        try await acknowledgePrivateSync(catalogRevision: nil, threadRevisions: [threadId: revision])
        try cache.commitSyncState(
            macDeviceId: macID,
            scope: scope,
            revision: revision,
            acknowledgedRevision: revision
        )
        lastIncrementalSyncAt = Date()
    }

    private func acknowledgePrivateSync(
        catalogRevision: Int64?,
        threadRevisions: [String: Int64]
    ) async throws {
        var params: [String: JSONValue] = [
            "phoneDeviceId": .string(phoneIdentityState.phoneDeviceId),
            "threadRevisions": .object(threadRevisions.mapValues { .integer(Int($0)) }),
        ]
        if let catalogRevision {
            params["catalogRevision"] = .integer(Int(catalogRevision))
        }
        _ = try await sendRequest(method: "sync/ack", params: .object(params))
    }

    private func syncRevision(_ value: JSONValue?) -> Int64? {
        guard let value else { return nil }
        if let integer = value.intValue {
            return Int64(integer)
        }
        if let double = value.doubleValue,
           double.isFinite,
           double >= 0,
           double.rounded(.towardZero) == double {
            return Int64(double)
        }
        return nil
    }
}
