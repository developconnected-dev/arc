import SwiftUI

enum TextHelpers {
    /// Regional-indicator flag emoji from an ISO-3166 alpha-2 country code.
    static func flag(_ iso2: String) -> String {
        let code = iso2.uppercased()
        guard code.count == 2 else { return "🏳️" }
        var s = ""
        for scalar in code.unicodeScalars {
            guard let v = UnicodeScalar(127397 + scalar.value) else { return "🏳️" }
            s.unicodeScalars.append(v)
        }
        return s
    }

    /// Highlights the first case-insensitive occurrence of `query` in `text`.
    static func highlight(_ text: String, query: String, color: Color) -> Text {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty, let range = text.range(of: q, options: .caseInsensitive) else {
            return Text(text)
        }
        let pre = String(text[text.startIndex..<range.lowerBound])
        let match = String(text[range])
        let post = String(text[range.upperBound...])
        return Text("\(Text(pre))\(Text(match).foregroundColor(color))\(Text(post))")
    }

    /// "Zurich to Munich" — bold endpoints, quiet joiner, one Text.
    static func cityPair(_ dep: String, _ arr: String, size: CGFloat, weight: Font.Weight = .bold) -> Text {
        Text("\(Text(dep).font(.system(size: size, weight: weight)).foregroundColor(.primary))\(Text(" to ").font(.system(size: size)).foregroundColor(.secondary))\(Text(arr).font(.system(size: size, weight: weight)).foregroundColor(.primary))")
    }

    /// True if the string looks like a flight number, e.g. "LX1413", "U2 123".
    static func looksLikeFlightNumber(_ s: String) -> Bool {
        let t = s.uppercased().replacingOccurrences(of: " ", with: "")
        guard t.count >= 3, t.count <= 7 else { return false }
        let prefix = t.prefix(2)
        let rest = t.dropFirst(2)
        return prefix.allSatisfy { $0.isLetter || $0.isNumber } &&
               !rest.isEmpty && rest.allSatisfy { $0.isNumber }
    }
}
