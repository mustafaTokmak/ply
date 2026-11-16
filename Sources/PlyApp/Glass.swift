import SwiftUI

// Layout only: Liquid Glass surfaces on macOS 26, regular materials before that.
// `#if compiler` keeps the package building with Xcode 16 (CI), which has no glass APIs.

enum Brand {
    /// The one solid accent: switches, prominent buttons, selection.
    static let accent = Color(red: 0.72, green: 0.24, blue: 0.95)
}

extension View {
    /// A rounded glass card, optionally tinted.
    @ViewBuilder
    func glassCard(cornerRadius: CGFloat = 16, tint: Color? = nil) -> some View {
        #if compiler(>=6.2)
        if #available(macOS 26.0, *) {
            self.glassEffect(tint.map { Glass.clear.tint($0.opacity(0.25)) } ?? .clear, in: .rect(cornerRadius: cornerRadius))
        } else {
            materialCard(cornerRadius: cornerRadius, tint: tint)
        }
        #else
        materialCard(cornerRadius: cornerRadius, tint: tint)
        #endif
    }

    private func materialCard(cornerRadius: CGFloat, tint: Color?) -> some View {
        background(
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .fill(.regularMaterial)
                .overlay(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous).fill((tint ?? .clear).opacity(0.10)))
                .overlay(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous).strokeBorder(Color.primary.opacity(0.06)))
        )
    }

    /// Groups glass shapes so they blend and morph together.
    @ViewBuilder
    func glassGroup(spacing: CGFloat = 12) -> some View {
        #if compiler(>=6.2)
        if #available(macOS 26.0, *) {
            GlassEffectContainer(spacing: spacing) { self }
        } else {
            self
        }
        #else
        self
        #endif
    }
}
