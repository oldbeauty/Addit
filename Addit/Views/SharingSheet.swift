import SwiftUI

struct SharingSheet: View {
    let album: Album
    @Environment(GoogleDriveService.self) private var driveService
    @Environment(\.dismiss) private var dismiss
    @State private var permissions: [DrivePermission] = []
    @State private var generalAccess: GeneralAccess = .restricted
    @State private var isLoading = true
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            Group {
                if isLoading {
                    ProgressView()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if let errorMessage {
                    ContentUnavailableView {
                        Label("Unable to Load", systemImage: "exclamationmark.triangle")
                    } description: {
                        Text(errorMessage)
                    }
                } else {
                    List {
                        generalAccessSection
                        peopleSection
                    }
                }
            }
            .navigationTitle("Sharing")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .task { await loadPermissions() }
        }
    }

    // MARK: - Sections

    private var generalAccessSection: some View {
        Section {
            HStack(spacing: 12) {
                Image(systemName: generalAccessIcon)
                    .font(.title3)
                    .foregroundStyle(.secondary)
                    .frame(width: 32)
                VStack(alignment: .leading, spacing: 2) {
                    Text(generalAccess.label)
                        .font(.subheadline.weight(.medium))
                    Text(generalAccess.description)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        } header: {
            Text("General access")
        }
    }

    private var peopleSection: some View {
        Section {
            ForEach(sortedPermissions) { permission in
                permissionRow(permission)
            }
        } header: {
            Text("People with access")
        }
    }

    // MARK: - Rows

    private func permissionRow(_ permission: DrivePermission) -> some View {
        HStack(spacing: 12) {
            avatar(for: permission)
            VStack(alignment: .leading, spacing: 2) {
                Text(permission.displayName ?? permission.emailAddress ?? "Unknown")
                    .font(.subheadline.weight(.medium))
                    .lineLimit(1)
                if let email = permission.emailAddress, permission.displayName != nil {
                    Text(email)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            Spacer()
            Text(permission.roleLabel)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private func avatar(for permission: DrivePermission) -> some View {
        if let photoLink = permission.photoLink, let url = URL(string: photoLink) {
            AsyncImage(url: url) { phase in
                switch phase {
                case .success(let image):
                    image
                        .resizable()
                        .scaledToFill()
                        .frame(width: 32, height: 32)
                        .clipShape(Circle())
                default:
                    defaultAvatar(for: permission)
                }
            }
        } else {
            defaultAvatar(for: permission)
        }
    }

    private func defaultAvatar(for permission: DrivePermission) -> some View {
        Circle()
            .fill(avatarColor(for: permission))
            .frame(width: 32, height: 32)
            .overlay {
                Text(avatarInitial(for: permission))
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.white)
            }
    }

    // MARK: - Helpers

    private var generalAccessIcon: String {
        switch generalAccess {
        case .restricted: return "lock"
        case .anyoneViewer, .anyoneEditor: return "link"
        }
    }

    private var sortedPermissions: [DrivePermission] {
        // Owner first, then editors, then viewers
        let roleOrder: [String: Int] = ["owner": 0, "writer": 1, "commenter": 2, "reader": 3]
        return permissions
            .filter { $0.type != "anyone" }
            .sorted { (roleOrder[$0.role] ?? 99) < (roleOrder[$1.role] ?? 99) }
    }

    private func avatarInitial(for permission: DrivePermission) -> String {
        let name = permission.displayName ?? permission.emailAddress ?? "?"
        return String(name.prefix(1)).uppercased()
    }

    private func avatarColor(for permission: DrivePermission) -> Color {
        let name = permission.displayName ?? permission.emailAddress ?? ""
        let hash = abs(name.hashValue)
        let colors: [Color] = [.blue, .green, .orange, .purple, .pink, .teal, .indigo]
        return colors[hash % colors.count]
    }

    // MARK: - Data Loading

    private func loadPermissions() async {
        isLoading = true
        errorMessage = nil

        do {
            let perms = try await driveService.listPermissions(fileId: album.googleFolderId)
            permissions = perms

            // Determine general access from the "anyone" permission
            if let anyonePerm = perms.first(where: { $0.type == "anyone" }) {
                generalAccess = anyonePerm.role == "writer" ? .anyoneEditor : .anyoneViewer
            } else {
                generalAccess = .restricted
            }

            isLoading = false
        } catch {
            errorMessage = error.localizedDescription
            isLoading = false
        }
    }
}
