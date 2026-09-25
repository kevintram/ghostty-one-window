# Ghostty Workspaces for macOS

Status: Draft 0.4  
Platform: macOS  
Project type: Thin fork of Ghostty's native macOS application

## 1. Summary

This project adds lightweight workspace organization to Ghostty on macOS.

A workspace is a named group of terminal tabs. A window can contain multiple
workspaces, and each workspace can contain multiple tabs. The user selects a
workspace from a sidebar, while the selected workspace's tabs remain in
Ghostty's native macOS tab bar at the top of the window. The project retains
Ghostty's existing terminal implementation, native tab lifecycle, split panes,
renderer, configuration, and macOS integrations.

The project is intentionally narrow. It is not intended to become an IDE,
terminal multiplexer, agent dashboard, browser, file manager, or general
automation platform.

## 2. Goals

- Add multiple named workspaces to a Ghostty window.
- Let each workspace own an ordered set of Ghostty tabs.
- Present workspaces in a native macOS sidebar.
- Keep each workspace's tabs in Ghostty's native macOS tab bar.
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

## 4. Terminology

### Application window

A user-visible terminal window context. Each application window owns an
independent `WorkspaceWindowGroup` and shows one workspace at a time.

Internally, Ghostty uses native AppKit tabbing, where each tab is represented
by an `NSWindow` in an `NSWindowTabGroup`. This specification uses
"application window" or "logical window" for the single window the user
perceives while moving between tabs and workspaces. Internally, switching
workspaces may exchange one native tab group for another at the same frame;
it does not require all workspaces to share one physical `NSWindow`.

### Workspace window group

The application-level coordinator that provides the workspace layer AppKit
does not provide. It owns one stable workspace bar, an ordered set of
workspaces, the selected workspace, and the shared frame and presentation state
for the logical application window.

A `WorkspaceWindowGroup` is conceptually one level above
`NSWindowTabGroup`:

```text
WorkspaceWindowGroup
├── Workspace bar
└── Selected Workspace
    └── NSWindowTabGroup
        └── Ghostty tabs
```

### Workspace

A named, ordered group of tabs within one application window. A workspace is
organizational metadata; it does not own a separate terminal runtime.

### Tab

An existing Ghostty terminal tab backed by Ghostty's current
`TerminalController` and native AppKit tab implementation. A tab may contain
one or more split terminal surfaces.

### Pane

A Ghostty terminal surface within a tab's split tree.

## 5. Product model

The hierarchy is:

```text
Application
└── WorkspaceWindowGroup[]
    ├── Workspace bar
    └── Workspace[]
        └── NSWindowTabGroup
            └── Tab[]
                └── Pane[]
```

Each workspace window group has at least one workspace. Each workspace has at
least one tab while it exists. Each tab has at least one terminal pane while
it exists.

Each workspace is backed by its own native `NSWindowTabGroup`. Only the
selected workspace's tab group is visible for a given workspace window group.
Its tabs appear in the normal macOS tab bar at the top of the window.

Switching workspaces hides the current workspace's native tab group and shows
the selected workspace's native tab group in the same logical window position.
It does not change terminal ownership or process lifetime.

## 6. Core user experience

### 6.1 Sidebar

The sidebar is the workspace bar for a `WorkspaceWindowGroup`. It appears on
the left side of the logical application window and contains:

- An ordered list of workspaces.
- A clear selected state for the active workspace.
- Controls or contextual actions for creating, renaming, reordering, and
  closing workspaces.

Tabs do not appear in the sidebar. The active workspace's tabs appear in the
native macOS tab bar at the top of the window.

The workspace bar should use standard macOS appearance and interaction
patterns. It is stable application chrome: switching tabs or workspaces must
not visibly recreate, move, resize, or reset it.

The workspace bar can be shown or hidden. Its width, visibility, selection,
and ordering belong to the `WorkspaceWindowGroup`, not to an individual tab or
workspace.

### 6.2 Workspace selection

Selecting a workspace hides the currently visible native tab group and shows
the selected workspace's native tab group. The newly visible group uses its
last-selected tab. If that tab is no longer available, its first available tab
is selected.

The incoming tab group should adopt the outgoing logical window's frame so
that workspace switching feels like changing content within one window rather
than opening another window.

Switching workspaces does not terminate, recreate, suspend, or reset any
terminal process. Background terminal output continues to be processed using
Ghostty's existing behavior.

### 6.3 Tab selection

Selecting a tab uses Ghostty's existing native tab bar and tab-selection path.
The selected tab becomes the active native window in the current workspace's
tab group.

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

The proposed default commands are:

| Command | Default shortcut | Behavior |
| --- | --- | --- |
| New Window | `Command-Shift-N` | Create a new application window with one workspace and one tab. |
| New Tab | `Command-T` | Create a tab in the current workspace. |
| New Workspace | `Command-N` | Create and select a workspace containing one new tab. |
| Close Tab | `Command-W` | Close the active tab using Ghostty's existing confirmation behavior. |
| Toggle Sidebar | `Command-B` | Show or hide the workspace sidebar. |
| Next Tab | `Command-Shift-]` | Select the next tab within the current workspace. |
| Previous Tab | `Command-Shift-[` | Select the previous tab within the current workspace. |
| Next Workspace | `Command-Option-]` | Select the next workspace in display order. |
| Previous Workspace | `Command-Option-[` | Select the previous workspace in display order. |

