# Ghostty Workspaces for macOS

Status: Draft 0.5  
Platform: macOS  
Project type: Thin fork of Ghostty's native macOS application

## 1. Summary

This project adds lightweight workspace organization to Ghostty on macOS.

A workspace is a named group of terminal tabs. A window can contain multiple
workspaces, and each workspace can contain multiple tabs. The user selects a
workspace from a sidebar on the left of the window, and the selected
workspace's tabs appear in a tab strip above the terminal. The project retains
Ghostty's existing terminal implementation, native tab lifecycle, split panes,
renderer, configuration, and macOS integrations.

Under the hood every tab is still a native AppKit tab. All tabs of a window,
across all of its workspaces, live in one native `NSWindowTabGroup`. The
native tab bar is hidden and replaced by a workspace-aware tab strip that
shows only the selected workspace's tabs.

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
- Support multiple application windows, each coordinated by its own
  `WorkspaceWindowGroup`.
- Keep terminals alive when the user switches workspaces.
- Restore workspace organization alongside Ghostty's existing window and tab
  restoration.
- Maintain a small, understandable patch set against upstream Ghostty.

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
- A custom tab implementation. Tabs remain native AppKit tab windows; only
  the tab bar's presentation is replaced (see 10.7).

## 4. Terminology

### Application window

A user-visible terminal window. Each application window owns an independent
`WorkspaceWindowGroup` and shows one workspace at a time.

Internally, Ghostty uses native AppKit tabbing, where each tab is represented
by an `NSWindow` in an `NSWindowTabGroup`. An application window is exactly one
native tab group: it contains the tab windows of every one of its workspaces.
Only the selected tab window is visible at a time, as with ordinary native
tabs.

### Workspace window group

The application-level coordinator that provides the workspace layer AppKit
does not provide. It owns the ordered set of workspaces, the selected
workspace, the last-selected tab of each workspace, and the list of tabs shown
in the tab strip.

```text
WorkspaceWindowGroup
├── Workspace bar (sidebar)
├── Tab strip (selected workspace's tabs)
└── NSWindowTabGroup
    └── Tab windows of every workspace
```

### Workspace

A named, ordered group of tabs within one application window. A workspace is
organizational metadata; it does not own a separate terminal runtime or a
separate native tab group.

### Tab

An existing Ghostty terminal tab backed by Ghostty's current
`TerminalController` and native AppKit tab window. A tab may contain one or
more split terminal surfaces. Each tab belongs to exactly one workspace.

### Pane

A Ghostty terminal surface within a tab's split tree.

## 5. Product model

The hierarchy is:

```text
Application
└── WorkspaceWindowGroup[]          (one per application window)
    ├── Workspace bar
    ├── Tab strip
    ├── Workspace[]
    │   └── Tab[] (by membership)
    │       └── Pane[]
    └── NSWindowTabGroup            (holds every workspace's tabs)
```

Each workspace window group has at least one workspace. Each workspace has at
least one tab while it exists. Each tab has at least one terminal pane while
it exists.

A workspace's tab order is the order of its tabs within the shared native tab
group. Tabs of different workspaces may be interleaved in the native group;
only the relative order within a workspace is meaningful.

Switching workspaces selects a tab in the target workspace. It does not
change the native tab group's membership, terminal ownership, or process
lifetime.

## 6. Core user experience

### 6.1 Sidebar

The sidebar is the workspace bar for a `WorkspaceWindowGroup`. It is a native
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
which stays in place while the sidebar is collapsed. Collapsing animates in
the visible tab; the terminal column takes the freed width and the window
keeps its frame. The sidebar never collapses on its own when the window is
resized narrow.

Its width, visibility, selection, and ordering belong to the
`WorkspaceWindowGroup`, not to an individual tab or workspace: every tab
window of the group follows the group's collapsed state, applying it
instantly in hidden tabs so switching tabs never animates.

### 6.2 Workspace selection

Selecting a workspace selects that workspace's last-selected tab in the
shared native tab group. If that tab is no longer available, its first
available tab is selected. The tab strip then shows the selected workspace's
tabs.

