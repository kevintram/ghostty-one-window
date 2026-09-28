# Ghostty Workspaces for macOS

Status: Draft 0.6  
Platform: macOS  
Project type: Fork of Ghostty's native macOS application

## 1. Summary

This project adds lightweight workspace organization to Ghostty on macOS.

A workspace is a named group of terminal tabs. A window can contain multiple
workspaces, and each workspace can contain multiple tabs. The user selects a
workspace from a sidebar on the left of the window, and the selected
workspace's tabs appear in a tab strip above the terminal. The project retains
Ghostty's existing terminal implementation, split panes, renderer,
configuration, and macOS integrations.

Tabs are not native AppKit tabs. Each application window is one `NSWindow`
that holds the tabs of all of its workspaces. A tab is a split tree of
terminals; only the selected tab's terminals are in the window, and the
others keep running outside it.

The project is intentionally narrow. It is not intended to become an IDE,
terminal multiplexer, agent dashboard, browser, file manager, or general
automation platform.

## 2. Goals

- Add multiple named workspaces to a Ghostty window.
- Let each workspace own an ordered set of Ghostty tabs.
- Present workspaces in a native macOS sidebar.
- Show the selected workspace's tabs in a tab strip above the terminal.
- Make switching workspaces as fast as switching tabs.
- Preserve Ghostty's existing terminal behavior as closely as possible.
- Support multiple application windows, each with its own workspaces.
- Keep terminals alive when the user switches workspaces.
- Restore workspace organization alongside Ghostty's existing window and tab
  restoration.
- Keep the workspace code isolated and understandable. Keeping the patch set
  against upstream Ghostty small is no longer a goal.

## 3. Non-goals

The initial product will not include:

- An embedded web browser.
- A file explorer.
- Git status or pull request integrations.
- AI-agent-specific features.
- A plugin system.
- A socket API or extensive command-line automation API.
- Cloud synchronization.
- Cross-platform support.
- Restoration of arbitrary live processes after the application quits.
- Replacement of Ghostty's terminal engine, renderer, configuration format,
  split implementation, or shell integration.

## 4. Terminology

### Application window

A user-visible terminal window: one `NSWindow` managed by one
`TerminalController`. It holds every tab of every one of its workspaces and
shows one workspace, and one of its tabs, at a time.

### Workspace model

The window's `WorkspaceModel`: its ordered workspaces with their tabs, the
selected workspace, each workspace's last-selected tab, and the state the
sidebar and tab strip share.

```text
TerminalController (one NSWindow)
├── Workspace bar (sidebar)
├── Tab strip (selected workspace's tabs)
├── Terminal view (the selected tab's split tree)
└── WorkspaceModel
    └── Workspace[]
        └── TerminalTab[] (split trees of terminals)
```

### Workspace

A named, ordered group of tabs within one application window. It does not
own a separate terminal runtime.

### Tab

A `TerminalTab`: a split tree of one or more terminal surfaces, with its
focused surface and title override. Each tab belongs to exactly one
workspace.

### Pane

A Ghostty terminal surface within a tab's split tree.

## 5. Product model

The hierarchy is:

```text
Application
└── TerminalController[]            (one per application window)
    ├── Workspace bar
    ├── Tab strip
    └── WorkspaceModel
        └── Workspace[]
            └── TerminalTab[]
                └── Pane[]
```

Each window has at least one workspace. Each workspace has at least one tab
while it exists. Each tab has at least one terminal pane while it exists.

Switching workspaces selects a tab in the target workspace. It does not
create, destroy, or restart any terminal.

## 6. Core user experience

### 6.1 Sidebar

The sidebar is the window's workspace bar. It is a native
full-height split-view sidebar on the left of the window: it extends under the
titlebar, and the window buttons sit on top of it. It contains:

- An ordered list of workspaces.
- A clear selected state for the active workspace.
- Controls or contextual actions for creating, renaming, reordering, and
  closing workspaces.

Tabs do not appear in the sidebar. The active workspace's tabs appear in the
tab strip (6.3).

The workspace bar should use standard macOS appearance and interaction
patterns. It is stable application chrome: switching tabs or workspaces must
not visibly recreate, move, resize, or reset it.

