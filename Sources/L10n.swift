import Foundation

/// The single entry point for user-facing copy. Stable identifiers (database
/// fields, defaults keys, URL routes, archive values, and font names) never pass
/// through this type.
enum L10n {
    /// Bundle used for localization lookups. Defaults to .main, but falls back
    /// to the English resource bundle if running outside a bundled application
    /// (e.g., during command-line tests).
    static var fallbackBundle: Bundle = {
        let bundle = Bundle.main
        if bundle.path(forResource: "Localizable", ofType: "strings") != nil {
            return bundle
        }
        let devURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Resources/en.lproj")
        return Bundle(url: devURL) ?? .main
    }()

    static func text(_ key: String, bundle: Bundle? = nil) -> String {
        let b = bundle ?? fallbackBundle
        return b.localizedString(forKey: key, value: nil, table: "Localizable")
    }

    static func format(_ key: String, _ arguments: CVarArg...) -> String {
        String(format: text(key), locale: .current, arguments: arguments)
    }

    static func plural(_ key: String, _ count: Int, bundle: Bundle? = nil) -> String {
        let b = bundle ?? fallbackBundle
        return String(format: text(key, bundle: b), locale: locale(for: b),
                      arguments: [count])
    }

    static func plural(_ key: String, _ count: Int, _ value: String,
                       bundle: Bundle? = nil) -> String {
        let b = bundle ?? fallbackBundle
        return String(format: text(key, bundle: b), locale: locale(for: b),
                      arguments: [count, value])
    }

    /// Plural rules follow the app language, which can differ from the Mac's
    /// regional format when the user chooses a per-app language in Settings.
    private static func locale(for bundle: Bundle) -> Locale {
        if bundle.bundleURL.pathExtension == "lproj" {
            return Locale(identifier: bundle.bundleURL.deletingPathExtension().lastPathComponent)
        }
        return Locale(identifier: bundle.preferredLocalizations.first
                      ?? bundle.developmentLocalization
                      ?? Locale.current.identifier)
    }
}
