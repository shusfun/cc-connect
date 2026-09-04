// FILE: CodexService+ThreadForkCompatibility.swift
// Purpose: Isolates bridge-compatibility upgrade prompts used by native thread forking.
// Layer: Service
// Exports: CodexService thread-fork compatibility helpers
// Depends on: Foundation

import Foundation

extension CodexService {
    // Keeps the rejected fork visible while suppressing further unsupported actions for this session.
    func presentUnsupportedThreadForkUpgradeIfNeeded(_ error: Error) {
        guard shouldTreatAsUnsupportedThreadFork(error) else {
            return
        }

        markThreadForkUnsupportedForCurrentBridge()
    }

    func shouldTreatAsUnsupportedThreadFork(_ error: Error) -> Bool {
        guard let serviceError = error as? CodexServiceError,
              case .rpcError(let rpcError) = serviceError else {
            return false
        }

        if rpcError.code == -32601 {
            return true
        }

        let message = rpcError.message.lowercased()
        let mentionsUnsupportedMethod = message.contains("method not found")
            || message.contains("unknown method")
            || message.contains("not implemented")
            || message.contains("does not support")
        let mentionsForkSpecificUnsupported = (message.contains("thread/fork") || message.contains("thread fork"))
            && (message.contains("unsupported") || message.contains("not supported"))

        guard rpcError.code == -32600 || rpcError.code == -32602 || rpcError.code == -32000 else {
            return mentionsUnsupportedMethod || mentionsForkSpecificUnsupported
        }

        return mentionsUnsupportedMethod || mentionsForkSpecificUnsupported
    }

    func markThreadForkUnsupportedForCurrentBridge() {
        supportsThreadFork = false

        guard !hasPresentedThreadForkBridgeUpdatePrompt else {
            return
        }

        hasPresentedThreadForkBridgeUpdatePrompt = true
        bridgeUpdatePrompt = threadForkBridgeUpdatePrompt
    }
}

private extension CodexService {
    var threadForkBridgeUpdatePrompt: CodexBridgeUpdatePrompt {
        CodexBridgeUpdatePrompt(
            title: "请更新 Mac 上的 Remodex.app 以使用 /fork",
            message: "当前 Mac App 内置的 Bridge 不支持原生任务分叉。更新 Mac App 后重新连接。",
            command: nil
        )
    }
}
