// FILE: CodexAccessMode.swift
// Purpose: Runtime permission mode for thread/turn operations.
// Layer: Model
// Exports: CodexAccessMode
// Depends on: Foundation

import Foundation

enum CodexAccessMode: String, Codable, CaseIterable, Hashable, Sendable {
    case onRequest = "on-request"
    case autoReview = "auto-review"
    case fullAccess = "full-access"

    var displayName: String {
        switch self {
        case .onRequest:
            return L10n.string("Ask")
        case .autoReview:
            return L10n.string("Approve for me")
        case .fullAccess:
            return L10n.string("Full")
        }
    }

    var pickerTitle: String {
        switch self {
        case .onRequest:
            return L10n.string("Ask for approval")
        case .autoReview:
            return L10n.string("Approve for me")
        case .fullAccess:
            return L10n.string("Full access")
        }
    }

    var pickerSubtitle: String {
        switch self {
        case .onRequest:
            return L10n.string("Always ask to edit external files and use the internet")
        case .autoReview:
            return L10n.string("Only ask for actions detected as potentially unsafe")
        case .fullAccess:
            return L10n.string("Full computer access (elevated risk)")
        }
    }

    // Tries modern approval-policy enums first, then the bridge's kebab-case sandbox enum fallback.
    var approvalPolicyCandidates: [String] {
        switch self {
        case .onRequest, .autoReview:
            return ["on-request", "onRequest"]
        case .fullAccess:
            return ["never"]
        }
    }

    var approvalsReviewerCandidates: [String?] {
        switch self {
        case .onRequest, .fullAccess:
            return ["user", nil]
        case .autoReview:
            return ["auto_review", "guardian_subagent"]
        }
    }

    var sandboxLegacyValue: String {
        switch self {
        case .onRequest, .autoReview:
            return "workspace-write"
        case .fullAccess:
            return "danger-full-access"
        }
    }
}

struct RuntimeAccessConfiguration: Equatable, Sendable {
    let mode: CodexAccessMode
    let approvalPolicyCandidates: [String]
    let approvalsReviewerCandidates: [String?]
    let legacySandbox: String
    let sandboxPolicy: JSONValue

    var approvalPolicy: String {
        approvalPolicyCandidates[0]
    }

    var approvalsReviewer: String? {
        approvalsReviewerCandidates[0]
    }

    init(mode: CodexAccessMode) {
        self.mode = mode
        approvalPolicyCandidates = mode.approvalPolicyCandidates
        approvalsReviewerCandidates = mode.approvalsReviewerCandidates
        legacySandbox = mode.sandboxLegacyValue
        switch mode {
        case .onRequest, .autoReview:
            sandboxPolicy = .object([
                "type": .string("workspaceWrite"),
                "networkAccess": .bool(true),
            ])
        case .fullAccess:
            sandboxPolicy = .object([
                "type": .string("dangerFullAccess"),
            ])
        }
    }
}
