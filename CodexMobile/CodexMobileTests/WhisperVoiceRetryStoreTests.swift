// FILE: WhisperVoiceRetryStoreTests.swift
// Purpose: Verifies encrypted local voice retry retention and the 24-hour cleanup boundary.
// Layer: Unit Test
// Depends on: CryptoKit, Foundation, XCTest, CodexMobile

import CryptoKit
import Foundation
import XCTest
@testable import CodexMobile

final class WhisperVoiceRetryStoreTests: XCTestCase {
    private let key = SymmetricKey(data: Data(repeating: 0x5A, count: 32))

    func testRetainedClipRoundTripsEncryptedAndIsDiscardedExplicitly() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        let id = try fixture.store.retain(fixture.clip)
        let encryptedURL = fixture.storeDirectory
            .appendingPathComponent(id.uuidString)
            .appendingPathExtension("voiceclip")
        let encryptedBytes = try Data(contentsOf: encryptedURL)
        XCTAssertNil(encryptedBytes.range(of: fixture.audioData))

        let retained = try fixture.store.latest()
        defer { try? FileManager.default.removeItem(at: retained.fileURL) }
        XCTAssertEqual(retained.clip.id, id)
        XCTAssertEqual(retained.clip.audioData, fixture.audioData)
        XCTAssertEqual(retained.clip.durationSeconds, fixture.clip.durationSeconds)

        fixture.store.discard(id)
        XCTAssertFalse(FileManager.default.fileExists(atPath: encryptedURL.path))
    }

    func testRemoveExpiredDeletesClipsAtTwentyFourHoursOnly() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        let id = try fixture.store.retain(fixture.clip)
        let encryptedURL = fixture.storeDirectory
            .appendingPathComponent(id.uuidString)
            .appendingPathExtension("voiceclip")
        let now = Date(timeIntervalSince1970: 2_000_000_000)

        try FileManager.default.setAttributes(
            [.modificationDate: now.addingTimeInterval(-WhisperVoiceRetryStore.retentionSeconds + 1)],
            ofItemAtPath: encryptedURL.path
        )
        fixture.store.removeExpired(now: now)
        XCTAssertTrue(FileManager.default.fileExists(atPath: encryptedURL.path))

        try FileManager.default.setAttributes(
            [.modificationDate: now.addingTimeInterval(-WhisperVoiceRetryStore.retentionSeconds)],
            ofItemAtPath: encryptedURL.path
        )
        fixture.store.removeExpired(now: now)
        XCTAssertFalse(FileManager.default.fileExists(atPath: encryptedURL.path))
    }

    private func makeFixture() throws -> (
        root: URL,
        storeDirectory: URL,
        store: WhisperVoiceRetryStore,
        clip: VoiceRecordingClip,
        audioData: Data
    ) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("remodex-voice-retry-tests-\(UUID().uuidString)", isDirectory: true)
        let storeDirectory = root.appendingPathComponent("store", isDirectory: true)
        let audioURL = root.appendingPathComponent("recording.wav")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        let audioData = Data("private voice fixture".utf8)
        try audioData.write(to: audioURL)
        let clip = VoiceRecordingClip(
            url: audioURL,
            mimeType: "audio/wav",
            durationSeconds: 4.25,
            byteCount: audioData.count
        )
        let key = self.key
        let store = WhisperVoiceRetryStore(directory: storeDirectory) { key }
        return (root, storeDirectory, store, clip, audioData)
    }
}
