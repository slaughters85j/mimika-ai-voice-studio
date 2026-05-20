//
//  Theme.swift
//  pocket-tts-macos
//
//  Exact-match design tokens from the Electron app's tailwind.config.js.
//  Anything color-related anywhere in the app references one of these
//  constants — never a raw hex literal.

import SwiftUI

// MARK: - Theme namespace
// Statics on an empty enum: no instances, callable from any actor context.

nonisolated enum Theme {

    // MARK: Colors (verbatim from tailwind.config.js)

    /// `#1A1A2E` — Page background.
    static let bgPrimary    = Color(red: 0x1A / 255, green: 0x1A / 255, blue: 0x2E / 255)
    /// `#16213E` — Card / panel surface.
    static let bgSecondary  = Color(red: 0x16 / 255, green: 0x21 / 255, blue: 0x3E / 255)
    /// `#0F3460` — Input-field background.
    static let bgTertiary   = Color(red: 0x0F / 255, green: 0x34 / 255, blue: 0x60 / 255)
    /// `#2A2A4A` — Borders, dividers, slider track.
    static let borderColor  = Color(red: 0x2A / 255, green: 0x2A / 255, blue: 0x4A / 255)
    /// `#E8E8E8` — Primary text.
    static let textPrimary  = Color(red: 0xE8 / 255, green: 0xE8 / 255, blue: 0xE8 / 255)
    /// `#A0A0A0` — Secondary / disabled text.
    static let textSecondary = Color(red: 0xA0 / 255, green: 0xA0 / 255, blue: 0xA0 / 255)
    /// `#FF6B35` — Primary action / brand accent (orange).
    static let accent       = Color(red: 0xFF / 255, green: 0x6B / 255, blue: 0x35 / 255)
    /// `#FF8C5A` — Accent hover state.
    static let accentHover  = Color(red: 0xFF / 255, green: 0x8C / 255, blue: 0x5A / 255)

    // Secondary semantic colors used in History badges (Electron uses tailwind
    // utility classes like `bg-blue-500/20`, `text-blue-400`, etc.).
    static let badgeSingleBG = Color.blue.opacity(0.20)
    static let badgeSingleFG = Color(red: 0.4, green: 0.6, blue: 1.0)        // ~tailwind blue-400
    static let badgeMultiBG  = Color.purple.opacity(0.20)
    static let badgeMultiFG  = Color(red: 0.75, green: 0.55, blue: 1.0)      // ~tailwind purple-400

    static let successFG = Color(red: 0.3, green: 0.85, blue: 0.4)            // tailwind green-500-ish
    static let errorFG   = Color(red: 0.95, green: 0.35, blue: 0.35)
    static let warningFG = Color(red: 0.95, green: 0.75, blue: 0.30)          // amber-400-ish

    // MARK: Speaker palette
    // Eight visually-distinct hues for the Multi-Talk speaker-colors
    // toggle. Tuned for readability on the dark Theme.bgPrimary +
    // Theme.bgTertiary surfaces. Indexed by speaker position (cycles
    // if more than 8 speakers — unlikely in practice).
    static let speakerColors: [Color] = [
        Color(red: 1.00, green: 0.55, blue: 0.45),   // coral
        Color(red: 1.00, green: 0.78, blue: 0.30),   // amber
        Color(red: 0.60, green: 0.90, blue: 0.45),   // green
        Color(red: 0.40, green: 0.85, blue: 0.90),   // cyan
        Color(red: 0.55, green: 0.70, blue: 1.00),   // periwinkle
        Color(red: 0.85, green: 0.60, blue: 1.00),   // lavender
        Color(red: 1.00, green: 0.55, blue: 0.85),   // pink
        Color(red: 1.00, green: 0.92, blue: 0.55),   // butter
    ]

    /// Cyclical palette lookup. Safe to call with any non-negative index.
    static func speakerColor(at index: Int) -> Color {
        speakerColors[(index % speakerColors.count + speakerColors.count) % speakerColors.count]
    }

    // MARK: Radii (Tailwind defaults)
    static let radiusSmall: CGFloat = 4    // rounded
    static let radius:      CGFloat = 8    // rounded-lg (cards, panels, inputs)
    static let radiusLarge: CGFloat = 12   // rounded-xl (modals)
    static let radiusFull:  CGFloat = 9_999  // rounded-full (pills, circular buttons)

    // MARK: Spacing (Tailwind 4pt scale, the ones we actually use)
    static let space1: CGFloat = 4
    static let space2: CGFloat = 8
    static let space3: CGFloat = 12
    static let space4: CGFloat = 16
    static let space6: CGFloat = 24

    // MARK: Window (Electron BrowserWindow defaults)
    static let windowDefaultWidth:  CGFloat = 1200
    static let windowDefaultHeight: CGFloat = 1270
    static let windowMinWidth:      CGFloat = 600
    static let windowMinHeight:     CGFloat = 500

    // MARK: Layout
    /// 380pt sidebar in Single Voice and Multi-Talk tabs (matches Electron's `w-[380px]`).
    static let sidebarWidth: CGFloat = 380
    /// Top drag region — overlap with the system title bar.
    static let dragRegionHeight: CGFloat = 56
    /// TextEditor min height for both single-voice and multi-talk script editors.
    static let textEditorMinHeight: CGFloat = 900

    // MARK: Type scale (Tailwind classes → SwiftUI fonts)
    static let fontXS = Font.system(size: 12, weight: .regular)
    static let fontSM = Font.system(size: 14, weight: .regular)
    static let fontSMBold = Font.system(size: 14, weight: .semibold)
    static let fontBase = Font.system(size: 16, weight: .regular)
    static let fontLG = Font.system(size: 18, weight: .semibold)
    static let font2XL = Font.system(size: 24, weight: .bold)
}

// MARK: - View modifiers for common Electron patterns

extension View {
    /// Apply the `bg-bg-secondary rounded-lg p-4` panel treatment.
    func themePanel(padding: CGFloat = Theme.space4) -> some View {
        self
            .padding(padding)
            .background(Theme.bgSecondary)
            .clipShape(RoundedRectangle(cornerRadius: Theme.radius))
    }

    /// Apply the `bg-bg-tertiary rounded-lg border` input field treatment.
    func themeInputField() -> some View {
        self
            .background(Theme.bgTertiary)
            .overlay(
                RoundedRectangle(cornerRadius: Theme.radius)
                    .stroke(Theme.borderColor, lineWidth: 1)
            )
            .clipShape(RoundedRectangle(cornerRadius: Theme.radius))
    }
}
