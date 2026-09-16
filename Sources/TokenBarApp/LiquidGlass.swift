import SwiftUI

/// Centralized Apple Liquid Glass adoption for the menu-bar app.
///
/// The package deploys to macOS 14, so every newer API lives behind one
/// compile gate plus one runtime gate, and every call site in
/// `DashboardView`/`SettingsView` goes through this file instead of
/// scattering `#available` checks.
///
/// - Compile gate: `#if compiler(>=6.2)`. The Xcode 26 toolchain (Swift
///   6.2, macOS 26 SDK) is the first to ship `glassEffect`,
///   `GlassEffectContainer`, and the glass button styles. Older toolchains
///   (Xcode 15/16, e.g. the macOS 14 CI runner) compile only the fallback
///   branch, so `swift build`/`swift test` keep passing there.
/// - Runtime gate: `if #available(macOS 26, *)`. A binary built with the
///   new SDK still runs on macOS 14/15 through the fallback.
/// - Fallback: the exact pre-glass visuals (standard Material opacities,
///   system colors, accent-blue active chips), so macOS 14 renders what it
///   always rendered.
/// - Accessibility: custom `glassEffect` surfaces are skipped when Reduce
///   Transparency is on (opaque fallback instead); Increase Contrast
///   strengthens the fallback strokes. The system `.glass` button style
///   adapts to both on its own, so it needs no extra gating.
///
/// Deliberately glassed (functional layer only, per Apple guidance):
/// header icon actions, the source/range chip rows, and the primary
/// Details/collapse actions. Everything else stays on standard content
/// surfaces: charts, metric cards, hero totals, and explanatory text never
/// sit inside glass, and the `MenuBarExtra` window keeps its system
/// material (no whole-popover glass). No morphing `glassEffectID` is used:
/// chip selection changes tint only, never the view hierarchy, and no
/// continuous or decorative animation was added.
enum LiquidGlass {
    /// Corner radius shared by chips and primary actions.
    static let cornerRadius: CGFloat = 9
    /// Blend spacing for the chip rows; matches their `HStack` spacing.
    static let chipRowSpacing: CGFloat = 6
}

/// Blends neighboring custom glass effects in one functional row.
///
/// On SDKs without `GlassEffectContainer` (or OSes below macOS 26) this
/// renders its content directly, so the wrapped `HStack` layout is
/// identical with and without glass.
struct LiquidGlassContainer<Content: View>: View {
    var spacing: CGFloat
    @ViewBuilder var content: () -> Content

    var body: some View {
#if compiler(>=6.2)
        if #available(macOS 26, *) {
            GlassEffectContainer(spacing: spacing) {
                content()
            }
        } else {
            content()
        }
#else
        content()
#endif
    }
}

extension View {
    /// System glass style for small header icon/text actions
    /// (Refresh, Settings, Close, section-level Show less).
    ///
    /// Falls back to `.bordered`, the previous style, on older SDKs/OSes.
    @ViewBuilder
    func liquidGlassHeaderButton() -> some View {
#if compiler(>=6.2)
        if #available(macOS 26, *) {
            self.buttonStyle(.glass)
        } else {
            self.buttonStyle(.bordered)
        }
#else
        self.buttonStyle(.bordered)
#endif
    }

    /// Custom glass surface for source/range chips.
    ///
    /// Applied after layout and padding (never before), with `.interactive()`
    /// because chips are tappable, and a restrained accent tint for the
    /// active chip only. Source semantics (Codex green, OpenCode blue,
    /// Claude orange dots) are untouched; this styles the chip surface.
    @ViewBuilder
    func liquidGlassChip(isActive: Bool, reduceTransparency: Bool, increaseContrast: Bool) -> some View {
#if compiler(>=6.2)
        if #available(macOS 26, *), !reduceTransparency {
            if isActive {
                self.glassEffect(
                    .regular.tint(.accentColor).interactive(),
                    in: .rect(cornerRadius: LiquidGlass.cornerRadius)
                )
            } else {
                self.glassEffect(
                    .regular.interactive(),
                    in: .rect(cornerRadius: LiquidGlass.cornerRadius)
                )
            }
        } else {
            self.chipFallbackSurface(isActive: isActive, increaseContrast: increaseContrast)
        }
#else
        self.chipFallbackSurface(isActive: isActive, increaseContrast: increaseContrast)
#endif
    }

    /// Custom glass surface for the full-width Details/collapse actions.
    ///
    /// The primary (expand) action carries the restrained blue tint; the
    /// secondary (collapse) action uses untinted regular glass. The fallback
    /// is the previous plain surface in both cases, so macOS 14 output is
    /// pixel-identical to before.
    @ViewBuilder
    func liquidGlassAction(isPrimary: Bool, reduceTransparency: Bool, increaseContrast: Bool) -> some View {
#if compiler(>=6.2)
        if #available(macOS 26, *), !reduceTransparency {
            if isPrimary {
                self.glassEffect(
                    .regular.tint(.accentColor).interactive(),
                    in: .rect(cornerRadius: LiquidGlass.cornerRadius)
                )
            } else {
                self.glassEffect(
                    .regular.interactive(),
                    in: .rect(cornerRadius: LiquidGlass.cornerRadius)
                )
            }
        } else {
            self.actionFallbackSurface(increaseContrast: increaseContrast)
        }
#else
        self.actionFallbackSurface(increaseContrast: increaseContrast)
#endif
    }

    /// Pre-glass chip visuals, kept as the macOS 14/15 rendering.
    @ViewBuilder
    fileprivate func chipFallbackSurface(isActive: Bool, increaseContrast: Bool) -> some View {
        self
            .background(isActive ? Color.accentColor.opacity(0.9) : Color.white.opacity(0.07))
            .clipShape(RoundedRectangle(cornerRadius: LiquidGlass.cornerRadius))
            .overlay(
                RoundedRectangle(cornerRadius: LiquidGlass.cornerRadius)
                    .stroke(
                        Color.white.opacity(isActive ? 0.0 : (increaseContrast ? 0.35 : 0.14)),
                        lineWidth: 1
                    )
            )
    }

    /// Pre-glass full-width action visuals, kept as the macOS 14/15 rendering.
    @ViewBuilder
    fileprivate func actionFallbackSurface(increaseContrast: Bool) -> some View {
        self
            .background(Color.white.opacity(increaseContrast ? 0.10 : 0.07))
            .clipShape(RoundedRectangle(cornerRadius: LiquidGlass.cornerRadius))
    }
}
