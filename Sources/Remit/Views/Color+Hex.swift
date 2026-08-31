import SwiftUI

extension Color {
    /// Parses a "#RRGGBB" string (as stored on RemitProject.colorHex). Falls back to gray on
    /// any malformed input rather than crashing.
    init(hex: String) {
        var hexString = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        hexString = hexString.replacingOccurrences(of: "#", with: "")

        var rgbValue: UInt64 = 0
        guard hexString.count == 6, Scanner(string: hexString).scanHexInt64(&rgbValue) else {
            self = .gray
            return
        }

        let r = Double((rgbValue & 0xFF0000) >> 16) / 255
        let g = Double((rgbValue & 0x00FF00) >> 8) / 255
        let b = Double(rgbValue & 0x0000FF) / 255
        self.init(red: r, green: g, blue: b)
    }
}
