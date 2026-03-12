import Foundation

@Observable
final class GoogleDriveService {
    var authService: GoogleAuthService?

    private let session = URLSession.shared
    private let baseURL = Constants.driveAPIBase

    func listFolders(pageToken: String? = nil) async throws -> DriveFileListResponse {
        let query = "'root' in parents and mimeType='application/vnd.google-apps.folder' and trashed=false"
        return try await listFiles(query: query, pageToken: pageToken, pageSize: 100, orderBy: "name",
                                   fields: "files(id,name,mimeType,size,parents,ownedByMe,modifiedTime,capabilities/canEdit,capabilities/canAddChildren),nextPageToken")
    }

    func listStarredFolders(pageToken: String? = nil) async throws -> DriveFileListResponse {
        let query = "starred=true and mimeType='application/vnd.google-apps.folder' and trashed=false"
        return try await listFiles(query: query, pageToken: pageToken, pageSize: 100, orderBy: "name",
                                   fields: "files(id,name,mimeType,size,parents,ownedByMe,modifiedTime,capabilities/canEdit,capabilities/canAddChildren),nextPageToken")
    }

    func listSharedFolders(pageToken: String? = nil) async throws -> DriveFileListResponse {
        let query = "mimeType='application/vnd.google-apps.folder' and trashed=false and not 'me' in owners"
        return try await listFiles(query: query, pageToken: pageToken, pageSize: 100, orderBy: "name",
                                   fields: "files(id,name,mimeType,size,parents,ownedByMe,modifiedTime,capabilities/canEdit,capabilities/canAddChildren),nextPageToken")
    }

    func listSubfolders(inFolder folderId: String) async throws -> DriveFileListResponse {
        let query = "'\(folderId)' in parents and mimeType='application/vnd.google-apps.folder' and trashed=false"
        return try await listFiles(query: query, pageSize: 100, orderBy: "name",
                                   fields: "files(id,name,mimeType,size,parents,ownedByMe,modifiedTime,capabilities/canEdit,capabilities/canAddChildren),nextPageToken")
    }

    func searchFolders(query searchText: String) async throws -> DriveFileListResponse {
        let escaped = searchText.replacingOccurrences(of: "'", with: "\\'")
        let query = "mimeType='application/vnd.google-apps.folder' and trashed=false and name contains '\(escaped)'"
        return try await listFiles(query: query, pageSize: 50, orderBy: "name",
                                   fields: "files(id,name,mimeType,size,parents,ownedByMe,modifiedTime,capabilities/canEdit,capabilities/canAddChildren),nextPageToken")
    }

    func listAudioFiles(inFolder folderId: String, pageToken: String? = nil) async throws -> DriveFileListResponse {
        let query = "'\(folderId)' in parents and mimeType contains 'audio/' and trashed=false"
        return try await listFiles(query: query, pageToken: pageToken, pageSize: 1000, orderBy: "name")
    }

    func findCoverImage(inFolder folderId: String) async throws -> DriveItem? {
        let query = "'\(folderId)' in parents and mimeType contains 'image/' and trashed=false"
        let response = try await listFiles(query: query, pageSize: 100, orderBy: "name")
        // Only match files named exactly "cover" (any extension: cover.jpg, cover.png, etc.)
        return response.files.first { item in
            let nameWithoutExt = (item.name as NSString).deletingPathExtension.lowercased()
            return nameWithoutExt == "cover"
        }
    }

    func upsertCoverImage(inFolder folderId: String, data: Data, fileName: String = "cover.jpg") async throws -> DriveItem {
        if let existing = try await findCoverImage(inFolder: folderId) {
            try await updateFileData(fileId: existing.id, data: data, mimeType: "image/jpeg")
            return existing
        }

        return try await createFile(
            name: fileName,
            mimeType: "image/jpeg",
            inFolder: folderId,
            data: data
        )
    }

    func findFile(named fileName: String, inFolder folderId: String) async throws -> DriveItem? {
        let escaped = fileName.replacingOccurrences(of: "'", with: "\\'")
        let query = "'\(folderId)' in parents and name = '\(escaped)' and trashed=false"
        let response = try await listFiles(query: query, pageSize: 1)
        return response.files.first
    }

