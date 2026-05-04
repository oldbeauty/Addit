import SwiftUI

struct SettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(ThemeService.self) private var themeService
    /// Which scheme's accent the picker sheet is currently editing.
    /// `nil` = sheet closed. Driving presentation off this optional
    /// (instead of a separate `Bool`) means the sheet always knows
    /// which scheme to operate on without an extra prop drill.
    @State private var editingScheme: ColorScheme? = nil

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("Appearance", selection: Binding(
                        get: { themeService.appearanceMode },
                        set: { themeService.appearanceMode = $0 }
                    )) {
                        ForEach(AppearanceMode.allCases, id: \.self) { mode in
                            Text(mode.label).tag(mode)
                        }
                    }
                    .pickerStyle(.segmented)
                }

                // Per-scheme accent rows. Each shows its own swatch so
                // the user sees both colors at a glance even while
                // viewing in a single mode. Tapping either opens the
                // same picker sheet, scoped to that scheme.
                Section("Default Color") {
                    accentRow(label: "Light Mode", scheme: .light)
                    accentRow(label: "Dark Mode", scheme: .dark)
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") {
                        dismiss()
                    }
                }
            }
            .sheet(item: Binding(
                get: { editingScheme.map(SchemeIdentifier.init) },
                set: { editingScheme = $0?.scheme }
            )) { identifier in
                AccentColorPickerSheet(scheme: identifier.scheme)
            }
        }
    }

    private func accentRow(label: String, scheme: ColorScheme) -> some View {
        Button {
            editingScheme = scheme
        } label: {
            HStack {
                Text(label)
                Spacer()
                RoundedRectangle(cornerRadius: 6)
                    .fill(themeService.accentColor(for: scheme))
                    .frame(width: 22, height: 22)
                    .overlay {
                        RoundedRectangle(cornerRadius: 6)
                            .stroke(Color.primary.opacity(0.2), lineWidth: 1)
                    }
            }
        }
        .buttonStyle(.plain)
    }
}

/// Identifiable wrapper so `ColorScheme` (which isn't `Identifiable` by
/// default) can drive `.sheet(item:)`. Lets us bind sheet presentation
/// directly to "which scheme are we editing right now."
private struct SchemeIdentifier: Identifiable {
    let scheme: ColorScheme
    var id: String { scheme == .dark ? "dark" : "light" }
}

private struct AccentColorPickerSheet: View {
    /// Which scheme this picker is editing. The sheet operates on a
    /// single scheme at a time so the user can pick distinct colors
    /// for light and dark.
    let scheme: ColorScheme

    @Environment(\.dismiss) private var dismiss
    @Environment(ThemeService.self) private var themeService

    private let columns = [GridItem(.adaptive(minimum: 62), spacing: 14)]

    private var navTitle: String {
        scheme == .dark ? "Dark Mode Color" : "Light Mode Color"
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVGrid(columns: columns, spacing: 14) {
                    ForEach(ThemeService.paletteHexes, id: \.self) { hex in
                        let isSelected = themeService.selectedHex(for: scheme) == hex
                        Button {
                            themeService.setAccent(hex: hex, for: scheme)
                        } label: {
                            RoundedRectangle(cornerRadius: 10)
                                .fill(themeColor(hex))
                                .frame(height: 62)
                                .overlay(alignment: .topTrailing) {
                                    if isSelected {
                                        Image(systemName: "checkmark.circle.fill")
                                            .foregroundStyle(.white, .black.opacity(0.35))
                                            .padding(6)
                                    }
                                }
                                .overlay {
                                    RoundedRectangle(cornerRadius: 10)
                                        .stroke(isSelected ? Color.primary : Color.primary.opacity(0.2), lineWidth: isSelected ? 2 : 1)
                                }
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Color \(hex)")
                    }
                }
                .padding()
            }
            .navigationTitle(navTitle)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }

    private func themeColor(_ hex: String) -> Color {
        let cleaned = hex.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        guard let value = UInt64(cleaned, radix: 16) else { return .clear }
        let red = Double((value >> 16) & 0xFF) / 255.0
        let green = Double((value >> 8) & 0xFF) / 255.0
        let blue = Double(value & 0xFF) / 255.0
        return Color(.sRGB, red: red, green: green, blue: blue, opacity: 1.0)
    }
}
