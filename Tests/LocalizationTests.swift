import Foundation

enum LocalizationTests {
    typealias Check = (Bool, String) -> Void

    static func run(check: Check) {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let resources = root.appendingPathComponent("Resources", isDirectory: true)
        let enURL = resources.appendingPathComponent("en.lproj", isDirectory: true)
        let zhURL = resources.appendingPathComponent("zh-Hans.lproj", isDirectory: true)

        guard let enStrings = strings(at: enURL.appendingPathComponent("Localizable.strings")),
              let zhStrings = strings(at: zhURL.appendingPathComponent("Localizable.strings")) else {
            check(false, "both Localizable.strings files must parse")
            return
        }

        check(Set(enStrings.keys) == Set(zhStrings.keys),
              "English and Simplified Chinese string keys must match")
        check(enStrings.values.allSatisfy { !$0.isEmpty },
              "English fallback strings must all be non-empty")
        for key in Set(enStrings.keys).intersection(zhStrings.keys) {
            check(placeholders(in: enStrings[key]!) == placeholders(in: zhStrings[key]!),
                  "format placeholders must match for \(key)")
        }

        let referenced = sourceKeys(in: root.appendingPathComponent("Sources", isDirectory: true))
            .union(dynamicKeys)
        check(referenced.isSubset(of: Set(enStrings.keys)),
              "every L10n key referenced by source must exist in the English fallback")

        guard let enDict = dictionary(at: enURL.appendingPathComponent("Localizable.stringsdict")),
              let zhDict = dictionary(at: zhURL.appendingPathComponent("Localizable.stringsdict")) else {
            check(false, "both Localizable.stringsdict files must parse")
            return
        }
        check(Set(enDict.keys) == Set(zhDict.keys),
              "English and Simplified Chinese plural keys must match")
        check(Set(enDict.keys).isSubset(of: Set(enStrings.keys)),
              "every plural key must have an English fallback string")
        checkPluralCompatibility(enDict, zhDict, check: check)

        if let enBundle = Bundle(path: enURL.path), let zhBundle = Bundle(path: zhURL.path) {
            check(L10n.text("menu.new_note", bundle: enBundle) == "New Note",
                  "English bundle lookup must resolve English")
            check(L10n.text("menu.new_note", bundle: zhBundle) == "新建便笺",
                  "Simplified Chinese bundle lookup must resolve Chinese")
            check(L10n.plural("notes.count", 1, bundle: enBundle) == "1 note",
                  "English singular rule must resolve")
            check(L10n.plural("notes.count", 2, bundle: enBundle) == "2 notes",
                  "English plural rule must resolve")
            check(L10n.plural("notes.count", 2, bundle: zhBundle) == "2 篇便笺",
                  "Simplified Chinese plural rule must resolve")
            check(L10n.plural("export.choose_folder", 1, "MD", bundle: enBundle)
                  == "Choose a folder for 1 MD file.",
                  "plural formatting must preserve additional English arguments")
            check(L10n.plural("export.choose_folder", 2, "MD", bundle: zhBundle)
                  == "请选择用于保存 2 个 MD 文件的文件夹。",
                  "plural formatting must preserve additional Chinese arguments")
        } else {
            check(false, "language resource directories must load as bundles")
        }

        let available = ["en", "zh-Hans"]
        check(Bundle.preferredLocalizations(from: available,
                                            forPreferences: ["en-US"]).first == "en",
              "an English system preference must select English")
        check(Bundle.preferredLocalizations(from: available,
                                            forPreferences: ["zh-Hans-CN"]).first == "zh-Hans",
              "a Simplified Chinese system preference must select zh-Hans")

        check(AppLanguage.resolve(nil) == .system
              && AppLanguage.resolve(["en-GB"]) == .english
              && AppLanguage.resolve(["zh-Hans-CN"]) == .simplifiedChinese,
              "application language identifiers must resolve to the supported choices")
        testLanguagePreference(check: check)

        guard let info = dictionary(at: root.appendingPathComponent("Info.plist")) else {
            check(false, "Info.plist must parse")
            return
        }
        check(info["CFBundleDevelopmentRegion"] as? String == "en",
              "Info.plist must declare English as the development language")
        check(Set(info["CFBundleLocalizations"] as? [String] ?? []) == Set(available),
              "Info.plist must declare exactly English and Simplified Chinese")

        check(NoteTextDirection.leftToRight.rawValue == "leftToRight"
              && DeckStyle.tabs.rawValue == "tabs"
              && LibraryMode.all.rawValue == "All Notes",
              "localization must not change existing enum raw values")
        check(StickyNote(Note(color: 0)).colorName == "Lemon",
              ".stickies colorName must remain the stable English archive value")
    }

    private static func testLanguagePreference(check: Check) {
        let suite = "app.noty.localization-tests.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suite) else {
            check(false, "an isolated defaults suite must be available")
            return
        }
        defer { defaults.removePersistentDomain(forName: suite) }

