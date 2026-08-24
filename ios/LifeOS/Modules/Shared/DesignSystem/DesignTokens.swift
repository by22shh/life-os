// MARK: - Life OS Design System Tokens
// Source of truth: life_os_design_system.md v2.24

import SwiftUI

// MARK: - Shared Constants (Invariant §2)

/// Centralized constants referenced by invariants.
enum LifeOSConstants {
    /// Scores below this threshold show "Estimate" badge per invariant §2.
    static let lowConfidenceThreshold: Double = 0.65
}

// MARK: - Color Palette

/// Okabe-Ito recovery zone colors (color-blind safe)
/// RULE: Never use color alone to convey meaning — always pair with icon + text label.
enum LifeOSColors {

    // MARK: Recovery Zone Colors

    enum Recovery {
        /// Resolves asset catalog color with automatic Hex fallback.
        static let optimal = resolveColor("RecoveryOptimal", lightFallback: Hex.optimalLight, darkFallback: Hex.optimalDark)
        static let ready = resolveColor("RecoveryReady", lightFallback: Hex.readyLight, darkFallback: Hex.readyDark)
        static let caution = resolveColor("RecoveryCaution", lightFallback: Hex.cautionLight, darkFallback: Hex.cautionDark)
        static let critical = resolveColor("RecoveryCritical", lightFallback: Hex.criticalLight, darkFallback: Hex.criticalDark)

        /// Attempts to load an asset catalog color; falls back to adaptive Hex if unavailable.
        private static func resolveColor(_ name: String, lightFallback: Color, darkFallback: Color) -> Color {
            #if canImport(UIKit)
            if UIColor(named: name) != nil {
                return Color(name)
            }
            // Fallback: create a dynamic color that adapts to light/dark mode.
            return Color(UIColor { traits in
                traits.userInterfaceStyle == .dark
                    ? UIColor(darkFallback)
                    : UIColor(lightFallback)
            })
            #else
            return lightFallback
            #endif
        }

        /// Programmatic fallbacks (used when asset catalog not available)
        enum Hex {
            // Light mode
            static let optimalLight = Color(hex: 0x0072B2)
            static let readyLight = Color(hex: 0x009E73)
            // Spec base: #E69F00. Darkened to #9A6800 for WCAG AA ≥4.5:1 contrast on #FFF7F0 background.
            // See: life_os_design_system.md §Recovery Zone Colors, WCAG override.
            static let cautionLight = Color(hex: 0x9A6800)
            static let criticalLight = Color(hex: 0xD55E00)

            // Dark mode
            static let optimalDark = Color(hex: 0x56B4E9)
            static let readyDark = Color(hex: 0x009E73)
            static let cautionDark = Color(hex: 0xF0E442)
            static let criticalDark = Color(hex: 0xD55E00)
        }
    }

    // MARK: Surface Colors (Warm Neutrals — life_os_design_system.md §Surface Theme)

    enum Surface {
        static let background = Color("SurfaceBackground")
        static let card = Color("SurfaceCard")
        static let elevated = Color("SurfaceElevated")

        /// Programmatic fallbacks matching Warm Neutrals spec exactly.
        enum Hex {
            // Light mode
            static let backgroundLight = Color(hex: 0xFFF7F0)   // surface.background
            static let backgroundDark  = Color(hex: 0x12100E)
            static let cardLight       = Color(hex: 0xF7EEE4)   // surface.card
            static let cardDark        = Color(hex: 0x1B1713)
            static let elevatedLight   = Color(hex: 0xFFFBF7)   // surface.card_elevated
            static let elevatedDark    = Color(hex: 0x221C17)
            static let separatorLight  = Color(hex: 0xE6D8CB)   // surface.separator
            static let separatorDark   = Color(hex: 0x3A3128)

            /// Adaptive background that switches with color scheme.
            static func adaptiveBackground(_ colorScheme: ColorScheme) -> Color {
                colorScheme == .dark ? backgroundDark : backgroundLight
            }

            /// Adaptive card that switches with color scheme.
            static func adaptiveCard(_ colorScheme: ColorScheme) -> Color {
                colorScheme == .dark ? cardDark : cardLight
            }
        }
    }

    // MARK: Semantic Colors

    enum Semantic {
        static let primary: Color = {
            #if canImport(UIKit)
            return Color(UIColor { traits in
                traits.userInterfaceStyle == .dark
                    ? UIColor(hex: 0x0A84FF)
                    : UIColor(hex: 0x005DBA)
            })
            #else
            return Color(hex: 0x005DBA)
            #endif
        }()
        static let destructive = Color.red
        static let success = Color(hex: 0x009E73)
        static let warning = Color(hex: 0xE69F00)

        // Link/Interactive (from design system spec §Semantic Colors)
        static let link = Color(hex: 0x007AFF)
        static let linkDark = Color(hex: 0x0A84FF)
    }

    enum Text {
        static let primary = Color.primary
        static let secondary = Color.primary.opacity(0.78)
        static let tertiary = Color.primary.opacity(0.68)
    }
}

#if DEBUG
extension LifeOSColors.Recovery {
    static func _testResolveColor(_ name: String, lightFallback: Color, darkFallback: Color) -> Color {
        resolveColor(name, lightFallback: lightFallback, darkFallback: darkFallback)
    }
}
#endif

// MARK: - Typography