Because this is an ordinary native tab selection, the window frame, sidebar,
and titlebar do not change, and the switch costs the same as switching tabs.

Switching workspaces does not terminate, recreate, suspend, or reset any
terminal process. Background terminal output continues to be processed using
Ghostty's existing behavior.

Selecting a tab of another workspace by any means (for example, when AppKit
makes it key) also selects that tab's workspace: the key tab decides the
selected workspace.

### 6.3 Tab strip and tab selection

The tab strip sits above the terminal, below the titlebar, and shows only the
selected workspace's tabs, in their native order. Each tab shows its title,
its `goto_tab` shortcut (⌘1–⌘9, numbered within the workspace), and a close
button on hover. The strip ends with a New Tab button.

Like the native tab bar, the strip is hidden while the selected workspace has
a single tab.

Selecting a tab uses Ghostty's existing native tab-selection path (setting the
tab group's selected window and making it key). Ghostty's tab navigation —
`goto_tab` (index, next, previous, last), `move_tab`, Close Other Tabs, and
Close Tabs to the Right — operates within the current workspace.

The project must not create a second terminal-session abstraction merely to
support workspace navigation.

### 6.4 Multiple windows

The application may have multiple application windows. Each window has its own:

- `WorkspaceWindowGroup`.
- Selected workspace.
- Last-selected tab for each workspace.
- Workspace ordering.
- Sidebar width and visibility.

Creating a new application window creates a new `WorkspaceWindowGroup` with
one workspace and one tab.

## 7. Commands and expected behavior

The default commands are:

| Command | Default shortcut | Behavior |
| --- | --- | --- |
| New Window | `Command-Shift-N` | Create a new application window with one workspace and one tab. |
| New Tab | `Command-T` | Create a tab in the current workspace. |
| New Workspace | `Command-N` | Create and select a workspace containing one new tab. |
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
3. Creates one Ghostty tab with the captured working directory as its initial
   working directory, and adds it to the window's native tab group.
4. Assigns the tab to the new workspace.
5. Selects the workspace and its new tab.

If the focused pane does not report a working directory, creation falls back
to Ghostty's normal new-terminal working-directory behavior.

Default workspace naming is initially `Workspace 1`, `Workspace 2`, and so on
within an application window. Numbers are not reused within a window.
Renaming a workspace does not change terminal titles, working directories, or
commands.

Workspace names do not need to be unique within an application window.

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

Workspaces can be reordered in the sidebar. Reordering affects display and
workspace-navigation order only.

### Moving tabs between workspaces

A tab can be reassigned from one workspace to another within the same
application window. Because all workspaces share one native tab group, this
only changes the tab's workspace membership (and optionally its position in
the native group). The terminal process and split tree remain unchanged.

Dragging tabs between workspaces is desirable but may be deferred if it adds
substantial complexity. A context-menu action is an acceptable initial
interaction.

Dragging a tab out of its application window creates a one-tab workspace in
the destination window's `WorkspaceWindowGroup`. If a new destination window
is created, the application creates a new `WorkspaceWindowGroup` for it. The
new workspace uses the source workspace's name but receives its own workspace
UUID; it is not linked to the source workspace. The terminal process and
split tree continue without restarting.

If the dragged tab was the source workspace's final tab, the now-empty source
workspace is automatically removed.

## 9. Tab lifecycle

### Creating a tab

A new tab joins the window's native tab group through Ghostty's existing
new-tab path and is assigned to the selected workspace. Its creation,
terminal configuration, working directory inheritance, and initial focus
follow Ghostty's existing behavior.

### Closing a tab

Closing a tab uses Ghostty's existing close and process-confirmation behavior.

When the visible tab closes, the workspace chooses the next tab before AppKit
does: the tab to its right in the same workspace, else the tab to its left.
Otherwise AppKit would select a neighbor in the shared tab group, which may
belong to another workspace. If it was the workspace's last tab, the
neighboring workspace is selected and the workspace is removed (8).

The tab is removed from its workspace when it closes. Closed tabs may remain
alive for undo, so membership is cleared explicitly rather than inferred from
the window list.

