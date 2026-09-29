/// An UndoManager subclass that supports registering undo operations that automatically expire after a specified duration.
///
/// This class extends the standard UndoManager to add time-based expiration for undo operations.
/// When an undo operation expires, it is automatically removed from the undo stack and cannot be invoked.
///
/// Example usage:
/// ```swift
/// let undoManager = ExpiringUndoManager()
/// undoManager.registerUndo(withTarget: myObject, expiresAfter: .seconds(30)) { target in
///     // Undo operation that expires after 30 seconds
///     target.restorePreviousState()
/// }
/// ```
class ExpiringUndoManager: UndoManager {
    /// The set of expiring targets so we can properly clean them up when removeAllActions
    /// is called with the real target.
    private lazy var expiringTargets: Set<ExpiringTarget> = []

    /// The closes that `reopenLastClosed` can undo, oldest first: each is the
    /// undo actions its close registered, in order. A close stays here while
    /// all of its actions can still be undone.
    private var closes: [[ReopenAction]] = []

    /// The undo actions of the close being recorded, if one is (see
    /// `recordClose`).
    private var recordingClose: [ReopenAction]?

    /// Registers an undo operation that automatically expires after the specified duration.
    ///
    /// - Parameters:
    ///   - target: The target object for the undo operation. The undo operation will be removed
    ///             if this object is deallocated before the operation is invoked.
    ///   - duration: The duration after which the undo operation should expire and be removed from the undo stack.
    ///   - handler: The closure to execute when the undo operation is invoked. The closure receives
    ///              the target object as its parameter.
    func registerUndo<TargetType: AnyObject>(
        withTarget target: TargetType,
        expiresAfter duration: Duration,
        handler: @escaping (TargetType) -> Void
    ) {
        // Ignore instantly expiring undos
        guard duration.timeInterval > 0 else { return }

        // Ignore when undo registration is disabled. UndoManager still lets
        // registration happen then cancels later but I was seeing some
        // weird behavior with this so let's just guard on it.
        guard self.isUndoRegistrationEnabled else { return }

        let expiringTarget = ExpiringTarget(
            target,
            expiresAfter: duration,
            in: self)
        expiringTargets.insert(expiringTarget)

        super.registerUndo(withTarget: expiringTarget) { [weak self] expiringTarget in
            self?.expiringTargets.remove(expiringTarget)
            self?.pruneCloses()
            guard let target = expiringTarget.target as? TargetType else { return }
            handler(target)
        }

        // What an undo registers is a redo, not part of the close.
        if recordingClose != nil, !isUndoing {
            recordingClose?.append(ReopenAction(target: expiringTarget) {
                guard let target = expiringTarget.target as? TargetType else { return }
                handler(target)
            })
        }
    }

    /// Runs `body`, which closes something (a split, tab, workspace or
    /// window) and registers the undo that brings it back, so that
    /// `reopenLastClosed` can undo it later even under newer actions. A close
    /// within another (e.g. each tab of a closing workspace) is part of it.
    func recordClose(_ body: () -> Void) {
        guard recordingClose == nil else { return body() }
        recordingClose = []
        defer { recordingClose = nil }
        body()
        if let actions = recordingClose, !actions.isEmpty {
            closes.append(actions)
        }
    }

    /// Whether there's a close `reopenLastClosed` can undo.
    var canReopenClosed: Bool {
        closes.contains(where: canReopen)
    }

    /// Undoes the most recent close that can still be undone, even if newer
    /// actions are above it on the undo stack, and takes its undo off the
    /// stack. What its undo registers (e.g. redoing the close) becomes
    /// undoable. Returns false if there's no close to reopen.
    @discardableResult
    func reopenLastClosed() -> Bool {
        pruneCloses()
        guard let actions = closes.popLast() else { return false }

        actions.forEach { removeAllActions(withTarget: $0.target) }

        // In reverse, as undo runs a group. What they register is grouped by
        // the event that asked for the reopen, like any action's.
        actions.reversed().forEach { $0.perform() }
        return true
    }

