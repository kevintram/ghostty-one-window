import Foundation
import Testing
@testable import Ghostty

@MainActor
struct ExpiringUndoManagerTests {
    /// Something a close keeps alive until its undo expires, like a tab.
    private final class Closed {}

    /// Records a close whose undo appends `name` to `log` and holds `kept`.
    private func close(
        _ name: String,
        keeping kept: Closed? = nil,
        in undoManager: ExpiringUndoManager,
        log: Log,
        expiresAfter duration: Duration = .seconds(60)
    ) {
        undoManager.recordClose {
            undoManager.registerUndo(withTarget: log, expiresAfter: duration) { log in
                _ = kept
                log.entries.append(name)
            }
        }
    }

    private final class Log {
        var entries: [String] = []
    }

    private func makeUndoManager() -> ExpiringUndoManager {
        let undoManager = ExpiringUndoManager()
        undoManager.groupsByEvent = false
        return undoManager
    }

    @Test func reopensTheLastCloseUnderNewerActions() {
        let undoManager = makeUndoManager()
        let log = Log()

        undoManager.beginUndoGrouping()
        close("tab", in: undoManager, log: log)
        undoManager.endUndoGrouping()

        undoManager.beginUndoGrouping()
        undoManager.registerUndo(withTarget: log, expiresAfter: .seconds(60)) { log in
            log.entries.append("rename")
        }
        undoManager.endUndoGrouping()

        #expect(undoManager.canReopenClosed)
        #expect(undoManager.reopenLastClosed())
        #expect(log.entries == ["tab"])

        // The close is off the undo stack; the newer action is still there.
        undoManager.undo()
        #expect(log.entries == ["tab", "rename"])
        #expect(!undoManager.canReopenClosed)
    }

    @Test func reopensClosesNewestFirst() {
        let undoManager = makeUndoManager()
        let log = Log()

        for name in ["first", "second"] {
            undoManager.beginUndoGrouping()
            close(name, in: undoManager, log: log)
            undoManager.endUndoGrouping()
        }

        #expect(undoManager.reopenLastClosed())
        #expect(undoManager.reopenLastClosed())
        #expect(!undoManager.reopenLastClosed())
        #expect(log.entries == ["second", "first"])
    }

    @Test func aCloseUndoneByUndoCantBeReopened() {
        let undoManager = makeUndoManager()
        let log = Log()

        undoManager.beginUndoGrouping()
        close("tab", in: undoManager, log: log)
        undoManager.endUndoGrouping()

        undoManager.undo()
        #expect(!undoManager.canReopenClosed)
        #expect(!undoManager.reopenLastClosed())
        #expect(log.entries == ["tab"])
    }

    @Test func anExpiredCloseReleasesWhatItKept() async throws {
        let undoManager = makeUndoManager()
        let log = Log()
        weak var weakKept: Closed?

        do {
            let kept = Closed()
            weakKept = kept
            undoManager.beginUndoGrouping()
            close("tab", keeping: kept, in: undoManager, log: log, expiresAfter: .milliseconds(50))
            undoManager.endUndoGrouping()
        }
        #expect(weakKept != nil)

        // Let the expiry timer fire.
        try await Task.sleep(for: .milliseconds(300))
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))

        #expect(weakKept == nil)
        #expect(!undoManager.canReopenClosed)
    }
}
