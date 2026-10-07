import AppKit
import SwiftUI

/// A tooltip's text, and the least width it's shown at.
struct HoverTooltip: Equatable {
    let text: String
    let minWidth: CGFloat
}

/// Coordinates the tooltips in one workspace window. AppKit's native help
/// tags don't expose their delay and can restart their timer when SwiftUI
/// replaces hovered content, so these tooltips use stable tracking views and
/// an explicitly shared warm state.
@MainActor
final class HoverTooltipCoordinator {
    private static let initialDelay: Duration = .milliseconds(400)
    private static let warmDelay: Duration = .milliseconds(75)
    private static let warmGrace: Duration = .milliseconds(300)

    private final class Target {
        let id: UUID
        weak var view: NSView?
        var tooltip: HoverTooltip
        let order: UInt64

        init(id: UUID, view: NSView, tooltip: HoverTooltip, order: UInt64) {
            self.id = id
            self.view = view
            self.tooltip = tooltip
            self.order = order
        }
    }

    private var targets: [UUID: Target] = [:]
    private var nextOrder: UInt64 = 0
    private var activeID: UUID?
    private var displayedID: UUID?
    private var isWarm = false
    private var showTask: Task<Void, Never>?
    private var coolTask: Task<Void, Never>?
    private var eventMonitor: Any?
    private let panel = HoverTooltipPanel()

    deinit {
        if let eventMonitor { NSEvent.removeMonitor(eventMonitor) }
    }

    func entered(id: UUID, view: NSView, tooltip: HoverTooltip) {
        nextOrder &+= 1
        targets[id] = Target(id: id, view: view, tooltip: tooltip, order: nextOrder)
        coolTask?.cancel()
        coolTask = nil
        installEventMonitor()
        activate(id)
    }

    func updated(id: UUID, view: NSView, tooltip: HoverTooltip) {
        guard let target = targets[id] else { return }
        target.view = view
        target.tooltip = tooltip
        if displayedID == id { panel.update(tooltip) }
    }

    func exited(id: UUID) {
        targets[id] = nil
        guard activeID == id else { return }

        if let next = targets.values.max(by: { $0.order < $1.order }) {
            activate(next.id)
        } else {
            activeID = nil
            showTask?.cancel()
            showTask = nil
            hidePanel()
            removeEventMonitor()
            scheduleCooling()
        }
    }

    private func activate(_ id: UUID) {
        guard let target = targets[id] else { return }
        activeID = id
        showTask?.cancel()
        hidePanel()

        let delay = isWarm ? Self.warmDelay : Self.initialDelay
        showTask = Task { @MainActor [weak self, weak target] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled,
                  let self,
                  let target,
                  self.activeID == id,
                  self.targets[id] === target,
                  let view = target.view,
                  view.window?.isVisible == true
            else { return }

            self.displayedID = id
            self.isWarm = true
            self.panel.show(target.tooltip, below: view)
        }
    }

    private func hidePanel() {
        displayedID = nil
        panel.hide()
    }

    private func scheduleCooling() {
        guard isWarm else { return }
        coolTask?.cancel()
        coolTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: Self.warmGrace)
            guard !Task.isCancelled, let self, self.targets.isEmpty else { return }
            self.isWarm = false
            self.coolTask = nil
        }
    }

    private func installEventMonitor() {
        guard eventMonitor == nil else { return }
        eventMonitor = NSEvent.addLocalMonitorForEvents(
            matching: [
                .leftMouseDown, .rightMouseDown, .otherMouseDown,
                .leftMouseDragged, .rightMouseDragged, .otherMouseDragged,
                .scrollWheel,
            ]) { [weak self] event in
                MainActor.assumeIsolated {
                    guard let self,
                          self.targets.values.contains(where: { $0.view?.window === event.window })
                    else { return }
                    self.cancelInteraction()
                }
                return event
            }
    }

    private func removeEventMonitor() {
        guard let eventMonitor else { return }
        NSEvent.removeMonitor(eventMonitor)
        self.eventMonitor = nil
    }

    private func cancelInteraction() {
        targets.removeAll()
        activeID = nil
        showTask?.cancel()
        showTask = nil
        coolTask?.cancel()
        coolTask = nil
        hidePanel()
        removeEventMonitor()
        isWarm = false
    }
}

private struct HoverTooltipCoordinatorKey: EnvironmentKey {
    static let defaultValue: HoverTooltipCoordinator? = nil
}

private extension EnvironmentValues {
    var hoverTooltipCoordinator: HoverTooltipCoordinator? {
        get { self[HoverTooltipCoordinatorKey.self] }
        set { self[HoverTooltipCoordinatorKey.self] = newValue }
    }
}

private struct HoverTooltipModifier: ViewModifier {
    @Environment(\.hoverTooltipCoordinator) private var coordinator
    let tooltip: HoverTooltip

    @ViewBuilder
    func body(content: Content) -> some View {
        if let coordinator {
            content
                .overlay {
                    HoverTooltipTrackingRegion(tooltip: tooltip, coordinator: coordinator)
                }
                .accessibilityHint(tooltip.text)
        } else {
            content.help(tooltip.text)
        }
    }
}

extension View {
    /// Shares one tooltip coordinator with this view hierarchy.
    func coordinatedHoverTooltips(using coordinator: HoverTooltipCoordinator) -> some View {
        environment(\.hoverTooltipCoordinator, coordinator)
    }

