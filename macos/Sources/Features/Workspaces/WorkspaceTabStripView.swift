import Combine
import SwiftUI

/// The tab strip above the terminal. It replaces the native tab bar, which
/// would show the tabs of every workspace since they share one tab group.
///
/// The tabs are still native: each is a window in the logical window's
/// `NSWindowTabGroup`. This only draws the selected workspace's tabs and
/// forwards actions.
struct WorkspaceTabStripView: View {
    @ObservedObject var membership: WorkspaceMembership

    var body: some View {
        if let group = membership.group {
            TabStrip(group: group)
        } else {
            Color.clear
        }
    }
}

private struct TabStrip: View {
    @ObservedObject var group: WorkspaceWindowGroup

    var body: some View {
        HStack(spacing: 4) {
            ForEach(group.tabs) { tab in
                TabButton(tab: tab) {
                    if let window = tab.window { group.selectTab(window) }
                }
            }

            Button {
                NSApp.sendAction(#selector(TerminalController.newTab(_:)), to: nil, from: nil)
            } label: {
                Image(systemName: "plus")
                    .frame(width: 24, height: 24)
            }
            .buttonStyle(.borderless)
            .help("New Tab")
        }
        // Match the vertical inset: 24pt tabs centered in the strip's height.
        .padding(.horizontal, (WorkspaceWindowGroup.tabStripHeight - 24) / 2)
        .frame(height: WorkspaceWindowGroup.tabStripHeight)
    }
}

private struct TabButton: View {
    let tab: WorkspaceWindowGroup.Tab
    let select: () -> Void

    @State private var title: String
    @State private var hovering = false
    @ObservedObject private var commandKey = CommandKeyState.shared

    init(tab: WorkspaceWindowGroup.Tab, select: @escaping () -> Void) {
        self.tab = tab
        self.select = select
        _title = State(initialValue: tab.window?.title ?? "")
    }

    var body: some View {
        // The shortcut and close button get equal fixed-width slots, shown
        // or hidden in place, so the title stays centered and never shifts.
        // Each sits flush with its outer edge so both are inset equally.
        HStack(spacing: 4) {
            Text(tab.shortcut ?? "")
                .foregroundStyle(.secondary)
                .frame(width: Self.sideWidth, alignment: .leading)
                .opacity(commandKey.isPressed ? 1 : 0)
                .animation(.easeOut(duration: 0.12), value: commandKey.isPressed)

            Text(title)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: .infinity)

            Button {
                (tab.window?.windowController as? TerminalController)?.closeTab(nil)
            } label: {
                // Sized to the glyph so it sits flush with the edge, with a
                // larger hit area around it.
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .semibold))
                    .padding(4)
                    .contentShape(Rectangle())
                    .padding(-4)
            }
            .buttonStyle(.borderless)
            .frame(width: Self.sideWidth, alignment: .trailing)
            .opacity(hovering ? 1 : 0)
            .allowsHitTesting(hovering)
            .help("Close Tab")
        }
        .font(.system(size: 12))
        .foregroundStyle(tab.isSelected ? .primary : .secondary)
        .padding(.horizontal, 6)
        .frame(height: 24)
        .frame(maxWidth: .infinity)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(Color.primary.opacity(backgroundOpacity))
        )
        .animation(.easeOut(duration: 0.12), value: backgroundOpacity)
        .contentShape(Rectangle())
        .onTapGesture(perform: select)
        .onHover { hovering = $0 }
        .onReceive(titlePublisher) { title = $0 }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(tab.isSelected ? [.isButton, .isSelected] : .isButton)
    }

    private static let sideWidth: CGFloat = 24

    /// The tint over the glass for each state: resting, hovered, and
    /// selected (unchanged by hover).
    private var backgroundOpacity: Double {
        if tab.isSelected { return 0.16 }
        return hovering ? 0.09 : 0.05
    }

    private var titlePublisher: AnyPublisher<String, Never> {
        guard let window = tab.window else { return Empty().eraseToAnyPublisher() }
        return window.publisher(for: \.title).eraseToAnyPublisher()
    }
}

/// Whether ⌘ is held, so tabs show their ⌘-number shortcuts only then. One
/// app-wide modifier monitor shared by every tab.
@MainActor
private final class CommandKeyState: ObservableObject {
    static let shared = CommandKeyState()

    @Published private(set) var isPressed = false

    private init() {
        _ = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
            self?.update(event.modifierFlags)
            return event
        }

        // Releasing ⌘ in another app never reaches us.
        _ = NotificationCenter.default.addObserver(
            forName: NSApplication.didResignActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.isPressed = false }
        }
    }

    private func update(_ flags: NSEvent.ModifierFlags) {
        let pressed = flags.contains(.command)
        if pressed != isPressed { isPressed = pressed }
    }
}