### Reordering tabs

A workspace's tab order is its tabs' order in the native tab group. Reordering
a tab in the tab strip moves its native tab window relative to the other tabs
of the same workspace.

### Splits

Ghostty's existing split-pane behavior remains unchanged. Workspaces group
tabs, not individual panes.

## 10. Technical architecture

### 10.1 Upstream strategy

The project will be based on a pinned fork of Ghostty rather than on a
separately installed Ghostty application.

The implementation should favor:

- New, isolated source files for workspace functionality
  (`macos/Sources/Features/Workspaces/`).
- Narrow hooks into Ghostty's existing window and tab lifecycle.
- Reuse of existing actions, notifications, controllers, and restoration.
- Minimal changes to terminal, renderer, PTY, and configuration code.
- Regular, deliberate synchronization with a pinned upstream revision.

### 10.2 Runtime ownership

The application continues to use one Ghostty application/runtime instance.
Workspaces do not create additional Ghostty runtimes.

Existing Ghostty objects retain their responsibilities:

- `TerminalController` manages a terminal tab and its split tree.
- `Ghostty.SurfaceView` represents an individual terminal pane.
- One `NSWindowTabGroup` per application window manages the native tab
  windows of all its workspaces.
- Ghostty's existing app object manages global terminal configuration and
  callbacks.

Workspace code adds organization and navigation around those objects.

### 10.3 Workspace types

```swift
@MainActor
final class WorkspaceWindowGroup: ObservableObject {
    struct Workspace: Identifiable {
        let id: UUID
        var name: String
    }

    @Published private(set) var workspaces: [Workspace]
    @Published private(set) var selectedID: UUID?

    /// The selected workspace's tabs, in native order, for the tab strip.
    @Published private(set) var tabs: [Tab]

    /// Runtime only: last-selected tab window per workspace.
    private var lastSelectedTab: [UUID: Weak<NSWindow>]
}
```

The group does not store tabs. A workspace's tabs are derived on demand from
the live `TerminalController`s whose membership points at the group and
workspace, ordered by the native tab group.

Sidebar width and visibility belong to the group once they become adjustable
(see 11 for their persistence).

Runtime references to `TerminalController`, `NSWindow`, and Ghostty surfaces
must not be stored in serialized records.

### 10.4 Tab workspace membership

Tabs do not receive a new persistent ID. Ghostty continues to identify a live
tab through its existing `NSWindow` and `TerminalController`, while the native
tab group provides ordering.

At runtime each `TerminalController` owns a small observable membership: its
`WorkspaceWindowGroup` and workspace ID. The sidebar and tab strip of every
tab window observe it, so they appear as soon as the tab is assigned.

A native tab group and a `WorkspaceWindowGroup` correspond one to one. The
native tab group is the source of truth: AppKit can change it underneath the
workspace layer (Merge All Windows, Move Tab to New Window, undo re-inserting
tabs), so membership is reconciled against it whenever a tab is shown or
becomes key, and after Merge All Windows. Reconciliation runs one event loop
tick later, because callers such as undo show a window before inserting it
into its tab group. It applies these rules to the tabs of one native tab
group:

- Tabs whose workspace group mostly lives in another native tab group split
  off into a new workspace group, keeping their workspaces' names under new
  IDs (Move Tab to New Window).
- Workspace groups that meet in one native tab group merge into the group of
  the selected tab, keeping their workspaces (Merge All Windows).
- Tabs without membership join the selected workspace; if there is no group,
  a new one is created (new windows and tabs).

New Workspace assigns its tab explicitly. Undoing a tab or window close
restores the tab's original membership before the window is shown,
recreating the workspace (same ID and name) if the close removed it. A
recreated workspace returns to its original position: after the nearest
workspace that preceded it when it was closed. The undo state holds the
workspace group strongly until the undo expires.

For restoration, the minimum persistent information is encoded in each tab's
existing `TerminalRestorableState`:

```swift
struct TerminalWorkspaceMembership: Codable {
    var workspaceWindowGroupID: UUID
    var workspaceID: UUID
}
```

