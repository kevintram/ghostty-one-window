import AppKit

extension AppDelegate {
    /// New Workspace when no workspace window is in the responder chain (no
    /// windows open, the Quick Terminal or e.g. Settings is key). There's no
    /// workspace to add to, so ⌘N does what it did before workspaces: the
    /// `new_window` action, from the focused terminal if there is one so the
    /// new window inherits its settings such as the working directory.
    @IBAction func newWorkspace(_ sender: Any?) {
        if let controller = NSApp.keyWindow?.windowController as? BaseTerminalController,
           let surface = controller.focusedSurface?.surface {
            ghostty.newWindow(surface: surface)
        } else {
            newWindow(sender)
        }
    }

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
