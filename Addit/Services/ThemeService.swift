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

    /// Old single-color UserDefaults key, kept around purely for one-shot
    /// migration to the per-scheme keys below. Reads on first launch
    /// after the upgrade and seeds both new keys so existing users don't
    /// lose their selection.
    private let legacyHexKey = "selectedAccentHex"
    private let lightHexKey = "selectedAccentHexLight"
    private let darkHexKey = "selectedAccentHexDark"
    private let appearanceModeKey = "appearanceMode"
    /// Static so the migration helper inside `init` can read it before
    /// the instance's stored properties are fully initialized.
    private static let fallbackHex = "4D7298"

    /// Accent color the user picked while light mode is the effective
    /// appearance. Persists to UserDefaults on every change.
    var lightHex: String {
        didSet {
            UserDefaults.standard.set(lightHex, forKey: lightHexKey)
        }
    }

    /// Accent color the user picked while dark mode is the effective
    /// appearance. Persists separately from `lightHex`.
    var darkHex: String {
        didSet {
            UserDefaults.standard.set(darkHex, forKey: darkHexKey)
        }
    }

    /// Which color scheme is currently displayed. Updated by the root
    /// view (`ContentView`) whenever SwiftUI's `\.colorScheme`
    /// environment changes — that's the only signal that respects both
    /// the system setting AND any in-app `.preferredColorScheme`
    /// override the user has chosen via Settings.
    ///
    /// The accent-color computed property reads this to decide which
    /// per-scheme hex to return, so every call site that already says
    /// `themeService.accentColor` keeps working unchanged.
    var currentScheme: ColorScheme = .light

    var appearanceMode: AppearanceMode {
        didSet {
            UserDefaults.standard.set(appearanceMode.rawValue, forKey: appearanceModeKey)
        }
    }

    /// The hex string for whichever scheme is currently displayed.
    /// Useful for the picker UI ("which swatch is highlighted right
    /// now?") without forcing callers to know which scheme is in
    /// effect.
    var selectedHex: String {
        currentScheme == .dark ? darkHex : lightHex
    }

    var accentColor: Color {
        Color(hex: selectedHex) ?? Color(hex: Self.fallbackHex) ?? .blue
    }

    init() {
        let storedLight = UserDefaults.standard.string(forKey: lightHexKey)?.uppercased()
        let storedDark = UserDefaults.standard.string(forKey: darkHexKey)?.uppercased()

        // Migration: if neither per-scheme key has ever been written
        // but the legacy single-color key is present, seed both new
        // keys with the legacy value. After this runs once the legacy
        // key is harmless — we never read it again.
        let legacy = UserDefaults.standard.string(forKey: legacyHexKey)?.uppercased()

        func resolve(_ value: String?) -> String {
            if let value, Self.paletteHexes.contains(value) { return value }
            return Self.fallbackHex
        }

        if storedLight == nil && storedDark == nil, let legacy {
            let migrated = resolve(legacy)
            lightHex = migrated
            darkHex = migrated
        } else {
            lightHex = resolve(storedLight)
            darkHex = resolve(storedDark)
        }

        if let modeRaw = UserDefaults.standard.string(forKey: appearanceModeKey),
           let mode = AppearanceMode(rawValue: modeRaw) {
            appearanceMode = mode
        } else {
            appearanceMode = .system
        }
    }

    /// Set the accent color for a specific scheme. Callers in the
    /// Settings UI use this directly so the picker can edit one
    /// scheme's color without affecting the other.
    func setAccent(hex: String, for scheme: ColorScheme) {
        let normalized = hex.uppercased()
        guard Self.paletteHexes.contains(normalized) else { return }
        switch scheme {
        case .dark: darkHex = normalized
        default:    lightHex = normalized
        }
    }

    /// Read the stored hex for a specific scheme. Settings UI reads
    /// this to draw the per-row swatch and the highlighted-checkmark
    /// state inside the picker.
    func selectedHex(for scheme: ColorScheme) -> String {
        scheme == .dark ? darkHex : lightHex
    }

    /// Resolve the SwiftUI `Color` for a specific scheme. Used by
    /// per-row swatches in Settings so the user sees both colors at a
    /// glance regardless of which mode is currently active.
    func accentColor(for scheme: ColorScheme) -> Color {
        Color(hex: selectedHex(for: scheme)) ?? Color(hex: Self.fallbackHex) ?? .blue
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
