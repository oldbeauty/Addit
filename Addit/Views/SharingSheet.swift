import SwiftUI

struct SharingSheet: View {
    let album: Album
    @Environment(GoogleDriveService.self) private var driveService
    @Environment(GoogleAuthService.self) private var authService
    @Environment(\.dismiss) private var dismiss
    @State private var permissions: [DrivePermission] = []
    @State private var generalAccess: GeneralAccess = .restricted
    @State private var isLoading = true
    @State private var isSaving = false
    @State private var errorMessage: String?
    @State private var newEmail = ""
    @State private var newRole = "reader"
    @State private var removeTarget: DrivePermission?
    @State private var showRemoveAlert = false
    @State private var showSelfDemoteAlert = false
    @State private var pendingSelfChange: (permission: DrivePermission, newRole: String)?

    private var canEdit: Bool { album.canEdit }

    private func isSelf(_ permission: DrivePermission) -> Bool {
        guard let myEmail = authService.userEmail else { return false }
        return permission.emailAddress?.lowercased() == myEmail.lowercased()
    }

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
                    listContent
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
            .alert("Remove Access", isPresented: $showRemoveAlert) {
                Button("Remove", role: .destructive) {
                    guard let perm = removeTarget else { return }
                    Task { await removePermission(perm) }
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("Remove access for \(removeTarget?.displayName ?? removeTarget?.emailAddress ?? "this person")?")
            }
            .alert("Are you sure?", isPresented: $showSelfDemoteAlert) {
                Button("Confirm", role: .destructive) {
                    guard let pending = pendingSelfChange else { return }
                    if pending.newRole == "remove" {
                        Task { await removePermission(pending.permission) }
                    } else {
                        Task { await changeRole(permission: pending.permission, to: pending.newRole) }
                    }
                    pendingSelfChange = nil
                }
                Button("Cancel", role: .cancel) {
                    pendingSelfChange = nil
                }
            } message: {
                Text("This will change access for the account you are logged in with.")
            }
        }
    }

    // MARK: - List Content

    private var listContent: some View {
        List {
            generalAccessSection
            peopleSection
            if canEdit {
                addPersonSection
            }
        }
        .disabled(isSaving)
        .overlay {
            if isSaving {
                Color.black.opacity(0.05).ignoresSafeArea()
                ProgressView()
            }
        }
    }

    // MARK: - Sections

    private var generalAccessSection: some View {
        Section {
            if canEdit {
                Menu {
                    Button {
                        Task { await updateGeneralAccess(.restricted) }
                    } label: {
                        if generalAccess == .restricted { Label("Restricted", systemImage: "checkmark") }
                        else { Text("Restricted") }
                    }
                    Button {
                        Task { await updateGeneralAccess(.anyoneViewer) }
                    } label: {
                        if generalAccess == .anyoneViewer { Label("Anyone with the link: Viewer", systemImage: "checkmark") }
                        else { Text("Anyone with the link: Viewer") }
                    }
                    Button {
                        Task { await updateGeneralAccess(.anyoneEditor) }
                    } label: {
                        if generalAccess == .anyoneEditor { Label("Anyone with the link: Editor", systemImage: "checkmark") }
                        else { Text("Anyone with the link: Editor") }
                    }
                } label: {
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
                        Spacer()
                        Image(systemName: "chevron.up.chevron.down")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            } else {
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

    private var addPersonSection: some View {
        Section {
            HStack(spacing: 12) {
                TextField("Email address", text: $newEmail)
                    .textContentType(.emailAddress)
                    .keyboardType(.emailAddress)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)

                Picker("Role", selection: $newRole) {
                    Text("Viewer").tag("reader")
                    Text("Editor").tag("writer")
                }
                .labelsHidden()
                .pickerStyle(.menu)

                Button {
                    Task { await addPerson() }
                } label: {
                    Image(systemName: "plus.circle.fill")
                        .font(.title3)
                }
                .disabled(newEmail.isEmpty || isSaving)
            }
        } header: {
            Text("Add people")
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
            if canEdit && permission.role != "owner" {
                roleMenu(for: permission)
            } else {
                Text(permission.roleLabel)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func handleRoleChange(permission: DrivePermission, to newRole: String) {
        if isSelf(permission) {
            pendingSelfChange = (permission, newRole)
            showSelfDemoteAlert = true
        } else {
            Task { await changeRole(permission: permission, to: newRole) }
        }
    }

    private func handleRemove(permission: DrivePermission) {
        if isSelf(permission) {
            pendingSelfChange = (permission, "remove")
            showSelfDemoteAlert = true
        } else {
            removeTarget = permission
            showRemoveAlert = true
        }
    }

    private func roleMenu(for permission: DrivePermission) -> some View {
        Menu {
            Button { handleRoleChange(permission: permission, to: "reader") } label: {
                if permission.role == "reader" { Label("Viewer", systemImage: "checkmark") }
                else { Text("Viewer") }
            }
            Button { handleRoleChange(permission: permission, to: "writer") } label: {
                if permission.role == "writer" { Label("Editor", systemImage: "checkmark") }
                else { Text("Editor") }
            }
            Divider()
            Button(role: .destructive) {
                handleRemove(permission: permission)
            } label: {
                Label("Remove access", systemImage: "trash")
            }
        } label: {
            HStack(spacing: 4) {
                Text(permission.roleLabel)
                    .font(.caption)
                Image(systemName: "chevron.up.chevron.down")
                    .font(.caption2)
            }
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

    /// Refresh permissions without showing full loading spinner
    private func refreshPermissions() async {
        do {
            let perms = try await driveService.listPermissions(fileId: album.googleFolderId)
            permissions = perms

            if let anyonePerm = perms.first(where: { $0.type == "anyone" }) {
                generalAccess = anyonePerm.role == "writer" ? .anyoneEditor : .anyoneViewer
            } else {
                generalAccess = .restricted
            }
        } catch {
            // Silently fail on refresh — data is still showing from before
        }
    }

    // MARK: - Actions

    private func updateGeneralAccess(_ newAccess: GeneralAccess) async {
        guard newAccess != generalAccess else { return }
        let previousAccess = generalAccess
        generalAccess = newAccess  // Optimistic update
        isSaving = true
        defer { isSaving = false }

        do {
            if let anyonePerm = permissions.first(where: { $0.type == "anyone" }) {
                try await driveService.deletePermission(fileId: album.googleFolderId, permissionId: anyonePerm.id)
            }

            switch newAccess {
            case .restricted:
                break
            case .anyoneViewer:
                try await driveService.createAnyonePermission(fileId: album.googleFolderId, role: "reader")
            case .anyoneEditor:
                try await driveService.createAnyonePermission(fileId: album.googleFolderId, role: "writer")
            }

            await refreshPermissions()
        } catch {
            generalAccess = previousAccess  // Revert on failure
        }
    }

    private func changeRole(permission: DrivePermission, to newRole: String) async {
        guard permission.role != newRole else { return }
        isSaving = true
        defer { isSaving = false }

        do {
            try await driveService.updatePermissionRole(
                fileId: album.googleFolderId,
                permissionId: permission.id,
                role: newRole
            )
            await refreshPermissions()
        } catch {
            // Refresh to show actual state
            await refreshPermissions()
        }
    }

    private func addPerson() async {
        let email = newEmail.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !email.isEmpty else { return }
        isSaving = true
        defer { isSaving = false }

        do {
            try await driveService.createPermission(
                fileId: album.googleFolderId,
                email: email,
                role: newRole
            )
            newEmail = ""
            await refreshPermissions()
        } catch {
            // Keep email in field so user can retry
        }
    }

    private func removePermission(_ permission: DrivePermission) async {
        isSaving = true
        defer { isSaving = false }

        do {
            try await driveService.deletePermission(
                fileId: album.googleFolderId,
                permissionId: permission.id
            )
            await refreshPermissions()
        } catch {
            await refreshPermissions()
        }
    }
}
