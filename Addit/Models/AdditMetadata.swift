import Foundation

struct AdditMetadata: Codable {
    var tracklist: [String]?
    var artist: String?

    static let discMarkerPrefix = "::disc::"
}

enum TracklistItem: Identifiable {
    case track(Track)
    case discMarker(id: UUID, label: String)

    var id: String {
        switch self {
        case .track(let track):
            return track.googleFileId
        case .discMarker(let id, _):
            return "disc-\(id.uuidString)"
        }
    }

    /// Identity by *content* rather than by instance. Disc markers get a
    /// fresh `UUID` on every build, so two builds of an identical tracklist
    /// never compare equal by `id` — this key does, which is what lets a
    /// rebuild that changed nothing skip reassigning `displayItems`.
    var contentKey: String {
        switch self {
        case .track(let track):
            return track.googleFileId
        case .discMarker(_, let label):
            return "\(AdditMetadata.discMarkerPrefix)\(label)"
        }
    }

    var isDiscMarker: Bool {
        if case .discMarker = self { return true }
        return false
    }

    var asTrack: Track? {
        if case .track(let t) = self { return t }
        return nil
    }
}