The tab's position within its workspace comes from its position in the
restored native tab group, so no separate tab index is required.

### 10.5 Workspace coordination hooks

The group is kept consistent through a few hooks in Ghostty's existing
lifecycle rather than a separate registry:

| Event | Hook | Group responsibility |
| --- | --- | --- |
| Tab shown | `TerminalController.showWindow` | Reconcile with the native tab group. |
| Tab becomes key | `windowDidBecomeKey` | Record last-selected tab; select its workspace; reconcile. |
| Tab about to close | `TerminalWindow.close()` | Choose the next tab within the workspace (9). |
| Tab closed | `windowWillClose` | Clear membership; remove an empty workspace. |
| Tab order or labels change | `relabelTabs()` | Number tabs per workspace; refresh the tab strip. |
| Windows merged | `TerminalWindow.mergeAllWindows` | Reconcile the merged tab group. |
| Close undone | `TerminalController.init(with:)` | Restore the tab's original membership. |

The group must degrade safely when AppKit changes the tab group
unexpectedly. An unrecognized live tab is placed in the selected workspace
rather than being discarded or closed.

### 10.6 Stable workspace bar and window layout

Each tab window's content is a split view controller:

- A native split-view sidebar item (full-height layout, fixed width) hosting
  the workspace bar.
- A detail column containing the tab strip, pinned below the titlebar's safe
  area, and Ghostty's existing terminal container below it.

The window uses a full-size content view so the sidebar extends under the
titlebar. Ghostty's existing terminal view remains intact inside its
container.

