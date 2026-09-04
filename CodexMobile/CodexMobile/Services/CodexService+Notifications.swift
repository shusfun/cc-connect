// FILE: CodexService+Notifications.swift
// Purpose: 处理前台声音/触感提示和 Remodex 深链路由，不注册 APNs。
// Layer: Service

import AudioToolbox
import Foundation
import UIKit

extension CodexService {
    func notifyRunCompletionIfNeeded(threadId: String, turnId: String?, result: CodexRunCompletionResult) {
        guard isAppInForeground else { return }
        AudioServicesPlaySystemSound(result == .completed ? 1007 : 1053)
        HapticFeedback.shared.triggerNotificationFeedback(type: result == .completed ? .success : .error)
    }

    func notifyStructuredUserInputIfNeeded(
        threadId: String,
        turnId: String?,
        requestID: JSONValue,
        questions: [CodexStructuredUserInputQuestion]
    ) {
        guard isAppInForeground else { return }
        AudioServicesPlaySystemSound(1007)
        HapticFeedback.shared.triggerNotificationFeedback(type: .warning)
    }

    func handleNotificationOpen(threadId: String, turnId: String?) {
        let normalizedThreadId = threadId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedThreadId.isEmpty else { return }

        pendingNotificationOpenThreadID = normalizedThreadId
        externalThreadOpenRequest = CodexExternalThreadOpenRequest(threadId: normalizedThreadId)
        Task { @MainActor [weak self] in
            guard let self else { return }
            let routed = await routePendingNotificationOpenIfPossible()
            if !routed, turnId?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false {
                debugRuntimeLog("deep link target deferred thread=\(normalizedThreadId) turn=\(turnId ?? "")")
            }
        }
    }

    @discardableResult
    func routePendingNotificationOpenIfPossible(refreshIfNeeded: Bool = true) async -> Bool {
        guard let pendingThreadId = pendingNotificationOpenThreadID?
            .trimmingCharacters(in: .whitespacesAndNewlines),
              !pendingThreadId.isEmpty else {
            return false
        }

        if hasDeepLinkRoutingCandidate(threadId: pendingThreadId) {
            missingNotificationThreadPrompt = nil
            if await prepareThreadForDisplay(threadId: pendingThreadId) {
                if pendingNotificationOpenThreadID == pendingThreadId {
                    pendingNotificationOpenThreadID = nil
                }
                return true
            }
            if hasDeepLinkRoutingCandidate(threadId: pendingThreadId) {
                return false
            }
        }

        guard isConnected else { return false }
        let didRefreshThreads = refreshIfNeeded ? await refreshThreadsForDeepLinkRouting() : true
        guard hasDeepLinkRoutingCandidate(threadId: pendingThreadId) else {
            guard didRefreshThreads else { return false }
            return finalizeMissingDeepLinkRouteIfNeeded(
                threadId: pendingThreadId,
                isAuthoritativeMissingResult: thread(for: pendingThreadId)?.syncState == .archivedLocal
            )
        }

        missingNotificationThreadPrompt = nil
        if await prepareThreadForDisplay(threadId: pendingThreadId) {
            if pendingNotificationOpenThreadID == pendingThreadId {
                pendingNotificationOpenThreadID = nil
            }
            return true
        }
        return false
    }
}

private extension CodexService {
    func hasDeepLinkRoutingCandidate(threadId: String) -> Bool {
        guard let thread = thread(for: threadId) else { return false }
        return thread.syncState != .archivedLocal
    }

    func finalizeMissingDeepLinkRouteIfNeeded(
        threadId: String,
        isAuthoritativeMissingResult: Bool
    ) -> Bool {
        guard isAuthoritativeMissingResult else { return false }
        if pendingNotificationOpenThreadID == threadId {
            pendingNotificationOpenThreadID = nil
        }
        if externalThreadOpenRequest?.threadId == threadId {
            externalThreadOpenRequest = nil
        }
        if activeThreadId == nil || activeThreadId == threadId {
            activeThreadId = firstLiveThreadID()
        }
        missingNotificationThreadPrompt = CodexMissingNotificationThreadPrompt(threadId: threadId)
        return false
    }

    func refreshThreadsForDeepLinkRouting() async -> Bool {
        guard isConnected else { return false }
        do {
            try await listThreads()
            return true
        } catch {
            debugRuntimeLog("thread refresh for deep link failed: \(error.localizedDescription)")
            return false
        }
    }
}
