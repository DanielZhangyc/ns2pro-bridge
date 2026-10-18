import Foundation
import XCTest
@testable import BridgeApp

final class LocalizationTests: XCTestCase {
    private var resourcesURL: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Resources", isDirectory: true)
    }

    private func strings(_ language: String) throws -> [String: String] {
        let url = resourcesURL.appendingPathComponent("\(language).lproj/Localizable.strings")
        let value = try PropertyListSerialization.propertyList(from: Data(contentsOf: url), format: nil)
        return try XCTUnwrap(value as? [String: String])
    }

    func testBothLanguagesContainTheSameKeysAndEnglishDefaults() throws {
        let english = try strings("en")
        let chinese = try strings("zh-Hans")
        XCTAssertFalse(english.isEmpty)
        XCTAssertEqual(Set(english.keys), Set(chinese.keys))
        for (key, value) in english {
            XCTAssertEqual(value, key, "English key must remain a readable default: \(key)")
            XCTAssertFalse(try XCTUnwrap(chinese[key]).isEmpty)
        }
    }

    func testFoundationBundleLoadsSelectedLanguageAndEnglishFallback() throws {
        let bundle = try XCTUnwrap(Bundle(url: resourcesURL))
        XCTAssertEqual(L10n.text("Connect Controller", bundle: bundle, language: "en-US"), "Connect Controller")
        XCTAssertEqual(L10n.text("Connect Controller", bundle: bundle, language: "zh-CN"), "连接手柄")
        XCTAssertEqual(L10n.text("Searching for controller", bundle: bundle, language: "zh-Hans"), "正在搜索手柄")
        XCTAssertEqual(L10n.text("Connect Controller", bundle: bundle, language: "fr-FR"), "Connect Controller")
    }

    func testDynamicAccessibilityAndNumericFormatting() throws {
        let bundle = try XCTUnwrap(Bundle(url: resourcesURL))
        XCTAssertEqual(L10n.format("%@, %@", "GL", "Pressed", bundle: bundle, language: "en"), "GL, Pressed")
        let pressed = L10n.text("Pressed", bundle: bundle, language: "zh-Hans")
        XCTAssertEqual(L10n.format("%@, %@", "GL", pressed, bundle: bundle, language: "zh-Hans"), "GL，按下")
        XCTAssertEqual(L10n.format("%lld / 9", 6, bundle: bundle, language: "en"), "6 / 9")
        XCTAssertEqual(L10n.format("%.3f V", 3.875, bundle: bundle, language: "zh-Hans"), "3.875 V")
        XCTAssertEqual(L10n.format("%+.2f, %+.2f", 0.25, -0.5, bundle: bundle, language: "en"), "+0.25, -0.50")
        XCTAssertEqual(L10n.text(", ", bundle: bundle, language: "zh-Hans"), "、")
    }

    func testDynamicErrorFormattingAndButtonNames() throws {
        let bundle = try XCTUnwrap(Bundle(url: resourcesURL))
        let operation = L10n.text("Could not create the dual-frequency interface", bundle: bundle, language: "zh-Hans")
        XCTAssertEqual(L10n.format("%@: %@", operation, "EIO", bundle: bundle, language: "zh-Hans"), "创建双频接口失败：EIO")
        XCTAssertEqual(L10n.text("Left stick", bundle: bundle, language: "zh-Hans"), "左摇杆")
        XCTAssertEqual(L10n.text("Capture", bundle: bundle, language: "zh-Hans"), "截图")
        XCTAssertEqual(L10n.text("Collapsed", bundle: bundle, language: "zh-Hans"), "已收起")
        XCTAssertTrue(NativeHapticsError.invalidFrame.localizedDescription.hasPrefix("Invalid dual-frequency frame."))
    }
}