    func getFileMetadata(fileId: String) async throws -> DriveItem {
        let token = try await getToken()
        let fields = "id,name,mimeType,size,parents,ownedByMe,modifiedTime,capabilities/canEdit,capabilities/canAddChildren"
        var components = URLComponents(string: "\(baseURL)/files/\(fileId)")!
        components.queryItems = [
            URLQueryItem(name: "fields", value: fields),
            URLQueryItem(name: "supportsAllDrives", value: "true")
        ]

        var request = URLRequest(url: components.url!)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")

        let (data, response) = try await session.data(for: request)
        try validateResponse(response)
        return try JSONDecoder().decode(DriveItem.self, from: data)
    }

    func listAllFilesInFolder(_ folderId: String) async throws -> DriveFileListResponse {
        let query = "'\(folderId)' in parents and trashed=false"
        return try await listFiles(query: query, pageSize: 1000, orderBy: "name")
    }

    // MARK: - Rename

    @discardableResult
    func renameFile(fileId: String, newName: String) async throws -> DriveItem {
        let token = try await getToken()

        var components = URLComponents(string: "\(baseURL)/files/\(fileId)")!
        components.queryItems = [
            URLQueryItem(name: "supportsAllDrives", value: "true"),
            URLQueryItem(name: "fields", value: "id,name,mimeType,size,parents,ownedByMe,modifiedTime,capabilities/canEdit,capabilities/canAddChildren")
        ]

        var request = URLRequest(url: components.url!)
        request.httpMethod = "PATCH"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let body = ["name": newName]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await session.data(for: request)
        try validateResponse(response)
        return try JSONDecoder().decode(DriveItem.self, from: data)
    }

    // MARK: - Ownership

    /// Removes a file from a folder without deleting it.
    /// The file remains in the creator's Drive but is no longer in the specified folder.
    func removeFileFromFolder(fileId: String, folderId: String) async throws {
        let token = try await getToken()

        var components = URLComponents(string: "\(baseURL)/files/\(fileId)")!
        components.queryItems = [
            URLQueryItem(name: "removeParents", value: folderId),
            URLQueryItem(name: "supportsAllDrives", value: "true")
        ]

        var request = URLRequest(url: components.url!)
        request.httpMethod = "PATCH"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = "{}".data(using: .utf8)

        let (_, response) = try await session.data(for: request)
        try validateResponse(response)
    }

    // MARK: - Folder Operations

    func createFolder(name: String, inParent parentId: String) async throws -> DriveItem {
        let token = try await getToken()

        let url = URL(string: "\(baseURL)/files?supportsAllDrives=true")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let metadata: [String: Any] = [
            "name": name,
            "mimeType": "application/vnd.google-apps.folder",
            "parents": [parentId]
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: metadata)

        let (data, response) = try await session.data(for: request)
        try validateResponse(response)
        return try JSONDecoder().decode(DriveItem.self, from: data)
    }

    func findOrCreateFolder(named name: String, inParent parentId: String) async throws -> DriveItem {
        let escaped = name.replacingOccurrences(of: "'", with: "\\'")
        let query = "'\(parentId)' in parents and name = '\(escaped)' and mimeType = 'application/vnd.google-apps.folder' and trashed=false"
        let response = try await listFiles(query: query, pageSize: 1)
        if let existing = response.files.first {
            return existing
        }
        return try await createFolder(name: name, inParent: parentId)
    }

    // MARK: - Write Operations

    func createFile(name: String, mimeType: String, inFolder parentId: String, data: Data) async throws -> DriveItem {
        let token = try await getToken()

        let boundary = UUID().uuidString
        let url = URL(string: "https://www.googleapis.com/upload/drive/v3/files?uploadType=multipart&supportsAllDrives=true")!

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("multipart/related; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")

        let metadata: [String: Any] = [
            "name": name,
            "mimeType": mimeType,
            "parents": [parentId]
        ]
        let metadataData = try JSONSerialization.data(withJSONObject: metadata)

        var body = Data()
        body.append("--\(boundary)\r\n".data(using: .utf8)!)
        body.append("Content-Type: application/json; charset=UTF-8\r\n\r\n".data(using: .utf8)!)
        body.append(metadataData)
        body.append("\r\n--\(boundary)\r\n".data(using: .utf8)!)
        body.append("Content-Type: \(mimeType)\r\n\r\n".data(using: .utf8)!)
        body.append(data)
        body.append("\r\n--\(boundary)--\r\n".data(using: .utf8)!)

        request.httpBody = body

        let (responseData, response) = try await session.data(for: request)
        try validateResponse(response)
        return try JSONDecoder().decode(DriveItem.self, from: responseData)
    }

