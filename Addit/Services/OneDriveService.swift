import Foundation

/// Microsoft Graph (OneDrive) implementation of `CloudDriveService`.
///
/// Maps Graph `driveItem` JSON into the app's neutral `DriveItem` DTOs,
/// normalizing to Google Drive conventions so nothing downstream changes:
/// folders get the Google folder mimeType synthesized (so
/// `DriveItem.isFolder` works), sizes become strings, and permission roles
/// are translated to Google role names ("reader"/"writer"/"owner") so
/// `DrivePermission.roleLabel` renders correctly.
///
/// **ID scheme**: every id handed out by this service is a composite
/// `driveId|itemId`. Graph item IDs are only unique within one drive, and
/// the collaborative-album case means folders shared from *other people's*
/// drives — those are only addressable as /drives/{driveId}/items/{itemId}.
/// Callers treat ids as opaque and round-trip them back to this service,
/// so the composite never leaks.
///
/// Not supported by Graph (capability flags are false, UI hides the
/// features): starring, comments, and the "commenter" permission role.
@Observable
final class OneDriveService: CloudDriveService {
    var authService: MicrosoftAuthService?

    // CloudDriveService capability flags
    let supportsComments = false
    let supportsStarred = false
    let supportsCommenterRole = false

    private let session = URLSession.shared
    private let baseURL = Constants.graphAPIBase

    enum OneDriveError: LocalizedError {
        case notConfigured
        case badResponse(Int, String)
        case copyTimedOut

        var errorDescription: String? {
            switch self {
            case .notConfigured: return "OneDrive service not configured"
            case .badResponse(let code, let body): return "OneDrive error \(code): \(body)"
            case .copyTimedOut: return "OneDrive copy operation timed out"
            }
        }
    }

    // MARK: - Browsing

    func listFolders(pageToken: String?) async throws -> DriveFileListResponse {
        let url = pageToken ?? "\(baseURL)/me/drive/root/children?$top=200&$orderby=name"
        let page = try await fetchItemPage(urlString: url, ownedByMe: true)
        return DriveFileListResponse(
            files: page.files.filter(\.isFolder),
            nextPageToken: page.nextPageToken
        )
    }

    /// OneDrive has no per-item "starred" concept. Returns empty; the
    /// Starred browse tab is hidden for Microsoft accounts via
    /// `supportsStarred`.
    func listStarredFolders(pageToken: String?) async throws -> DriveFileListResponse {
        DriveFileListResponse(files: [], nextPageToken: nil)
    }

    func listSharedFolders(pageToken: String?) async throws -> DriveFileListResponse {
        let url = pageToken ?? "\(baseURL)/me/drive/sharedWithMe"
        let (data, _) = try await authorizedRequest(urlString: url)
        let decoded = try JSONDecoder().decode(GraphItemList.self, from: data)
        // sharedWithMe entries carry the actual item coordinates in
        // `remoteItem` — the top-level id belongs to a stub in *our* drive
        // and is useless for children/content calls.
        let items = decoded.value.compactMap { mapItem($0, ownedByMe: false) }
        return DriveFileListResponse(
            files: items.filter(\.isFolder),
            nextPageToken: decoded.nextLink
        )
    }

    func listSubfolders(inFolder folderId: String) async throws -> DriveFileListResponse {
        let all = try await listChildren(of: folderId)
        return DriveFileListResponse(files: all.filter(\.isFolder), nextPageToken: nil)
    }

    func searchFolders(query searchText: String) async throws -> DriveFileListResponse {
        let escaped = searchText
            .replacingOccurrences(of: "'", with: "''")
            .addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? searchText
        let url = "\(baseURL)/me/drive/root/search(q='\(escaped)')?$top=200"
        let page = try await fetchItemPage(urlString: url, ownedByMe: true)
        return DriveFileListResponse(
            files: page.files.filter(\.isFolder),
            nextPageToken: nil
        )
    }

