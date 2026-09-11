import XCTest
@testable import QuadMonitor

final class AppTextTests: XCTestCase {
    func testPrimarySystemLanguageAndUnsupportedFallback() {
        for code in ["ko","ko-KR","KO_kr"] { XCTAssertEqual(AppLanguage.system.resolved(preferredLanguages:[code]),"ko") }
        for code in ["en","en-GB","en_US","ja-JP","fr-FR","de","","invalid"] {
            XCTAssertEqual(AppLanguage.system.resolved(preferredLanguages:[code,"ko-KR"]),"en")
        }
        for code in ["zh","zh-CN","zh-Hans-SG","zh-Hant-TW","zh-HK"] {
            XCTAssertEqual(AppLanguage.system.resolved(preferredLanguages:[code]),"zh-Hans")
        }
        XCTAssertEqual(AppLanguage.system.resolved(preferredLanguages:[]),"en")
    }
    func testExplicitChoiceOverridesSystemAndMessagesRenderInNewLanguage() {
        let message=AppMessage(.running,3)
        XCTAssertEqual(message.render(AppText(choice:.korean,preferredLanguages:["fr"])),"실행 중 — 독립 화면 3개")
        XCTAssertEqual(message.render(AppText(choice:.english,preferredLanguages:["ko"])),"Running — 3 independent displays")
        XCTAssertEqual(message.render(AppText(choice:.chinese,preferredLanguages:["en"])),"运行中 — 3 个独立显示器")
    }
    func testCatalogsHaveEveryKeyAndMatchingFormatArguments() throws {
        var catalogs: [[String:String]]=[]
        let expected=Set(AppText.Key.allCases.map(\.rawValue))
        let expression=try NSRegularExpression(pattern:"%(?:[0-9]+\\$)?(?:\\.[0-9]+)?(?:ld|@|f)")
        func placeholders(_ value:String) -> [String] {
            expression.matches(in:value,range:NSRange(value.startIndex...,in:value)).map {
                String(value[Range($0.range,in:value)!])
            }
        }
        for language in ["en","ko","zh-Hans"] {
            let directory=try XCTUnwrap(AppText.resourceBundle.url(forResource:language.lowercased(),withExtension:"lproj"))
            let data=try Data(contentsOf:directory.appendingPathComponent("Localizable.strings"))
            let values=try XCTUnwrap(PropertyListSerialization.propertyList(from:data,format:nil) as? [String:String])
            XCTAssertEqual(Set(values.keys),expected)
            XCTAssertTrue(values.values.allSatisfy{!$0.isEmpty})
            catalogs.append(values)
        }
        for key in expected {
            XCTAssertEqual(placeholders(catalogs[0][key]!),placeholders(catalogs[1][key]!))
            XCTAssertEqual(placeholders(catalogs[0][key]!),placeholders(catalogs[2][key]!))
        }
    }
    func testOldPreferencesKeepPerformanceAndLanguageDefaultsToSystem() throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at:root) }
        let directory=root.appendingPathComponent("control")
        try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true)
        let old=Data(#"{"fps":60,"demo":false,"panels":["left","top"],"performance":{"workers":1,"scheduling":"arrival","damage":"cpu","compression":"delta","queueDepth":3,"reuseBuffers":true}}"#.utf8)
        try old.write(to:directory.appendingPathComponent("preferences.json"))
        let defaults=["resources":"/tmp/Resources","coordinator":"/tmp/VerifiedSession","data_root":root.path]
        var config=try DesktopAppConfiguration.parse(["app"],defaults:defaults)
        XCTAssertEqual(config.language,.system);XCTAssertEqual(config.fps,60)
        XCTAssertEqual(config.selectedPanels,["left","top"]);XCTAssertTrue(config.performance.reuseBuffers)
        let arguments=config.workerArguments()
        for language in AppLanguage.allCases {
            config.language=language;try config.savePreferences()
            let loaded=try DesktopAppConfiguration.parse(["app"],defaults:defaults)
            XCTAssertEqual(loaded.language,language)
            XCTAssertEqual(loaded.workerArguments(),arguments)
        }
    }
}