With a glass background, the terminal's glass covers the whole window and
overhangs its edges, so its rim is clipped by the window rather than drawn
inside it. The titlebar draws no background over the terminal column (the
split view's per-column titlebar backgrounds are made transparent), so the
title row is part of the same glass surface. The sidebar keeps its native
material.

Workspaces require native tabbing. Windows that disallow tabbing (for
example `macos-titlebar-style = hidden`) keep Ghostty's plain terminal
layout with no sidebar or tab strip, and the workspace commands are disabled
for them.

AppKit implements every native tab as an `NSWindow` and does not expose a
group-level content view, so each tab window hosts its own sidebar and tab
strip, all rendering the same `WorkspaceWindowGroup`. Only the selected
window's hosts are visible. They must not duplicate workspace state or
perform per-host persistence. Because the sidebar has a fixed width and the
state is shared, switching tabs or workspaces is visually indistinguishable
from one persistent sidebar.

The window's content size accounts for the sidebar, titlebar, and tab strip
so that Ghostty's `window-width` and `window-height` still describe the
terminal area.

Switching tabs or workspaces must preserve:

- Sidebar visibility.
- Sidebar width.
- Selected workspace.
- Scroll position where practical.

### 10.7 Tab strip and the hidden native tab bar

The native tab bar would show the tabs of every workspace, because they share
one tab group. It is therefore hidden: when AppKit adds the tab bar's titlebar
accessory view controller, Ghostty's `TerminalWindow` sets its `isHidden`,
which also collapses its space in the titlebar.

The tab strip replaces only the bar's presentation. Tabs remain native tab
windows, and tab creation, selection, closing, key equivalents, and
restoration continue to use the native tab group and Ghostty's existing code.
Features the native bar provided that the strip must reimplement over time:
drag-to-reorder, the tab context menu (including inline rename), tab colors,
and bell indicators.

### 10.8 AppKit constraints

These behaviors were verified with standalone AppKit experiments and shaped
the design above:

- Ordering out a tabbed window removes it from its tab group; hiding only the
  selected tab makes AppKit select and show another. A hidden tab group
  cannot be kept intact, so per-workspace tab groups cannot be parked while
  hidden.
- Moving tabs into and out of a tab group is expensive (roughly 30 ms per
  added tab and 70–140 ms per ordered-out tab in a debug build) and animates
  the native tab bar, including a deferred layout pass. Animation suppression
  reduces but does not remove the motion.
- `NSWindow.toggleTabBar(_:)` cannot hide the tab bar once a group has two or
  more tabs.
- A split-view sidebar with full-height layout in a full-size content window
  makes AppKit lay out titlebar content over the detail column only.

## 11. State restoration

Workspace persistence supplements Ghostty's existing terminal restoration. It
does not replace it.

Because every tab of an application window is in one native tab group,
Ghostty's existing restoration already restores all of a window's tabs
together, in order. Workspace restoration only needs to reassign them.

Persisted workspace state includes:

- Workspace IDs, names, and ordering.
- Workspace-window-group and workspace membership in each tab's existing
  `TerminalRestorableState`.
- Last-selected workspace and tab.

Sidebar visibility and width are runtime preferences only in the initial
release. They reset to application defaults when a new application window is
created or restored.

Workspace state should be stored in the application's normal Application
Support location using a versioned format.

On launch or window restoration:

1. Workspace-window-group and workspace metadata is loaded.
2. Ghostty restores each window's tab group, tabs, and split trees together
   with each tab's `TerminalWorkspaceMembership`.
3. Restored tabs are assigned to their workspace-window-group and workspace.
4. Tabs with missing or invalid membership are assigned to a default
   workspace.
5. Workspace and tab selection are restored, with safe fallbacks to the first
   available workspace and tab.

Corrupt, missing, or incompatible workspace metadata must never prevent
Ghostty from opening usable terminal windows.

Undoing a tab or window close should restore tabs into their original
workspace when it still exists.

## 12. Process and rendering behavior

Switching workspaces changes only which tab of the shared native tab group is
selected. It does not create or destroy terminal surfaces.

Background terminals continue running and receiving output. Rendering and
occlusion remain governed by Ghostty and AppKit's existing tab visibility
behavior: tabs of hidden workspaces are ordinary unselected tabs.

The initial implementation will not support creating a terminal surface in a
workspace without selecting that tab at least once. This avoids introducing a
new headless or off-screen surface lifecycle.

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

- Switching workspaces must cost no more than switching tabs. Workspace
  operations must not move tabs into or out of the native tab group.
- Sidebar and tab strip updates must not subscribe directly to terminal
  output streams.
- Tab titles and working directories should update through existing,
  event-driven Ghostty state (tab titles are observed from the tab window's
  title).
- Sidebar state changes should occur on the main actor.
- Structural coordination should happen only on events such as tab creation,
  closure, selection, movement, or restoration.
- The number of sidebar and tab strip instances must not multiply observation
  work for terminal content.

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

- Sidebar with workspace list, selection, and New Workspace button.
- Tab strip with titles, per-workspace ⌘1–⌘9 labels, selection, close on
  hover, and New Tab; hidden for a single tab.
- New Workspace (`Command-N`), Next/Previous Workspace
  (`Command-Option-]`/`[`), New Window moved to `Command-Shift-N`.
- Workspace switching via the shared tab group.
- Per-workspace tab navigation, move-tab, Close Other Tabs, and Close Tabs to
  the Right.
- Closing tabs and workspaces with in-workspace next-tab selection.
- Reconciliation with native tab groups: undo restores tabs into their
  original workspace; Merge All Windows merges workspace groups; Move Tab to
  New Window splits the tab into its own workspace group.
- New Workspace rolls back (closing the new terminal) if its tab cannot join
  the tab group, and is unavailable for windows that disallow tabbing.
- Collapsible sidebar: View → Hide/Show Sidebar (`Command-B`) and a titlebar
  sidebar button; state shared by the window group, not persisted.

Not yet implemented:

- Workspace rename, reorder, and close (with all-or-cancel confirmation).
- Moving tabs between workspaces; tab drag-to-reorder; dragging tabs out.
- Tab context menu, tab colors, and bell indicators in the tab strip.
- Adjustable sidebar width.
- Workspace commands as Ghostty actions.
- State restoration of workspaces.
- AppKit's Window-menu Show Next/Previous Tab and Show All Tabs, which still
  cycle through every workspace's tabs.
- Native fullscreen and non-native titlebar styles have not been verified.
- Accessibility review.