    func listAudioFiles(inFolder folderId: String, pageToken: String?) async throws -> DriveFileListResponse {
        let all = try await listChildren(of: folderId)
        let audio = all.filter(\.isAudio).sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        return DriveFileListResponse(files: audio, nextPageToken: nil)
    }

    func listAllFilesInFolder(_ folderId: String) async throws -> DriveFileListResponse {
        let all = try await listChildren(of: folderId)
        let sorted = all.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        return DriveFileListResponse(files: sorted, nextPageToken: nil)
    }

    // MARK: - Files

    func findCoverImage(inFolder folderId: String) async throws -> DriveItem? {
        let all = try await listChildren(of: folderId)
        // Mirror Google behavior: only files named exactly "cover" (any
        // image extension) count as the album cover.
        return all.first { item in
            item.mimeType.hasPrefix("image/") &&
            (item.name as NSString).deletingPathExtension.lowercased() == "cover"
        }
    }

    func upsertCoverImage(inFolder folderId: String, data: Data, fileName: String) async throws -> DriveItem {
        if let existing = try await findCoverImage(inFolder: folderId) {
            try await updateFileData(fileId: existing.id, data: data, mimeType: "image/jpeg")
            return existing
        }
        return try await createFile(name: fileName, mimeType: "image/jpeg", inFolder: folderId, data: data)
    }

    func findFile(named fileName: String, inFolder folderId: String) async throws -> DriveItem? {
        let all = try await listChildren(of: folderId)
        return all.first { $0.name == fileName }
    }

    func storageQuota() async throws -> StorageQuota {
        // `/me/drive` is the signed-in account's own drive. Deliberately not a
        // `driveId` from one of the composite item IDs — those can point at a
        // *shared* drive, whose quota belongs to whoever owns it, not to us.
        let (data, _) = try await authorizedRequest(urlString: "\(baseURL)/me/drive?$select=quota")

        struct DriveQuota: Decodable {
            struct Quota: Decodable {
                let total: Int64?
                let used: Int64?
            }
            let quota: Quota?
        }

        let quota = try JSONDecoder().decode(DriveQuota.self, from: data).quota
        #if DEBUG
        if let quota, let total = quota.total {
            let free = total - (quota.used ?? 0)
            print("[OneDrive] quota: \(free / 1_048_576) MB free of \(total / 1_048_576) MB")
        }
        #endif
        return StorageQuota(
            usedBytes: quota?.used ?? 0,
            limitBytes: quota?.total
        )
    }

    func getFileMetadata(fileId: String) async throws -> DriveItem {
        let (data, _) = try await authorizedRequest(urlString: itemURL(fileId))
        let item = try JSONDecoder().decode(GraphItem.self, from: data)
        guard let mapped = mapItem(item, ownedByMe: nil) else {
            throw OneDriveError.badResponse(0, "Unmappable item")
        }
        return mapped
    }

    @discardableResult
    func renameFile(fileId: String, newName: String) async throws -> DriveItem {
        let body = try JSONSerialization.data(withJSONObject: ["name": newName])
        let (data, _) = try await authorizedRequest(
            urlString: itemURL(fileId), method: "PATCH", body: body,
            contentType: "application/json"
        )
        let item = try JSONDecoder().decode(GraphItem.self, from: data)
        return mapItem(item, ownedByMe: nil) ?? DriveItem(
            id: fileId, name: newName, mimeType: "application/octet-stream",
            size: nil, parents: nil, capabilities: nil, ownedByMe: nil, modifiedTime: nil
        )
    }

    /// Google semantics are "unparent the file from this folder" (the file
    /// survives elsewhere in Drive). OneDrive items live in exactly one
    /// place, so the closest equivalent is moving the item to the drive
    /// root — it leaves the album folder but isn't destroyed.
    func removeFileFromFolder(fileId: String, folderId: String) async throws {
        let (driveId, _) = try splitId(fileId)
        // `parentReference` wants a real item id. "root" is a path alias, not
        // an id, so resolve the drive's actual root item first — same trap as
        // the one `itemURL` sidesteps.
        let (rootData, _) = try await authorizedRequest(
            urlString: "\(baseURL)/drives/\(driveId)/root?$select=id"
        )
        struct RootItem: Decodable { let id: String }
        let rootId = try JSONDecoder().decode(RootItem.self, from: rootData).id
        let body = try JSONSerialization.data(withJSONObject: [
            "parentReference": ["driveId": driveId, "id": rootId]
        ])
        _ = try await authorizedRequest(
            urlString: itemURL(fileId), method: "PATCH", body: body,
            contentType: "application/json"
        )
    }

