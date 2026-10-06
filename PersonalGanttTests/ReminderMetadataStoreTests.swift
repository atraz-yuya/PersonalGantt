import Foundation
import Testing
@testable import PersonalGantt

@MainActor
struct ReminderMetadataStoreTests {
    @Test func localMetadataAndSelectionsRoundTripWithoutCachingReminderText() throws {
        let url = temporaryURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let store = FileReminderMetadataStore(url: url)
        #expect(try store.load() == ReminderLocalState())
        var state = ReminderLocalState(selectedListIDs: ["list"])
        state.metadata["r"] = ReminderFixtures.metadata(minutes: 120, override: ReminderFixtures.date(23))
        try store.save(state)
        #expect(try FileReminderMetadataStore(url: url).load() == state)
        let json = try String(contentsOf: url, encoding: .utf8)
        #expect(!json.contains("title") && !json.contains("accessToken") && !json.contains("sourceDeadline"))
    }

    @Test func corruptFileIsReportedRatherThanOverwritten() throws {
        let url = temporaryURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let bad = Data("corrupt-synthetic-file".utf8)
        try bad.write(to: url)
        #expect(throws: ReminderServiceError.localStorage) { try FileReminderMetadataStore(url: url).load() }
        #expect(try Data(contentsOf: url) == bad)
    }

    @Test func invalidUpdateDoesNotReplacePreviousAtomicFile() throws {
        let url = temporaryURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let store = FileReminderMetadataStore(url: url)
        var good = ReminderLocalState()
        good.metadata["r"] = ReminderFixtures.metadata()
        try store.save(good)
        var bad = good
        bad.metadata["r"]?.estimatedMinutes = 0
        #expect(throws: ReminderServiceError.localStorage) { try store.save(bad) }
        #expect(try store.load() == good)
    }

    @Test func collidingTaskUUIDsAndEmptyIdentifiersAreRejected() {
        var state = ReminderLocalState()
        state.metadata["a"] = ReminderFixtures.metadata()
        state.metadata["b"] = ReminderFixtures.metadata()
        #expect(throws: ReminderServiceError.localStorage) { try state.validate() }
        state.metadata = ["": ReminderFixtures.metadata()]
        #expect(throws: ReminderServiceError.localStorage) { try state.validate() }
    }

    private func temporaryURL() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("PersonalGanttMetadataTests-\(UUID())/metadata.json")
    }
}
