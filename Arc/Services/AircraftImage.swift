import Foundation

/// Maps a free-text aircraft type/model to a bundled side-silhouette asset name.
enum AircraftImage {
    static func assetName(for type: String?) -> String {
        guard let t = type?.uppercased() else { return "aircraft-generic" }
        let map: [(String, String)] = [
            ("A321", "aircraft-a321"), ("A320", "aircraft-a320"), ("A319", "aircraft-a320"),
            ("A318", "aircraft-a320"), ("A330", "aircraft-a330"), ("A350", "aircraft-a350"),
            ("A340", "aircraft-a340"), ("A380", "aircraft-a380"),
            ("777", "aircraft-b777"), ("787", "aircraft-b787"), ("767", "aircraft-b767"),
            ("757", "aircraft-b757"), ("737", "aircraft-b737"), ("747", "aircraft-b747"),
            ("E19", "aircraft-e190"), ("E17", "aircraft-e190"), ("E75", "aircraft-e190"),
            ("CRJ", "aircraft-crj"), ("AT7", "aircraft-atr"), ("DH8", "aircraft-atr"),
        ]
        for (needle, asset) in map where t.contains(needle) { return asset }
        return "aircraft-generic"
    }

    /// True for twin-aisle / wide-body families.
    static func isWide(_ type: String?) -> Bool {
        guard let t = type?.uppercased() else { return false }
        let wides = ["777", "787", "767", "747", "A330", "A340", "A350", "A380", "A300", "A310"]
        return wides.contains { t.contains($0) }
    }
}
