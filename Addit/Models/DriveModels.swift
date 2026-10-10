import Foundation

struct DriveFileListResponse: Codable {
    let files: [DriveItem]
    let nextPageToken: String?
}

struct DriveItem: Codable, Identifiable, Hashable {
    let id: String
    let name: String
    let mimeType: String
    let size: String?
    let parents: [String]?
    let capabilities: DriveCapabilities?
    let ownedByMe: Bool?
    let modifiedTime: String?
    /// The provider's own description field. Drive exposes it on every file
    /// (folders included) and only returns it when asked for by name; Graph
    /// has it on `driveItem`, documented as OneDrive Personal only — which is
    /// the only OneDrive this app talks to (`/consumers`). Albums use the
    /// album folder's copy as their blurb.
    let description: String?
    /// In the provider's trash — which is where deleting something in Drive
    /// puts it, and where it still answers a metadata request as if nothing
    /// happened. Only `getFileMetadata` asks Drive for it; OneDrive answers a
    /// recycled item with a 404 instead, so it's never set there.
    var trashed: Bool? = nil

    /// Drive's folder type, which `OneDriveService` stamps on Graph folders too.
    nonisolated static let folderMimeType = "application/vnd.google-apps.folder"

    var isFolder: Bool {
        mimeType == Self.folderMimeType
    }

    var isAudio: Bool {
        Self.isPlayableAudio(mimeType: mimeType, name: name)
    }

    /// Audio Addit can play: an `audio/` type, or MPEG-4 video (how Drive
    /// labels some .m4a files) — but not MIDI. That's note data rather than
    /// sound, and both drives file it under `audio/` (`audio/midi`,
    /// `audio/x-midi`, `audio/mid`), so a .mid in an album folder was listed
    /// as a track that could never play (TestFlight, build 10). Folder
    /// tracking asks the same question of what it lists, so a track that
    /// shows up as news is one the album would list.
    nonisolated static func isPlayableAudio(mimeType: String, name: String) -> Bool {
        let type = mimeType.lowercased()
        let ext = (name as NSString).pathExtension.lowercased()
        if type.contains("midi") || type == "audio/mid" || ["mid", "midi", "kar", "rmi"].contains(ext) {
            return false
        }
        return type.hasPrefix("audio/") || type == "video/mp4"
    }

    var canEdit: Bool {
        capabilities?.canEdit ?? false
    }

    var canAddChildren: Bool {
        capabilities?.canAddChildren ?? false
    }

    var fileSizeBytes: Int64? {
        guard let size else { return nil }
        return Int64(size)
    }

    var fileExtension: String {
        (name as NSString).pathExtension.lowercased()
    }
}

struct DriveCapabilities: Codable, Hashable {
    let canEdit: Bool?
    let canAddChildren: Bool?
}

// MARK: - Permissions

struct DrivePermissionListResponse: Codable {
    let permissions: [DrivePermission]
}

struct DrivePermission: Codable, Identifiable {
    let id: String
    let role: String              // "owner", "writer", "commenter", "reader"
    let type: String              // "user", "group", "domain", "anyone"
    let emailAddress: String?
    let displayName: String?
    let photoLink: String?

    var roleLabel: String {
        switch role {
        case "owner": return "Owner"
        case "writer": return "Editor"
        case "commenter": return "Commenter"
        case "reader": return "Viewer"
        default: return role.capitalized
        }
    }
}

// MARK: - Comments

struct DriveCommentListResponse: Codable {
    let comments: [DriveComment]
    let nextPageToken: String?
}

struct DriveComment: Codable, Identifiable {
    let id: String
    let content: String
    let createdTime: String
    let author: DriveCommentAuthor

    var createdDate: Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.date(from: createdTime) ?? ISO8601DateFormatter().date(from: createdTime)
    }
}

struct DriveCommentAuthor: Codable {
    let displayName: String
    let photoLink: String?
    let me: Bool
}

// MARK: - General Access

enum GeneralAccess: Equatable {
    case restricted
    case anyoneViewer
    case anyoneCommenter
    case anyoneEditor

    var label: String {
        switch self {
        case .restricted: return "Restricted"
        case .anyoneViewer: return "Anyone with the link: Viewer"
        case .anyoneCommenter: return "Anyone with the link: Commenter"
        case .anyoneEditor: return "Anyone with the link: Editor"
        }
    }

    var description: String {
        switch self {
        case .restricted: return "Only people added can open"
        case .anyoneViewer: return "Anyone with the link can view"
        case .anyoneCommenter: return "Anyone with the link can comment"
        case .anyoneEditor: return "Anyone with the link can edit"
        }
    }
}
