import Foundation

@Observable
final class GoogleDriveService: CloudDriveService {
    var authService: GoogleAuthService?

    // CloudDriveService capability flags
    let supportsComments = true
    let supportsStarred = true
    let supportsCommenterRole = true

    private let session = CloudSession()
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
        let query = "sharedWithMe=true and mimeType='application/vnd.google-apps.folder' and trashed=false"
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
        let query = "'\(folderId)' in parents and (mimeType contains 'audio/' or mimeType = 'video/mp4') and trashed=false"
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
        let fields = "id,name,mimeType,size,parents,ownedByMe,modifiedTime,description,capabilities/canEdit,capabilities/canAddChildren"
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

    func storageQuota() async throws -> StorageQuota {
        let token = try await getToken()
        var components = URLComponents(string: "\(baseURL)/about")!
        components.queryItems = [URLQueryItem(name: "fields", value: "storageQuota")]

        var request = URLRequest(url: components.url!)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")

        let (data, response) = try await session.data(for: request)
        try validateResponse(response)

        /// Drive reports these as **strings**, not numbers — they're int64s
        /// that would lose precision in JSON's double, so decoding them as
        /// `Int64` directly fails.
        struct About: Decodable {
            struct Quota: Decodable {
                let limit: String?
                let usage: String?
            }
            let storageQuota: Quota
        }

        let quota = try JSONDecoder().decode(About.self, from: data).storageQuota
        return StorageQuota(
            usedBytes: quota.usage.flatMap(Int64.init) ?? 0,
            // Absent for unlimited plans, which is a state the UI has to show
            // rather than treat as zero.
            limitBytes: quota.limit.flatMap(Int64.init)
        )
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

    /// Drive's `description` is a plain writable field on any file, folders
    /// included — the same box the web UI's "Folder details" pane edits.
    func setDescription(_ description: String, fileId: String) async throws {
        let token = try await getToken()

        var components = URLComponents(string: "\(baseURL)/files/\(fileId)")!
        components.queryItems = [
            URLQueryItem(name: "supportsAllDrives", value: "true"),
            URLQueryItem(name: "fields", value: "id")
        ]

        var request = URLRequest(url: components.url!)
        request.httpMethod = "PATCH"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["description": description])

        let (_, response) = try await session.data(for: request)
        try validateResponse(response)
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

    /// Moves a file to the Drive trash, where the owner can restore it for 30
    /// days. Never a `DELETE`: that erases the file outright, skipping the
    /// trash, and an album's tracks are the user's files — a slip in edit mode
    /// shouldn't cost them one.
    func deleteFile(fileId: String) async throws {
        let token = try await getToken()

        var components = URLComponents(string: "\(baseURL)/files/\(fileId)")!
        components.queryItems = [
            URLQueryItem(name: "supportsAllDrives", value: "true")
        ]

        var request = URLRequest(url: components.url!)
        request.httpMethod = "PATCH"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["trashed": true])

        let (_, response) = try await session.data(for: request)
        try validateResponse(response)
    }

    /// Copies a file into a target folder, returning the new DriveItem.
    func copyFile(fileId: String, toFolder folderId: String) async throws -> DriveItem {
        let token = try await getToken()

        let url = URL(string: "\(baseURL)/files/\(fileId)/copy?supportsAllDrives=true&fields=id,name,mimeType,size,parents,capabilities,ownedByMe,modifiedTime")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let metadata: [String: Any] = ["parents": [folderId]]
        request.httpBody = try JSONSerialization.data(withJSONObject: metadata)

        let (data, response) = try await session.data(for: request)
        try validateResponse(response)
        return try JSONDecoder().decode(DriveItem.self, from: data)
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
        try await createFile(name: name, mimeType: mimeType, inFolder: parentId, data: data, onProgress: { _ in })
    }

