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

    var isFolder: Bool {
        mimeType == "application/vnd.google-apps.folder"
    }

    var isAudio: Bool {
        mimeType.hasPrefix("audio/") || mimeType == "video/mp4"
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
