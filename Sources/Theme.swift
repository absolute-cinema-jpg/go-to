import AppKit
import SwiftUI

/// Colour palette modelled on DaVinci Resolve: graphite panels, etched dividers, a muted phosphor-green accent.
enum Theme {
    static func rgb(_ hex: UInt32, _ alpha: CGFloat = 1) -> NSColor {
        NSColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
                green: CGFloat((hex >> 8) & 0xFF) / 255,
                blue: CGFloat(hex & 0xFF) / 255,
                alpha: alpha)
    }

    static let panelBG = rgb(0x1C1C1F)
    static let headerTop = rgb(0x2A2A2E)
    static let headerBottom = rgb(0x232326)
    static let footerBG = rgb(0x18181A)
    static let cardBG = rgb(0x222225)
    static let fieldBG = rgb(0x141416)
    static let rowSelected = rgb(0x2E2E33)
    static let borderOuter = rgb(0x3A3A3F)
    static let border = rgb(0x323236)
    static let etchDark = rgb(0x0D0D0F)
    static let etchLight = rgb(0x2B2B2F)
    static let keycapBG = rgb(0x26262A)
    static let keycapBorder = rgb(0x37373C)

    static let textPrimary = rgb(0xE6E6E9)
    static let textBright = rgb(0xFAFAFC)
    static let textSecondary = rgb(0x8B8B92)
    static let textTertiary = rgb(0x5E5E65)

    static let accent = rgb(0x5CC98A)
    /// How opaque the search panel is over the blurred desktop behind it.
    static let panelOpacity: CGFloat = 0.82
    static let danger = rgb(0xE5534B)

    static func caps(_ s: String, size: CGFloat, color: NSColor, weight: NSFont.Weight = .semibold, kern: CGFloat = 1.2) -> NSAttributedString {
        NSAttributedString(string: s.uppercased(), attributes: [
            .font: NSFont.systemFont(ofSize: size, weight: weight),
            .foregroundColor: color,
            .kern: kern,
        ])
    }
}

extension Color {
    static let gtPanel = Color(nsColor: Theme.panelBG)
    static let gtHeader = Color(nsColor: Theme.headerBottom)
    static let gtCard = Color(nsColor: Theme.cardBG)
    static let gtField = Color(nsColor: Theme.fieldBG)
    static let gtBorder = Color(nsColor: Theme.border)
    static let gtEtchDark = Color(nsColor: Theme.etchDark)
    static let gtEtchLight = Color(nsColor: Theme.etchLight)
    static let gtText = Color(nsColor: Theme.textPrimary)
    static let gtText2 = Color(nsColor: Theme.textSecondary)
    static let gtText3 = Color(nsColor: Theme.textTertiary)
    static let gtAccent = Color(nsColor: Theme.accent)
    static let gtDanger = Color(nsColor: Theme.danger)
    static let gtKeycap = Color(nsColor: Theme.keycapBG)
}
