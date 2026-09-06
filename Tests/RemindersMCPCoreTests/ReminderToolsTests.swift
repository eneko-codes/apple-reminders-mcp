import Foundation
import MCP
import Testing

@testable import RemindersMCPCore

/// Drives the tool layer end to end against `FakeReminderStore`. No test in this file
/// touches EventKit, so the suite runs with no permissions and no reminders — which is
/// the point.
@Suite("Tool dispatch")
struct ReminderToolsTests {

    private func call(
        _ name: String, _ arguments: [String: Value] = [:],
        store: FakeReminderStore = FakeReminderStore()
    ) async -> (text: String, isError: Bool) {
        let tools = ReminderTools(
            store: store, calendar: Fixtures.calendar, now: { Fixtures.now })
        let result = await tools.handle(.init(name: name, arguments: arguments))
        guard case .text(let text, _, _) = result.content.first else {
            return ("(no text content)", true)
        }
        return (text, result.isError ?? false)
    }

    // MARK: Catalogue

    @Test("Every tool has a unique name, title and description")
    func catalogueIsWellFormed() {
        let names = ToolCatalog.all().map(\.name)
        #expect(names.count == Set(names).count)
        for tool in ToolCatalog.all() {
            #expect(tool.description?.isEmpty == false, "\(tool.name) has no description")
            #expect(tool.title?.isEmpty == false, "\(tool.name) has no title")
        }
    }

    @Test("Annotations match what each tool actually does")
    func annotationsAreHonest() {
        let reads = ["reminders_status", "reminder_lists", "reminders_search", "reminder_get"]
        // Both deletes are irreversible, and a client treats an unannotated tool as
        // destructive anyway — the lie that costs something is the other direction.
        let destroys = ["delete_reminder", "delete_list"]
        for tool in ToolCatalog.all() {
            #expect(tool.annotations.readOnlyHint == reads.contains(tool.name), "\(tool.name)")
            #expect(tool.annotations.destructiveHint == destroys.contains(tool.name), "\(tool.name)")
        }
    }

    @Test("Write tools carry a verb prefix and reads do not")
    func namingConventionHolds() {
        for tool in ToolCatalog.all() {
            let isWrite = tool.annotations.readOnlyHint == false
            let hasVerb = ToolCatalog.writePrefixes.contains { tool.name.hasPrefix($0) }
            #expect(isWrite == hasVerb, "\(tool.name)")
        }
    }

    /// Claude Desktop's schema sanitiser drops any property whose `type` is a union such
    /// as `["string", "null"]`, handing the model a bare `{}` instead. Observed live in
    /// the sibling contacts server, where it turned an array argument into a string and
    /// every nullable field became untyped. Text fields hide the fault; arrays do not.
    @Test("No schema property declares a union type")
    func schemasStayInTheScalarSubset() {
        func walk(_ value: Value, path: String) {
            guard case .object(let fields) = value else { return }
            if let type = fields["type"] {
                #expect(type.stringValue != nil, "\(path) declares a union type: \(type)")
            }
            if case .object(let properties)? = fields["properties"] {
                for (name, property) in properties { walk(property, path: "\(path).\(name)") }
            }
            if let items = fields["items"] { walk(items, path: "\(path)[]") }
        }
        for tool in ToolCatalog.all() { walk(tool.inputSchema, path: tool.name) }
    }

    /// The schema cannot advertise null, so the empty string has to work — otherwise a
    /// field the description says is clearable simply is not. Also covers the other half
    /// of the same contract: a field left out of the call entirely must survive untouched,
    /// or "clearable" and "optional" become the same bug.
    @Test("An empty string clears a field just as null does; omitting it leaves it alone")
    func emptyStringClears() async {
        for empty in [Value.string(""), Value.null] {
            let store = FakeReminderStore()
            let result = await call(
                "update_reminder",
                ["id": .string("rem-open"), "due": empty, "notes": empty], store: store)
            #expect(!result.isError)
            let updated = store.reminders.first { $0.id == "rem-open" }
            #expect(updated?.due == nil)
            #expect(updated?.notes == nil)
            #expect(updated?.title == "Buy olive oil", "an untouched field must survive")
        }
    }

    // MARK: Dates

