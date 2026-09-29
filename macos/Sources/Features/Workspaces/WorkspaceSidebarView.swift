import SwiftUI

/// The workspace sidebar of a terminal window.
struct WorkspaceSidebarView: View {
    @ObservedObject var model: WorkspaceModel

    /// Performs the sidebar's actions. Weak, since the controller owns the
    /// window this is in.
    let controller: Weak<TerminalController>

    @ObservedObject var insets: WorkspaceSidebarInsets

    var body: some View {
        WorkspaceListView(model: model, controller: controller, topInset: insets.top)
    }
}

/// Where the sidebar's content starts, set by its split view controller.
/// It's the window's titlebar height, since the sidebar extends under it.
@MainActor
final class WorkspaceSidebarInsets: ObservableObject {
    @Published var top: CGFloat = 0
}

/// The workspace list, laid out by hand rather than with `List` so rows can
/// be dragged to reorder them, sliding aside like the tab strip's tabs. The
/// rows draw the selection from the model.
private struct WorkspaceListView: View {
    @ObservedObject var model: WorkspaceModel
    let controller: Weak<TerminalController>
    let topInset: CGFloat

    /// The workspace a tab dragged out of the tab strip would be dropped on.
    @State private var dropTarget: UUID?

    private var drag: WorkspaceModel.WorkspaceDrag? { model.workspaceDrag }

    private static let rowHeight: CGFloat = 32
    private static let slide = Animation.easeOut(duration: 0.15)

    // The metrics match the native sidebar list this replaced.

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                Text("Workspaces")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.tertiary)
                    .padding(.horizontal, 4)
                    .padding(.top, 6)
                    .padding(.bottom, 2)

                ForEach(Array(model.workspaces.enumerated()), id: \.element.id) { index, workspace in
                    let isRenaming = model.renaming == .workspace(workspace.id)
                    // Every workspace in the list has a tab, which names it
                    // unless it has a custom name.
                    if let tab = workspace.selectedTab {
                        WorkspaceRow(
                            workspace: workspace,
                            tab: tab,
                            isSelected: workspace.id == model.selectedWorkspaceID,
                            isDropTarget: workspace.id == dropTarget,
                            isRenaming: isRenaming,
                            select: { controller.value?.selectWorkspace(workspace.id) },
                            endRenaming: { controller.value?.endRenamingWorkspace(workspace.id, name: $0) })
                            .frame(height: Self.rowHeight)
                            .offset(y: offset(at: index))
                            // The dragged row tracks the pointer; the others slide.
                            .animation(drag?.id == workspace.id ? nil : Self.slide, value: offset(at: index))
                            .zIndex(drag?.id == workspace.id ? 1 : 0)
                            // Clicks in the name field while renaming position the cursor.
                            .gesture(
                                DragGesture(minimumDistance: 0).onChanged { _ in beginDrag(workspace.id) },
                                including: isRenaming ? .subviews : .all)
                            .contextMenu { menu(for: workspace) }
                            .onDrop(
                                of: [.ghosttyWorkspaceTab],
                                delegate: TabDropDelegate(
                                    workspace: workspace.id,
                                    controller: controller,
                                    target: $dropTarget))
                    }
                }
            }
            .padding(.horizontal, 10)
            .padding(.top, topInset)
        }
        .ignoresSafeArea(.container, edges: .top)
    }

    /// The workspace's context menu. It acts on the workspace, which it
    /// doesn't select.
    @ViewBuilder
    private func menu(for workspace: Workspace) -> some View {
        Button("New Tab") {
            controller.value?.newTab(inWorkspace: workspace.id)
        }
        Button("Rename Workspace…") {
            controller.value?.beginRenamingWorkspace(workspace.id)
        }
        Divider()
        Button("Close Workspace") {
            controller.value?.close(workspace: workspace.id)
        }
        Button("Close Other Workspaces") {
            controller.value?.closeOtherWorkspaces(than: workspace.id)
        }
        .disabled(model.workspaces.count < 2)
    }

    // MARK: Reordering

    // Pressing a row selects its workspace right away, like a tab, so a
    // click is just a drag that doesn't go anywhere. Dragging moves the row
    // with the pointer while the rows it passes slide into its place, and
    // the workspaces reorder on release. Double-clicking renames it.
    //
    // The rest of the drag is followed by `PressDragTracker` and drawn from
    // the model's `workspaceDrag`. The row is found by ID each time, since
    // workspaces can come and go during the drag (e.g. when a last terminal
    // exits).

    private func beginDrag(_ id: UUID) {
        // The gesture also reports every move; only the press begins a drag.
        guard let press = NSApp.currentEvent, press.type == .leftMouseDown else { return }

        controller.value?.selectWorkspace(id)
        if press.clickCount == 2 {
            controller.value?.beginRenamingWorkspace(id)
            return
        }

        model.workspaceDrag = .init(id: id)

        let model = model
        PressDragTracker.begin(from: press) { [weak model] _, translation in
            guard let model else { return false }
            guard let from = model.workspaceIndex(of: id) else {
                // The workspace is gone.
                model.workspaceDrag = nil
                return false
            }
            model.workspaceDrag = .init(id: id, offset: Self.slots(of: model).clamped(translation.height, from: from))
            return true
        } released: { [weak model] translation in
            guard let model else { return }
            withAnimation(Self.slide) {
                if let from = model.workspaceIndex(of: id) {
                    let slots = Self.slots(of: model)
                    let offset = slots.clamped(translation.height, from: from)
                    model.moveWorkspace(id, to: slots.destination(from: from, offset: offset))
                }
                model.workspaceDrag = nil
            }
        } cancelled: { [weak model] in
            withAnimation(Self.slide) { model?.workspaceDrag = nil }
        }
    }

    private static func slots(of model: WorkspaceModel) -> ReorderSlots {
        ReorderSlots(count: model.workspaces.count, stride: rowHeight)
    }

    /// How far the row is drawn from its slot during a drag.
    private func offset(at index: Int) -> CGFloat {
        guard let drag, let from = model.workspaceIndex(of: drag.id) else { return 0 }
        return Self.slots(of: model).offset(of: index, draggingFrom: from, by: drag.offset)
    }
}

