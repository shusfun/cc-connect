// FILE: CodexService+TurnPaginationCompatibility.swift
// Purpose: Detects unsupported turn pagination and presents the required Mac App upgrade.
// Layer: Service
// Exports: CodexService turn-pagination compatibility helpers
// Depends on: Foundation, RPCMessage, CodexServiceError

import Foundation

extension CodexService {
    // Rejects known-old app-server versions instead of switching to the embedded-turn protocol.
    func validateTurnPaginationRuntimeVersion(_ response: RPCMessage) throws {
        guard let resultObject = response.result?.objectValue,
              let userAgent = resultObject["userAgent"]?.stringValue
                ?? resultObject["user_agent"]?.stringValue else {
            return
        }

        guard let version = codexCLIUserAgentVersion(userAgent),
              codexVersion(version, isOlderThan: (0, 147, 0)) else {
            return
        }

        presentTurnPaginationUpgradePrompt()
        throw CodexServiceError.invalidInput(
            "Mac 上的 Codex 版本过旧。Remodex 当前要求 codex-cli 0.147.0 或更高版本。"
        )
    }

    // Returns true when an RPC failure means the runtime cannot page turns or exclude embedded turns.
    func shouldDisableTurnPagination(_ error: Error, attemptedMethod: String? = nil) -> Bool {
        guard let serviceError = error as? CodexServiceError else {
            return false
        }

        switch serviceError {
        case .invalidResponse(let reason):
            let message = reason.lowercased()
            let attemptedTurnList = attemptedMethod == "thread/turns/list"
            guard attemptedTurnList || message.contains("thread/turns/list") else {
                return false
            }

            // New or bridge-wrapped runtimes can acknowledge the method but return a
            // non-page payload; use the older thread/read path instead of surfacing it.
            return message.contains("missing payload")
                || message.contains("missing data array")
                || message.contains("missing turns")
        case .rpcError(let rpcError):
            let message = rpcError.message.lowercased()
            let attemptedTurnList = attemptedMethod == "thread/turns/list"
            let mentionsMissingMethod = message.contains("method not found")
                || message.contains("unknown method")
                || message.contains("not implemented")
            let mentionsTurnList = message.contains("thread/turns/list")
                || message.contains("turns/list")
                || message.contains("turn pagination")
            let mentionsUnsupportedPagination = message.contains("unsupported")
                || message.contains("not supported")
            let mentionsExcludeTurns = message.contains("excludeturns")
                || message.contains("exclude_turns")
                || message.contains("exclude turns")
            let mentionsUnsupportedField = message.contains("unknown field")
                || message.contains("unrecognized field")
                || message.contains("failed to parse")
                || message.contains("invalid params")

            if rpcError.code == -32601 {
                return attemptedTurnList || mentionsTurnList || mentionsExcludeTurns
            }

            return mentionsMissingMethod
                && (attemptedTurnList || mentionsTurnList || mentionsExcludeTurns)
                || (attemptedTurnList && mentionsUnsupportedPagination)
                || (mentionsExcludeTurns && mentionsUnsupportedField)
        default:
            return false
        }
    }

    // Leaves the failing request intact and tells the user how to restore the current protocol.
    func presentUnsupportedTurnPaginationUpgradeIfNeeded(
        _ error: Error,
        attemptedMethod: String? = nil
    ) {
        guard shouldDisableTurnPagination(error, attemptedMethod: attemptedMethod) else {
            return
        }

        presentTurnPaginationUpgradePrompt()
    }

    func presentTurnPaginationUpgradePrompt() {
        guard bridgeUpdatePrompt == nil else {
            return
        }

        bridgeUpdatePrompt = CodexBridgeUpdatePrompt(
            title: L10n.string("请更新 Mac 上的 Remodex.app"),
            message: L10n.string("当前 Mac App 内置的 Bridge 或 Codex 不支持增量任务读取。更新 Mac App 和 Codex 后重新连接。"),
            command: nil
        )
    }
}

private extension CodexService {
    // Remodex validates codex_cli_rs/0.147.0 as its first supported app-server version.
    func codexCLIUserAgentVersion(_ userAgent: String) -> (major: Int, minor: Int, patch: Int)? {
        let parts = userAgent.split(separator: "/", maxSplits: 1)
        guard parts.count == 2,
              parts[0] == "codex_cli_rs" else {
            return nil
        }

        let versionParts = parts[1].split(separator: ".")
        guard versionParts.count >= 2,
              let major = Int(versionParts[0]),
              let minor = Int(versionParts[1]) else {
            return nil
        }

        let patchText = versionParts.dropFirst(2).first.map { String($0.prefix { $0.isNumber }) } ?? "0"
        return (major, minor, Int(patchText) ?? 0)
    }

    func codexVersion(
        _ lhs: (major: Int, minor: Int, patch: Int),
        isOlderThan rhs: (major: Int, minor: Int, patch: Int)
    ) -> Bool {
        if lhs.major != rhs.major {
            return lhs.major < rhs.major
        }
        if lhs.minor != rhs.minor {
            return lhs.minor < rhs.minor
        }
        return lhs.patch < rhs.patch
    }
}
