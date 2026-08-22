import Foundation

/// Lightweight in-code localization. The app ships no .lproj bundles (the .app is
/// hand-assembled by scripts/build_app.sh), so translations live here and follow
/// the user's system language. Replace with String Catalogs if the project ever
/// grows full i18n needs.
enum L10n {
    static var isChinese: Bool {
        Locale.preferredLanguages.first?.hasPrefix("zh") == true
    }

    /// Returns the Chinese variant when the system language is Chinese,
    /// otherwise the English original (which also stays as the source of truth
    /// for grep-ability).
    static func t(_ en: String, _ zh: String) -> String {
        isChinese ? zh : en
    }
}
