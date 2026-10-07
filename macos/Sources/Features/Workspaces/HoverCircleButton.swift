import SwiftUI

/// The glyph buttons of the tab strip and sidebar (new tab, close). Muted
/// at rest, the glyph brightens while hovered and a circle filling the
/// label's frame appears behind it, marking its hit area, and darkens while
/// pressed.
struct HoverCircleButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        HoverCircleButton(configuration: configuration)
    }

    private struct HoverCircleButton: View {
        let configuration: Configuration

        @State private var hovering = false

        var body: some View {
            configuration.label
                .foregroundStyle(hovering ? .primary : .secondary)
                .background(Circle().fill(Color.primary.opacity(circleOpacity)))
                .contentShape(Circle())
                .onHover { hovering = $0 }
                .animation(.easeOut(duration: 0.1), value: circleOpacity)
        }

        private var circleOpacity: Double {
            if configuration.isPressed { return 0.2 }
            return hovering ? 0.12 : 0
        }
    }
}

/// A close button drawn as its ×, muted until hovered. It's laid out as just
/// the glyph, so the × can sit flush with an edge while its hover circle
/// extends past it.
struct HoverCloseButton: View {
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: "xmark")
                .font(.system(size: 9, weight: .semibold))
                .frame(width: Self.circleSize, height: Self.circleSize)
        }
        .buttonStyle(HoverCircleButtonStyle())
        .padding(-Self.circleOverhang)
    }

    /// The hover circle, and how far it extends past the ×.
    private static let circleSize: CGFloat = 16
    private static let circleOverhang: CGFloat = 4
}