Shortcut assignments remain subject to Ghostty's configuration and conflict
handling. The final implementation should use Ghostty's action system rather
than introducing an unrelated shortcut system.

## 8. Workspace lifecycle

### Creating a workspace

Creating a workspace:

1. Creates a workspace with a stable UUID and default name.
2. Captures the focused pane's current working directory from the active tab.
3. Creates one Ghostty tab using the existing new-tab path, with the captured
   working directory as its initial working directory.
4. Assigns the tab to the new workspace.
5. Selects the workspace and its new tab.

If the focused pane does not report a working directory, creation falls back
to Ghostty's normal new-terminal working-directory behavior.

Default workspace naming is initially `Workspace 1`, `Workspace 2`, and so on
within an application window. Renaming a workspace does not change terminal
titles, working directories, or commands.

Workspace names do not need to be unique within an application window.

### Closing a workspace

Closing a workspace closes all tabs assigned to it.

Ghostty's existing running-process confirmation behavior must be respected.
The operation should be all-or-cancel from the user's perspective: if closing
requires confirmation, the user confirms closing the workspace rather than
receiving a confusing sequence of unrelated per-tab prompts.

If the last workspace in an application window is closed, the application
window closes.

### Reordering workspaces

Workspaces can be reordered in the sidebar. Reordering affects display and
workspace-navigation order only.

### Moving tabs between workspaces

A tab can be reassigned from one workspace to another within the same
application window. Its native tab window moves from the source workspace's
`NSWindowTabGroup` to the destination workspace's group. The terminal process
and split tree remain unchanged.

Dragging tabs between workspaces is desirable but may be deferred if it adds
substantial complexity. A context-menu action is an acceptable initial
interaction.

Dragging a native tab out of its logical application window creates a one-tab
workspace in the destination window's `WorkspaceWindowGroup`. If AppKit
creates a new destination window, the application creates a new
`WorkspaceWindowGroup` for it. The new workspace uses the source workspace's
name but receives its own workspace UUID; it is not linked to the source
workspace. The terminal process and split tree continue without restarting.

If the dragged tab was the source workspace's final tab, the now-empty source
workspace is automatically removed.

## 9. Tab lifecycle

### Creating a tab

A new tab is assigned to the active workspace. Its creation, terminal
configuration, working directory inheritance, and initial focus should follow
Ghostty's existing behavior.

### Closing a tab

Closing a tab uses Ghostty's existing close and process-confirmation behavior.
The tab is removed from its workspace only after closure succeeds.

If a workspace's last tab is closed, the workspace is removed. If that was the
last workspace, the application window closes.

### Reordering tabs

Tab order is maintained by the workspace's native macOS tab bar. Reordering a
native tab updates the persisted tab order for that workspace.

### Splits

Ghostty's existing split-pane behavior remains unchanged. Workspaces group
tabs, not individual panes.

## 10. Technical architecture

### 10.1 Upstream strategy

The project will be based on a pinned fork of Ghostty rather than on a
separately installed Ghostty application.

The implementation should favor:

- New, isolated source files for workspace functionality.
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
- One `NSWindowTabGroup` manages the native tabs belonging to each workspace.
- Ghostty's existing app object manages global terminal configuration and
  callbacks.

Workspace code adds organization and navigation around those objects.

### 10.3 Proposed workspace types

The exact names may change, but the conceptual types are:

```swift
struct WorkspaceRecord: Identifiable, Codable {
    let id: UUID
    var name: String
    var selectedTabIndex: Int?
}

@MainActor
final class WorkspaceWindowGroup: ObservableObject {
    let id: UUID
    @Published var workspaces: [WorkspaceRecord]
    @Published var selectedWorkspaceID: UUID
    @Published var sidebarVisibility: SidebarVisibility
    @Published var sidebarWidth: CGFloat

    // Runtime-only mapping. Not serialized.
    var workspaceTabGroups: [UUID: NSWindowTabGroup]
}
```

Runtime references to `TerminalController`, `NSWindow`, and Ghostty surfaces
must not be stored in the serialized records.

### 10.4 Tab workspace membership

Tabs do not receive a new persistent ID. Ghostty continues to identify a live
tab through its existing `NSWindow` and `TerminalController`, while
`NSWindowTabGroup.windows` provides native tab ordering.

Each `TerminalController` instead carries the minimum information needed to
place its window into the correct workspace:

```swift
struct TerminalWorkspaceMembership: Codable {
    var workspaceWindowGroupID: UUID
    var workspaceID: UUID
    var tabIndex: Int
}
```

This membership is encoded directly in the tab's existing
`TerminalRestorableState`. Reordering or moving a tab updates its membership
and invalidates the affected windows' restorable state.

The selected tab for a workspace is represented at runtime by
`NSWindowTabGroup.selectedWindow`. `WorkspaceRecord.selectedTabIndex` provides
a restoration fallback without introducing a persistent tab identity.