/// SF Pro typography scale with Dynamic Type support.
/// All text styles MUST support scaling via system text styles.
/// Source of truth: life_os_design_system.md §Typography
enum LifeOSTypography {
    /// Large Title — 34pt Bold (Dynamic Type: .largeTitle)
    static let largeTitle: Font = .largeTitle.weight(.bold)
    /// Title 1 — 28pt Bold (Dynamic Type: .title)
    static let title: Font = .title.weight(.bold)
    /// Title 2 — 22pt Bold (Dynamic Type: .title2)
    static let title2: Font = .title2.weight(.bold)
    /// Title 3 — 20pt Semibold (Dynamic Type: .title3)
    static let title3: Font = .title3.weight(.semibold)
    /// Headline — 17pt Semibold (Dynamic Type: .headline)
    static let headline: Font = .headline
    /// Body — 17pt Regular (Dynamic Type: .body)
    static let body: Font = .body
    /// Callout — 16pt Regular (Dynamic Type: .callout)
    static let callout: Font = .callout
    /// Subheadline — 15pt Regular (Dynamic Type: .subheadline)
    static let subheadline: Font = .subheadline
    /// Footnote — 13pt Regular (Dynamic Type: .footnote)
    static let footnote: Font = .footnote
    /// Caption — 12pt Regular (Dynamic Type: .caption)
    static let caption: Font = .caption
    /// Caption 2 — 11pt Regular (Dynamic Type: .caption2)
    static let caption2: Font = .caption2

    /// Large metric display (recovery score) — rounded large title with Dynamic Type.
    /// - Important: Call sites using this font MUST apply `.minimumScaleFactor(0.5)` and
    ///   `.lineLimit(1)` to prevent truncation at AX5 accessibility sizes.
    static let metricLarge: Font = .system(.largeTitle, design: .rounded).weight(.bold)
    /// Medium metric display — rounded title with Dynamic Type.
    /// - Important: Apply `.minimumScaleFactor(0.6)` at call sites for AX accessibility sizes.
    static let metricMedium: Font = .system(.title, design: .rounded).weight(.semibold)
}

// MARK: - Spacing (8pt Grid)

/// All spacing values are multiples of the 8pt base unit.
/// Source of truth: life_os_design_system.md §Spacing System
enum Spacing {
    /// 4pt — Exception only (icons)
    static let xxs: CGFloat = 4
    /// 8pt — Between items in a group
    static let xs: CGFloat = 8
    /// 12pt — Exception: non-8pt value for compact spacing between related elements
    static let s: CGFloat = 12
    /// 16pt — Between sections in a card
    static let m: CGFloat = 16
    /// 24pt — Between cards
    static let l: CGFloat = 24
    /// 32pt — Between screen sections
    static let xl: CGFloat = 32
    /// 40pt — Top offset from title
    static let xxl: CGFloat = 40
    /// 48pt — Bottom safe area padding
    static let xxxl: CGFloat = 48
}

// MARK: - Corner Radius

/// Corner radius values per design system spec §Corner Radius.
enum CornerRadius {
    /// 10pt — Buttons, small elements
    static let sm: CGFloat = 10
    /// 16pt — Cards
    static let md: CGFloat = 16
    /// 20pt — Modals
    static let lg: CGFloat = 20
    /// 24pt — Large cards, sheets
    static let xl: CGFloat = 24
    /// 9999pt — Fully round (avatars)
    static let full: CGFloat = 9999
}

// MARK: - Layout Constants

enum LayoutConstants {
    /// Minimum touch target size — 44×44pt (WCAG 2.2 AA)
    static let minTouchTarget: CGFloat = 44
    /// List row minimum height — 56pt
    static let listRowMinHeight: CGFloat = 56
    /// Card corner radius — 16pt (same as CornerRadius.md)
    static let cardCornerRadius: CGFloat = CornerRadius.md
    /// Content horizontal padding — 16pt
    static let contentPadding: CGFloat = 16
    /// Small corner radius — 10pt (same as CornerRadius.sm)
    static let smallCornerRadius: CGFloat = CornerRadius.sm
    /// Button corner radius — 10pt (kept separate for semantic clarity)
    static let buttonCornerRadius: CGFloat = CornerRadius.sm
    /// Icon size (standard) — 24pt
    static let iconSize: CGFloat = 24
}

// MARK: - Animation

/// Animation curves per design system spec §Animations.
enum LifeOSAnimation {
    /// Default — 0.25s ease-in-out (most transitions, per design_system.md §Animations)
    static let standard: Animation = .easeInOut(duration: 0.25)
    /// Quick — 0.2s ease-out (fast interactions)
    static let quick: Animation = .easeOut(duration: 0.2)
    /// Spring — response 0.5, damping 0.8 (bouncy cards)
    static let spring: Animation = .spring(response: 0.5, dampingFraction: 0.8)
    /// Slow — 0.5s ease-in-out (modals)
    static let slow: Animation = .easeInOut(duration: 0.5)
    /// Sheet presentation — 0.35s spring with 0.86 damping (design_system.md §Animations)
    static let sheet: Animation = .spring(duration: 0.35, bounce: 0.14)
}

// MARK: - Color Hex Extension

extension Color {
    init(hex: UInt, alpha: Double = 1.0) {
        self.init(
            .sRGB,
            red: Double((hex >> 16) & 0xFF) / 255.0,
            green: Double((hex >> 8) & 0xFF) / 255.0,
            blue: Double(hex & 0xFF) / 255.0,
            opacity: alpha
        )
    }
}

#if canImport(UIKit)
extension UIColor {
    convenience init(hex: UInt, alpha: CGFloat = 1.0) {
        self.init(
            red: CGFloat((hex >> 16) & 0xFF) / 255.0,
            green: CGFloat((hex >> 8) & 0xFF) / 255.0,
            blue: CGFloat(hex & 0xFF) / 255.0,
            alpha: alpha
        )
    }
}
#endif
