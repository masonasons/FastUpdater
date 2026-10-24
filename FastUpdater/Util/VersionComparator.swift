import Foundation

/// Compares version strings the way Sparkle does: numeric runs compare numerically,
/// letter runs compare as text, and a trailing letter run marks a pre-release
/// (so `1.0b1 < 1.0 < 1.0.1`).
enum VersionComparator {
    private enum Token: Equatable {
        case number(UInt64)
        case text(String)
    }

    static func compare(_ lhs: String, _ rhs: String) -> ComparisonResult {
        let a = tokenize(lhs)
        let b = tokenize(rhs)

        for (x, y) in zip(a, b) {
            switch (x, y) {
            case let (.number(m), .number(n)):
                if m != n { return m < n ? .orderedAscending : .orderedDescending }
            case let (.text(s), .text(t)):
                let result = s.caseInsensitiveCompare(t)
                if result != .orderedSame { return result }
            case (.number, .text):
                return .orderedDescending
            case (.text, .number):
                return .orderedAscending
            }
        }

        guard a.count != b.count else { return .orderedSame }
        // The longer version wins if its extra part is numeric (1.0.1 > 1.0)
        // and loses if it's text (1.0b > 1.0 is false).
        let longerIsLeft = a.count > b.count
        let extra = longerIsLeft ? a[b.count] : b[a.count]
        let longerIsNewer: Bool
        if case .number = extra { longerIsNewer = true } else { longerIsNewer = false }
        return (longerIsLeft == longerIsNewer) ? .orderedDescending : .orderedAscending
    }

    static func isNewer(_ candidate: String, than current: String) -> Bool {
        compare(candidate, current) == .orderedDescending
    }

    private static func tokenize(_ version: String) -> [Token] {
        var tokens: [Token] = []
        var current = ""
        var currentIsDigit = false

        func flush() {
            guard !current.isEmpty else { return }
            if currentIsDigit, let value = UInt64(current) {
                tokens.append(.number(value))
            } else {
                tokens.append(.text(current))
            }
            current = ""
        }

        for char in version {
            if char.isASCII && char.isNumber {
                if !currentIsDigit { flush() }
                currentIsDigit = true
                current.append(char)
            } else if char.isLetter {
                if currentIsDigit { flush() }
                currentIsDigit = false
                current.append(char)
            } else {
                // Separators (., -, _, spaces) just end the current run.
                flush()
            }
        }
        flush()
        return tokens
    }
}
