import SwiftUI

struct SettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(ThemeService.self) private var themeService
    @State private var showColorPicker = false

    var body: some View {
        NavigationStack {
            Form {
                Button {
                    showColorPicker = true
                } label: {
                    HStack {
                        Text("Change Default Color")
                        Spacer()
                        RoundedRectangle(cornerRadius: 6)
                            .fill(themeService.accentColor)
                            .frame(width: 22, height: 22)
                            .overlay {
                                RoundedRectangle(cornerRadius: 6)
                                    .stroke(Color.primary.opacity(0.2), lineWidth: 1)
                            }
                    }
                }
                .buttonStyle(.plain)
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
            .sheet(isPresented: $showColorPicker) {
                AccentColorPickerSheet()
            }
        }
    }
}

private struct AccentColorPickerSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(ThemeService.self) private var themeService

    private let columns = [GridItem(.adaptive(minimum: 62), spacing: 14)]

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVGrid(columns: columns, spacing: 14) {
                    ForEach(ThemeService.paletteHexes, id: \.self) { hex in
                        let isSelected = themeService.selectedHex == hex
                        Button {
                            themeService.setAccent(hex: hex)
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
            .navigationTitle("Default Color")
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
