import Foundation
import Testing
@testable import PromptDockCore

@Suite struct UsageStoreTests {

    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private func days(_ n: Double) -> TimeInterval { n * 86_400 }

    private func tempPath() -> String {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("promptdock-tests-\(UUID().uuidString)")
            .appendingPathComponent("nested/usage.sqlite").path
    }

    @Test func recordsAndReadsEventsInTimeOrder() throws {
        let store = try UsageStore(path: ":memory:")
        try store.record(promptID: "b", kind: .copy, at: now)
        try store.record(promptID: "a", kind: .paste, at: now - days(1))

        let events = try store.events(since: now - days(10))
        #expect(events == [
            UsageEvent(promptID: "a", usedAt: now - days(1), kind: .paste),
            UsageEvent(promptID: "b", usedAt: now, kind: .copy),
        ])
    }

    @Test func eventsSinceFiltersOlderOnes() throws {
        let store = try UsageStore(path: ":memory:")
        try store.record(promptID: "old", kind: .paste, at: now - days(30))
        try store.record(promptID: "new", kind: .paste, at: now - days(2))

        #expect(try store.events(since: now - days(7)).map(\.promptID) == ["new"])
    }

    @Test func purgeRemovesEventsBeyondRetention() throws {
        let store = try UsageStore(path: ":memory:")
        try store.record(promptID: "a", kind: .paste, at: now - days(181))
        try store.record(promptID: "b", kind: .paste, at: now - days(179))

        let removed = try store.purgeExpired(now: now)
        #expect(removed == 1)
        #expect(try store.events(since: .distantPast).map(\.promptID) == ["b"])
    }

    @Test func defaultRetentionIs180Days() {
        #expect(UsageStore.defaultRetentionDays == 180)
    }

    @Test func persistsAcrossReopenAndCreatesParentDirectory() throws {
        let path = tempPath()
        defer { try? FileManager.default.removeItem(atPath: (path as NSString).deletingLastPathComponent) }

        do {
            let store = try UsageStore(path: path)
            try store.record(promptID: "x", kind: .paste, at: now)
        }
        #expect(FileManager.default.fileExists(atPath: path))

        let reopened = try UsageStore(path: path)
        #expect(try reopened.events(since: .distantPast).map(\.promptID) == ["x"])
    }

    @Test func handlesUnicodePromptIDs() throws {
        let store = try UsageStore(path: ":memory:")
        try store.record(promptID: "中文-id 🚀", kind: .paste, at: now)
        #expect(try store.events(since: .distantPast).first?.promptID == "中文-id 🚀")
    }

    @Test func throwsWhenPathUnwritable() {
        #expect(throws: UsageStoreError.self) {
            try UsageStore(path: "/dev/null/not-a-dir/usage.sqlite")
        }
    }
}
