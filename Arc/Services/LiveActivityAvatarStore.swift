import Foundation
import UIKit

/// Stages friend avatars for Live Activities. A widget extension can't load
/// network images, so the app downloads the avatar once, scales it to icon
/// size, and drops it in the shared App Group container; the widget renders
/// it by filename (see FlightActivityAttributes.friendAvatarFile).
enum LiveActivityAvatarStore {
    static let groupID = "group.com.arc.flighttracker"

    private static var directory: URL? {
        FileManager.default
            .containerURL(forSecurityApplicationGroupIdentifier: groupID)?
            .appendingPathComponent("la-avatars", isDirectory: true)
    }

    /// Returns the container filename for this user's avatar, downloading and
    /// scaling on first use. nil when the user has no avatar or the download
    /// fails — callers fall back to the generic person icon.
    static func ensureAvatar(userId: String, urlString: String?) async -> String? {
        guard let directory else { return nil }
        let file = "\(userId).png"
        let target = directory.appendingPathComponent(file)
        if FileManager.default.fileExists(atPath: target.path) { return file }
        guard let urlString, let url = URL(string: urlString) else { return nil }
        do {
            let (data, _) = try await URLSession.shared.data(from: url)
            guard let image = UIImage(data: data) else { return nil }
            // Aspect-fill crop into a small square — the widget shows it at
            // ~18pt, so 64px covers 3x displays without bloating the payload
            // path (the file lives on disk; only the NAME rides the wire).
            let side: CGFloat = 64
            let scale = side / min(image.size.width, image.size.height)
            let scaledSize = CGSize(width: image.size.width * scale, height: image.size.height * scale)
            let renderer = UIGraphicsImageRenderer(size: CGSize(width: side, height: side))
            let square = renderer.image { _ in
                image.draw(in: CGRect(
                    x: (side - scaledSize.width) / 2,
                    y: (side - scaledSize.height) / 2,
                    width: scaledSize.width,
                    height: scaledSize.height))
            }
            guard let png = square.pngData() else { return nil }
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try png.write(to: target, options: .atomic)
            return file
        } catch {
            return nil
        }
    }
}