        Settings.setAppLanguage(.english, in: defaults)
        check(Settings.appLanguage(in: defaults, applicationDomain: suite) == .english,
              "English must persist as an application language override")
        Settings.setAppLanguage(.simplifiedChinese, in: defaults)
        check(Settings.appLanguage(in: defaults, applicationDomain: suite) == .simplifiedChinese,
              "Simplified Chinese must persist as an application language override")
        Settings.setAppLanguage(.system, in: defaults)
        check(Settings.appLanguage(in: defaults, applicationDomain: suite) == .system,
              "System Default must remove the application language override")
    }

    private static let dynamicKeys: Set<String> = [
        "color.lemon", "color.peach", "color.rose", "color.lilac",
        "color.sky", "color.mint", "color.sand", "color.slate",
        "size.small", "size.medium", "size.large", "size.extra_large",
        "size.huge", "size.default", "width.narrow", "width.standard",
        "width.wide", "width.very_wide",
    ]

    private static func strings(at url: URL) -> [String: String]? {
        guard let value = dictionary(at: url) else { return nil }
        return value as? [String: String]
    }

    private static func dictionary(at url: URL) -> [String: Any]? {
        guard let data = try? Data(contentsOf: url),
              let value = try? PropertyListSerialization.propertyList(from: data,
                                                                       options: [],
                                                                       format: nil)
        else { return nil }
        return value as? [String: Any]
    }

    private static func placeholders(in value: String) -> [String] {
        let pattern = #"%(?:[0-9]+\$)?(?:[-+0 #']*\d*(?:\.\d+)?)?(?:hh|h|ll|l|L|z|j|t|q)?[@diuoxXfFeEgGaAcCsSp]"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let ns = value as NSString
        return regex.matches(in: value, range: NSRange(location: 0, length: ns.length))
            .map { ns.substring(with: $0.range) }
            .sorted()
    }

    private static func pluralTokens(in value: String) -> [String] {
        let pattern = #"%(?:[0-9]+\$)?#@[^@]+@"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let ns = value as NSString
        return regex.matches(in: value, range: NSRange(location: 0, length: ns.length))
            .map { ns.substring(with: $0.range) }
            .sorted()
    }

    private static func sourceKeys(in directory: URL) -> Set<String> {
        let manager = FileManager.default
        guard let files = try? manager.contentsOfDirectory(at: directory,
                                                            includingPropertiesForKeys: nil) else {
            return []
        }
        let pattern = #"L10n\.(?:text|format|plural)\(\s*\"([^\"]+)\""#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        var keys = Set<String>()
        for file in files where file.pathExtension == "swift" {
            guard let source = try? String(contentsOf: file, encoding: .utf8) else { continue }
            let ns = source as NSString
            for match in regex.matches(in: source,
                                       range: NSRange(location: 0, length: ns.length)) {
                keys.insert(ns.substring(with: match.range(at: 1)))
            }
        }
        return keys.filter { !$0.contains("\\(") }
    }

    private static func checkPluralCompatibility(_ en: [String: Any],
                                                 _ zh: [String: Any],
                                                 check: Check) {
        for key in Set(en.keys).intersection(zh.keys) {
            guard let left = en[key] as? [String: Any],
                  let right = zh[key] as? [String: Any],
                  let leftFormat = left["NSStringLocalizedFormatKey"] as? String,
                  let rightFormat = right["NSStringLocalizedFormatKey"] as? String else {
                check(false, "plural entry \(key) must have a localized format")
                continue
            }
            check(pluralTokens(in: leftFormat) == pluralTokens(in: rightFormat),
                  "plural variables must match for \(key)")
            let leftVariables = Set(left.keys).subtracting(["NSStringLocalizedFormatKey"])
            let rightVariables = Set(right.keys).subtracting(["NSStringLocalizedFormatKey"])
            check(leftVariables == rightVariables, "plural variable keys must match for \(key)")

            for variable in leftVariables.intersection(rightVariables) {
                guard let leftRule = left[variable] as? [String: String],
                      let rightRule = right[variable] as? [String: String] else {
                    check(false, "plural rule \(key).\(variable) must parse")
                    continue
                }
                check(leftRule["NSStringFormatSpecTypeKey"] == rightRule["NSStringFormatSpecTypeKey"],
                      "plural rule type must match for \(key).\(variable)")
                check(leftRule["NSStringFormatValueTypeKey"] == rightRule["NSStringFormatValueTypeKey"],
                      "plural value type must match for \(key).\(variable)")
                let leftCategories = Set(leftRule.keys).subtracting([
                    "NSStringFormatSpecTypeKey", "NSStringFormatValueTypeKey",
                ])
                let rightCategories = Set(rightRule.keys).subtracting([
                    "NSStringFormatSpecTypeKey", "NSStringFormatValueTypeKey",
                ])
                check(leftCategories == rightCategories,
                      "plural categories must match for \(key).\(variable)")
                for category in leftCategories.intersection(rightCategories) {
                    check(placeholders(in: leftRule[category]!) == placeholders(in: rightRule[category]!),
                          "plural placeholders must match for \(key).\(variable).\(category)")
                }
            }
        }
    }
}
