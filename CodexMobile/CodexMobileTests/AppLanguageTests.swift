import XCTest
@testable import CodexMobile

final class AppLanguageTests: XCTestCase {
    func testSystemResolutionAndExplicitSelection() {
        XCTAssertEqual(AppLanguage.system.resolved(preferredLanguages: ["zh-Hans-CN"]), "zh-Hans")
        XCTAssertEqual(AppLanguage.system.resolved(preferredLanguages: ["zh-CN"]), "zh-Hans")
        XCTAssertEqual(AppLanguage.system.resolved(preferredLanguages: ["fr-FR", "zh-Hans"]), "en")
        XCTAssertEqual(AppLanguage.system.resolved(preferredLanguages: ["zh-Hant-TW"]), "en")
        XCTAssertEqual(AppLanguage.system.resolved(preferredLanguages: []), "en")
        XCTAssertEqual(AppLanguage.english.resolved(preferredLanguages: ["zh-Hans"]), "en")
        XCTAssertEqual(AppLanguage.simplifiedChinese.resolved(preferredLanguages: ["en"]), "zh-Hans")
    }

    func testCompiledCatalogIncludesBothLanguages() {
        XCTAssertEqual(L10n.string("Settings", language: .english), "Settings")
        XCTAssertEqual(L10n.string("Settings", language: .simplifiedChinese), "设置")
        XCTAssertEqual(L10n.string("确认配对设备", language: .english), "Confirm pairing device")
        XCTAssertEqual(L10n.string("A source thread id is required.", language: .simplifiedChinese), "缺少来源任务标识。")
        XCTAssertEqual(L10n.string("user supplied project name", language: .simplifiedChinese), "user supplied project name")
    }

    func testLanguagePreferenceDoesNotModifyOtherDefaultsAndPluralFormatting() {
        let defaults = UserDefaults.standard
        let previous = defaults.object(forKey: AppLanguage.storageKey)
        defer { if let previous { defaults.set(previous, forKey: AppLanguage.storageKey) } else { defaults.removeObject(forKey: AppLanguage.storageKey) } }
        // 只检查本测试拥有的业务状态，避免系统异步更新 UserDefaults 导致假失败。
        let draftKey = "remodex.tests.language.draft"
        let previousDraft = defaults.object(forKey: draftKey)
        defaults.set("Original draft / 原始草稿", forKey: draftKey)
        defer { if let previousDraft { defaults.set(previousDraft, forKey: draftKey) } else { defaults.removeObject(forKey: draftKey) } }
        defaults.set(AppLanguage.english.rawValue, forKey: AppLanguage.storageKey)
        XCTAssertEqual(L10n.count("files.count", 1), "1 file")
        XCTAssertEqual(L10n.count("files.count", 2), "2 files")
        defaults.set(AppLanguage.simplifiedChinese.rawValue, forKey: AppLanguage.storageKey)
        XCTAssertEqual(L10n.count("files.count", 2), "2 个文件")
        XCTAssertEqual(L10n.format("Connection status: %@", "设备 A"), "连接状态：设备 A")
        XCTAssertEqual(defaults.string(forKey: draftKey), "Original draft / 原始草稿")
    }

    func testAccessErrorIsLocalizedWhenPresentedAndKeepsDiagnosticIdentity() {
        let defaults = UserDefaults.standard
        let previous = defaults.object(forKey: AppLanguage.storageKey)
        defer { if let previous { defaults.set(previous, forKey: AppLanguage.storageKey) } else { defaults.removeObject(forKey: AppLanguage.storageKey) } }
        let requestID = UUID()
        let error = RelayAccessFailure(code: "device_offline", status: 409, requestID: requestID)
        defaults.set(AppLanguage.english.rawValue, forKey: AppLanguage.storageKey)
        XCTAssertTrue(error.localizedDescription.contains("Device offline."))
        defaults.set(AppLanguage.simplifiedChinese.rawValue, forKey: AppLanguage.storageKey)
        XCTAssertTrue(error.localizedDescription.contains("设备离线"))
        XCTAssertTrue(error.localizedDescription.contains(requestID.uuidString))
        let unknown = RelayAccessFailure(code: "untrusted-server-text", status: 500, requestID: nil)
        XCTAssertFalse(unknown.localizedDescription.contains("untrusted-server-text"))
        XCTAssertTrue(unknown.localizedDescription.contains("重试"))
    }
}
