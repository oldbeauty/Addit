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