    /// Every file this app creates in Drive goes up as a *resumable* upload —
    /// Google's protocol for mobile apps on networks that drop, which is the
    /// network that failed a demo on 2026-09-29 (see `CloudSession`). A
    /// multipart upload is one request: when its connection dies, everything
    /// sent is gone and the only move left is to start again. Here the bytes go
    /// to an upload session that remembers what arrived, so a dropped
    /// connection costs only what was in flight: ask the session how much it
    /// has, wait a moment, and send the rest — over a fresh connection, since
    /// the failure retired the dead one.
    ///
    /// One path for every size. A tiny file pays one extra round trip to open
    /// its session, which isn't worth a second code path to save.
    func createFile(
        name: String, mimeType: String, inFolder parentId: String, data: Data,
        onProgress: @escaping @Sendable (Int64) -> Void
    ) async throws -> DriveItem {
        let metadata = try JSONSerialization.data(withJSONObject: [
            "name": name,
            "mimeType": mimeType,
            "parents": [parentId]
        ])

        var uploadURL: URL?   // the session; nil until opened, or once Google forgets it
        var offset: Int? = 0  // where to send from; nil means ask the session first
        var confirmed = 0     // bytes the session has acknowledged
        var failures = 0      // tries in a row that got no further

        while true {
            do {
                guard let sessionURL = uploadURL else {
                    uploadURL = try await openUploadSession(metadata: metadata, mimeType: mimeType, size: data.count)
                    offset = 0
                    continue
                }
                let askedForStatus = offset == nil
                let status = if let offset {
                    try await sendBytes(data, from: offset, to: sessionURL, mimeType: mimeType, onProgress: onProgress)
                } else {
                    try await uploadStatus(of: sessionURL, size: data.count)
                }
                switch status {
                case .complete(let item):
                    return item
                case .incomplete(let received):
                    offset = received
                    if received > confirmed {
                        confirmed = received
                        failures = 0
                        continue
                    }
                    // Asking after a failure and hearing nothing new is
                    // expected — that failure has already been counted.
                    if askedForStatus { continue }
                case .expired:
                    // Sessions last a week; one that's gone means starting over.
                    uploadURL = nil
                    confirmed = 0
                }
                // Came back without getting any further. Can't happen on a
                // healthy session, but a loop that can't end is worse.
                failures += 1
                guard failures < Self.uploadAttempts else { throw DriveError.uploadRefused }
            } catch where Self.isWorthRetrying(error) {
                failures += 1
                guard failures < Self.uploadAttempts else { throw error }
                offset = nil
                try await Task.sleep(for: .seconds(1 << (failures - 1)))
            }
        }
    }

    /// Tries in a row without the session confirming more bytes before an
    /// upload gives up — about fifteen seconds of backoff (1, 2, 4, 8) plus
    /// however long each try took to fail.
    private static let uploadAttempts = 5

    private enum UploadStatus {
        case complete(DriveItem)
        case incomplete(received: Int)
        /// Google no longer knows the session (404/410).
        case expired
    }

    private func openUploadSession(metadata: Data, mimeType: String, size: Int) async throws -> URL {
        let token = try await getToken()
        let url = URL(string: "https://www.googleapis.com/upload/drive/v3/files?uploadType=resumable&supportsAllDrives=true")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json; charset=UTF-8", forHTTPHeaderField: "Content-Type")
        request.setValue(mimeType, forHTTPHeaderField: "X-Upload-Content-Type")
        request.setValue(String(size), forHTTPHeaderField: "X-Upload-Content-Length")
        request.httpBody = metadata

        let (_, response) = try await session.data(for: request)
        try validateResponse(response)
        guard let location = (response as? HTTPURLResponse)?.value(forHTTPHeaderField: "Location"),
              let sessionURL = URL(string: location) else {
            throw DriveError.invalidResponse
        }
        return sessionURL
    }

    /// Everything from `offset` on, in one request. Chunking would only add
    /// round trips: the session is what makes this resumable, not the size of
    /// each piece.
    private func sendBytes(
        _ data: Data, from offset: Int, to uploadURL: URL, mimeType: String,
        onProgress: @escaping @Sendable (Int64) -> Void
    ) async throws -> UploadStatus {
        let token = try await getToken()
        var request = URLRequest(url: uploadURL)
        request.httpMethod = "PUT"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue(mimeType, forHTTPHeaderField: "Content-Type")
        if !data.isEmpty {
            request.setValue("bytes \(offset)-\(data.count - 1)/\(data.count)", forHTTPHeaderField: "Content-Range")
        }

        let base = Int64(offset)
        let (responseData, response) = try await session.upload(
            for: request, from: data[offset...],
            delegate: UploadProgress { sent in onProgress(base + sent) }
        )
        return try uploadStatus(from: responseData, response)
    }

