import Foundation

/// Pinyin index helpers built on the system's CFStringTransform (the same
/// transliteration the input method stack uses). Zero data tables; the
/// transform is context-aware for most polyphonic characters
/// (重庆 → chong, 重启 → zhong).
///
/// Search matching: a pure-ASCII-letter query also matches the toneless
/// syllables ("zhan"…) and their initials ("ztb"…).
enum Pinyin {
    /// Han text → space-separated toneless syllables; non-Han passes through.
    /// Lowercased, and punctuation inside a token stays attached to it.
    static func syllables(_ text: String) -> String {
        let capped = String(text.prefix(500)) // pinyin targets titles/beginnings
        let mutable = NSMutableString(string: capped)
        CFStringTransform(mutable, nil, kCFStringTransformMandarinLatin, false)
        CFStringTransform(mutable, nil, kCFStringTransformStripDiacritics, false)
        return (mutable as String).lowercased()
    }

    /// First ASCII letter of every syllable: "zhan tie ban" → "ztb".
    static func initials(_ text: String) -> String {
        syllables(text)
            .split(whereSeparator: { $0 == " " || $0 == "\t" || $0 == "\n" })
            .compactMap { token -> Character? in
                guard let first = token.first,
                      first.isASCII, first.isLetter else { return nil }
                return first
            }
            .map { String($0) }
            .joined()
    }

    /// Everything a query may match against (plain + syllables + initials).
    static func index(for searchableText: String) -> String {
        let syl = syllables(searchableText)
        let ini = initials(searchableText)
        return syl + "\u{1f}" + ini
    }

    /// A query goes down the pinyin path only when it is bare ASCII letters.
    static func isPinyinQuery(_ query: String) -> Bool {
        !query.isEmpty && query.allSatisfy { $0.isASCII && $0.isLetter }
    }
}
