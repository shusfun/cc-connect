// FILE: TurnGitSyncAlertTests.swift
// Purpose: Verifies the guided Git sync alerts map backend repo states to the right user decisions.
// Layer: Unit Test
// Exports: TurnGitSyncAlertTests
// Depends on: XCTest, CodexMobile

import XCTest
@testable import CodexMobile

@MainActor
final class TurnGitSyncAlertTests: XCTestCase {
    private static var retainedServices: [CodexService] = []

    func testCheckingRemoteStateDoesNotPullBeforeConfirmation() async {
        let viewModel = TurnViewModel()
        let defaults = UserDefaults(suiteName: "GitSyncAlertTests.\(UUID().uuidString)")!
        let service = CodexService(defaults: defaults)
        Self.retainedServices.append(service)
        service.isConnected = true
        service.isInitialized = true
        var methods: [String] = []
        service.requestTransportOverride = { method, _ in
            methods.append(method)
            return RPCMessage(id: .string(UUID().uuidString), result: .object(["state": .string("behind_only"), "branch": .string("feature/test"), "behind": .integer(2)]), includeJSONRPC: false)
        }
        viewModel.triggerGitAction(.syncNow, codex: service, workingDirectory: "/fixture/repo", threadID: "fixture", activeTurnID: nil)
        let deadline = Date().addingTimeInterval(2)
        while viewModel.isRunningGitAction && Date() < deadline { await Task.yield() }
        XCTAssertFalse(viewModel.isRunningGitAction)
        XCTAssertEqual(methods, ["git/status"])
        XCTAssertEqual(viewModel.gitSyncAlert?.buttons.map(\.action), [.dismissOnly, .pullRebase])
    }

    func testBehindOnlyOffersSafeRemoteUpdate() throws {
        let viewModel = TurnViewModel()

        let alert = try XCTUnwrap(viewModel.makeGitSyncAlert(
            for: GitRepoSyncResult(from: ["branch": .string("feature/sync"), "tracking": .string("origin/feature/sync"), "dirty": .bool(false), "ahead": .integer(0), "behind": .integer(2), "state": .string("behind_only"), "canPush": .bool(false)])
        ))

        XCTAssertEqual(alert.title, "Remote Update Available")
        XCTAssertEqual(alert.buttons.first(where: { $0.action != .dismissOnly })?.title, "Update Now")
        XCTAssertEqual(alert.buttons.map(\.action), [.dismissOnly, .pullRebase])
    }

    func testDivergedOffersConfirmedPullRebase() throws {
        let viewModel = TurnViewModel()

        let alert = try XCTUnwrap(viewModel.makeGitSyncAlert(
            for: GitRepoSyncResult(from: ["branch": .string("feature/rebase"), "tracking": .string("origin/feature/rebase"), "dirty": .bool(false), "ahead": .integer(1), "behind": .integer(1), "state": .string("diverged"), "canPush": .bool(false)])
        ))

        XCTAssertEqual(alert.title, "Remote History Diverged")
        XCTAssertEqual(alert.buttons.first(where: { $0.action != .dismissOnly })?.title, "Try Update")
        XCTAssertEqual(alert.buttons.map(\.action), [.dismissOnly, .pullRebase])
    }

    func testDirtyAndBehindStaysInformationalOnly() throws {
        let viewModel = TurnViewModel()

        let alert = try XCTUnwrap(viewModel.makeGitSyncAlert(
            for: GitRepoSyncResult(from: ["branch": .string("feature/dirty"), "tracking": .string("origin/feature/dirty"), "dirty": .bool(true), "ahead": .integer(0), "behind": .integer(3), "state": .string("dirty_and_behind"), "canPush": .bool(false)])
        ))

        XCTAssertEqual(alert.title, "Local Changes + Remote Update")
        XCTAssertNil(alert.buttons.first(where: { $0.action != .dismissOnly })?.title)
        XCTAssertEqual(alert.buttons.map(\.action), [.dismissOnly])
    }
}