The workspace bar can be shown or hidden with View → Hide/Show Sidebar
(`Command-B`) or a sidebar button in the titlebar beside the window buttons,
which stays in place while the sidebar is collapsed. The same Liquid Glass
control also holds a New Workspace button. Collapsing animates in
the visible tab; the terminal column takes the freed width and the window
keeps its frame. The sidebar never collapses on its own when the window is
resized narrow.

Its width, visibility, selection, and ordering belong to the window, not to
an individual tab or workspace. There is one sidebar per window, so switching
tabs or workspaces never touches it.

### 6.2 Workspace selection

Selecting a workspace selects that workspace's last-selected tab. If that tab
is no longer available, its first available tab is selected. The tab strip
then shows the selected workspace's tabs.

Because this is an ordinary tab selection, the window frame, sidebar, and
titlebar do not change, and the switch costs the same as switching tabs.

Switching workspaces does not terminate, recreate, suspend, or reset any
terminal process. Background terminal output continues to be processed using
Ghostty's existing behavior.

Selecting a tab of another workspace by any means (for example, presenting
one of its terminals from the command palette or a notification) also
selects that tab's workspace.

### 6.3 Tab strip and tab selection

The tab strip sits above the terminal, below the titlebar, and shows only the
selected workspace's tabs, in order. Each tab is a capsule
showing a terminal icon, its title, and a close button on hover. While
Command is held, the icon gives way to the tab's `goto_tab` shortcut (⌘1–⌘9,
numbered within the workspace). Resting tabs are transparent, hovered ones
tinted, and the selected one Liquid Glass. The strip ends with a New Tab
button.

However many tabs there are, they share the strip's width and keep
shrinking, as in Chrome: titles shorten, then the close button's space goes
(the selected tab shows it in place of its icon on hover), and finally only
a shrinking icon is left. The selected tab keeps a minimum width so it stays
findable and closable. Hovering a tab shows its full title.

Like Ghostty's native tab bar, the strip is hidden while the selected
workspace has a single tab.

