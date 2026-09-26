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
        .padding(.horizontal, 6)
        .frame(height: WorkspaceWindowGroup.tabStripHeight)
    }
}

private struct TabButton: View {
    let tab: WorkspaceWindowGroup.Tab
    let select: () -> Void

    @State private var title: String
    @State private var hovering = false

    init(tab: WorkspaceWindowGroup.Tab, select: @escaping () -> Void) {
        self.tab = tab
        self.select = select
        _title = State(initialValue: tab.window?.title ?? "")
    }

    var body: some View {
        HStack(spacing: 4) {
            Button {
                (tab.window?.windowController as? TerminalController)?.closeTab(nil)
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .semibold))
                    .frame(width: 16, height: 16)
            }
            .buttonStyle(.borderless)
            .opacity(hovering ? 1 : 0)
            .allowsHitTesting(hovering)
            .help("Close Tab")

            Text(title)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: .infinity)

            if let shortcut = tab.shortcut, !shortcut.isEmpty {
                Text(shortcut)
                    .foregroundStyle(.secondary)
            }
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