    /// Drops the closes that can no longer be reopened, as soon as any of
    /// their undo actions is undone, removed or expired. Their actions hold
    /// what the close keeps alive (e.g. a tab's terminals), which must end
    /// when the undo does.
    private func pruneCloses() {
        closes.removeAll { !canReopen($0) }
    }

    /// Whether every undo action of a close is still on the undo stack, with
    /// its target.
    private func canReopen(_ actions: [ReopenAction]) -> Bool {
        actions.allSatisfy { expiringTargets.contains($0.target) && $0.target.target != nil }
    }

    /// Removes all undo and redo operations from the undo manager.
    ///
    /// This override ensures that all expiring targets are also cleared when
    /// the undo manager is reset.
    override func removeAllActions() {
        super.removeAllActions()
        expiringTargets = []
        closes = []
    }

    /// Removes all undo and redo operations involving the specified target.
    ///
    /// This override ensures that when actions are removed for a target, any associated
    /// expiring targets are also properly cleaned up.
    ///
    /// - Parameter target: The target object whose actions should be removed.
    override func removeAllActions(withTarget target: Any) {
        // Call super to handle standard removal
        super.removeAllActions(withTarget: target)

        // If the target is an expiring target, remove it. That's also how
        // an undo action expires.
        if let expiring = target as? ExpiringTarget {
            expiringTargets.remove(expiring)
        } else {
            // Find and remove any ExpiringTarget instances that wrap this target.
            expiringTargets
                .filter { $0.target == nil || $0.target === (target as AnyObject) }
                .forEach {
                    // Technically they'll always expire when they get deinitialized
                    // but we want to make sure it happens right now.
                    $0.expire()
                    expiringTargets.remove($0)
                }
        }

        pruneCloses()
    }
}

/// An undo action of a close, to run it outside the undo stack (see
/// `ExpiringUndoManager.reopenLastClosed`).
private struct ReopenAction {
    let target: ExpiringTarget
    let perform: () -> Void
}

/// A target object for ExpiringUndoManager that removes itself from the
/// undo manager after it expires.
///
/// This class acts as a proxy for the real target object in undo operations.
/// It holds a weak reference to the actual target and automatically removes
/// all associated undo operations when either:
/// - The specified duration expires
/// - The ExpiringTarget instance is deallocated
/// - The expire() method is called manually
private class ExpiringTarget {
    /// The actual target object for the undo operation, held weakly to avoid retain cycles.
    private(set) weak var target: AnyObject?

    /// Timer that triggers expiration after the specified duration.
    private var timer: Timer?

    /// The undo manager from which to remove actions when this target expires.
    private weak var undoManager: UndoManager?

    /// Creates an expiring target that will automatically remove undo actions after the specified duration.
    ///
    /// - Parameters:
    ///   - target: The target object to hold weakly.
    ///   - duration: The time after which the target should expire.
    ///   - undoManager: The UndoManager from which to remove actions when expired.
    init(_ target: AnyObject? = nil, expiresAfter duration: Duration, in undoManager: UndoManager) {
        self.target = target
        self.undoManager = undoManager
        self.timer = Timer.scheduledTimer(
            withTimeInterval: duration.timeInterval,
            repeats: false) { [weak self] _ in
            self?.expire()
        }
    }

    /// Manually expires the target, removing all associated undo actions and invalidating the timer.
    ///
    /// This method is called automatically when the timer fires, but can also be called manually
    /// to expire the target before the timer duration has elapsed.
    func expire() {
        target = nil
        undoManager?.removeAllActions(withTarget: self)
        timer?.invalidate()
        timer = nil
    }

    deinit {
        expire()
    }
}

extension ExpiringTarget: Hashable, Equatable {
    static func == (lhs: ExpiringTarget, rhs: ExpiringTarget) -> Bool {
        return lhs === rhs
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(ObjectIdentifier(self))
    }
}