### 10.5 Workspace registry

A main-thread registry associates:

- Native tab windows with terminal controllers and their workspace membership.
- Native tab groups with their owning workspaces.
- Workspaces with their owning `WorkspaceWindowGroup`.

The registry must handle:

- New tab creation.
- Tab closure.
- Native tab selection changes.
- Window restoration.
- Tab detachment or movement performed through macOS UI.
- Window closure.

The registry must degrade safely when AppKit changes a tab group unexpectedly.
An unrecognized live tab is placed in the active workspace rather than being
discarded or closed.

### 10.6 Stable workspace bar

Each `WorkspaceWindowGroup` presents one stable workspace bar beside the
terminal. Tabs remain in the selected workspace's normal macOS tab bar above
the terminal.

The workspace bar is shared application state and chrome. Its model and
identity belong to the `WorkspaceWindowGroup`; they must not be owned by an
individual workspace, tab, or terminal controller.

AppKit implements every native window tab as an `NSWindow`, and it does not
expose a group-level content view beside those windows. A thin implementation
may therefore place a lightweight workspace-bar host in each member window,
with every host rendering the same `WorkspaceWindowGroup`. Only the selected
window's host is visible.

This hosting detail is acceptable only if it is visually indistinguishable
from one persistent sidebar. It must not duplicate workspace state, perform
per-host persistence, or reset local UI state during tab or workspace
selection. The implementation may instead reparent a single host if an
architectural spike proves that approach reliable.

The workspace bar should be inserted around the existing terminal content
using a native split container. The existing terminal view should remain as
intact as possible.

Switching tabs or workspaces must preserve:

- Sidebar visibility.
- Sidebar width.
- Selected workspace.
- Scroll position where practical.

### 10.7 Native tab bar

The native macOS tab bar remains visible and is the primary tab interface. It
shows only the tabs in the selected workspace because every workspace owns a
separate `NSWindowTabGroup`.

The project should preserve Ghostty's existing native tab appearance and
behavior, including tab creation, selection, reordering, titles, and close
controls. Workspace functionality must not replace the native tab bar with a
custom tab implementation.

## 11. State restoration

Workspace persistence supplements Ghostty's existing terminal restoration. It
does not replace it.

Persisted workspace state includes:

- Workspace IDs, names, and ordering.
- Workspace-window-group and workspace membership in each tab's existing
  `TerminalRestorableState`.
- A per-workspace tab index in each tab's restoration state.
- Last-selected workspace and tab.

Sidebar visibility and width are runtime preferences only in the initial
release. They reset to application defaults when a new application window is
created or restored.

Workspace state should be stored in the application's normal Application
Support location using a versioned format.

On launch or window restoration:

1. Workspace-window-group and workspace metadata is loaded.
2. Ghostty restores each window, tab, and split tree together with that tab's
   `TerminalWorkspaceMembership`.
3. Restored windows are collected by workspace-window-group ID and workspace
   ID.
4. Each workspace's windows are ordered by their stored tab index and formed
   into its native `NSWindowTabGroup`.
5. Tabs with missing or invalid membership are assigned to a default workspace.
6. Workspace and tab selection are restored, with safe fallbacks to the first
   available workspace and tab.

Corrupt, missing, or incompatible workspace metadata must never prevent
Ghostty from opening usable terminal windows.

## 12. Process and rendering behavior

Switching workspaces changes only which native tab group is presented. It does
not create or destroy terminal surfaces.

Background terminals continue running and receiving output. Rendering and
occlusion remain governed by Ghostty and AppKit's existing tab/window
visibility behavior.

The initial implementation will not support creating a terminal surface in a
workspace without selecting that tab at least once. This avoids introducing a
new headless or off-screen surface lifecycle.

## 13. Error handling and recovery

The workspace layer must favor preserving terminals over preserving metadata.

- If a workspace record references a missing tab, remove the reference.
- If a live tab has no workspace, assign it to the active or default workspace.
- If a selected workspace or tab is missing, choose the first valid option.
- If workspace persistence fails, continue with an in-memory default
  workspace.
- If sidebar construction fails, the terminal content should remain usable.
- Workspace operations must never silently terminate terminal processes.

## 14. Performance expectations

The workspace feature should add negligible overhead to normal terminal
rendering.

- Sidebar updates must not subscribe directly to terminal output streams.
- Tab titles and working directories should update through existing,
  event-driven Ghostty state.
- Sidebar state changes should occur on the main actor.
- Structural coordination should happen only on events such as tab creation,
  closure, movement, or restoration.
- The number of sidebar view instances must not multiply observation work for
  terminal content.

## 15. Accessibility

All workspace and tab rows must expose appropriate accessibility labels,
selection state, and actions.

Keyboard-only users must be able to:

- Focus the sidebar.
- Move between workspaces and tabs.
- Create, rename, and close workspaces.
- Create, move, and close tabs.
- Return focus to the active terminal.

Adding the sidebar must not interfere with VoiceOver access to Ghostty's
existing terminal surfaces.