/// Accepts a tab dragged out of a tab strip, this window's or another's,
/// moving it to the row's workspace. Dropped on its own workspace, it goes
/// back where it was.
private struct TabDropDelegate: DropDelegate {
    let workspace: UUID
    let controller: Weak<TerminalController>
    @Binding var target: UUID?

    func validateDrop(info: DropInfo) -> Bool {
        WorkspaceTabDragOut.dragged != nil
    }

    func dropEntered(info: DropInfo) {
        target = workspace
    }

    func dropExited(info: DropInfo) {
        if target == workspace { target = nil }
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        DropProposal(operation: .move)
    }

    func performDrop(info: DropInfo) -> Bool {
        target = nil
        guard let (tab, source) = WorkspaceTabDragOut.dragged, let controller = controller.value else { return false }
        if source === controller {
            controller.moveTab(tab, toWorkspace: workspace)
        } else {
            controller.receive(tab, from: source, inWorkspace: workspace)
        }
        return true
    }
}

/// A workspace row, styled like a sidebar list's own selection: highlighted
/// edge to edge within the sidebar's 10pt inset, with the name in bold.
private struct WorkspaceRow: View {
    let workspace: Workspace

    /// The workspace's current tab, observed since its title names the
    /// workspace without a custom name.
    @ObservedObject var tab: TerminalTab

    let isSelected: Bool
    let isDropTarget: Bool
    let isRenaming: Bool
    let select: () -> Void
    let endRenaming: (_ name: String?) -> Void

    private var name: String { workspace.name }

    var body: some View {
        HStack(spacing: 6.5) {
            Image(systemName: "rectangle.stack")
                .imageScale(.large)
                .foregroundStyle(isDropTarget ? Color.white : Color.accentColor)
            if isRenaming {
                InlineTitleField("Workspace Name", title: name, end: endRenaming)
                    .fontWeight(.bold)
            } else {
                Text(name)
                    .fontWeight(isSelected ? .bold : .regular)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
        }
        // A drop target is filled with the accent color, like Finder's.
        .foregroundStyle(isDropTarget ? Color.white : Color.primary)
        .padding(.horizontal, 8.5)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .background {
            if isDropTarget {
                RoundedRectangle(cornerRadius: 8).fill(Color.accentColor)
            } else if isSelected {
                RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.13))
            }
        }
        .contentShape(Rectangle())
        // One button for VoiceOver, except while renaming, when the name
        // field must stay reachable.
        .accessibilityElement(children: isRenaming ? .contain : .combine)
        .accessibilityAddTraits(isRenaming ? [] : isSelected ? [.isButton, .isSelected] : .isButton)
        // Pointer selection happens in the list's drag gesture, on press.
        .accessibilityAction { select() }
    }
}
