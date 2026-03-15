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

    var isFolder: Bool {
        mimeType == "application/vnd.google-apps.folder"
    }

    var isAudio: Bool {
        mimeType.hasPrefix("audio/")
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

enum GeneralAccess: Equatable {
    case restricted
    case anyoneViewer
    case anyoneEditor

    var label: String {
        switch self {
        case .restricted: return "Restricted"
        case .anyoneViewer: return "Anyone with the link: Viewer"
        case .anyoneEditor: return "Anyone with the link: Editor"
        }
    }

    var description: String {
        switch self {
        case .restricted: return "Only people added can open"
        case .anyoneViewer: return "Anyone with the link can view"
        case .anyoneEditor: return "Anyone with the link can edit"
        }
    }
}