    @Test("The three accepted date forms parse, and nothing else does")
    func dateFormsParse() throws {
        let calendar = Fixtures.calendar
        let day = try DateParsing.parse("2026-08-12", argument: "due", calendar: calendar)
        #expect(day.isDateOnly)

        let local = try DateParsing.parse("2026-08-12T09:00", argument: "due", calendar: calendar)
        #expect(!local.isDateOnly)
        #expect(local.date == Fixtures.date(2026, 8, 12, 9, 0))

        let absolute = try DateParsing.parse(
            "2026-08-12T09:00:00+02:00", argument: "due", calendar: calendar)
        #expect(absolute.date == Fixtures.date(2026, 8, 12, 9, 0))

        for bad in ["12/08/2026", "tomorrow", "2026-13-01", "2026-08-12 09:00"] {
            #expect(throws: ToolError.self) {
                try DateParsing.parse(bad, argument: "due", calendar: calendar)
            }
        }
    }

    /// The one that stops the process dying. `EKReminder` raises an Objective-C exception
    /// — uncatchable from Swift — if `dueDateComponents` carries a non-Gregorian calendar,
    /// and `Calendar.current` follows whatever the region setting in System Settings says.
    @Test("Due components are always Gregorian, whatever calendar the Mac is set to")
    func dueComponentsAreAlwaysGregorian() {
        var buddhist = Calendar(identifier: .buddhist)
        buddhist.timeZone = Fixtures.timeZone
        let due = Fixtures.due(2026, 8, 12, 9, 0)

        let components = DateParsing.dueComponents(due, calendar: buddhist)
        #expect(components.calendar?.identifier == .gregorian)
        #expect(components.year == 2026, "a Buddhist calendar would say 2569")
        #expect(components.timeZone == nil, "a floating date is what Reminders.app writes")
    }

    /// EventKit reads the *absence* of time components as "all day", so a whole-day due
    /// date must not carry a zeroed hour. Also covers the trip back: `due(from:)` is only
    /// ever called inside `SystemReminderStore`, below the seam no fake can reach, so this
    /// is the one place that reverse conversion gets checked at all.
    @Test("A whole-day due date carries no time components; a timed one does, and both survive the round trip")
    func dueComponentsCarryTimeOnlyWhenGiven() {
        let calendar = Fixtures.calendar
        let wholeDay = DateParsing.dueComponents(Fixtures.wholeDay(2026, 8, 12), calendar: calendar)
        #expect(wholeDay.hour == nil)
        #expect(wholeDay.day == 12)

        let timed = DateParsing.dueComponents(Fixtures.due(2026, 8, 12, 9, 30), calendar: calendar)
        #expect(timed.hour == 9)
        #expect(timed.minute == 30)

        for original in [Fixtures.due(2026, 8, 12, 9, 30), Fixtures.wholeDay(2026, 8, 12)] {
            let components = DateParsing.dueComponents(original, calendar: calendar)
            let recovered = DateParsing.due(from: components, calendar: calendar)
            #expect(recovered?.date == original.date)
            #expect(recovered?.isDateOnly == original.isDateOnly)
        }
    }

    @Test("Alarm offsets parse into signed minutes")
    func alarmOffsetsParse() throws {
        #expect(try Arguments.alarmMinutes("-15m") == -15)
        #expect(try Arguments.alarmMinutes("-1h") == -60)
        #expect(try Arguments.alarmMinutes("-1d") == -1440)
        #expect(try Arguments.alarmMinutes("0") == 0)
        #expect(throws: ToolError.self) { try Arguments.alarmMinutes("soon") }
    }

    /// Reading is wider than writing on purpose: another CalDAV client may have written 3,
    /// which RFC 5545 calls high even though this server would only ever write 1.
    @Test("Priorities read the whole RFC band and write one value per band")
    func prioritiesMapBothWays() {
        #expect(Priority(rfc5545: 0) == .none)
        #expect(Priority(rfc5545: 3) == .high)
        #expect(Priority(rfc5545: 5) == .medium)
        #expect(Priority(rfc5545: 7) == .low)
        #expect(Priority(rfc5545: 42) == .none, "nothing EventKit could have stored")
        #expect(Priority.high.rfc5545 == 1)
    }

    // MARK: Permissions

    @Test("A denied permission names the switch and where to find it")
    func deniedPermissionExplainsItself() async {
        let store = FakeReminderStore(status: .denied)
        let result = await call("reminder_lists", store: store)
        #expect(result.isError)
        #expect(result.text.contains("System Settings"))
        #expect(result.text.contains("apple-reminders-mcp"))
    }

    @Test("reminders_status reports without needing permission")
    func statusWorksWhileDenied() async {
        let result = await call("reminders_status", store: FakeReminderStore(status: .denied))
        #expect(!result.isError)
        #expect(result.text.contains("DENIED"))
    }

    @Test("A not-yet-determined permission is requested once, then used")
    func accessIsRequestedOnce() async {
        let store = FakeReminderStore(status: .notDetermined)
        let result = await call("reminder_lists", store: store)
        #expect(!result.isError)
        #expect(store.accessRequests == 1)
    }

    // MARK: Search

    /// The default is what someone means by "my reminders" — the ones still to do.
    @Test("Search looks at open reminders unless told otherwise")
    func searchDefaultsToIncomplete() async {
        let open = await call("reminders_search")
        #expect(open.text.contains("Buy olive oil"))
        #expect(!open.text.contains("File the quarterly expenses"))

        let done = await call("reminders_search", ["status": .string("completed")])
        #expect(done.text.contains("File the quarterly expenses"))
        #expect(!done.text.contains("Buy olive oil"))

        let both = await call("reminders_search", ["status": .string("any")])
        #expect(both.text.contains("Buy olive oil"))
        #expect(both.text.contains("File the quarterly expenses"))
    }

    @Test("Results run soonest first, with undated reminders last")
    func resultsAreOrdered() async {
        let result = await call("reminders_search")
        let lines = result.text.split(separator: "\n").map(String.init)
        let titles = ["Renew the passport", "Buy olive oil", "Read the migration guide"]
        let positions = titles.map { title in lines.firstIndex { $0.contains(title) } }
        #expect(positions.allSatisfy { $0 != nil })
        #expect(positions.compactMap { $0 } == positions.compactMap { $0 }.sorted())
    }

    /// The off-by-one that would otherwise hide everything due on the very day asked about.
    @Test("A plain day as due_to covers that whole day")
    func plainDayUpperBoundIncludesTheDay() async {
        let result = await call(
            "reminders_search", ["due_to": .string("2026-08-12")])
        #expect(result.text.contains("Buy olive oil"), "due 12 Aug at 18:00, not midnight")
        #expect(!result.text.contains("Water the plants"), "due 14 Aug, outside the bound")
    }

    /// The bound is echoed as it was written. Reporting the resolved value would tell
    /// someone who asked for the 12th that they had searched up to the 13th.
    @Test("The echoed due window is the one that was asked for")
    func dueWindowIsEchoedAsWritten() async {
        let result = await call(
            "reminders_search",
            ["due_from": .string("2026-08-01"), "due_to": .string("2026-08-12")])
        #expect(result.text.contains("due 2026-08-01 → 2026-08-12"))
        #expect(!result.text.contains("2026-08-13"))

        let timed = await call(
            "reminders_search", ["due_to": .string("2026-08-12T18:30")])
        #expect(timed.text.contains("due any → 2026-08-12T18:30"), "a timed bound keeps its time")
    }

    @Test("A due window excludes reminders that have no due date")
    func dueWindowExcludesUndated() async {
        let result = await call(
            "reminders_search",
            ["due_from": .string("2026-08-01"), "due_to": .string("2026-08-31")])
        #expect(!result.text.contains("Read the migration guide"))
    }

    @Test("A due range that runs backwards is refused")
    func backwardsDueRangeIsRefused() async {
        let result = await call(
            "reminders_search",
            ["due_from": .string("2026-08-31"), "due_to": .string("2026-08-01")])
        #expect(result.isError)
    }

    @Test("An overdue reminder is marked as such")
    func overdueIsMarked() async {
        let result = await call("reminders_search")
        let line = result.text.split(separator: "\n").first { $0.contains("Renew the passport") }
        #expect(line?.contains("overdue") == true)
        #expect(line?.contains("!high") == true)
    }

    /// A whole-day task is not late at nine in the morning.
    @Test("A reminder due today is not overdue until the day is over")
    func todayIsNotOverdue() async {
        let store = FakeReminderStore(reminders: [
            Fixtures.reminder(id: "today", title: "Post the letter", due: Fixtures.wholeDay(2026, 8, 9))
        ])
        let result = await call("reminders_search", store: store)
        #expect(!result.text.contains("overdue"))
    }

    @Test("A truncated page announces what it withheld")
    func truncationIsAnnounced() async {
        let result = await call("reminders_search", ["limit": .int(2)])
        #expect(result.text.contains("more · call again with offset=2"))
    }

    @Test("An unrecognised status is refused rather than guessed")
    func badStatusIsRefused() async {
        let result = await call("reminders_search", ["status": .string("pending")])
        #expect(result.isError)
        #expect(result.text.contains("status"))
    }

    @Test("Search matches notes as well as titles")
    func searchMatchesNotes() async {
        let result = await call("reminders_search", ["query": .string("green tin")])
        #expect(result.text.contains("Buy olive oil"))
    }

    // MARK: The completion rule

    @Test("A completed reminder cannot be updated")
    func completedCannotBeUpdated() async {
        let store = FakeReminderStore()
        let result = await call(
            "update_reminder", ["id": .string("rem-done"), "title": .string("Rewritten")],
            store: store)
        #expect(result.isError)
        #expect(result.text.contains("already completed"))
        #expect(result.text.contains("complete_reminder"), "must say how to undo it")
        #expect(store.updated.isEmpty)
    }

    @Test("A completed reminder cannot be deleted")
    func completedCannotBeDeleted() async {
        let store = FakeReminderStore()
        let result = await call(
            "delete_reminder", ["id": .string("rem-done"), "confirm": .bool(true)], store: store)
        #expect(result.isError)
        #expect(store.deleted.isEmpty)
    }

    /// The door left open: a mistaken tick has to be undoable, or the rule becomes a trap.
    @Test("A completed reminder can always be reopened")
    func completedCanBeReopened() async {
        let store = FakeReminderStore()
        let result = await call(
            "complete_reminder", ["id": .string("rem-done"), "completed": .bool(false)],
            store: store)
        #expect(!result.isError)
        #expect(result.text.contains("Reopened"))
        #expect(store.completionWrites.first?.completed == false)
    }

    @Test("A reopened reminder is editable again")
    func reopenedIsEditable() async {
        let store = FakeReminderStore()
        _ = await call(
            "complete_reminder", ["id": .string("rem-done"), "completed": .bool(false)],
            store: store)
        let result = await call(
            "update_reminder", ["id": .string("rem-done"), "title": .string("Renamed")],
            store: store)
        #expect(!result.isError)
        #expect(store.updated == ["rem-done"])
    }

    /// Re-ticking would stamp the completion date with now, quietly destroying the record
    /// of when the thing was actually done.
    @Test("Completing an already-completed reminder writes nothing")
    func recompletionIsNotAWrite() async {
        let store = FakeReminderStore()
        let result = await call(
            "complete_reminder", ["id": .string("rem-done"), "completed": .bool(true)],
            store: store)
        #expect(!result.isError)
        #expect(result.text.contains("already completed"))
        #expect(store.completionWrites.isEmpty)
    }

    @Test("Reopening an already-open reminder writes nothing")
    func redundantReopenIsNotAWrite() async {
        let store = FakeReminderStore()
        let result = await call(
            "complete_reminder", ["id": .string("rem-open"), "completed": .bool(false)],
            store: store)
        #expect(result.text.contains("already open"))
        #expect(store.completionWrites.isEmpty)
    }

    @Test("complete_reminder defaults to ticking off, not reopening")
    func completeDefaultsToDone() async {
        let store = FakeReminderStore()
        _ = await call("complete_reminder", ["id": .string("rem-open")], store: store)
        #expect(store.completionWrites.first?.completed == true)
    }

    @Test("A read-only list refuses every write, including completion")
    func readOnlyListRefusesWrites() async {
        let store = FakeReminderStore()
        for name in ["update_reminder", "complete_reminder", "delete_reminder"] {
            let result = await call(
                name,
                ["id": .string("rem-shared"), "title": .string("Nope"), "confirm": .bool(true)],
                store: store)
            #expect(result.isError, "\(name) must refuse a read-only list")
            #expect(result.text.contains("read-only"))
        }
        #expect(store.updated.isEmpty)
        #expect(store.deleted.isEmpty)
        #expect(store.completionWrites.isEmpty)
    }

    // MARK: Create

    @Test("An unknown list is refused, naming the writable ones")
    func unknownListIsRefused() async {
        let result = await call(
            "create_reminder",
            ["list": .string("Nonexistent"), "title": .string("X")])
        #expect(result.isError)
        #expect(result.text.contains("Personal"))
        #expect(result.text.contains("Work"))
        #expect(!result.text.contains("Household"), "a read-only list is not an option")
    }

    @Test("Creating into a read-only list is refused")
    func createIntoReadOnlyIsRefused() async {
        let result = await call(
            "create_reminder",
            ["list": .string("Household"), "title": .string("X")])
        #expect(result.isError)
        #expect(result.text.contains("read-only"))
    }

    @Test("A reminder with no due date at all is normal")
    func undatedCreateIsFine() async {
        let store = FakeReminderStore()
        let result = await call(
            "create_reminder",
            ["list": .string("Work"), "title": .string("Think about it")], store: store)
        #expect(!result.isError)
        #expect(store.reminders.last?.due == nil)
        #expect(result.text.contains("due"))
    }

    /// Without this a reminder saved with a time would never actually notify: EventKit
    /// adds no alarm of its own.
    @Test("A due time gets an alarm, and the response says so")
    func dueTimeImpliesAnAlarm() async {
        let store = FakeReminderStore()
        let result = await call(
            "create_reminder",
            [
                "list": .string("Personal"), "title": .string("Call the dentist"),
                "due": .string("2026-09-01T09:00"),
            ], store: store)
        #expect(store.reminders.last?.alarmOffsetsMinutes == [0])
        #expect(result.text.contains("An alarm was set"))
    }

    /// Matching Reminders.app: a task due "today" with no time appears in the list without
    /// interrupting anyone.
    @Test("A whole-day due date gets no alarm")
    func wholeDayDueImpliesNoAlarm() async {
        let store = FakeReminderStore()
        let result = await call(
            "create_reminder",
            [
                "list": .string("Personal"), "title": .string("Water the garden"),
                "due": .string("2026-09-01"),
            ], store: store)
        #expect(store.reminders.last?.alarmOffsetsMinutes.isEmpty == true)
        #expect(!result.text.contains("An alarm was set"))
    }

    @Test("An explicit empty alarm list is honoured")
    func explicitSilenceIsHonoured() async {
        let store = FakeReminderStore()
        let result = await call(
            "create_reminder",
            [
                "list": .string("Personal"), "title": .string("Quietly due"),
                "due": .string("2026-09-01T09:00"), "alarms": .array([]),
            ], store: store)
        #expect(store.reminders.last?.alarmOffsetsMinutes.isEmpty == true)
        #expect(!result.text.contains("An alarm was set"))
    }

    @Test("An alarm without a due date is refused")
    func alarmNeedsADueDate() async {
        let store = FakeReminderStore()
        let result = await call(
            "create_reminder",
            [
                "list": .string("Personal"), "title": .string("Impossible"),
                "alarms": .array([.string("-1h")]),
            ], store: store)
        #expect(result.isError)
        #expect(result.text.contains("due"))
        #expect(store.reminders.allSatisfy { $0.title != "Impossible" })
    }

    @Test("Creating something already overdue is allowed and flagged")
    func overdueCreateIsFlagged() async {
        let result = await call(
            "create_reminder",
            [
                "list": .string("Personal"), "title": .string("Should have done this"),
                "due": .string("2026-07-01T09:00"),
            ])
        #expect(!result.isError)
        #expect(result.text.contains("overdue"))
    }

    @Test("An unrecognised priority is refused rather than guessed")
    func badPriorityIsRefused() async {
        let result = await call(
            "create_reminder",
            [
                "list": .string("Personal"), "title": .string("X"),
                "priority": .string("urgent"),
            ])
        #expect(result.isError)
        #expect(result.text.contains("priority"))
    }

    @Test("A named priority is stored")
    func priorityIsStored() async {
        let store = FakeReminderStore()
        _ = await call(
            "create_reminder",
            [
                "list": .string("Personal"), "title": .string("Important"),
                "priority": .string("high"),
            ], store: store)
        #expect(store.reminders.last?.priority == .high)
    }

    // MARK: Update

    @Test("An update with no fields is refused")
    func emptyUpdateIsRefused() async {
        let store = FakeReminderStore()
        let result = await call("update_reminder", ["id": .string("rem-open")], store: store)
        #expect(result.isError)
        #expect(store.updated.isEmpty)
    }

    /// An alarm is an instant derived from the due date. Left behind, it would still fire
    /// for a deadline that no longer exists.
    @Test("Clearing the due date takes its alarms with it, and says so")
    func clearingDueClearsAlarms() async {
        let store = FakeReminderStore()
        let result = await call(
            "update_reminder", ["id": .string("rem-open"), "due": .null], store: store)
        #expect(!result.isError)
        #expect(store.reminders.first { $0.id == "rem-open" }?.alarmOffsetsMinutes.isEmpty == true)
        #expect(result.text.contains("due, alarms"))
    }

    @Test("Setting an alarm while clearing the due date is refused")
    func alarmAgainstAClearedDueIsRefused() async {
        let store = FakeReminderStore()
        let result = await call(
            "update_reminder",
            ["id": .string("rem-open"), "due": .null, "alarms": .array([.string("-1h")])],
            store: store)
        #expect(result.isError)
        #expect(store.updated.isEmpty)
    }

    @Test("Priority none clears the priority")
    func priorityNoneClears() async {
        let store = FakeReminderStore()
        let result = await call(
            "update_reminder",
            ["id": .string("rem-overdue"), "priority": .string("none")], store: store)
        #expect(!result.isError)
        #expect(store.reminders.first { $0.id == "rem-overdue" }?.priority == Priority.none)
    }

    // MARK: Delete

    @Test("Delete without confirm=true changes nothing")
    func deleteRequiresConfirmation() async {
        let store = FakeReminderStore()
        let before = store.reminders.count
        let result = await call("delete_reminder", ["id": .string("rem-open")], store: store)
        #expect(result.isError)
        #expect(result.text.contains("confirm=true"))
        #expect(store.reminders.count == before)
    }

    @Test("Delete describes what it removed and how to recreate it")
    func deleteIsAuditable() async {
        let store = FakeReminderStore()
        let result = await call(
            "delete_reminder", ["id": .string("rem-open"), "confirm": .bool(true)], store: store)
        #expect(!result.isError)
        #expect(result.text.contains("Buy olive oil"))
        #expect(result.text.contains("create_reminder("))
        #expect(result.text.contains("due=\"2026-08-12T18:00\""))
        #expect(result.text.contains("no longer exists"))
    }

    /// The recreate line cannot restore a recurrence rule, so it must say so.
    @Test("Deleting a repeating reminder warns the recreate call is a one-off")
    func repeatingDeleteWarns() async {
        let store = FakeReminderStore()
        let result = await call(
            "delete_reminder", ["id": .string("rem-repeats"), "confirm": .bool(true)], store: store)
        #expect(result.text.contains("not the recurrence rule"))
    }

    // MARK: Detail

    @Test("Detail states whether the reminder can still be edited")
    func detailReportsEditability() async {
        let open = await call("reminder_get", ["id": .string("rem-open")])
        #expect(open.text.contains("open · editable"))

        let overdue = await call("reminder_get", ["id": .string("rem-overdue")])
        #expect(overdue.text.contains("OVERDUE"))

        let done = await call("reminder_get", ["id": .string("rem-done")])
        #expect(done.text.contains("NOT editable"))
        #expect(done.text.contains("complete_reminder(completed=false)"))
    }

    @Test("An unknown id is refused with advice, not an empty answer")
    func unknownIDIsRefused() async {
        let result = await call("reminder_get", ["id": .string("nope")])
        #expect(result.isError)
        #expect(result.text.contains("reminders_search"))
    }

    @Test("An unknown tool name is refused")
    func unknownToolIsRefused() async {
        let result = await call("reminders_wipe_everything")
        #expect(result.isError)
    }

    // MARK: Creating lists

    @Test("A new list lands in the default list's account and starts empty")
    func createListUsesTheDefaultAccount() async {
        let store = FakeReminderStore()
        let result = await call("create_list", ["title": .string("Garden")], store: store)
        #expect(!result.isError)
        #expect(result.text.contains("Garden"))
        #expect(result.text.contains("It is empty."))
        // "Personal" is the default fixture list and lives in iCloud.
        #expect(store.createdLists.first?.accountName == "iCloud")
        #expect(store.listCatalogue.contains { $0.title == "Garden" })
    }

    @Test("An explicit account is honoured, and an unknown one is refused")
    func createListResolvesTheAccount() async {
        let store = FakeReminderStore()
        let placed = await call(
            "create_list", ["title": .string("Garden"), "account": .string("Shared")], store: store)
        #expect(!placed.isError)
        #expect(store.createdLists.first?.accountName == "Shared")

        let unknown = await call(
            "create_list", ["title": .string("Shed"), "account": .string("Dropbox")], store: store)
        #expect(unknown.isError)
        #expect(unknown.text.contains("No account named 'Dropbox'"))
        // The message has to name the accounts that do exist, or it is a dead end.
        #expect(unknown.text.contains("iCloud"))
    }

    /// Every tool here addresses a list by name. Two lists sharing one inside a single
    /// account could never be told apart again — including by this server's own delete.
    @Test("A duplicate title in the same account is refused")
    func createListRefusesADuplicate() async {
        let store = FakeReminderStore()
        let before = store.listCatalogue.count
        let result = await call("create_list", ["title": .string("Work")], store: store)
        #expect(result.isError)
        #expect(result.text.contains("already exists"))
        #expect(store.listCatalogue.count == before)
        #expect(store.createdLists.isEmpty)
    }

    /// The same title in a *different* account is ordinary, and must stay possible.
    @Test("The same title in another account is allowed")
    func createListAllowsTheSameNameElsewhere() async {
        let store = FakeReminderStore()
        let result = await call(
            "create_list", ["title": .string("Work"), "account": .string("Shared")], store: store)
        #expect(!result.isError)
    }

    @Test("Colours accept a palette name or a hex value, and nothing else")
    func createListParsesColours() async {
        let named = await call(
            "create_list", ["title": .string("A"), "color": .string("orange")],
            store: FakeReminderStore())
        #expect(!named.isError)
        #expect(named.text.contains("orange"))

        // A hex outside the palette has no name, so it is reported back as a hex.
        let hex = await call(
            "create_list", ["title": .string("B"), "color": .string("#123456")],
            store: FakeReminderStore())
        #expect(!hex.isError)
        #expect(hex.text.contains("#123456"))

        let nonsense = await call(
            "create_list", ["title": .string("C"), "color": .string("burgundy")],
            store: FakeReminderStore())
        #expect(nonsense.isError)
        #expect(nonsense.text.contains("orange"), "the refusal must list what is accepted")
    }

    @Test("A hex colour round-trips through the model unchanged")
    func hexColoursRoundTrip() {
        #expect(ListColor(hex: "#FF9500") == ListColor.named("orange"))
        #expect(ListColor(hex: "ff9500")?.hex == "#FF9500")
        #expect(ListColor(hex: "#FF9500")?.described == "orange")
        #expect(ListColor(hex: "#123456")?.described == "#123456")
        // Shorthand and stray alpha are rejected rather than guessed at.
        for bad in ["#FFF", "#FF95000", "orange", "", "#GGGGGG"] {
            #expect(ListColor(hex: bad) == nil, "\(bad)")
        }
    }

    // MARK: Renaming and recolouring

    @Test("A rename reports both names, since every later call needs the new one")
    func updateListRenames() async {
        let store = FakeReminderStore()
        let result = await call(
            "update_list", ["list": .string("Work"), "title": .string("Job")], store: store)
        #expect(!result.isError)
        #expect(result.text.contains("Renamed list 'Work' to 'Job'"))
        #expect(store.listCatalogue.contains { $0.title == "Job" })
        #expect(!store.listCatalogue.contains { $0.title == "Work" })
    }

    @Test("A recolour keeps the name and says which field moved")
    func updateListRecolours() async {
        let store = FakeReminderStore()
        let result = await call(
            "update_list", ["list": .string("Work"), "color": .string("pink")], store: store)
        #expect(!result.isError)
        #expect(result.text.contains("Fields changed: color"))
        #expect(store.listCatalogue.first { $0.title == "Work" }?.color == ListColor.named("pink"))
    }

    @Test("An update naming no field is refused")
    func updateListNeedsAField() async {
        let result = await call("update_list", ["list": .string("Work")])
        #expect(result.isError)
        #expect(result.text.contains("No change was given"))
    }

    /// Mirrors the rule for re-completing a reminder: a write that changes nothing still
    /// touches the record, so the values already in place are compared first.
    @Test("Setting a list to the values it already has writes nothing")
    func updateListSkipsANoOp() async {
        let store = FakeReminderStore()
        let result = await call(
            "update_list",
            ["list": .string("Personal"), "title": .string("Personal"), "color": .string("blue")],
            store: store)
        #expect(!result.isError)
        #expect(result.text.contains("already has those values"))
        #expect(store.updatedLists.isEmpty, "nothing should have reached the store")
    }

    @Test("Renaming onto a name already used in that account is refused")
    func updateListRefusesACollision() async {
        let store = FakeReminderStore()
        let result = await call(
            "update_list", ["list": .string("Work"), "title": .string("Personal")], store: store)
        #expect(result.isError)
        #expect(result.text.contains("already exists"))
        #expect(store.updatedLists.isEmpty)
    }

    @Test("A list the account marks as fixed cannot be renamed or deleted")
    func lockedListsAreRefused() async {
        let store = FakeReminderStore()
        let renamed = await call(
            "update_list", ["list": .string("Household"), "title": .string("Home")], store: store)
        #expect(renamed.isError)
        #expect(renamed.text.contains("cannot be renamed"))

        let deleted = await call(
            "delete_list", ["list": .string("Household"), "confirm": .bool(true)], store: store)
        #expect(deleted.isError)
        #expect(deleted.text.contains("cannot be renamed"))
        #expect(store.deletedLists.isEmpty)
    }

    // MARK: Ambiguous titles

    /// Renaming or deleting the wrong "Personal" is not recoverable, so a shared title is
    /// refused rather than resolved by enumeration order — unless an account breaks the tie,
    /// in which case it resolves to exactly the one named and leaves the other alone.
    @Test("A title held by two accounts is refused, naming both, unless an account breaks the tie")
    func ambiguousTitlesAreRefused() async {
        let refused = FakeReminderStore(lists: Fixtures.listsWithDuplicateTitle)
        let result = await call(
            "update_list", ["list": .string("Personal"), "title": .string("Mine")],
            store: refused)
        #expect(result.isError)
        #expect(result.text.contains("More than one"))
        #expect(result.text.contains("iCloud"))
        #expect(result.text.contains("On My Mac"))
        #expect(refused.updatedLists.isEmpty)

        let resolved = FakeReminderStore(lists: Fixtures.listsWithDuplicateTitle)
        let tieBroken = await call(
            "update_list",
            [
                "list": .string("Personal"), "account": .string("On My Mac"),
                "title": .string("Mine"),
            ], store: resolved)
        #expect(!tieBroken.isError)
        let renamed = resolved.listCatalogue.first { $0.title == "Mine" }
        #expect(renamed?.sourceName == "On My Mac")
        #expect(resolved.listCatalogue.contains { $0.title == "Personal" }, "iCloud's is untouched")
    }

    /// The same rule for the tool that runs most often. A reminder filed in the wrong
    /// "Personal" is not destroyed, but it is invisible to whoever expected it in the
    /// other one — and nothing in the confirmation would say so. Naming the account
    /// resolves the tie, and the account has to survive as far as the store: resolving it
    /// in the tool layer and then handing the store a title alone would leave the guess
    /// exactly where it was, one layer down.
    @Test("Creating into a title held by two accounts is refused, naming both, unless an account breaks the tie")
    func ambiguousListOnCreateIsRefused() async {
        let refused = FakeReminderStore(lists: Fixtures.listsWithDuplicateTitle)
        let result = await call(
            "create_reminder",
            ["list": .string("Personal"), "title": .string("Buy stamps")], store: refused)
        #expect(result.isError)
        #expect(result.text.contains("More than one"))
        #expect(result.text.contains("iCloud"))
        #expect(result.text.contains("On My Mac"))
        #expect(refused.createdReminders.isEmpty, "nothing may be written on a guess")

        let resolved = FakeReminderStore(lists: Fixtures.listsWithDuplicateTitle)
        let tieBroken = await call(
            "create_reminder",
            [
                "list": .string("Personal"), "account": .string("On My Mac"),
                "title": .string("Buy stamps"),
            ], store: resolved)
        #expect(!tieBroken.isError)
        #expect(resolved.createdReminders.last?.listAccountName == "On My Mac")
        #expect(resolved.createdReminders.last?.listTitle == "Personal")
    }

    /// An account that does not exist is a typo, and the tie it was meant to break is
    /// still there — silently ignoring it would file the reminder on a guess anyway.
    @Test("An unknown account is refused on create rather than ignored")
    func unknownAccountOnCreateIsRefused() async {
        let store = FakeReminderStore(lists: Fixtures.listsWithDuplicateTitle)
        let result = await call(
            "create_reminder",
            [
                "list": .string("Personal"), "account": .string("On My Macbook"),
                "title": .string("Buy stamps"),
            ], store: store)
        #expect(result.isError)
        #expect(result.text.contains("No account named"))
        #expect(store.createdReminders.isEmpty)
    }

    /// An unambiguous name needs no account, which is the ordinary case: one iCloud
    /// account and no local lists at all.
    @Test("A unique list name still needs no account")
    func uniqueListNeedsNoAccount() async {
        let store = FakeReminderStore(lists: Fixtures.listsWithDuplicateTitle)
        let result = await call(
            "create_reminder",
            ["list": .string("Work"), "title": .string("Book the room")], store: store)
        #expect(!result.isError)
        #expect(store.createdReminders.last?.listAccountName == "iCloud")
    }

    // MARK: Deleting lists

    /// The rule this feature turns on: `removeCalendar` takes every reminder in the list
    /// with it, completed ones included, which would be a way round "completion is the
    /// record". No confirmation flag gets past it.
    @Test("A list holding reminders is never deleted, even with confirm")
    func nonEmptyListsAreNeverDeleted() async {
        let store = FakeReminderStore()
        let result = await call(
            "delete_list", ["list": .string("Work"), "confirm": .bool(true)], store: store)
        #expect(result.isError)
        #expect(result.text.contains("still holds"))
        #expect(result.text.contains("no confirmation flag") || result.text.contains("overrides it"))
        #expect(store.deletedLists.isEmpty)
        #expect(store.listCatalogue.contains { $0.title == "Work" })
    }

    /// Counted with status "any": a list holding nothing but finished reminders is exactly
    /// the case where a cascade would destroy the record.
    @Test("Completed reminders alone still block the delete")
    func completedRemindersBlockTheDelete() async {
        let store = FakeReminderStore(
            lists: [Fixtures.emptyList],
            reminders: [
                Fixtures.reminder(
                    id: "rem-old", title: "Done long ago", listTitle: "Empty",
                    isCompleted: true, completionDate: Fixtures.date(2026, 1, 1))
            ])
        let result = await call(
            "delete_list", ["list": .string("Empty"), "confirm": .bool(true)], store: store)
        #expect(result.isError)
        #expect(result.text.contains("still holds 1 reminder"))
        #expect(store.deletedLists.isEmpty)
    }

    @Test("An empty list still needs confirm=true")
    func emptyListDeleteNeedsConfirmation() async {
        let store = FakeReminderStore(lists: [Fixtures.emptyList], reminders: [])
        let result = await call("delete_list", ["list": .string("Empty")], store: store)
        #expect(result.isError)
        #expect(result.text.contains("confirm=true"))
        #expect(store.deletedLists.isEmpty)
    }

    @Test("Deleting an empty list works and leaves a way to recreate it")
    func emptyListDeleteIsAuditable() async {
        let store = FakeReminderStore(lists: [Fixtures.emptyList], reminders: [])
        let result = await call(
            "delete_list", ["list": .string("Empty"), "confirm": .bool(true)], store: store)
        #expect(!result.isError)
        #expect(store.deletedLists == ["Empty"])
        #expect(store.listCatalogue.isEmpty)
        #expect(result.text.contains("create_list("))
        #expect(result.text.contains("account=\"iCloud\""))
        #expect(result.text.contains("color=\"purple\""))
    }

    @Test("Deleting a list that does not exist is refused with advice")
    func unknownListDeleteIsRefused() async {
        let result = await call(
            "delete_list", ["list": .string("Nowhere"), "confirm": .bool(true)])
        #expect(result.isError)
        #expect(result.text.contains("No reminder list named 'Nowhere'"))
    }

    // MARK: Sections

    /// Sections exist only inside Reminders.app: EventKit carries no section on a list or
    /// on a reminder, and neither does the AppleScript dictionary. The failure this guards
    /// against is not a crash but a plausible substitution — a model asked for a section,
    /// finding only create_list, quietly making a top-level list instead.
    @Test("Every list tool says sections are out of reach")
    func sectionsAreDeclaredUnreachable() {
        for name in [ToolCatalog.createListName, ToolCatalog.updateListName] {
            let tool = try! #require(ToolCatalog.all().first { $0.name == name })
            let description = tool.description ?? ""
            #expect(description.contains("Sections"), "\(name)")
            #expect(description.contains("A list is not a section"), "\(name)")
        }
        #expect(RemindersMCPServer.instructions.contains("SECTIONS INSIDE A LIST DO NOT EXIST"))
    }

    @Test("The list catalogue reports colour and what is locked")
    func catalogueShowsListAttributes() async {
        let result = await call("reminder_lists")
        #expect(!result.isError)
        #expect(result.text.contains("blue"), "Personal's colour")
        #expect(result.text.contains("#123456"), "a colour outside the palette stays hex")
        #expect(result.text.contains("locked"), "Household cannot be renamed")
        #expect(result.text.contains("read-only"), "and its contents cannot be written")
    }
}