    func deleteFile(fileId: String) async throws {
        _ = try await authorizedRequest(urlString: itemURL(fileId), method: "DELETE")
    }

    /// Graph copies are asynchronous: the POST returns 202 with a monitor
    /// URL we poll until the operation completes, then fetch the new item.
    func copyFile(fileId: String, toFolder folderId: String) async throws -> DriveItem {
        let (destDriveId, destItemId) = try splitId(folderId)
        let body = try JSONSerialization.data(withJSONObject: [
            "parentReference": ["driveId": destDriveId, "id": destItemId]
        ])

        let token = try await getToken()
        var request = URLRequest(url: URL(string: "\(itemURL(fileId))/copy")!)
        request.httpMethod = "POST"
        request.httpBody = body
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let (_, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse,
              http.statusCode == 202,
              let monitorURL = http.value(forHTTPHeaderField: "Location") else {
            throw OneDriveError.badResponse(
                (response as? HTTPURLResponse)?.statusCode ?? 0, "Copy did not start"
            )
        }

        // Poll the (unauthenticated) monitor endpoint until completion.
        struct MonitorStatus: Decodable {
            let status: String?
            let resourceId: String?
        }
        for _ in 0..<60 {
            try await Task.sleep(nanoseconds: 500_000_000)
            let (data, _) = try await session.data(from: URL(string: monitorURL)!)
            if let status = try? JSONDecoder().decode(MonitorStatus.self, from: data),
               status.status == "completed", let newItemId = status.resourceId {
                return try await getFileMetadata(fileId: encodeId(driveId: destDriveId, itemId: newItemId))
            }
        }
        throw OneDriveError.copyTimedOut
    }

    func createFolder(name: String, inParent parentId: String) async throws -> DriveItem {
        let body = try JSONSerialization.data(withJSONObject: [
            "name": name,
            "folder": [String: String](),
            "@microsoft.graph.conflictBehavior": "rename",
        ])
        let (data, _) = try await authorizedRequest(
            urlString: "\(itemURL(parentId))/children", method: "POST", body: body,
            contentType: "application/json"
        )
        let item = try JSONDecoder().decode(GraphItem.self, from: data)
        guard let mapped = mapItem(item, ownedByMe: nil) else {
            throw OneDriveError.badResponse(0, "Unmappable folder")
        }
        return mapped
    }

    func findOrCreateFolder(named name: String, inParent parentId: String) async throws -> DriveItem {
        let children = try await listChildren(of: parentId)
        if let existing = children.first(where: { $0.isFolder && $0.name == name }) {
            return existing
        }
        return try await createFolder(name: name, inParent: parentId)
    }

    /// Graph's simple `PUT …/content` upload takes files up to 250 MB, which
    /// covers any realistic audio file — only past that is an upload session
    /// actually required. The 4 MB threshold this used to carry was Graph's
    /// *old* published limit.
    ///
    /// Preferring the simple PUT is also a reliability win. `createUploadSession`
    /// on the consumer OneDrive endpoint intermittently answers `invalidRequest`
    /// ("The request is malformed or incorrect") to requests byte-identical to
    /// ones it accepted minutes earlier: observed 2026-08-11, where one run
    /// uploaded three tracks and was refused on the fourth, and the next run was
    /// refused three times on the track that had just succeeded. No `Retry-After`,
    /// 5 GB free. The simple PUT has never failed in any of those runs — it is
    /// what puts `.addit-data` and `cover.jpg` up every time.
    private static let simpleUploadLimit = 250 * 1024 * 1024

    func createFile(name: String, mimeType: String, inFolder parentId: String, data: Data) async throws -> DriveItem {
        let safeName = Self.sanitizedName(name)
        let encodedName = safeName.addingPercentEncoding(withAllowedCharacters: Self.nameAllowed) ?? safeName

        if data.count <= Self.simpleUploadLimit {
            do {
                let url = "\(itemURL(parentId)):/\(encodedName):/content?@microsoft.graph.conflictBehavior=replace"
                let (respData, _) = try await authorizedRequest(
                    urlString: url, method: "PUT", body: data, contentType: mimeType
                )
                let item = try JSONDecoder().decode(GraphItem.self, from: respData)
                guard let mapped = mapItem(item, ownedByMe: nil) else {
                    throw OneDriveError.badResponse(0, "Unmappable uploaded file")
                }
                return mapped
            } catch {
                // Fall through to the session path rather than failing outright,
                // so a size limit lower than advertised still has a way through.
                #if DEBUG
                print("[OneDrive] simple upload failed for \(safeName) — trying an upload session")
                #endif
            }
        }

        // Upload session: files past the simple-upload ceiling, or a retry
        // after the simple PUT was rejected.
        let sessionBody = try JSONSerialization.data(withJSONObject: [
            "item": ["@microsoft.graph.conflictBehavior": "replace", "name": safeName]
        ])
        // Graph intermittently refuses session creation with a bare
        // `invalidRequest` on requests that are structurally identical to ones
        // it just accepted — it shows up when several sessions are opened back
        // to back, and the drive has plenty of free space. Retry the identical
        // request: if attempt 2 succeeds, the request was never malformed.
        let sessionURL = "\(itemURL(parentId)):/\(encodedName):/createUploadSession"
        var sessionData: Data?
        var lastError: Error?
        for attempt in 1...3 {
            do {
                sessionData = try await authorizedRequest(
                    urlString: sessionURL, method: "POST", body: sessionBody,
                    contentType: "application/json"
                ).0
                #if DEBUG
                if attempt > 1 { print("[OneDrive] session for \(safeName) succeeded on attempt \(attempt)") }
                #endif
                break
            } catch {
                lastError = error
                #if DEBUG
                print("[OneDrive] session attempt \(attempt)/3 failed for \(safeName)")
                #endif
                if attempt < 3 {
                    try? await Task.sleep(for: .milliseconds(500 << (attempt - 1)))
                }
            }
        }
        guard let sessData = sessionData else {
            throw lastError ?? OneDriveError.badResponse(0, "No upload session for \(safeName)")
        }
        struct UploadSession: Decodable { let uploadUrl: String }
        let uploadSession = try JSONDecoder().decode(UploadSession.self, from: sessData)

        let chunkSize = 10 * 320 * 1024 * 4  // ~12.5MB, multiple of 320 KiB per Graph docs
        var offset = 0
        var finalData: Data?
        while offset < data.count {
            let end = min(offset + chunkSize, data.count)
            let chunk = data.subdata(in: offset..<end)

            var request = URLRequest(url: URL(string: uploadSession.uploadUrl)!)
            request.httpMethod = "PUT"
            request.httpBody = chunk
            request.setValue("\(chunk.count)", forHTTPHeaderField: "Content-Length")
            request.setValue("bytes \(offset)-\(end - 1)/\(data.count)", forHTTPHeaderField: "Content-Range")

            let (respData, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                throw OneDriveError.badResponse(0, "No response during chunked upload")
            }
            if http.statusCode == 201 || http.statusCode == 200 {
                finalData = respData  // last chunk returns the driveItem
            } else if http.statusCode != 202 {
                let bodyText = String(data: respData, encoding: .utf8) ?? ""
                throw OneDriveError.badResponse(http.statusCode, bodyText)
            }
            offset = end
        }

        guard let finalData,
              let item = try? JSONDecoder().decode(GraphItem.self, from: finalData),
              let mapped = mapItem(item, ownedByMe: nil) else {
            throw OneDriveError.badResponse(0, "Chunked upload did not return an item")
        }
        return mapped
    }

    /// No starred concept on OneDrive — silent no-op (feature hidden in UI).
    func setStarred(fileId: String, starred: Bool) async throws {}

    func updateFileData(fileId: String, data: Data, mimeType: String) async throws {
        guard data.count <= 4_000_000 else {
            // Large replacement: route through an upload session on the
            // existing item.
            let sessionBody = try JSONSerialization.data(withJSONObject: [
                "item": ["@microsoft.graph.conflictBehavior": "replace"]
            ])
            let (sessData, _) = try await authorizedRequest(
                urlString: "\(itemURL(fileId))/createUploadSession",
                method: "POST", body: sessionBody, contentType: "application/json"
            )
            struct UploadSession: Decodable { let uploadUrl: String }
            let uploadSession = try JSONDecoder().decode(UploadSession.self, from: sessData)

            var request = URLRequest(url: URL(string: uploadSession.uploadUrl)!)
            request.httpMethod = "PUT"
            request.httpBody = data
            request.setValue("\(data.count)", forHTTPHeaderField: "Content-Length")
            request.setValue("bytes 0-\(data.count - 1)/\(data.count)", forHTTPHeaderField: "Content-Range")
            let (respData, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                let bodyText = String(data: respData, encoding: .utf8) ?? ""
                throw OneDriveError.badResponse((response as? HTTPURLResponse)?.statusCode ?? 0, bodyText)
            }
            return
        }
        _ = try await authorizedRequest(
            urlString: "\(itemURL(fileId))/content", method: "PUT", body: data,
            contentType: mimeType
        )
    }

    func downloadFileData(fileId: String) async throws -> Data {
        // /content 302-redirects to a pre-authenticated CDN URL;
        // URLSession follows it transparently.
        let (data, _) = try await authorizedRequest(urlString: "\(itemURL(fileId))/content")
        return data
    }

    func downloadFile(fileId: String, to destination: URL) async throws {
        let token = try await getToken()
        var request = URLRequest(url: URL(string: "\(itemURL(fileId))/content")!)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")

        let (tempURL, response) = try await session.download(for: request)
        try validateResponse(response, data: nil)

        let fm = FileManager.default
        if fm.fileExists(atPath: destination.path) {
            try fm.removeItem(at: destination)
        }
        try fm.moveItem(at: tempURL, to: destination)
    }

    // MARK: - Permissions

    func listPermissions(fileId: String) async throws -> [DrivePermission] {
        let (data, _) = try await authorizedRequest(urlString: "\(itemURL(fileId))/permissions")
        struct PermissionList: Decodable { let value: [GraphPermission] }
        let decoded = try JSONDecoder().decode(PermissionList.self, from: data)
        return decoded.value.map { mapPermission($0) }
    }

    func updatePermissionRole(fileId: String, permissionId: String, role: String) async throws {
        let body = try JSONSerialization.data(withJSONObject: [
            "roles": [graphRole(fromGoogleRole: role)]
        ])
        _ = try await authorizedRequest(
            urlString: "\(itemURL(fileId))/permissions/\(permissionId)",
            method: "PATCH", body: body, contentType: "application/json"
        )
    }

    func createPermission(fileId: String, email: String, role: String, sendNotification: Bool) async throws {
        let body = try JSONSerialization.data(withJSONObject: [
            "recipients": [["email": email]],
            "roles": [graphRole(fromGoogleRole: role)],
            "requireSignIn": true,
            "sendInvitation": sendNotification,
        ])
        _ = try await authorizedRequest(
            urlString: "\(itemURL(fileId))/invite", method: "POST", body: body,
            contentType: "application/json"
        )
    }

    func deletePermission(fileId: String, permissionId: String) async throws {
        _ = try await authorizedRequest(
            urlString: "\(itemURL(fileId))/permissions/\(permissionId)", method: "DELETE"
        )
    }

    func createAnyonePermission(fileId: String, role: String) async throws {
        let body = try JSONSerialization.data(withJSONObject: [
            "type": role == "writer" ? "edit" : "view",
            "scope": "anonymous",
        ])
        _ = try await authorizedRequest(
            urlString: "\(itemURL(fileId))/createLink", method: "POST", body: body,
            contentType: "application/json"
        )
    }

    // MARK: - Graph JSON shapes

    private struct GraphItemList: Decodable {
        let value: [GraphItem]
        let nextLink: String?

        enum CodingKeys: String, CodingKey {
            case value
            case nextLink = "@odata.nextLink"
        }
    }

    private struct GraphItem: Decodable {
        struct FileFacet: Decodable { let mimeType: String? }
        struct FolderFacet: Decodable { let childCount: Int? }
        struct ParentRef: Decodable {
            let driveId: String?
            let id: String?
        }
        struct RemoteItem: Decodable {
            let id: String?
            let name: String?
            let size: Int64?
            let file: FileFacet?
            let folder: FolderFacet?
            let parentReference: ParentRef?
            let lastModifiedDateTime: String?
        }

        let id: String?
        let name: String?
        let size: Int64?
        let file: FileFacet?
        let folder: FolderFacet?
        let parentReference: ParentRef?
        let lastModifiedDateTime: String?
        let remoteItem: RemoteItem?
    }

    private struct GraphPermission: Decodable {
        struct IdentitySet: Decodable {
            struct Identity: Decodable {
                let displayName: String?
                let email: String?
            }
            let user: Identity?
        }
        struct LinkFacet: Decodable {
            let type: String?
            let scope: String?
        }

        let id: String
        let roles: [String]?
        let grantedToV2: IdentitySet?
        let grantedToIdentitiesV2: [IdentitySet]?
        let link: LinkFacet?
    }

    // MARK: - Mapping

    /// Convert a Graph item to the neutral DTO. For `sharedWithMe` stubs
    /// the real coordinates live in `remoteItem`. Returns nil for items
    /// with no usable id.
    private func mapItem(_ item: GraphItem, ownedByMe: Bool?) -> DriveItem? {
        // Prefer remoteItem coordinates when present (shared items).
        let driveId = item.remoteItem?.parentReference?.driveId ?? item.parentReference?.driveId
        let itemId = item.remoteItem?.id ?? item.id
        guard let driveId, let itemId else { return nil }

        let name = item.remoteItem?.name ?? item.name ?? ""
        let isFolder = (item.remoteItem?.folder ?? item.folder) != nil
        let rawMime = (item.remoteItem?.file ?? item.file)?.mimeType
        let size = item.remoteItem?.size ?? item.size
        let modified = item.remoteItem?.lastModifiedDateTime ?? item.lastModifiedDateTime

        let mimeType: String
        if isFolder {
            // Synthesize the Google folder mimeType so DriveItem.isFolder
            // (which string-matches it) works for OneDrive items too.
            mimeType = "application/vnd.google-apps.folder"
        } else {
            mimeType = Self.normalizeMimeType(rawMime, fileName: name)
        }

        return DriveItem(
            id: encodeId(driveId: driveId, itemId: itemId),
            name: name,
            mimeType: mimeType,
            size: size.map(String.init),
            parents: item.parentReference?.id.flatMap { parentItemId in
                item.parentReference?.driveId.map { [encodeId(driveId: $0, itemId: parentItemId)] }
            },
            // Graph listings don't carry per-item edit capabilities the way
            // Drive's `capabilities` field does. Assume editable — a
            // read-only share surfaces a 403 on the first write attempt.
            capabilities: DriveCapabilities(canEdit: true, canAddChildren: true),
            ownedByMe: ownedByMe,
            modifiedTime: modified
        )
    }

    /// Graph reports generic mime types for some audio ("application/
    /// octet-stream" for FLAC etc.). Recover a usable audio mimeType from
    /// the extension so the app's MIME allow-list logic keeps working.
    private static func normalizeMimeType(_ mime: String?, fileName: String) -> String {
        if let mime, mime != "application/octet-stream" { return mime }
        let ext = (fileName as NSString).pathExtension.lowercased()
        let byExtension: [String: String] = [
            "mp3": "audio/mpeg", "m4a": "audio/x-m4a", "aac": "audio/aac",
            "wav": "audio/wav", "flac": "audio/flac", "ogg": "audio/ogg",
            "aiff": "audio/aiff", "aif": "audio/aiff", "alac": "audio/alac",
            "mp4": "video/mp4",
            "jpg": "image/jpeg", "jpeg": "image/jpeg", "png": "image/png",
            "webp": "image/webp", "gif": "image/gif",
        ]
        return byExtension[ext] ?? mime ?? "application/octet-stream"
    }

    private func mapPermission(_ perm: GraphPermission) -> DrivePermission {
        // Graph roles: "read", "write", "owner" → Google-style names the
        // existing UI understands.
        let googleRole: String
        switch perm.roles?.first {
        case "owner": googleRole = "owner"
        case "write": googleRole = "writer"
        default: googleRole = "reader"
        }

        // Link permissions (anonymous share links) map to Google's
        // "anyone" type; direct grants are "user".
        let isLink = perm.link != nil
        let identity = perm.grantedToV2?.user ?? perm.grantedToIdentitiesV2?.first?.user

        return DrivePermission(
            id: perm.id,
            role: googleRole,
            type: isLink ? "anyone" : "user",
            emailAddress: identity?.email,
            displayName: identity?.displayName,
            photoLink: nil
        )
    }

    private func graphRole(fromGoogleRole role: String) -> String {
        switch role {
        case "writer": return "write"
        // Graph has no commenter concept; degrade to read. The role
        // picker hides "Commenter" for OneDrive via supportsCommenterRole.
        default: return "read"
        }
    }

    // MARK: - Composite IDs

    private func encodeId(driveId: String, itemId: String) -> String {
        "\(driveId)|\(itemId)"
    }

    private func splitId(_ compositeId: String) throws -> (driveId: String, itemId: String) {
        guard let sep = compositeId.firstIndex(of: "|") else {
            throw OneDriveError.badResponse(0, "Malformed OneDrive id: \(compositeId)")
        }
        return (
            String(compositeId[..<sep]),
            String(compositeId[compositeId.index(after: sep)...])
        )
    }

    private func itemURL(_ compositeId: String) -> String {
        // "root" is Google Drive's alias for the drive root, and it reaches us
        // from provider-neutral callers — the folder picker hands it back as
        // the parent whenever you create at the top level rather than inside a
        // folder. Graph has no item whose *id* is "root"; /me/drive/items/root
        // is a 400 invalidRequest. Address the root the way Graph expects.
        if compositeId == Self.rootAlias { return "\(baseURL)/me/drive/root" }
        guard let (driveId, itemId) = try? splitId(compositeId) else {
            // Fall back to own-drive addressing for non-composite ids.
            return "\(baseURL)/me/drive/items/\(compositeId)"
        }
        return "\(baseURL)/drives/\(driveId)/items/\(itemId)"
    }

    /// Google Drive's name for the drive root, which provider-neutral callers
    /// pass through to us as an opaque parent id.
    private static let rootAlias = "root"

    // MARK: - File names

    /// Graph addresses a new file as `{parent}:/{name}:/content`, so anything
    /// in the name that reads as path syntax corrupts the URL — a track called
    /// "AC/DC Live" would silently become a two-segment path and Graph answers
    /// `invalidRequest`. OneDrive rejects these characters in names anyway
    /// (`" * : < > ? / \ |`), plus surrounding spaces and trailing dots, so
    /// substitute rather than encode: the file lands with a legal name instead
    /// of a mangled one.
    private static func sanitizedName(_ name: String) -> String {
        let forbidden = CharacterSet(charactersIn: "\"*:<>?/\\|")
        var cleaned = String(name.unicodeScalars.map {
            forbidden.contains($0) ? "_" : Character($0)
        })
        cleaned = cleaned.trimmingCharacters(in: .whitespaces)
        while cleaned.hasSuffix(".") { cleaned.removeLast() }
        return cleaned.isEmpty ? "untitled" : cleaned
    }

    /// `.urlPathAllowed` leaves `/` and `:` unescaped — exactly the two
    /// characters the path syntax above is delimited by. Drop them, and the
    /// other reserved characters, so encoding can't reintroduce the problem
    /// `sanitizedName` just removed.
    private static let nameAllowed: CharacterSet = {
        var set = CharacterSet.urlPathAllowed
        set.remove(charactersIn: ":/?#[]@")
        return set
    }()

    // MARK: - HTTP plumbing

    /// Fetch every child of a folder, following @odata.nextLink pagination
    /// to completion. Albums are at most a few hundred items, so eager
    /// exhaustion is fine (and matches Google's pageSize:1000 behavior).
    private func listChildren(of folderId: String) async throws -> [DriveItem] {
        var results: [DriveItem] = []
        var next: String? = "\(itemURL(folderId))/children?$top=200"
        while let url = next {
            let page = try await fetchItemPage(urlString: url, ownedByMe: nil)
            results.append(contentsOf: page.files)
            next = page.nextPageToken
        }
        return results
    }

    private func fetchItemPage(urlString: String, ownedByMe: Bool?) async throws -> DriveFileListResponse {
        let (data, _) = try await authorizedRequest(urlString: urlString)
        let decoded = try JSONDecoder().decode(GraphItemList.self, from: data)
        return DriveFileListResponse(
            files: decoded.value.compactMap { mapItem($0, ownedByMe: ownedByMe) },
            nextPageToken: decoded.nextLink
        )
    }

    @discardableResult
    private func authorizedRequest(
        urlString: String,
        method: String = "GET",
        body: Data? = nil,
        contentType: String? = nil
    ) async throws -> (Data, URLResponse) {
        let token = try await getToken()
        guard let url = URL(string: urlString) else {
            throw OneDriveError.badResponse(0, "Bad URL: \(urlString)")
        }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.httpBody = body
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        if let contentType {
            request.setValue(contentType, forHTTPHeaderField: "Content-Type")
        }
        #if DEBUG
        print("[OneDrive] → \(method) \(relativePath(urlString))")
        #endif
        let (data, response) = try await session.data(for: request)
        try validateResponse(response, data: data, method: method, urlString: urlString)
        return (data, response)
    }

    /// Trims the API base off a URL so logs and error text show the part that
    /// actually varies — and stay short enough to survive an alert box.
    private func relativePath(_ urlString: String) -> String {
        urlString.hasPrefix(baseURL)
            ? String(urlString.dropFirst(baseURL.count))
            : urlString
    }

    private func getToken() async throws -> String {
        guard let authService else { throw OneDriveError.notConfigured }
        return try await authService.validAccessToken()
    }

    private func validateResponse(
        _ response: URLResponse,
        data: Data?,
        method: String = "",
        urlString: String = ""
    ) throws {
        guard let http = response as? HTTPURLResponse else { return }
        guard (200..<300).contains(http.statusCode) else {
            let bodyText = data.flatMap { String(data: $0, encoding: .utf8) } ?? ""
            // The failing request goes *first* in the message: Graph's error
            // bodies are long enough to fill an alert on their own, and which
            // call failed matters more than the boilerplate innerError.
            let request = urlString.isEmpty ? "" : "\(method) \(relativePath(urlString)) — "
            #if DEBUG
            print("[OneDrive] HTTP \(http.statusCode) on \(request)\(bodyText.prefix(300))")
            // Graph puts the real reason in headers more often than in the
            // body — throttling arrives as Retry-After, and quota problems
            // often surface only as a generic `invalidRequest`.
            let interesting = ["Retry-After", "x-ms-ags-diagnostic", "WWW-Authenticate"]
            for key in interesting {
                if let value = http.value(forHTTPHeaderField: key) {
                    print("[OneDrive]   \(key): \(value)")
                }
            }
            #endif
            throw OneDriveError.badResponse(http.statusCode, request + String(bodyText.prefix(300)))
        }
    }
}
