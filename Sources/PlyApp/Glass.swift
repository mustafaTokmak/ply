import SwiftUI

// Layout only: Liquid Glass surfaces on macOS 26, regular materials before that.
// `#if compiler` keeps the package building with Xcode 16 (CI), which has no glass APIs.

enum Brand {
    /// The rainbow of the app icon.
    static let rainbow = LinearGradient(
        colors: [Color(red: 1.0, green: 0.56, blue: 0.16), Color(red: 0.98, green: 0.25, blue: 0.55),
                 Color(red: 0.72, green: 0.24, blue: 0.95), Color(red: 0.24, green: 0.48, blue: 1.0)],
        startPoint: .leading, endPoint: .trailing)
}

extension View {
    /// A rounded glass card, optionally tinted.
    @ViewBuilder
    func glassCard(cornerRadius: CGFloat = 16, tint: Color? = nil) -> some View {
        #if compiler(>=6.2)
        if #available(macOS 26.0, *) {
            self.glassEffect(tint.map { Glass.regular.tint($0.opacity(0.22)) } ?? .regular, in: .rect(cornerRadius: cornerRadius))
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

/// Soft rainbow light behind the menu, so the glass has something to refract.
struct MenuBackdrop: View {
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        ZStack {
            Circle().fill(Color(red: 1.0, green: 0.56, blue: 0.16)).frame(width: 220).offset(x: -110, y: -40)
            Circle().fill(Color(red: 0.98, green: 0.25, blue: 0.55)).frame(width: 200).offset(x: 90, y: 10)
            Circle().fill(Color(red: 0.72, green: 0.24, blue: 0.95)).frame(width: 220).offset(x: -40, y: 170)
            Circle().fill(Color(red: 0.24, green: 0.48, blue: 1.0)).frame(width: 240).offset(x: 120, y: 260)
        }
        .blur(radius: 70)
        .opacity(scheme == .dark ? 0.45 : 0.30)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .allowsHitTesting(false)
    }
}
