import Foundation
import MCP
import Testing

@testable import RemindersMCPCore

/// This server is plug and play: the owner removed the list allow-list and the
/// configurable search limit from the extension's settings, so every list is reachable
/// unconditionally and the search page size is a fixed constant. These tests exist to
/// prove both of those, rather than to exercise a `Configuration` that no longer varies.
@Suite("Settings")
struct ConfigurationTests {

    private func call(
        _ name: String, _ arguments: [String: Value] = [:],
        store: FakeReminderStore = FakeReminderStore()
    ) async -> (text: String, isError: Bool) {
        let tools = ReminderTools(store: store, calendar: Fixtures.calendar, now: { Fixtures.now })
        let result = await tools.handle(.init(name: name, arguments: arguments))
        guard case .text(let text, _, _) = result.content.first else {
            return ("(no text content)", true)
        }
        return (text, result.isError ?? false)
    }

    // MARK: Every list is visible unconditionally

    @Test("reminder_lists shows every list")
    func listsShowEverything() async {
        let result = await call("reminder_lists")
        #expect(result.text.contains("Work"))
        #expect(result.text.contains("Personal"))
        #expect(result.text.contains("Household"))
    }

    @Test("An unfiltered search covers every list")
    func unfilteredSearchCoversEverything() async {
        let result = await call("reminders_search")
        #expect(!result.isError)
        #expect(result.text.contains("Buy olive oil"), "a Personal reminder must appear")
        #expect(result.text.contains("Read the migration guide"), "a Work reminder must appear")
    }

    @Test("A shared list's reminder is reachable by id")
    func idToolsReachEveryList() async {
        let result = await call("reminder_get", ["id": .string("rem-shared")])
        #expect(!result.isError)
        #expect(result.text.contains("Order more candles"))
    }

    // MARK: Search page size is now a fixed constant

    @Test("The default page size appears in the tool description")
    func descriptionStatesTheFixedLimit() {
        let search = ToolCatalog.all().first { $0.name == "reminders_search" }
        #expect(search?.description?.contains("\(Configuration.searchLimit)") == true)
    }

    @Test("The caller's own 'limit' still overrides the default")
    func explicitLimitStillWins() async {
        let result = await call("reminders_search", ["limit": .int(1)])
        #expect(result.text.contains("call again with offset=1"))
    }

    @Test("reminders_status reports the fixed default")
    func statusReportsTheFixedDefault() async {
        let result = await call("reminders_status")
        #expect(result.text.contains("default results"))
        #expect(result.text.contains("\(Configuration.searchLimit)"))
    }
}
