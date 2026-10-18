import Foundation

/// Tells Arabic from English by counting letters of each script.
/// For this pair, counting is exact enough and instant; no language model is needed.
nonisolated enum ScriptDetector {
    static func letterCounts(_ text: String) -> (arabic: Int, latin: Int) {
        var arabic = 0, latin = 0
        for scalar in text.unicodeScalars {
            switch scalar.value {
            case 0x0621...0x064A, 0x0671...0x06D3, 0xFB50...0xFDFF, 0xFE70...0xFEFC: arabic += 1
            case 0x41...0x5A, 0x61...0x7A: latin += 1
            default: break
            }
        }
        return (arabic, latin)
    }

    /// `texts` are ordered closest first (the newest message first).
    /// The closest pieces weigh more, so the latest message leads.
    static func detect(_ texts: [String]) -> Lang? {
        let weights = [3.0, 2.0, 1.0, 1.0, 1.0, 1.0]
        var arabic = 0.0, latin = 0.0
        for (index, text) in texts.prefix(weights.count).enumerated() {
            let counts = letterCounts(text)
            guard counts.arabic + counts.latin >= 2 else { continue }
            // Normalise each piece so one long message cannot drown the latest short one.
            let total = Double(counts.arabic + counts.latin)
            arabic += weights[index] * Double(counts.arabic) / total
            latin += weights[index] * Double(counts.latin) / total
        }
        guard arabic + latin > 0 else { return nil }
        return arabic >= latin ? .ar : .en
    }

    /// The language of the text already in the focused field, or nil when it holds fewer than 2 letters.
    /// Uses the same 2-letter threshold as the field's own text in the nearby-text list.
    static func detectOwn(_ text: String) -> Lang? {
        let counts = letterCounts(text)
        guard counts.arabic + counts.latin >= 2 else { return nil }
        return detect([text])
    }
}