Pressing a tab selects it right away. Dragging it along the strip reorders it
live: it follows the pointer while the tabs it passes slide aside, and it
settles into its slot on release. Pulling it out of the strip turns the drag
into a system drag: the tab leaves the strip and a preview card of it follows
the pointer, to be dropped on a workspace in the sidebar (see "Moving tabs
between workspaces"). Dragged back over the strip, the card gives way to the
tab itself, which rejoins the strip under the pointer. Escape, or dropping
anywhere else, returns the tab to where it was.

Selecting a tab swaps its split tree into the window (see 10.3). Ghostty's
tab navigation —
`goto_tab` (index, next, previous, last), `move_tab`, Close Other Tabs, and
Close Tabs to the Right — operates within the current workspace.


### 6.4 Multiple windows

The application may have multiple application windows. Each window has its own:

- Workspaces and tabs.
- Selected workspace.
- Last-selected tab for each workspace.
- Workspace ordering.
- Sidebar width and visibility.

Creating a new application window creates one workspace with one tab.

## 7. Commands and expected behavior

The default commands are:

| Command | Default shortcut | Behavior |
| --- | --- | --- |
| New Window | `Command-Shift-N` | Create a new application window with one workspace and one tab. |
| New Tab | `Command-T` | Create a tab in the current workspace. |
| New Workspace | `Command-N` | Create and select a workspace containing one new tab. |
| Rename Workspace | `Command-Shift-R` | Rename the selected workspace in place in the sidebar. |
| Close Tab | `Command-W` | Close the active tab using Ghostty's existing confirmation behavior. The next tab is chosen within the same workspace. |
| Close Window | `Command-Shift-W` | Close the application window, including every workspace in it. |
| Hide/Show Sidebar | `Command-B` | Show or hide the workspace sidebar (View menu, titlebar button). |
| Next Tab | `Command-Shift-]` | Select the next tab within the current workspace. |
| Previous Tab | `Command-Shift-[` | Select the previous tab within the current workspace. |
| Go to Tab 1–9 | `Command-1` … `Command-9` | Select the Nth tab of the current workspace. |
| Next Workspace | `Command-Option-]` | Select the next workspace in display order. |
| Previous Workspace | `Command-Option-[` | Select the previous workspace in display order. |
| Go to Workspace 1–8 / Last | `Control-1` … `Control-8`, `Control-9` | Select the Nth workspace, or the last one for 9. Keys without a matching workspace go to the terminal. |

Shortcut assignments remain subject to Ghostty's configuration and conflict
handling. Ghostty's default `new_window` binding moves from `Command-N` to
`Command-Shift-N` so that `Command-N` is free for New Workspace.

The workspace commands are currently native menu items in a Workspace menu,
which works because the terminal surface only claims keys bound in the
Ghostty config. The final implementation should use Ghostty's action system
rather than introducing an unrelated shortcut system.

## 8. Workspace lifecycle

### Creating a workspace

Creating a workspace:

1. Creates a workspace with a stable UUID and default name.
2. Captures the focused pane's current working directory from the active tab.
3. Creates one tab with the captured working directory as its initial
   working directory.
4. Assigns the tab to the new workspace.
5. Selects the workspace and its new tab.

If the focused pane does not report a working directory, creation falls back
to Ghostty's normal new-terminal working-directory behavior.

Default workspace naming is initially `Workspace 1`, `Workspace 2`, and so on
within an application window. Numbers are not reused within a window.
Renaming a workspace does not change terminal titles, working directories, or
commands.

Workspace names do not need to be unique within an application window.

### Renaming a workspace

A workspace is renamed in place in the sidebar, by double-clicking its row,
choosing Rename Workspace… from the row's context menu, or with Rename
Workspace (`Command-Shift-R`) for the selected workspace, which shows the
sidebar if it's collapsed. Its name becomes a text field: Return saves it,
and so does clicking elsewhere or switching apps; Escape cancels. Keyboard
focus then returns to the terminal. An empty name uses the title of the
workspace's current tab. Long names are truncated in the sidebar.

`Control-R` is left alone since shells use it for reverse history search.

### Closing a workspace

Closing a workspace closes all tabs assigned to it.

Ghostty's existing running-process confirmation behavior must be respected.
The operation should be all-or-cancel from the user's perspective: if closing
requires confirmation, the user confirms closing the workspace rather than
receiving a confusing sequence of unrelated per-tab prompts.

When a workspace loses its last tab, the workspace is removed and the
neighboring workspace (the next one, else the previous one) is selected. If
the last workspace in an application window is closed, the application window
closes.

### Reordering workspaces

Workspaces are reordered by dragging them in the sidebar, where the dragged
row follows the pointer and the rows it passes slide aside, as in the tab
strip. As with tabs, pressing a row selects its workspace right away.
Reordering affects display and workspace-navigation order only.

### Moving tabs between workspaces

A tab can be reassigned from one workspace to another within the same
application window. This only moves the tab between workspaces. The terminal
process and split tree remain unchanged.

A tab is moved by dragging it out of the tab strip onto another workspace in
the sidebar, which highlights while the tab is over it. The tab goes to the
end of that workspace, and the selection follows it: its new workspace is
selected with the tab. The workspace it left shows the tab's neighbor when
switched back to. A context-menu action is a possible later addition.

Dragging a tab out of its application window creates a one-tab workspace in
the destination window (not yet implemented). If a new destination window is
created, it gets its own workspaces. The
new workspace uses the source workspace's name but receives its own workspace
UUID; it is not linked to the source workspace. The terminal process and
split tree continue without restarting.

If the dragged tab was the source workspace's final tab, the now-empty source
workspace is automatically removed.

## 9. Tab lifecycle

### Creating a tab

A new tab is added to the selected workspace, after the selected tab or at
the end following `window-new-tab-position`, and selected. Its terminal
configuration, working directory inheritance, and initial focus follow
Ghostty's existing behavior. Windows that can't have tabs (see 10.4) open a
new window instead.

### Closing a tab

Closing a tab uses Ghostty's existing close and process-confirmation behavior.

When the visible tab closes, the tab to its right in the same workspace is
selected, else the tab to its left. If it was the workspace's last tab, the
neighboring workspace is selected and the workspace is removed (8). The
window's last tab closes the window.

A terminal exiting in a tab that isn't shown closes without selecting it,
unless it needs confirmation, in which case its tab is shown first.

Undoing a close puts the tab back in its place, recreating its workspace if
the close removed it. Until the undo expires, it keeps the tab's terminals
alive.

### Reordering tabs

Tabs are reordered within their workspace by dragging them in the tab strip
or with `move_tab`.

### Splits

Ghostty's existing split-pane behavior remains unchanged. Workspaces group
tabs, not individual panes.

## 10. Technical architecture

### 10.1 Upstream strategy

The project is a fork of Ghostty. Workspace code lives in isolated files
(`macos/Sources/Features/Workspaces/`) where practical, but changing
Ghostty's window and tab code to fit the design is acceptable.

### 10.2 Runtime ownership

The application continues to use one Ghostty application/runtime instance.

- `TerminalController` manages one application window and all of its tabs.
  Its inherited `surfaceTree` is always the selected tab's split tree, so
  Ghostty's split, focus, zoom, close, and clipboard logic works unchanged on
  the visible tab.
- `WorkspaceModel` holds the window's workspaces and `TerminalTab`s.
- `Ghostty.SurfaceView` represents an individual terminal pane.
- The quick terminal is unchanged and has no tabs.

### 10.3 Tabs and switching

A `TerminalTab` holds its split tree, its focused surface, and its title
override, and publishes its title for the tab strip. The selected tab's tree
is kept in sync with the controller's `surfaceTree`.

Selecting a tab:

1. Marks it selected in the model (and its workspace).
2. Unfocuses the previous tab's surfaces and occludes them, so they stop
   rendering.
3. Assigns the tab's title override and split tree to the controller, which
   puts its surfaces in the window.
4. Focuses the tab's last focused surface.

Terminals of tabs that aren't shown keep running and receiving output. The
base controller has hooks so they're still handled:

| Hook | Used for |
| --- | --- |
| `owns(_:)`, `allSurfaces` | Finding a surface's controller, quit and close confirmation, AppleScript, App Intents, the command palette. |
| `revealSurface(_:)` | Selecting a surface's tab before focusing or presenting it. |
| `revealSurfaces(of:)` | Selecting the right tab before undoing or redoing a split change. |
| `closeHiddenSurface(_:withConfirmation:)` | A terminal in a hidden tab exiting. |

Windows use `tabbingMode = .disallowed`; AppKit native tabs are never used.

### 10.4 Window layout

A window's content is a split view controller:

- A native split-view sidebar item (full-height layout, fixed width) hosting
  the workspace bar.
- A detail column containing the tab strip, pinned below the titlebar's safe
  area, and Ghostty's existing terminal container below it.

The window uses a full-size content view so the sidebar extends under the
titlebar. With a glass background, the terminal's glass covers the whole
window and overhangs its edges, so its rim is clipped by the window rather
than drawn inside it. The split view's per-column titlebar backgrounds are
made transparent, so the title row is part of the same glass surface.

Windows without a titlebar (`macos-titlebar-style = hidden`,
`window-decoration = false`) keep Ghostty's plain terminal layout, have no
tabs, and open new tabs and workspaces as new windows.

The window's content size accounts for the sidebar, titlebar, and tab strip
so that Ghostty's `window-width` and `window-height` still describe the
terminal area.

### 10.5 Tab strip

The tab strip is SwiftUI, rendered once per window from the model. Renaming a
tab (Change Tab Title…, `Command-R` by default through `prompt_tab_title`)
edits its title in place in the strip, which shows while a tab is renamed
even if it's the workspace's only tab.

## 11. State restoration

Restoration extends Ghostty's existing per-window `TerminalRestorableState`
(version 8). The selected tab's split tree is the state's existing
`surfaceTree`, so older state still restores as one tab. New state also
records each workspace's name, its tabs (split tree, focused surface, title
override), and its selected tab. The window's selected tab's tree isn't
repeated there, since decoding a tree creates its terminals; its workspace is
the selected one.

