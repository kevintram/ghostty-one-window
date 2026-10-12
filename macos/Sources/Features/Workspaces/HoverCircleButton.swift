import SwiftUI

/// The glyph buttons of the tab strip and sidebar (new tab, close). Muted
/// at rest, the glyph brightens while hovered and a circle filling the
/// label's frame appears behind it, marking its hit area, and darkens while
/// pressed. Disabled, the glyph is faint and doesn't respond to hover.
struct HoverCircleButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        HoverCircleButton(configuration: configuration)
    }

    private struct HoverCircleButton: View {
        let configuration: Configuration

        @Environment(\.isEnabled) private var isEnabled
        @State private var hovering = false

        var body: some View {
            configuration.label
                .foregroundStyle(!isEnabled ? .tertiary : hovering ? .primary : .secondary)
                .background(Circle().fill(Color.primary.opacity(circleOpacity)))
                .contentShape(Circle())
                .onHover { hovering = $0 }
                .animation(.easeOut(duration: 0.1), value: circleOpacity)
        }

        private var circleOpacity: Double {
            guard isEnabled else { return 0 }
            if configuration.isPressed { return 0.2 }
            return hovering ? 0.12 : 0
        }
    }
}

/// A close button drawn as its ×, muted until hovered. It's laid out as just
/// the glyph, so the × can sit flush with an edge while its hover circle
/// extends past it.
struct HoverCloseButton: View {
    /// The ×'s point size and its hover circle's diameter.
    let glyphSize: CGFloat
    let circleSize: CGFloat
    let action: () -> Void

    init(glyphSize: CGFloat = 9, circleSize: CGFloat = 16, action: @escaping () -> Void) {
        self.glyphSize = glyphSize
        self.circleSize = circleSize
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            Image(systemName: "xmark")
                .font(.system(size: glyphSize, weight: .semibold))
                .frame(width: circleSize, height: circleSize)
        }
        .buttonStyle(HoverCircleButtonStyle())
        .padding(-circleOverhang)
    }

    /// How far the hover circle extends past the ×.
    private var circleOverhang: CGFloat { circleSize / 4 }
}
