#if canImport(SwiftUI)
import SwiftUI

public enum MinutesTheme {
    public static let bg = Color(red: 11/255, green: 13/255, blue: 19/255) // #0b0d13
    public static let card = Color(red: 19/255, green: 23/255, blue: 34/255) // #131722
    public static let cardHover = Color(red: 26/255, green: 32/255, blue: 48/255) // #1a2030
    public static let border = Color(red: 35/255, green: 42/255, blue: 61/255) // #232a3d
    public static let primary = Color(red: 99/255, green: 102/255, blue: 241/255) // #6366f1
    public static let primaryHover = Color(red: 79/255, green: 70/255, blue: 229/255) // #4f46e5
    public static let emerald = Color(red: 16/255, green: 185/255, blue: 129/255) // #10b981
    public static let emeraldBg = Color(red: 16/255, green: 185/255, blue: 129/255, opacity: 0.12)
    public static let purple = Color(red: 168/255, green: 85/255, blue: 247/255) // #a855f7
    public static let blue = Color(red: 59/255, green: 130/255, blue: 246/255) // #3b82f6
    public static let text = Color(red: 241/255, green: 245/255, blue: 249/255) // #f1f5f9
    public static let muted = Color(red: 148/255, green: 163/255, blue: 184/255) // #94a3b8
}

public struct CardModifier: ViewModifier {
    public init() {}
    public func body(content: Content) -> some View {
        content
            .background(MinutesTheme.card)
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .stroke(MinutesTheme.border, lineWidth: 1)
            )
    }
}

public extension View {
    func minutesCard() -> some View {
        modifier(CardModifier())
    }
}
#endif