    /// Asks the session how much of the file it has, without sending any.
    private func uploadStatus(of uploadURL: URL, size: Int) async throws -> UploadStatus {
        let token = try await getToken()
        var request = URLRequest(url: uploadURL)
        request.httpMethod = "PUT"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("bytes */\(size)", forHTTPHeaderField: "Content-Range")
        request.httpBody = Data()

        let (responseData, response) = try await session.data(for: request)
        return try uploadStatus(from: responseData, response)
    }

    private func uploadStatus(from data: Data, _ response: URLResponse) throws -> UploadStatus {
        guard let http = response as? HTTPURLResponse else { throw DriveError.invalidResponse }
        switch http.statusCode {
        case 200, 201:
            return .complete(try JSONDecoder().decode(DriveItem.self, from: data))
        case 308:
            // "Range: bytes=0-N" is what arrived; no header means nothing has.
            let lastByte = http.value(forHTTPHeaderField: "Range")?
                .split(separator: "-").last.flatMap { Int($0) }
            return .incomplete(received: lastByte.map { $0 + 1 } ?? 0)
        case 404, 410:
            return .expired
        default:
            try validateResponse(response)
            throw DriveError.invalidResponse
        }
    }

    /// What a resumable upload waits out and tries again: the connection
    /// failing or going quiet, and Google saying "not now". Everything else —
    /// no permission, no such folder — fails the same way on every try.
    private static func isWorthRetrying(_ error: Error) -> Bool {
        if let error = error as? URLError {
            let transient: [URLError.Code] = [
                .timedOut, .networkConnectionLost, .notConnectedToInternet,
                .cannotConnectToHost, .cannotFindHost, .dnsLookupFailed,
            ]
            return transient.contains(error.code)
        }
        if let error = error as? DriveError {
            switch error {
            case .rateLimited: return true
            case .serverError(let code): return code >= 500
            default: return false
            }
        }
        return false
    }

    func setStarred(fileId: String, starred: Bool) async throws {
        let token = try await getToken()
        let url = URL(string: "\(baseURL)/files/\(fileId)?supportsAllDrives=true")!

        var request = URLRequest(url: url)
        request.httpMethod = "PATCH"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let body: [String: Any] = ["starred": starred]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (_, response) = try await session.data(for: request)
        try validateResponse(response)
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

    // MARK: - Permissions

    func listPermissions(fileId: String) async throws -> [DrivePermission] {
        let token = try await getToken()
        var components = URLComponents(string: "\(baseURL)/files/\(fileId)/permissions")!
        components.queryItems = [
            URLQueryItem(name: "fields", value: "permissions(id,role,type,emailAddress,displayName,photoLink)"),
            URLQueryItem(name: "supportsAllDrives", value: "true")
        ]

        var request = URLRequest(url: components.url!)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")

        let (data, response) = try await session.data(for: request)
        try validateResponse(response)
        let result = try JSONDecoder().decode(DrivePermissionListResponse.self, from: data)
        return result.permissions
    }

    func updatePermissionRole(fileId: String, permissionId: String, role: String) async throws {
        let token = try await getToken()
        var components = URLComponents(string: "\(baseURL)/files/\(fileId)/permissions/\(permissionId)")!
        components.queryItems = [
            URLQueryItem(name: "supportsAllDrives", value: "true")
        ]

        var request = URLRequest(url: components.url!)
        request.httpMethod = "PATCH"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["role": role])

        let (_, response) = try await session.data(for: request)
        try validateResponse(response)
    }

    func createPermission(fileId: String, email: String, role: String, sendNotification: Bool = true) async throws {
        let token = try await getToken()
        var components = URLComponents(string: "\(baseURL)/files/\(fileId)/permissions")!
        components.queryItems = [
            URLQueryItem(name: "supportsAllDrives", value: "true"),
            URLQueryItem(name: "sendNotificationEmail", value: sendNotification ? "true" : "false")
        ]

        var request = URLRequest(url: components.url!)
        request.httpMethod = "POST"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let body: [String: String] = ["type": "user", "role": role, "emailAddress": email]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (_, response) = try await session.data(for: request)
        try validateResponse(response)
    }