    func updateFileData(fileId: String, data: Data, mimeType: String) async throws {
        let token = try await getToken()
        let url = URL(string: "https://www.googleapis.com/upload/drive/v3/files/\(fileId)?uploadType=media&supportsAllDrives=true")!

        var request = URLRequest(url: url)
        request.httpMethod = "PATCH"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue(mimeType, forHTTPHeaderField: "Content-Type")
        request.httpBody = data

        let (_, response) = try await session.data(for: request)
        try validateResponse(response)
    }

    func downloadFileData(fileId: String) async throws -> Data {
        let token = try await getToken()
        let url = URL(string: "\(baseURL)/files/\(fileId)?alt=media&supportsAllDrives=true")!
        var request = URLRequest(url: url)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")

        let (data, response) = try await session.data(for: request)
        try validateResponse(response)
        return data
    }

    func downloadFile(fileId: String, to destination: URL) async throws {
        let token = try await getToken()
        let url = URL(string: "\(baseURL)/files/\(fileId)?alt=media&supportsAllDrives=true")!
        var request = URLRequest(url: url)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")

        let (tempURL, response) = try await session.download(for: request)
        try validateResponse(response)

        let fm = FileManager.default
        if fm.fileExists(atPath: destination.path) {
            try fm.removeItem(at: destination)
        }
        try fm.moveItem(at: tempURL, to: destination)
    }

    // MARK: - Private

    private func listFiles(query: String, pageToken: String? = nil,
                           pageSize: Int = 100, orderBy: String? = nil,
                           fields: String = "files(id,name,mimeType,size,parents,ownedByMe,modifiedTime),nextPageToken") async throws -> DriveFileListResponse {
        let token = try await getToken()

        var components = URLComponents(string: "\(baseURL)/files")!
        var queryItems = [
            URLQueryItem(name: "q", value: query),
            URLQueryItem(name: "fields", value: fields),
            URLQueryItem(name: "supportsAllDrives", value: "true"),
            URLQueryItem(name: "includeItemsFromAllDrives", value: "true"),
            URLQueryItem(name: "pageSize", value: "\(pageSize)")
        ]
        if let pageToken {
            queryItems.append(URLQueryItem(name: "pageToken", value: pageToken))
        }
        if let orderBy {
            queryItems.append(URLQueryItem(name: "orderBy", value: orderBy))
        }
        components.queryItems = queryItems

        var request = URLRequest(url: components.url!)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")

        let (data, response) = try await session.data(for: request)
        try validateResponse(response)
        return try JSONDecoder().decode(DriveFileListResponse.self, from: data)
    }

    private func getToken() async throws -> String {
        guard let authService else { throw DriveError.notConfigured }
        return try await authService.validAccessToken()
    }

    private func validateResponse(_ response: URLResponse) throws {
        guard let http = response as? HTTPURLResponse else {
            throw DriveError.invalidResponse
        }
        switch http.statusCode {
        case 200...299:
            return
        case 401:
            throw DriveError.unauthorized
        case 403:
            throw DriveError.forbidden
        case 429:
            throw DriveError.rateLimited
        case 404:
            throw DriveError.notFound
        default:
            throw DriveError.serverError(http.statusCode)
        }
    }
}

enum DriveError: LocalizedError {
    case notConfigured
    case unauthorized
    case forbidden
    case notFound
    case rateLimited
    case invalidResponse
    case serverError(Int)

    var errorDescription: String? {
        switch self {
        case .notConfigured: return "Drive service not configured"
        case .unauthorized: return "Not authorized. Please sign in again."
        case .forbidden: return "You don't have edit access to this folder."
        case .notFound: return "File or folder not found"
        case .rateLimited: return "Too many requests. Please try again later."
        case .invalidResponse: return "Invalid response from server"
        case .serverError(let code): return "Server error (\(code))"
        }
    }
}
