import Testing
@testable import Ghostty

struct ReorderSlotsTests {
    @Test func passesEqualSlotsOnceDraggedPastTheirMiddle() {
        let slots = ReorderSlots(lengths: Array(repeating: 32, count: 5))

        #expect(slots.destination(from: 1, offset: 15) == 1)
        #expect(slots.destination(from: 1, offset: 17) == 2)
        #expect(slots.destination(from: 1, offset: 49) == 3)
        #expect(slots.destination(from: 3, offset: -47) == 2)
        #expect(slots.destination(from: 3, offset: -49) == 1)
    }

    @Test func passesASlotOnceDraggedPastItsMiddle() {
        // A collapsed group, an expanded one with three tabs, and another
        // collapsed one.
        let slots = ReorderSlots(lengths: [34, 132, 34])

        #expect(slots.destination(from: 0, offset: 65) == 0)
        #expect(slots.destination(from: 0, offset: 67) == 1)
        #expect(slots.destination(from: 0, offset: 148) == 1)
        #expect(slots.destination(from: 0, offset: 150) == 2)
        #expect(slots.destination(from: 2, offset: -65) == 2)
        #expect(slots.destination(from: 2, offset: -67) == 1)
        #expect(slots.destination(from: 1, offset: -18) == 0)
    }

    @Test func movesPassedSlotsByTheDraggedSlotsLength() {
        // The tab strip: the dragged, selected tab is wider than the others.
        let strip = ReorderSlots(lengths: [40, 40, 60, 40])
        #expect(strip.offset(of: 3, draggingFrom: 2, by: 25) == -60)
        #expect(strip.offset(of: 1, draggingFrom: 2, by: 25) == 0)
        #expect(strip.distance(from: 2, to: 3) == 40)

        let sidebar = ReorderSlots(lengths: [34, 132, 34])
        #expect(sidebar.offset(of: 2, draggingFrom: 1, by: 20) == -132)
        #expect(sidebar.offset(of: 1, draggingFrom: 0, by: 70) == -34)
        #expect(sidebar.distance(from: 0, to: 1) == 132)
        #expect(sidebar.distance(from: 2, to: 0) == -166)
    }

    @Test func clampsToTheEnds() {
        let slots = ReorderSlots(lengths: [34, 132, 34])

        #expect(slots.clamped(-500, from: 1) == -34)
        #expect(slots.clamped(500, from: 1) == 34)
        #expect(slots.clamped(500, from: 0) == 166)
        #expect(slots.start(of: 2) == 166)
    }

    @Test func findsTheSlotAtAPosition() {
        let slots = ReorderSlots(lengths: [34, 132, 34])

        #expect(slots.slot(at: -1) == nil)
        #expect(slots.slot(at: 0) == 0)
        #expect(slots.slot(at: 33.9) == 0)
        #expect(slots.slot(at: 34) == 1)
        #expect(slots.slot(at: 165) == 1)
        #expect(slots.slot(at: 199) == 2)
        #expect(slots.slot(at: 200) == nil)
    }
}
