import Foundation

/// 只保存展示偏好；切换语言不替换 CodexService、连接或本地数据。
nonisolated enum AppLanguage: String, CaseIterable, Identifiable {
    case system, simplifiedChinese = "zh-Hans", english = "en"
    static let storageKey = "remodex.language"
    var id: String { rawValue }

    func resolved(preferredLanguages: [String] = Locale.preferredLanguages) -> String {
        switch self {
        case .simplifiedChinese: return "zh-Hans"
        case .english: return "en"
        case .system:
            let first = preferredLanguages.first?.lowercased() ?? "en"
            return first == "zh" || first.hasPrefix("zh-hans") || first.hasPrefix("zh-cn") || first.hasPrefix("zh-sg") ? "zh-Hans" : "en"
        }
    }
}

nonisolated enum L10n {
    static var language: AppLanguage {
        AppLanguage(rawValue: UserDefaults.standard.string(forKey: AppLanguage.storageKey) ?? "system") ?? .system
    }
    static var locale: Locale { Locale(identifier: language.resolved()) }

    static func string(_ key: String, language: AppLanguage? = nil, bundle: Bundle = .main) -> String {
        let code = (language ?? self.language).resolved()
        let localizedBundle = bundle.path(forResource: code, ofType: "lproj").flatMap(Bundle.init(path:)) ?? bundle
        return localizedBundle.localizedString(forKey: key, value: key, table: "Localizable")
    }

    static func format(_ key: String, _ arguments: CVarArg...) -> String {
        String(format: string(key), locale: locale, arguments: arguments)
    }

    static func count(_ key: String, _ count: Int) -> String {
        String.localizedStringWithFormat(string(key), count)
    }
}
