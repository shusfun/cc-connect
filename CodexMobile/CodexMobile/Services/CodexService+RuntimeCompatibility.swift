// FILE: CodexService+RuntimeCompatibility.swift
// Purpose: Presents explicit Mac App upgrade guidance for unsupported app-server capabilities.
// Layer: Service
// Exports: CodexService runtime compatibility helpers
// Depends on: Foundation

import Foundation

extension CodexService {
    // Keeps the rejected request visible while explaining the required Mac App upgrade.
    func presentUnsupportedServiceTierUpgradeIfNeeded(
        _ error: Error,
        includesServiceTier: Bool
    ) {
        guard includesServiceTier,
              shouldRetryTurnStartWithoutServiceTier(error) else {
            return
        }

        markServiceTierUnsupportedForCurrentBridge()
    }

    func shouldRetryTurnStartWithoutServiceTier(_ error: Error) -> Bool {
        guard let serviceError = error as? CodexServiceError,
              case .rpcError(let rpcError) = serviceError else {
            return false
        }

        guard rpcError.code == -32600 || rpcError.code == -32602 else {
            return false
        }

        let message = rpcError.message.lowercased()
        return message.contains("servicetier")
            || message.contains("service tier")
            || message.contains("unknown field")
            || message.contains("unexpected field")
            || message.contains("unrecognized field")
            || message.contains("invalid param")
            || message.contains("invalid params")
    }

    func markServiceTierUnsupportedForCurrentBridge() {
        supportsServiceTier = false

        guard selectedServiceTier != nil,
              !hasPresentedServiceTierBridgeUpdatePrompt else {
            return
        }

        hasPresentedServiceTierBridgeUpdatePrompt = true
        bridgeUpdatePrompt = serviceTierBridgeUpdatePrompt
    }
}

private extension CodexService {
    var serviceTierBridgeUpdatePrompt: CodexBridgeUpdatePrompt {
        CodexBridgeUpdatePrompt(
            title: L10n.string("请更新 Mac 上的 Remodex.app 以使用速度控制"),
            message: L10n.string("当前 Mac App 内置的 Bridge 不支持所选速度设置。更新 Mac App 后重新连接。"),
            command: nil
        )
    }
}