Sidebar visibility and width are runtime preferences only. Invalid workspace
state restores the selected tab alone rather than failing.

Undoing a window close restores all of its workspaces and tabs.

## 12. Process and rendering behavior

Switching tabs or workspaces does not create or destroy terminal surfaces.
Terminals of tabs that aren't shown keep running and receiving output, but
are occluded, so they don't render.

## 13. Error handling and recovery

The workspace layer must favor preserving terminals over preserving metadata.

- If a workspace record references a missing tab, remove the reference.
- If a live tab has no workspace, assign it to the selected or default
  workspace.
- If a selected workspace or tab is missing, choose the first valid option.
- If workspace persistence fails, continue with an in-memory default
  workspace.
- If sidebar construction fails, the terminal content should remain usable.
- Workspace operations must never silently terminate terminal processes.

## 14. Performance expectations

The workspace feature should add negligible overhead to normal terminal
rendering.

- Switching workspaces must cost no more than switching tabs.
- Sidebar and tab strip updates must not subscribe directly to terminal
  output streams.
- Tab titles and working directories should update through existing,
  event-driven Ghostty state (a tab observes its focused surface's title).
- Sidebar state changes should occur on the main actor.
- Structural coordination should happen only on events such as tab creation,
  closure, selection, movement, or restoration.
- There is one sidebar and one tab strip per window, however many tabs it
  has.

## 15. Accessibility

All workspace and tab rows must expose appropriate accessibility labels,
selection state, and actions.

Keyboard-only users must be able to:

- Focus the sidebar.
- Move between workspaces and tabs.
- Create, rename, and close workspaces.
- Create, move, and close tabs.
- Return focus to the active terminal.

Adding the sidebar and tab strip must not interfere with VoiceOver access to
Ghostty's existing terminal surfaces.

## 16. Implementation status

Implemented:

- One `NSWindow` per application window holding all of its workspaces' tabs;
  switching swaps split trees.
- Sidebar with workspace list and selection; a Liquid Glass titlebar control
  with New Workspace and the sidebar toggle.
- Tab strip with titles, per-workspace ⌘1–⌘9 labels, selection, close on
  hover, and New Tab; hidden for a single tab.
- Workspace drag-to-reorder in the sidebar.
- Tab drag-to-reorder in the strip, and moving tabs between workspaces by
  dragging them out of the strip onto the sidebar.
- Renaming tabs in place in the strip (`Command-R`), and workspaces in place
  in the sidebar (double-click, context menu, `Command-Shift-R`).
- New Workspace (`Command-N`), Next/Previous Workspace
  (`Command-Option-]`/`[`), Go to Workspace (`Control-1`–`9`), New Window
  moved to `Command-Shift-N`.
- Per-workspace tab navigation, move-tab, Close Other Tabs, and Close Tabs to
  the Right.
- Closing tabs and workspaces with in-workspace next-tab selection; terminals
  exiting in hidden tabs.
- Undo of closing tabs and windows.
- Restoration of workspaces and tabs.
- Collapsible sidebar: View → Hide/Show Sidebar (`Command-B`) and a titlebar
  sidebar button; not persisted.
- AppleScript windows and tabs map to windows and `TerminalTab`s.
- Terminals in hidden tabs: bells, notifications (clicking one selects its
  tab), `set_tab_title`, and child-exit messages.
- `move_tab_to_new_window` moves a tab (the same `TerminalTab`, with its
  focus and title) into a new window, in a workspace named after the one it
  left. It isn't undoable, and it clears the source window's undo history,
  whose entries for the tab would act on the wrong window.

Not yet implemented:

- Workspace close (with all-or-cancel confirmation).
- Dragging tabs out of the application window, or between windows; moving a
  tab into an existing window; a Move to Workspace context menu action.
- Tab context menu, per-tab colors (the tab color is per window), and bell
  indicators in the tab strip.
- `prompt_tab_title` targeted at a hidden terminal (it renames the shown tab);
  split actions on hidden terminals through AppleScript.
- Adjustable sidebar width.
- Workspace commands as Ghostty actions.
- Removing Ghostty's now unused native tab code (tab bar accessories, the
  `macos-titlebar-style = tabs` window styles, native tab context menus).
- Native fullscreen and non-native titlebar styles have not been verified.
- Accessibility review.
