import AppKit
import SwiftUI

/// Colour palette light parchment panels with Jet Black text, Sapphire accent and Blue Grey highlights.
enum Theme {
    static func rgb(_ hex: UInt32, _ alpha: CGFloat = 1) -> NSColor {
        NSColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
                green: CGFloat((hex >> 8) & 0xFF) / 255,
                blue: CGFloat(hex & 0xFF) / 255,
                alpha: alpha)
    }

    static let panelBG = rgb(0xF8F5F1)
    static let headerTop = rgb(0xFFFFFF)
    static let headerBottom = rgb(0xF3EFEA)
    static let footerBG = rgb(0xF0ECE6)
    static let cardBG = rgb(0xFFFFFF)
    static let fieldBG = rgb(0xFFFFFF)
    static let rowSelected = rgb(0xE4EAF5)
    static let borderOuter = rgb(0xD5D9E0)
    static let border = rgb(0xDDDFE4)
    static let etchDark = rgb(0xE2DED8)
    static let etchLight = rgb(0xFFFFFF)
    static let keycapBG = rgb(0xFFFFFF)
    static let keycapBorder = rgb(0xD5D9E0)

    static let textPrimary = rgb(0x1C2826)
    static let textBright = rgb(0x1C2826)
    static let textSecondary = rgb(0x5A6B72)
    static let textTertiary = rgb(0x8C9AA3)

    /// Sapphire.
    static let accent = rgb(0x4059AD)
    /// Blue Grey, for soft highlights.
    static let accentSoft = rgb(0x6B9AC4)
    /// How opaque the search panel is over the blurred desktop behind it.
    static let panelOpacity: CGFloat = 0.9
    static let danger = rgb(0xD04A3F)

    /// Dark "terminal" palette for everything to do with shell commands, set against the light theme.
    enum Term {
        static let bg = rgb(0x17191E)
        static let card = rgb(0x1E2127)
        static let row = rgb(0x1F2228)
        static let rowSelected = rgb(0x2B2F37)
        static let field = rgb(0x111317)
        static let border = rgb(0x30343D)
        static let text = rgb(0xE6E8EB)
        static let text2 = rgb(0x9BA3AE)
        static let text3 = rgb(0x68707B)
        /// Terminal green, for the "$" prompt, highlights and focus.
        static let prompt = rgb(0x7EE787)
    }

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

    static let termBG = Color(nsColor: Theme.Term.bg)
    static let termCard = Color(nsColor: Theme.Term.card)
    static let termField = Color(nsColor: Theme.Term.field)
    static let termBorder = Color(nsColor: Theme.Term.border)
    static let termText = Color(nsColor: Theme.Term.text)
    static let termText2 = Color(nsColor: Theme.Term.text2)
    static let termText3 = Color(nsColor: Theme.Term.text3)
    static let termPrompt = Color(nsColor: Theme.Term.prompt)
}
