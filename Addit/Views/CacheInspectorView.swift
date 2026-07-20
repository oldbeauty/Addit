#if DEBUG
import SwiftUI
import SwiftData

/// DEV ONLY — a raw window into every on-disk store the app manages, for
/// hunting dangling data (cached files whose library entries are gone).
/// Reached from Settings ▸ Developer. Not shipped: the whole file and its
/// Settings entry are compiled out of release builds via `#if DEBUG`.
///
/// Orphan detection cross-references the filesystem against SwiftData:
///   - AudioCache/<account>/<fileId>.<ext>  → orphan if no Track has that
///     googleFileId (conversion artifacts `<fileId>.converted.m4a` resolve
///     to the same id).
///   - AlbumArt/<account>/<fileId>.jpg      → orphan if no Album's
///     coverFileId matches.
///   - Documents/LocalAlbums/<dir>          → orphan if no Track's
///     localFilePath points inside that dir.
///   - tmp/                                 → everything is transient by
///     definition; listed for visibility, never flagged.
/// Account-level folders whose account is no longer in the switcher are
/// called out in the section title.
struct CacheInspectorView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(CloudAuthCoordinator.self) private var authService

    @State private var sections: [ScanSection] = []
    @State private var scannedAt: Date?

    struct ScanEntry: Identifiable {
        let url: URL
        let name: String
        let size: Int64
        let isDirectory: Bool
        let isOrphan: Bool
        let note: String?
        var id: String { url.path }
    }

    struct ScanSection: Identifiable {
        let title: String
        let path: String
        let entries: [ScanEntry]
        var id: String { path }
        var totalSize: Int64 { entries.reduce(0) { $0 + $1.size } }
        var orphanCount: Int { entries.filter(\.isOrphan).count }
    }

    var body: some View {
        List {
            summarySection
            ForEach(sections) { section in
                Section {
                    if section.entries.isEmpty {
                        Text("empty").foregroundStyle(.tertiary).font(.uiCaption)
                    }
                    ForEach(section.entries) { entry in
                        entryRow(entry)
                            .swipeActions(edge: .trailing) {
                                Button("Delete", role: .destructive) {
                                    try? FileManager.default.removeItem(at: entry.url)
                                    scan()
                                }
                            }
                    }
                } header: {
                    Text("\(section.title) — \(section.entries.count) item\(section.entries.count == 1 ? "" : "s") · \(Self.fmt(section.totalSize))\(section.orphanCount > 0 ? " · \(section.orphanCount) ORPHAN" : "")")
                } footer: {
                    Text(section.path).font(.system(size: 9, design: .monospaced))
                }
            }
        }
        .navigationTitle("Cache Inspector")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button("Clean Orphans", role: .destructive) { cleanOrphans() }
                    .disabled(sections.allSatisfy { $0.orphanCount == 0 })
            }
            ToolbarItem(placement: .secondaryAction) {
                Button("Rescan") { scan() }
            }
        }
        .onAppear { scan() }
    }

    private var summarySection: some View {
        Section {
            let total = sections.reduce(Int64(0)) { $0 + $1.totalSize }
            let orphans = sections.reduce(0) { $0 + $1.orphanCount }
            HStack {
                Text("Total on disk")
                Spacer()
                Text(Self.fmt(total)).bold()
            }
            HStack {
                Text("Orphaned items")
                Spacer()
                Text("\(orphans)").bold().foregroundStyle(orphans > 0 ? .red : .green)
            }
            if let scannedAt {
                Text("Scanned \(scannedAt.formatted(date: .omitted, time: .standard))")
                    .font(.uiCaption2).foregroundStyle(.secondary)
            }
        }
    }

    private func entryRow(_ entry: ScanEntry) -> some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text(entry.name)
                    .font(.system(size: 12, design: .monospaced))
                    .lineLimit(1)
                    .truncationMode(.middle)
                if let note = entry.note {
                    Text(note).font(.uiCaption2).foregroundStyle(.secondary)
                }
            }
            Spacer()
            if entry.isOrphan {
                Text("ORPHAN")
                    .font(.uiCaption2.bold())
                    .foregroundStyle(.red)
            }
            Text(Self.fmt(entry.size))
                .font(.uiCaption)
                .foregroundStyle(.secondary)
                .monospacedDigit()
        }
    }

    // MARK: - Scanning

    private func scan() {
        let fm = FileManager.default
        let tracks = (try? modelContext.fetch(FetchDescriptor<Track>())) ?? []
        let albums = (try? modelContext.fetch(FetchDescriptor<Album>())) ?? []

        let trackFileIds = Set(tracks.map(\.googleFileId))
        let coverFileIds = Set(albums.compactMap(\.coverFileId))
        // Local album dirs referenced by any track: "LocalAlbums/<dir>/…"
        let referencedLocalDirs = Set(tracks.compactMap { track -> String? in
            guard let path = track.localFilePath,
                  let range = path.range(of: "LocalAlbums/") else { return nil }
            return path[range.upperBound...].split(separator: "/").first.map(String.init)
        })
        let knownAccountIds = Set(authService.accountManager.accounts.map {
            AccountManager.storageIdentifier(for: $0.email)
        })

        var result: [ScanSection] = []
        let caches = fm.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        let documents = fm.urls(for: .documentDirectory, in: .userDomainMask)[0]

        // Per-account cache trees (AudioCache + AlbumArt).
        for (root, label, knownIds) in [
            (caches.appendingPathComponent("AudioCache"), "AudioCache", trackFileIds),
            (caches.appendingPathComponent("AlbumArt"), "AlbumArt", coverFileIds),
        ] {
            for accountDir in subdirectories(of: root) {
                let accountId = accountDir.lastPathComponent
                let stale = !knownAccountIds.contains(accountId)
                result.append(ScanSection(
                    title: "\(label) / \(accountId)\(stale ? " (account signed out)" : "")",
                    path: accountDir.path,
                    entries: files(in: accountDir).map { url in
                        entry(for: url, isOrphan: !knownIds.contains(Self.cacheFileId(from: url)))
                    }
                ))
            }
            // Legacy files sitting at the root (pre-account fallback).
            let rootFiles = files(in: root)
            if !rootFiles.isEmpty {
                result.append(ScanSection(
                    title: "\(label) / (no account)",
                    path: root.path,
                    entries: rootFiles.map { url in
                        entry(for: url, isOrphan: !knownIds.contains(Self.cacheFileId(from: url)))
                    }
                ))
            }
        }

        // Local library payloads: one row per album directory.
        let localRoot = documents.appendingPathComponent("LocalAlbums")
        result.append(ScanSection(
            title: "Documents / LocalAlbums",
            path: localRoot.path,
            entries: subdirectories(of: localRoot).map { dir in
                let count = files(in: dir).count
                return ScanEntry(
                    url: dir,
                    name: dir.lastPathComponent,
                    size: directorySize(dir),
                    isDirectory: true,
                    isOrphan: !referencedLocalDirs.contains(dir.lastPathComponent),
                    note: "\(count) file\(count == 1 ? "" : "s")"
                )
            }
        ))

        // tmp — transient by definition (exports, conversions); never
        // orphan-flagged so Clean Orphans won't yank a mid-flight export.
        result.append(ScanSection(
            title: "tmp (transient)",
            path: fm.temporaryDirectory.path,
            entries: (try? fm.contentsOfDirectory(at: fm.temporaryDirectory, includingPropertiesForKeys: nil))
                .map { $0.sorted { $0.lastPathComponent < $1.lastPathComponent } }?
                .map { url -> ScanEntry in
                    var isDir: ObjCBool = false
                    fm.fileExists(atPath: url.path, isDirectory: &isDir)
                    return ScanEntry(
                        url: url,
                        name: url.lastPathComponent,
                        size: isDir.boolValue ? directorySize(url) : fileSize(url),
                        isDirectory: isDir.boolValue,
                        isOrphan: false,
                        note: nil
                    )
                } ?? []
        ))

        sections = result
        scannedAt = Date()
    }

    private func cleanOrphans() {
        for section in sections {
            for entry in section.entries where entry.isOrphan {
                try? FileManager.default.removeItem(at: entry.url)
            }
        }
        scan()
    }

    // MARK: - Filesystem helpers

    /// `<fileId>.<ext>` and the converter's `<fileId>.converted.m4a` both
    /// resolve back to `<fileId>` for the orphan check.
    private static func cacheFileId(from url: URL) -> String {
        var stem = (url.lastPathComponent as NSString).deletingPathExtension
        if stem.hasSuffix(".converted") {
            stem = (stem as NSString).deletingPathExtension
        }
        return stem
    }

    private func entry(for url: URL, isOrphan: Bool) -> ScanEntry {
        ScanEntry(url: url, name: url.lastPathComponent, size: fileSize(url),
                  isDirectory: false, isOrphan: isOrphan, note: nil)
    }

    private func subdirectories(of url: URL) -> [URL] {
        ((try? FileManager.default.contentsOfDirectory(
            at: url, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]
        )) ?? [])
        .filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
        .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    private func files(in url: URL) -> [URL] {
        ((try? FileManager.default.contentsOfDirectory(
            at: url, includingPropertiesForKeys: [.fileSizeKey], options: [.skipsHiddenFiles]
        )) ?? [])
        .filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) != true }
        .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    private func fileSize(_ url: URL) -> Int64 {
        Int64((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
    }

    private func directorySize(_ url: URL) -> Int64 {
        guard let enumerator = FileManager.default.enumerator(
            at: url, includingPropertiesForKeys: [.fileSizeKey], options: [.skipsHiddenFiles]
        ) else { return 0 }
        var total: Int64 = 0
        for case let fileURL as URL in enumerator {
            total += fileSize(fileURL)
        }
        return total
    }

    private static func fmt(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }
}
#endif
