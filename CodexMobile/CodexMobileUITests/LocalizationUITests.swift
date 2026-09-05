import XCTest

final class LocalizationUITests: XCTestCase {
    override func setUpWithError() throws { continueAfterFailure = false }
    private func launch(_ route: String, language: String, theme: String = "light", large: Bool = false) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-RemodexLocalizationFixture", "-FixtureRoute", route, "-FixtureTheme", theme, "-remodex.language", language, "-AppleLanguages", language == "zh-Hans" ? "(zh-Hans)" : "(en)"]
        if large { app.launchArguments += ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"] }
        app.launch()
        return app
    }
    func testProductionScreensInBothLanguages() {
        let screens = [
            ("onboarding", "Control Codex from your iPhone.", "在 iPhone 上操作 Codex。"),
            ("pairing", "Confirm pairing device", "确认配对设备"),
            ("devices", "No paired devices yet.", "尚未配对任何设备。"),
            ("chat", "Working on it...", "正在处理…"),
            ("loading", "Loading chat...", "正在加载任务…"),
            ("questions", "Questions", "问题"),
            ("git", "Checking whether the reverse patch applies cleanly...", "正在检查反向补丁能否无冲突应用…"),
            ("voice", "On-device offline voice", "设备端离线语音"),
            ("errors", "Device offline. Open the desktop app and reconnect.", "设备离线，请打开桌面应用后重新连接。")
        ]
        for language in ["en", "zh-Hans"] {
            for (route, english, chinese) in screens {
                let app = launch(route, language: language, theme: language == "en" ? "light" : "dark")
                XCTAssertTrue(app.staticTexts[language == "en" ? english : chinese].waitForExistence(timeout: 15), route)
                let attachment = XCTAttachment(screenshot: app.screenshot()); attachment.name = "\(route)-\(language)"; attachment.lifetime = .keepAlways; add(attachment)
                app.terminate()
            }
        }
    }
    func testLanguageSwitchPreservesDraftAndServiceIdentity() {
        let app = launch("settings", language: "en")
        XCTAssertTrue(app.navigationBars["Settings"].waitForExistence(timeout: 15))
        let identity = app.staticTexts["fixture.service"].label
        let draft = app.textFields["fixture.draft"].value as? String
        app.buttons["fixture.zh"].tap()
        XCTAssertTrue(app.navigationBars["设置"].waitForExistence(timeout: 5))
        XCTAssertEqual(app.staticTexts["fixture.service"].label, identity)
        XCTAssertEqual(app.textFields["fixture.draft"].value as? String, draft)
        app.buttons["fixture.en"].tap()
        XCTAssertTrue(app.navigationBars["Settings"].waitForExistence(timeout: 5))
        XCTAssertEqual(app.staticTexts["fixture.service"].label, identity)
    }
    func testPairingAtAccessibilityTextSize() {
        let app = launch("pairing", language: "zh-Hans", theme: "dark", large: true)
        XCTAssertTrue(app.staticTexts["确认配对设备"].waitForExistence(timeout: 15))
        app.swipeUp()
        let confirm = app.buttons["确认设备，申请配对"]
        if !confirm.isHittable { app.swipeUp() }
        XCTAssertTrue(confirm.isHittable)
        let attachment = XCTAttachment(screenshot: app.screenshot()); attachment.name = "pairing-zh-accessibility"; attachment.lifetime = .keepAlways; add(attachment)
    }
}