    /// Shows help text with the workspace window's shared tooltip timing,
    /// centered below the view and at least `minWidth` wide, so even a
    /// short text like "~" stands out.
    func hoverTooltip(_ text: String, minWidth: CGFloat = 40) -> some View {
        modifier(HoverTooltipModifier(tooltip: HoverTooltip(text: text, minWidth: minWidth)))
    }
}

private struct HoverTooltipTrackingRegion: NSViewRepresentable {
    let tooltip: HoverTooltip
    let coordinator: HoverTooltipCoordinator

    func makeNSView(context: Context) -> HoverTooltipTrackingView {
        let view = HoverTooltipTrackingView(tooltip: tooltip)
        view.coordinator = coordinator
        return view
    }

    func updateNSView(_ view: HoverTooltipTrackingView, context: Context) {
        if view.isInside, view.coordinator !== coordinator {
            view.coordinator?.exited(id: view.id)
            coordinator.entered(id: view.id, view: view, tooltip: tooltip)
        }
        view.tooltip = tooltip
        view.coordinator = coordinator
        coordinator.updated(id: view.id, view: view, tooltip: tooltip)
    }

    static func dismantleNSView(_ view: HoverTooltipTrackingView, coordinator: ()) {
        if view.isInside { view.coordinator?.exited(id: view.id) }
    }
}

private final class HoverTooltipTrackingView: NSView {
    let id = UUID()
    weak var coordinator: HoverTooltipCoordinator?
    var tooltip: HoverTooltip
    fileprivate var isInside = false

    init(tooltip: HoverTooltip) {
        self.tooltip = tooltip
        super.init(frame: .zero)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func updateTrackingAreas() {
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(
            rect: .zero,
            options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
            owner: self,
            userInfo: nil))
        super.updateTrackingAreas()
    }

    override func mouseEntered(with event: NSEvent) {
        isInside = true
        coordinator?.entered(id: id, view: self, tooltip: tooltip)
    }

    override func mouseExited(with event: NSEvent) {
        isInside = false
        coordinator?.exited(id: id)
    }
}

/// A nonactivating, mouse-transparent panel styled like an AppKit tooltip.
/// It's centered below the view it describes, rather than placed by the
/// pointer, so it lines up with that view wherever it was entered.
@MainActor
private final class HoverTooltipPanel: NSPanel {
    private let effect = NSVisualEffectView()
    private let label = NSTextField(labelWithString: "")

    /// The tooltip shown, and the view it's shown below.
    private var tooltip: HoverTooltip?
    private weak var anchor: NSView?

    private lazy var minWidthConstraint = effect.widthAnchor.constraint(greaterThanOrEqualToConstant: 0)

    /// The space between the tooltip and its view.
    private static let gap: CGFloat = 4

    init() {
        super.init(
            contentRect: .zero,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false)

        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        ignoresMouseEvents = true
        hidesOnDeactivate = true
        isReleasedWhenClosed = false
        animationBehavior = .none
        collectionBehavior = [.transient, .ignoresCycle]

        effect.material = .toolTip
        effect.blendingMode = .behindWindow
        effect.state = .active
        effect.wantsLayer = true
        effect.layer?.cornerRadius = 4
        effect.layer?.borderWidth = 0.5
        effect.layer?.borderColor = NSColor.separatorColor.withAlphaComponent(0.45).cgColor

        label.font = .toolTipsFont(ofSize: NSFont.smallSystemFontSize)
        label.textColor = .labelColor
        label.maximumNumberOfLines = 0
        label.lineBreakMode = .byWordWrapping
        label.alignment = .natural
        label.translatesAutoresizingMaskIntoConstraints = false
        effect.addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: effect.leadingAnchor, constant: 6),
            label.trailingAnchor.constraint(equalTo: effect.trailingAnchor, constant: -6),
            label.topAnchor.constraint(equalTo: effect.topAnchor, constant: 3),
            label.bottomAnchor.constraint(equalTo: effect.bottomAnchor, constant: -3),
            label.widthAnchor.constraint(lessThanOrEqualToConstant: 480),
            minWidthConstraint,
        ])
        contentView = effect
    }

    func show(_ tooltip: HoverTooltip, below view: NSView) {
        guard let parent = view.window else { return }
        anchor = view
        update(tooltip)
        place()

        if self.parent !== parent {
            self.parent?.removeChildWindow(self)
            parent.addChildWindow(self, ordered: .above)
        }
        orderFront(nil)
    }

    func update(_ tooltip: HoverTooltip) {
        guard self.tooltip != tooltip else { return }
        self.tooltip = tooltip
        label.stringValue = tooltip.text
        minWidthConstraint.constant = tooltip.minWidth
        effect.needsLayout = true
        effect.layoutSubtreeIfNeeded()
        if isVisible { place() }
    }

    func hide() {
        anchor = nil
        parent?.removeChildWindow(self)
        orderOut(nil)
    }

    /// Sizes the tooltip to its text and centers it below its view, or
    /// above it when there's no room below, kept on the view's screen.
    private func place() {
        guard let anchor, let window = anchor.window else { return }
        let size = effect.fittingSize
        let rect = window.convertToScreen(anchor.convert(anchor.bounds, to: nil))
        let visible = (window.screen ?? NSScreen.main)?.visibleFrame ?? .zero
        var origin = NSPoint(x: rect.midX - size.width / 2, y: rect.minY - Self.gap - size.height)
        origin.x = min(max(origin.x, visible.minX), visible.maxX - size.width)
        if origin.y < visible.minY { origin.y = rect.maxY + Self.gap }
        setFrame(NSRect(origin: origin, size: size), display: true)
    }
}
