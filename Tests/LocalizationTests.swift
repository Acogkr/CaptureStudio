import AppKit

@MainActor
func runLocalizationTests() throws -> Int {
    var checks = 0
    func check(_ value: @autoclosure () throws -> Bool, _ message: String) throws {
        guard try value() else { throw NSError(domain: "CaptureStudio.LocalizationTests", code: 1,
            userInfo: [NSLocalizedDescriptionKey: message]) }
        checks += 1
    }
    defer { L10n.testCode = nil }
    let domain = "CaptureStudio-LanguageTests-" + UUID().uuidString
    let defaults = UserDefaults(suiteName: domain)!
    defer { defaults.removePersistentDomain(forName: domain) }
    var system = ["fr-FR", "ja-JP", "ko-KR"]
    let preference = Localization(defaults: defaults, preferredLanguages: { system })
    try check(preference.selection == "system" && preference.resolvedCode == "ja"
        && defaults.object(forKey: Localization.preferenceKey) == nil,
        "First launch follows supported system preferences without writing an override")
    system = ["ko-KR"]
    preference.refreshSystemLanguage()
    try check(preference.resolvedCode == "ko", "System default follows a changed preferred language")
    preference.selection = "en"
    try check(preference.resolvedCode == "en" && defaults.string(forKey: Localization.preferenceKey) == "en",
        "Explicit selection overrides the system and is persisted")
    let restarted = Localization(defaults: defaults, preferredLanguages: { system })
    try check(restarted.selection == "en" && restarted.resolvedCode == "en", "Selection survives restart")
    restarted.selection = "system"
    try check(defaults.object(forKey: Localization.preferenceKey) == nil && restarted.resolvedCode == "ko",
        "Returning to system default removes only the app's language override")
    defaults.set("missing", forKey: Localization.preferenceKey)
    try check(Localization(defaults: defaults, preferredLanguages: { ["ja"] }).resolvedCode == "ja",
        "Unknown saved language falls back to system preferences")
    try check(Localization.preferenceKey != "StudioLanguage", "The two apps have independent language preferences")
    let cases: [([String], String)] = [
        (["ko-KR"], "ko"), (["en_GB"], "en"), (["ja-JP"], "ja"), (["zh-CN"], "zh-Hans"),
        (["zh-Hant-TW"], "zh-Hans"), (["de", "ko", "en"], "ko"), (["fr", "en-US", "ja"], "en"),
        (["de-DE"], "en"), ([], "en"), (["JA_jp"], "ja"),
    ]
    for (languages, expected) in cases {
        try check(L10n.resolve(languages) == expected, "System language negotiation: \(languages)")
    }
    try check(L10n.text("Undo", code: "unknown") == "Undo", "Missing languages fall back to English")
    try check(L10n.format("{1} / {0} / {1}", arguments: ["User text {1}", "B"], locale: Locale(identifier: "en"))
        == "B / User text {1} / B", "Formatting never interprets user-provided braces")
    let codes = ["en", "ko", "ja", "zh-Hans"]
    try check(Set(L10n.bundles.keys) == Set(codes), "All four language resources are bundled")
    var expectedKeys: Set<String>?
    let toolNames = ["en": "Arrow", "ko": "화살표", "ja": "矢印", "zh-Hans": "箭头"]
    let model = EditorModel()
    let userTitle = "My photo 한국어 日本語 中文 {0}"
    model.load(DemoImage.make(), title: userTitle)
    model.beginTextEditing(at: CGPoint(x: 30, y: 40))
    model.updateText("User text 한국어 日本語 中文 {1}")
    model.finishTextEditing()
    let image = model.state.image
    let stateID = model.state.id
    let mark = model.state.marks[0]
    for code in codes {
        L10n.testCode = code
        let url = L10n.bundles[code]!.url(forResource: "Localizable", withExtension: "strings")!
        let dictionary = try PropertyListSerialization.propertyList(from: Data(contentsOf: url), format: nil) as! [String: String]
        let keys = Set(dictionary.keys)
        if let expectedKeys { try check(keys == expectedKeys, "\(code): translation keys match English") }
        else { expectedKeys = keys }
        try check(dictionary.values.allSatisfy { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty },
            "\(code): no empty translations")
        func tokens(_ text: String) -> [String] {
            let source = text as NSString
            return L10n.placeholders.matches(in: text, range: NSRange(location: 0, length: source.length))
                .map { source.substring(with: $0.range) }.sorted()
        }
        try check(dictionary.allSatisfy { tokens($0.key) == tokens($0.value) }, "\(code): all placeholders are preserved")
        try check(EditorTool.arrow.title == toolNames[code], "\(code): actual tool labels use the selected language")
        try check(!L("Images: {0}", 12).contains("{0}") && !UpdateStatus.available(AppRelease("v1.2")!).message.contains("{0}"),
            "\(code): counts and update notifications interpolate correctly")
        try check(CaptureMode.area.rawValue == "area" && CaptureMode.area.title != "area",
            "\(code): capture identifiers remain independent of translated labels")
        try check(model.state.id == stateID && model.state.image === image && model.title == userTitle
            && model.state.marks[0].text == mark.text && model.canUndo,
            "\(code): language changes preserve image, user text, filename and undo history")
        try check(!L10n.date(Date(timeIntervalSince1970: 0)).isEmpty, "\(code): recent dates use the selected locale")
    }
    model.undo()
    try check(model.state.marks.isEmpty && model.canRedo, "Undo still works after changing languages")
    model.redo()
    try check(model.state.marks[0].text == mark.text, "Redo still restores exact user text")
    let sourceRoot = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Sources")
    let pattern = try NSRegularExpression(pattern: #"\bL\("((?:[^"\\]|\\.)*)""#)
    var usedKeys = Set<String>()
    for source in try FileManager.default.contentsOfDirectory(at: sourceRoot, includingPropertiesForKeys: nil)
        where source.pathExtension == "swift" {
        let text = try String(contentsOf: source, encoding: .utf8) as NSString
        for match in pattern.matches(in: text as String, range: NSRange(location: 0, length: text.length)) {
            let escaped = text.substring(with: match.range(at: 1))
            let key = try JSONDecoder().decode(String.self, from: Data(("\"" + escaped + "\"").utf8))
            usedKeys.insert(key)
        }
    }
    try check(usedKeys.isSubset(of: expectedKeys!), "Every localized source key exists in all four resources")
    return checks
}
