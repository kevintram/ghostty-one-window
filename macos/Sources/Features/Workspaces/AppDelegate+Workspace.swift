import AppKit

extension AppDelegate {
    /// Inserts the "Workspace" menu before the "Window" menu. The items
    /// target the first responder, so they act on the key terminal window.
    ///
    /// These use native key equivalents rather than Ghostty keybindings.
    /// That works because the surface only claims keys that are bound in
    /// the Ghostty config; unbound command keys fall through to the menu.
    func installWorkspaceMenu() {
        guard let mainMenu = NSApp.mainMenu else { return }

        let menu = NSMenu(title: "Workspace")
        menu.addItem(
            withTitle: "New Workspace",
            action: #selector(TerminalController.newWorkspace(_:)),
            keyEquivalent: "n")
        menu.addItem(.separator())

        let next = menu.addItem(
            withTitle: "Select Next Workspace",
            action: #selector(TerminalController.selectNextWorkspace(_:)),
            keyEquivalent: "]")
        next.keyEquivalentModifierMask = [.command, .option]

        let previous = menu.addItem(
            withTitle: "Select Previous Workspace",
            action: #selector(TerminalController.selectPreviousWorkspace(_:)),
            keyEquivalent: "[")
        previous.keyEquivalentModifierMask = [.command, .option]

        let item = NSMenuItem(title: "Workspace", action: nil, keyEquivalent: "")
        item.submenu = menu

        let index = NSApp.windowsMenu.flatMap { windowsMenu in
            mainMenu.items.firstIndex { $0.submenu === windowsMenu }
        } ?? mainMenu.items.count
        mainMenu.insertItem(item, at: index)
    }
}
