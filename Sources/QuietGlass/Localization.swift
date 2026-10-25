import AppKit
import SwiftUI

/// Looks up a runtime string (status, prompt, menu title) in Localizable.strings.
/// Missing keys fall back to the English text, so untranslated strings still read well.
func L(_ key: String) -> String {
    Bundle.main.localizedString(forKey: key, value: nil, table: nil)
}

/// Localized format string, e.g. LF("Blurs in %d:%@ · Esc to stop", minutes, seconds).
func LF(_ format: String, _ arguments: CVarArg...) -> String {
    String(format: L(format), locale: Locale.current, arguments: arguments)
}

extension Text {
    /// SwiftUI only localizes literal keys. Much of QuietGlass's UI shows model strings
    /// (`Text(model.status)`), so route every String through the same table.
    init(_ content: String) { self.init(verbatim: L(content)) }
}

extension Button where Label == Text {
    /// Dynamic button titles (`Button(primaryLabel)`) are localized like `Text`.
    init(_ title: String, action: @escaping () -> Void) {
        self.init(action: action) { Text(title) }
    }
}

/// In-app language override. "System" follows macOS (Settings → General → Language & Region).
enum AppLanguage: String, CaseIterable, Identifiable {
    case system, simplifiedChinese = "zh-Hans", english = "en"
    var id: String { rawValue }
    var title: String {
        switch self {
        case .system: return L("Same as System")
        case .simplifiedChinese: return "简体中文"
        case .english: return "English"
        }
    }
    static var current: AppLanguage {
        guard let languages = UserDefaults.standard.persistentDomain(forName: Bundle.main.bundleIdentifier ?? "")?["AppleLanguages"] as? [String],
              let first = languages.first else { return .system }
        return first.hasPrefix("zh") ? .simplifiedChinese : first.hasPrefix("en") ? .english : .system
    }
    /// Takes effect after relaunch, like per-app languages in System Settings.
    func apply() {
        if self == .system { UserDefaults.standard.removeObject(forKey: "AppleLanguages") }
        else { UserDefaults.standard.set([rawValue], forKey: "AppleLanguages") }
    }
}