    func deletePermission(fileId: String, permissionId: String) async throws {
        let token = try await getToken()
        var components = URLComponents(string: "\(baseURL)/files/\(fileId)/permissions/\(permissionId)")!
        components.queryItems = [
            URLQueryItem(name: "supportsAllDrives", value: "true")
        ]

        var request = URLRequest(url: components.url!)
        request.httpMethod = "DELETE"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")

        let (_, response) = try await session.data(for: request)
        try validateResponse(response)
    }

    func createAnyonePermission(fileId: String, role: String) async throws {
        let token = try await getToken()
        var components = URLComponents(string: "\(baseURL)/files/\(fileId)/permissions")!
        components.queryItems = [
            URLQueryItem(name: "supportsAllDrives", value: "true")
        ]

        var request = URLRequest(url: components.url!)
        request.httpMethod = "POST"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let body: [String: String] = ["type": "anyone", "role": role]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (_, response) = try await session.data(for: request)
        try validateResponse(response)
    }

    // MARK: - Comments

    func listComments(fileId: String, pageToken: String? = nil, pageSize: Int = 100) async throws -> DriveCommentListResponse {
        let token = try await getToken()
        var components = URLComponents(string: "\(baseURL)/files/\(fileId)/comments")!
        var queryItems = [
            URLQueryItem(name: "fields", value: "comments(id,content,createdTime,author),nextPageToken"),
            URLQueryItem(name: "pageSize", value: "\(pageSize)")
        ]
        if let pageToken {
            queryItems.append(URLQueryItem(name: "pageToken", value: pageToken))
        }
        components.queryItems = queryItems

        var request = URLRequest(url: components.url!)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")

        let (data, response) = try await session.data(for: request)
        try validateResponse(response)
        return try JSONDecoder().decode(DriveCommentListResponse.self, from: data)
    }

    @discardableResult
    func createComment(fileId: String, content: String) async throws -> DriveComment {
        let token = try await getToken()
        let url = URL(string: "\(baseURL)/files/\(fileId)/comments?fields=id,content,createdTime,author")!

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["content": content])

        let (data, response) = try await session.data(for: request)
        try validateResponse(response)
        return try JSONDecoder().decode(DriveComment.self, from: data)
    }

    func deleteComment(fileId: String, commentId: String) async throws {
        let token = try await getToken()
        let url = URL(string: "\(baseURL)/files/\(fileId)/comments/\(commentId)")!

        var request = URLRequest(url: url)
        request.httpMethod = "DELETE"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")

        let (_, response) = try await session.data(for: request)
        try validateResponse(response)
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

/// Hands an upload's running bytes-sent count to a closure. A per-task
/// delegate gets `didSendBodyData` without the session needing a delegate of
/// its own.
private final class UploadProgress: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    let report: @Sendable (Int64) -> Void

    init(report: @escaping @Sendable (Int64) -> Void) {
        self.report = report
    }

    nonisolated func urlSession(
        _ session: URLSession, task: URLSessionTask, didSendBodyData bytesSent: Int64,
        totalBytesSent: Int64, totalBytesExpectedToSend: Int64
    ) {
        report(totalBytesSent)
    }
}

enum DriveError: LocalizedError {
    case notConfigured
    /// A resumable upload kept coming back without Drive taking any more of it.
    case uploadRefused
    case unauthorized
    case forbidden
    case notFound
    case rateLimited
    case invalidResponse
    case serverError(Int)

    var errorDescription: String? {
        switch self {
        case .notConfigured: return "Drive service not configured"
        case .uploadRefused: return "Google Drive stopped accepting the upload. Try again."
        case .unauthorized: return "Not authorized. Please sign in again."
        case .forbidden: return "You don't have edit access to this folder."
        case .notFound: return "File or folder not found"
        case .rateLimited: return "Too many requests. Please try again later."
        case .invalidResponse: return "Invalid response from server"
        case .serverError(let code): return "Server error (\(code))"
        }
    }
}
