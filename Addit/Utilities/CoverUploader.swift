import Foundation
import UIKit

/// Puts album art somewhere a link preview can actually fetch it.
///
/// The preview card is built by an unauthenticated fetcher, so art that lives
/// only in a private Drive folder is invisible to it — a restricted album's
/// cover can't be read at all, and OneDrive has no anonymous thumbnail
/// endpoint. But the app is already holding the bytes: the same image it is
/// displaying. So it uploads that copy once and the link carries the id.
///
/// The server keys on the SHA-256 of the bytes, so re-sharing an album stores
/// nothing new, and the same art shared from two accounts collapses to one row.
enum CoverUploader {
    private static let endpoint = URL(string: "https://hollowpoint.tv/cover")!

    /// Cards render a few hundred points wide at most, and the server caps
    /// uploads at 512 KB. 640² lands well inside both.
    private static let maxSide: CGFloat = 640

    /// `nil` on any failure — no cover art is worth blocking a share over. The
    /// link still works; the card falls back to the plain tile.
    static func upload(_ image: UIImage?) async -> String? {
        guard let image, let data = encode(image) else { return nil }

        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("image/jpeg", forHTTPHeaderField: "Content-Type")
        request.httpBody = data
        request.timeoutInterval = 15

        guard let (body, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let object = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
              let id = object["id"] as? String,
              !id.isEmpty
        else {
            #if DEBUG
            print("[Link] cover upload failed; card will use the fallback tile")
            #endif
            return nil
        }
        return id
    }

    /// Downscaled JPEG. Covers coming out of Drive are routinely 1500² and a
    /// megabyte or more, which is both over the server's cap and far more than
    /// a preview card can show.
    private static func encode(_ image: UIImage) -> Data? {
        let side = max(image.size.width, image.size.height)
        let scale = side > maxSide ? maxSide / side : 1
        let target = CGSize(width: image.size.width * scale, height: image.size.height * scale)

        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1          // points are pixels here; the size is already final.
        format.opaque = true
        let resized = UIGraphicsImageRenderer(size: target, format: format).image { _ in
            image.draw(in: CGRect(origin: .zero, size: target))
        }
        return resized.jpegData(compressionQuality: 0.82)
    }
}
