import Foundation

/// Languages with first-class UI translations.
enum AppLanguage: String, CaseIterable {
    case english = "en"
    case simplifiedChinese = "zh-Hans"
    case traditionalChinese = "zh-Hant"

    static var current: AppLanguage {
        resolve(preferredLanguages: Locale.preferredLanguages)
    }

    /// Resolve Apple's ordered language preferences. Unknown languages deliberately
    /// use English so a partially translated interface is never selected.
    static func resolve(preferredLanguages: [String]) -> AppLanguage {
        for identifier in preferredLanguages {
            let normalized = identifier.replacingOccurrences(of: "_", with: "-").lowercased()
            if normalized == "en" || normalized.hasPrefix("en-") { return .english }
            if normalized == "zh-hant" || normalized.hasPrefix("zh-hant-")
                || ["zh-tw", "zh-hk", "zh-mo"].contains(normalized) { return .traditionalChinese }
            if normalized == "zh" || normalized == "zh-hans" || normalized.hasPrefix("zh-hans-")
                || ["zh-cn", "zh-sg"].contains(normalized) { return .simplifiedChinese }
        }
        return .english
    }

    var locale: Locale { Locale(identifier: rawValue) }
}

enum L10n {
    static func string(_ key: String, comment: String = "") -> String {
        NSLocalizedString(key, tableName: nil, bundle: .main, value: key, comment: comment)
    }

    static var openPanel: String { string("打开面板") }
    static var wipeScreen: String { string("擦屏幕") }
    static var backgroundWork: String { string("后台干") }
    static var settings: String { string("设置") }
    static var quit: String { string("退出") }
}
