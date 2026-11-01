import Foundation

/// Opaque theme selection colors: black or white always reaches at least 4.5:1
/// against an sRGB background. Secondary selected text uses the same foreground.
enum ThemeContrast {
    struct RGB: Equatable {
        let red: Double
        let green: Double
        let blue: Double
        var luminance: Double {
            func linear(_ c: Double) -> Double { c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4) }
            return 0.2126 * linear(red) + 0.7152 * linear(green) + 0.0722 * linear(blue)
        }
    }

    static func rgb(hex: String) -> RGB {
        let raw = hex.hasPrefix("#") ? String(hex.dropFirst()) : hex
        let value = raw.count == 6 ? UInt32(raw, radix: 16) ?? 0x7C6FF0 : 0x7C6FF0
        return RGB(red: Double((value >> 16) & 255) / 255,
                   green: Double((value >> 8) & 255) / 255, blue: Double(value & 255) / 255)
    }

    static func usesDarkForeground(hex: String) -> Bool {
        let luminance = rgb(hex: hex).luminance
        return (luminance + 0.05) / 0.05 >= 1.05 / (luminance + 0.05)
    }

    static func selectedContrast(hex: String) -> Double {
        let luminance = rgb(hex: hex).luminance
        return usesDarkForeground(hex: hex) ? (luminance + 0.05) / 0.05 : 1.05 / (luminance + 0.05)
    }
}
