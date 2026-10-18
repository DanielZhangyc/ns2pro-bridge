import Foundation

enum L10n {
    // 英文键同时作为默认文案；测试可显式指定资源 Bundle 和语言。
    // English keys are also defaults; tests can select a resource bundle and language explicitly.
    static func text(_ key: String, bundle: Bundle = .main, language: String? = nil) -> String {
        let resources: Bundle
        if let language {
            let selected = Bundle.preferredLocalizations(from: ["en", "zh-Hans"], forPreferences: [language])[0]
            guard let url = bundle.url(forResource: selected, withExtension: "lproj"),
                  let localized = Bundle(url: url) else {
                preconditionFailure("Missing localization resources: \(selected)")
            }
            resources = localized
        } else {
            resources = bundle
        }
        return NSLocalizedString(key, tableName: "Localizable", bundle: resources, value: key, comment: "")
    }

    static func format(_ key: String, _ arguments: any CVarArg..., bundle: Bundle = .main,
                       language: String? = nil) -> String {
        let locale = language.map(Locale.init(identifier:)) ?? .current
        return String(format: text(key, bundle: bundle, language: language), locale: locale, arguments: arguments)
    }
}
