#if canImport(SwiftUI)
import SwiftUI

/// Adaptive system colors keep meeting content legible in light, dark and increased contrast.
public enum MinutesTheme {
    #if os(macOS)
    public static let bg = Color(nsColor: .windowBackgroundColor)
    public static let document = Color(nsColor: .textBackgroundColor)
    public static let card = Color(nsColor: .controlBackgroundColor)
    public static let cardHover = Color(nsColor: .quaternaryLabelColor).opacity(0.3)
    #else
    public static let bg = Color(uiColor: .systemGroupedBackground)
    public static let document = Color(uiColor: .systemBackground)
    public static let card = Color(uiColor: .secondarySystemGroupedBackground)
    public static let cardHover = Color(uiColor: .tertiarySystemFill)
    #endif
    public static let border = Color.primary.opacity(0.09)
    public static let primary = Color.accentColor
    public static let primaryHover = Color.accentColor
    public static let emerald = Color.green
    public static let emeraldBg = Color.green.opacity(0.10)
    public static let purple = Color.secondary
    public static let blue = Color.blue
    public static let text = Color.primary
    public static let muted = Color.secondary
}

public struct CardModifier: ViewModifier {
    public init() {}
    public func body(content: Content) -> some View {
        content.background(MinutesTheme.card, in: RoundedRectangle(cornerRadius: 16))
            .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(MinutesTheme.border))
    }
}

/// Glass belongs to navigation and controls. Transcript and note surfaces stay opaque.
private struct MinutesGlassModifier: ViewModifier {
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    func body(content: Content) -> some View {
        if reduceTransparency {
            content.background(MinutesTheme.card, in: RoundedRectangle(cornerRadius: 20))
                .overlay(RoundedRectangle(cornerRadius: 20).strokeBorder(MinutesTheme.border))
        } else if #available(macOS 26, iOS 26, *) {
            content.background(.regularMaterial, in: RoundedRectangle(cornerRadius: 20))
                .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 20))
                .overlay(RoundedRectangle(cornerRadius: 20).strokeBorder(Color.primary.opacity(0.14)))
        } else {
            content.background(.regularMaterial, in: RoundedRectangle(cornerRadius: 20))
        }
    }
}
/// Native optical material for a deliberately shaped control or navigation surface.
/// Content surfaces continue to use the opaque document color.
private struct MinutesControlGlass<S: InsettableShape>: ViewModifier {
    let shape: S
    let interactive: Bool
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    func body(content: Content) -> some View {
        if reduceTransparency {
            content.background(MinutesTheme.card, in: shape)
                .overlay(shape.strokeBorder(MinutesTheme.border))
        } else if #available(macOS 26, iOS 26, *) {
            // Keep a real material floor and quiet edge even when the window
            // is inactive and the platform attenuates its optical glass effect.
            content.background(.ultraThinMaterial, in: shape)
                .glassEffect(.regular.interactive(interactive), in: shape)
                .overlay(shape.strokeBorder(Color.primary.opacity(0.16)))
        } else {
            content.background(.regularMaterial, in: shape)
                .overlay(shape.strokeBorder(MinutesTheme.border))
        }
    }
}
public extension View {
    func minutesCard() -> some View { modifier(CardModifier()) }
    func minutesGlass() -> some View { modifier(MinutesGlassModifier()) }
    func minutesControlGlass<S: InsettableShape>(in shape: S, interactive: Bool = false) -> some View {
        modifier(MinutesControlGlass(shape: shape, interactive: interactive))
    }
}
#endif
