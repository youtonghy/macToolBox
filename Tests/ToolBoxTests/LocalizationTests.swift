import XCTest
@testable import ToolBoxCore

final class LocalizationTests: XCTestCase {
    func testEnglishIsSelectedAutomatically() {
        XCTAssertEqual(AppLanguage.resolve(preferredLanguages: ["en-US"]), .english)
    }

    func testChineseScriptAndRegionAreRecognized() {
        XCTAssertEqual(AppLanguage.resolve(preferredLanguages: ["zh-TW"]), .traditionalChinese)
        XCTAssertEqual(AppLanguage.resolve(preferredLanguages: ["zh-CN"]), .simplifiedChinese)
    }

    func testUnsupportedLanguageFallsBackToEnglish() {
        XCTAssertEqual(AppLanguage.resolve(preferredLanguages: ["fr-FR", "de-DE"]), .english)
    }

    func testLaterSupportedPreferenceIsUsed() {
        XCTAssertEqual(AppLanguage.resolve(preferredLanguages: ["fr-FR", "zh-Hant"]), .traditionalChinese)
    }
}
