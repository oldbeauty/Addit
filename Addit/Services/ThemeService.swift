import SwiftUI

@Observable
final class ThemeService {
    static let paletteHexes = [
        "DAB894",
        "FFCAAF",
        "F1FFC4",
        "C6E2E9",
        "4D7298",
        "F1E9DB",
        "36413E",
        "56494C",
        "C2D3CD"
    ]

    private let selectedHexKey = "selectedAccentHex"
    private let fallbackHex = "4D7298"

    var selectedHex: String {
        didSet {
            UserDefaults.standard.set(selectedHex, forKey: selectedHexKey)
        }
    }

    var accentColor: Color {
        Color(hex: selectedHex) ?? Color(hex: fallbackHex) ?? .blue
    }

    init() {
        let stored = UserDefaults.standard.string(forKey: selectedHexKey)?.uppercased()
        if let stored, Self.paletteHexes.contains(stored) {
            selectedHex = stored
        } else {
            selectedHex = fallbackHex
        }
    }

    func setAccent(hex: String) {
        let normalized = hex.uppercased()
        guard Self.paletteHexes.contains(normalized) else { return }
        selectedHex = normalized
    }
}

private extension Color {
    init?(hex: String) {
        let raw = hex.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        let cleaned = raw.hasPrefix("#") ? String(raw.dropFirst()) : raw
        guard cleaned.count == 6, let value = UInt64(cleaned, radix: 16) else { return nil }
        let red = Double((value >> 16) & 0xFF) / 255.0
        let green = Double((value >> 8) & 0xFF) / 255.0
        let blue = Double(value & 0xFF) / 255.0
        self.init(.sRGB, red: red, green: green, blue: blue, opacity: 1.0)
    }
}
