import AppKit
import Testing
@testable import PromptDockCore

@MainActor
@Suite struct PasteboardSnapshotTests {

    private func makePasteboard() -> NSPasteboard {
        NSPasteboard(name: .init("promptdock-test-\(UUID().uuidString)"))
    }

    @Test func restoresAllItemsAndTypes() {
        let pb = makePasteboard()
        defer { pb.releaseGlobally() }
        let custom = NSPasteboard.PasteboardType("local.promptdock.test")

        let first = NSPasteboardItem()
        first.setString("hello", forType: .string)
        first.setData(Data([1, 2, 3]), forType: custom)
        let second = NSPasteboardItem()
        second.setString("world", forType: .string)
        pb.clearContents()
        pb.writeObjects([first, second])

        let snapshot = PasteboardSnapshot.capture(pb)

        pb.clearContents()
        pb.setString("overwritten", forType: .string)

        snapshot.restore(to: pb)
        let items = pb.pasteboardItems ?? []
        #expect(items.count == 2)
        #expect(items[0].string(forType: .string) == "hello")
        #expect(items[0].data(forType: custom) == Data([1, 2, 3]))
        #expect(items[1].string(forType: .string) == "world")
    }

    @Test func restoringEmptySnapshotClearsPasteboard() {
        let pb = makePasteboard()
        defer { pb.releaseGlobally() }
        pb.clearContents()
        let snapshot = PasteboardSnapshot.capture(pb)
        #expect(snapshot.isEmpty)

        pb.setString("temp", forType: .string)
        snapshot.restore(to: pb)
        #expect(pb.string(forType: .string) == nil)
    }
}
