import Foundation

/// Builds the `full` / `abbr` search keys for a name.
///
/// * CJK runs (U+4E00…U+9FFF) are transliterated to latin pinyin (tones stripped) and each
///   syllable becomes a token.
/// * ASCII letter/digit runs are split at lower→upper case and letter↔digit boundaries.
/// * Any other single scalar becomes its own token.
/// `full` = tokens joined; `abbr` = first character of each token joined. All lowercased.
enum SearchKeyGenerator {
    static func keys(for input: String) -> (full: String, abbr: String) {
        guard !input.isEmpty else { return ("", "") }
        var full = ""
        var abbr = ""

        func append(_ token: String) {
            guard !token.isEmpty else { return }
            full += token
            if let first = token.first { abbr.append(first) }
        }

        let scalars = Array(input.unicodeScalars)
        var i = 0
        while i < scalars.count {
            let s = scalars[i]
            if isCJK(s) {
                var run = String.UnicodeScalarView()
                while i < scalars.count, isCJK(scalars[i]) { run.append(scalars[i]); i += 1 }
                let latin = transliterate(String(run))
                for syllable in latin.split(whereSeparator: { $0 == " " || $0 == "\t" || $0 == "\n" }) {
                    append(String(syllable).lowercased().filter { $0.isLetter || $0.isNumber })
                }
                continue
            } else if isLetterOrDigit(s) {
                var run = String.UnicodeScalarView()
                while i < scalars.count, isLetterOrDigit(scalars[i]) { run.append(scalars[i]); i += 1 }
                for token in splitCamelAndDigits(String(run)) where !token.isEmpty {
                    append(token.lowercased())
                }
                continue
            } else {
                // Any other single scalar is its own token; empty after trimming → skipped.
                let token = String(s).trimmingCharacters(in: .whitespacesAndNewlines)
                append(token.lowercased())
                i += 1
            }
        }
        return (full, abbr)
    }

    private static func isCJK(_ s: Unicode.Scalar) -> Bool {
        (0x4E00...0x9FFF).contains(s.value)
    }

    private static func isLetterOrDigit(_ s: Unicode.Scalar) -> Bool {
        // ASCII letters and decimal digits only, per spec ("CharacterSet.letters ∪ .decimalDigits").
        (s.value >= 0x30 && s.value <= 0x39) || (s.value >= 0x41 && s.value <= 0x5A) || (s.value >= 0x61 && s.value <= 0x7A)
    }

    private static func transliterate(_ s: String) -> String {
        let mutable = NSMutableString(string: s) as CFMutableString
        CFStringTransform(mutable, nil, kCFStringTransformToLatin as CFString, false)
        CFStringTransform(mutable, nil, kCFStringTransformStripCombiningMarks as CFString, false)
        return mutable as String
    }

    /// Splits at lower→upper, and at letter↔digit boundaries. e.g. "iTerm2" → ["i","Term","2"].
    private static func splitCamelAndDigits(_ s: String) -> [String] {
        var tokens: [String] = []
        var current = ""
        var previous: Character?
        for ch in s {
            if let prev = previous {
                let boundary = (prev.isLowercase && ch.isUppercase)
                    || (prev.isNumber != ch.isNumber)
                if boundary {
                    tokens.append(current)
                    current = ""
                }
            }
            current.append(ch)
            previous = ch
        }
        if !current.isEmpty { tokens.append(current) }
        return tokens
    }
}
