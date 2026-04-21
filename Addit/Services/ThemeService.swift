import SwiftUI

enum AppearanceMode: String, CaseIterable {
    case system
    case light
    case dark

    var label: String {
        switch self {
        case .system: "System"
        case .light: "Light"
        case .dark: "Dark"
        }
    }

    var colorScheme: ColorScheme? {
        switch self {
        case .system: nil
        case .light: .light
        case .dark: .dark
        }
    }
}

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
        "C2D3CD",
        "000000",
        "FFFFFF"
    ]

    private let selectedHexKey = "selectedAccentHex"
    private let appearanceModeKey = "appearanceMode"
    private let fallbackHex = "4D7298"

    var selectedHex: String {
        didSet {
            UserDefaults.standard.set(selectedHex, forKey: selectedHexKey)
        }
    }

    var appearanceMode: AppearanceMode {
        didSet {
            UserDefaults.standard.set(appearanceMode.rawValue, forKey: appearanceModeKey)
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

        if let modeRaw = UserDefaults.standard.string(forKey: appearanceModeKey),
           let mode = AppearanceMode(rawValue: modeRaw) {
            appearanceMode = mode
        } else {
            appearanceMode = .system
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
