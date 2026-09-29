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

    /// Adds the menu items for workspaces and windows that aren't in the
    /// main menu nib: the Workspace menu before the Window menu, Reopen
    /// Closed in the File menu, Merge All Windows in the Window menu, and
    /// Hide/Show Sidebar in the View menu. Their shortcuts are the Ghostty
    /// keybindings for their actions (see `codeMenuShortcuts`).
    @MainActor func installMenuItems() {
        guard let mainMenu = NSApp.mainMenu else { return }

        @discardableResult
        func add(
            _ title: String,
            _ action: Selector,
            binding: String?,
            to menu: NSMenu,
            at index: Int? = nil
        ) -> NSMenuItem {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
            menu.insertItem(item, at: index ?? menu.items.count)
            if let binding { codeMenuShortcuts.append((binding, item)) }
            return item
        }

        let menu = NSMenu(title: "Workspace")
        add("New Workspace", #selector(TerminalController.newWorkspace(_:)), binding: "new_workspace", to: menu)
        add("Rename Workspace…", #selector(TerminalController.renameWorkspace(_:)), binding: "rename_workspace", to: menu)
        add("Close Workspace", #selector(TerminalController.closeWorkspace(_:)), binding: "close_workspace", to: menu)
        menu.addItem(.separator())
        add("Select Next Workspace", #selector(TerminalController.selectNextWorkspace(_:)), binding: "next_workspace", to: menu)
        add(
            "Select Previous Workspace",
            #selector(TerminalController.selectPreviousWorkspace(_:)),
            binding: "previous_workspace",
            to: menu)
        add("Move Workspace Up", #selector(TerminalController.moveWorkspaceUp(_:)), binding: "move_workspace:-1", to: menu)
        add("Move Workspace Down", #selector(TerminalController.moveWorkspaceDown(_:)), binding: "move_workspace:1", to: menu)
        menu.addItem(.separator())
        add(
            "Move Tab to Previous Workspace",
            #selector(TerminalController.moveTabToPreviousWorkspace(_:)),
            binding: "move_tab_to_workspace:-1",
            to: menu)
        add(
            "Move Tab to Next Workspace",
            #selector(TerminalController.moveTabToNextWorkspace(_:)),
            binding: "move_tab_to_workspace:1",
            to: menu)

        // Workspaces 1-8 and the last one, like the tabs' Cmd+1-9. Hidden to
        // keep the menu short; hidden items still take their shortcuts.
        for number in 1...9 {
            let select = add(
                number == 9 ? "Select Last Workspace" : "Select Workspace \(number)",
                #selector(TerminalController.selectWorkspaceByNumber(_:)),
                binding: number == 9 ? "last_workspace" : "goto_workspace:\(number)",
                to: menu)
            select.tag = number
            select.isHidden = true
            select.allowsKeyEquivalentWhenHidden = true
        }

        let item = NSMenuItem(title: "Workspace", action: nil, keyEquivalent: "")
        item.submenu = menu
        let index = NSApp.windowsMenu.flatMap { windowsMenu in
            mainMenu.items.firstIndex { $0.submenu === windowsMenu }
        } ?? mainMenu.items.count
        mainMenu.insertItem(item, at: index)

        // Reopen Closed after the File menu's close items.
        if let fileMenu = mainMenu.items.first(where: { $0.title == "File" })?.submenu {
            let after = fileMenu.items.lastIndex { $0.title.hasPrefix("Close") }
            add(
                "Reopen Closed",
                #selector(AppDelegate.reopenClosed(_:)),
                binding: "reopen_closed",
                to: fileMenu,
                at: after.map { $0 + 1 })
        }

        // Merge All Windows before the Window menu's list of windows.
        if let windowsMenu = NSApp.windowsMenu {
            let before = windowsMenu.items.firstIndex { $0.title == "Bring All to Front" }
            let merge = add(
                "Merge All Windows",
                #selector(TerminalController.mergeAllWindows(_:)),
                binding: nil,
                to: windowsMenu,
                at: before)
            windowsMenu.insertItem(.separator(), at: windowsMenu.index(of: merge) + 1)
        }

        // Hide/Show Sidebar in the View menu, handled by the key window's
        // workspace split view (NSSplitViewController's standard action).
        if let viewMenu = mainMenu.items.first(where: { $0.title == "View" })?.submenu {
            viewMenu.addItem(.separator())
            add(
                "Hide Sidebar",
                #selector(NSSplitViewController.toggleSidebar(_:)),
                binding: "toggle_sidebar",
                to: viewMenu)
        }

        syncMenuShortcuts(ghostty.config)
    }
}
