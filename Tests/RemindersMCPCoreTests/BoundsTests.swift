import Foundation
import Testing

@testable import RemindersMCPCore

/// The edges of the tool standard for this server's own tools: each bound and one past it,
/// the text of each notice, pages and windows that chain, the longest result, the deadline
/// and the texts the model reads. Every reminder, list and account in here is invented.
@Suite("Bounds")
struct BoundsTests {

    // MARK: Helpers

    private static func call(
        _ name: String, _ arguments: [String: Value] = [:], store: any ReminderStore,
        timeout: Duration = Configuration.callTimeout
    ) async -> (text: String, isError: Bool) {
        let tools = ReminderTools(
            store: store, calendar: Fixtures.calendar, now: { Fixtures.now }, timeout: timeout)
        let result = await tools.handle(.init(name: name, arguments: arguments))
        guard case .text(let text) = result.content.first else { return ("(no text)", true) }
        return (text, result.isError)
    }

    private static func padded(_ index: Int) -> String { String(format: "%04d", index) }

    /// A title longer than a row shows, with its number first so that looking for the row
    /// never has to walk the filler.
    private static func longTitle(_ role: String, _ index: Int) -> String {
        "\(role)-\(padded(index))-" + String(repeating: "t", count: 100)
    }

    /// An identifier as long as EventKit's, which is the longest part of a row.
    private static func identifier(_ index: Int) -> String {
        "x-apple-reminder://INVENTED-0000-0000-0000-\(String(format: "%012d", index))"
    }

    /// One listing tool, and a store that gives it `count` rows of the widest ordinary
    /// width, in the order the tool lists them. `row` is text found in row `index` only.
    private struct Listing: Sendable, CustomTestStringConvertible {
        var tool: String
        var things: String
        var limits: ClosedRange<Int>
        var defaultLimit: Int
        var store: @Sendable (Int) -> FakeReminderStore
        var row: @Sendable (Int) -> String

        var testDescription: String { tool }

        func call(_ count: Int, _ arguments: [String: Value] = [:]) async -> (
            text: String, isError: Bool
        ) {
            await BoundsTests.call(tool, arguments, store: store(count))
        }

        func rows(in text: String, of count: Int) -> [Int] {
            (0..<count).filter { text.contains(row($0)) }
        }
    }

    private static let search = Listing(
        tool: ToolCatalog.searchName, things: "reminders", limits: Configuration.searchLimitRange,
        defaultLimit: Configuration.defaultSearchLimit,
        store: { count in
            FakeReminderStore(
                lists: Fixtures.lists,
                reminders: (0..<count).map {
                    Fixtures.reminder(
                        id: identifier($0), title: longTitle("row", $0),
                        listTitle: String(repeating: "l", count: 100),
                        due: DueDate(
                            date: Fixtures.date(2026, 9, 1).addingTimeInterval(Double($0) * 60),
                            isDateOnly: false),
                        priority: .high, isRecurring: true)
                })
        },
        row: { "row-\(padded($0))-" })

    private static let lists = Listing(
        tool: ToolCatalog.listsName, things: "lists", limits: Configuration.listLimitRange,
        defaultLimit: Configuration.defaultListLimit,
        store: { count in
            FakeReminderStore(
                lists: (0..<count).map {
                    ListInfo(
                        title: "list-\(padded($0))-" + String(repeating: "n", count: 40),
                        sourceName: "Invented account with a longish name", isWritable: true,
                        isDefaultForNewReminders: false, color: ListColor(hex: "#123456"))
                }, reminders: [])
        },
        row: { "list-\(padded($0))-" })

    private static let listings = [search, lists]

    // MARK: Pages

    @Test("A call with no optional argument returns one default page, announced before the data", arguments: listings)
    private func defaultPage(_ listing: Listing) async {
        let total = listing.defaultLimit + 5
        let result = await listing.call(total)
        #expect(!result.isError)
        #expect(
            result.text.contains(
                "Showing 1–\(listing.defaultLimit) of \(total) \(listing.things). Pass offset=\(listing.defaultLimit) for the next page.\n"
            ))
        #expect(listing.rows(in: result.text, of: total) == Array(0..<listing.defaultLimit))
        #expect(result.text.utf16.count <= ToolStandard.usualPage)
    }

    @Test("A result that holds every row from the start carries no page notice", arguments: listings)
    private func wholeListingHasNoNotice(_ listing: Listing) async {
        let result = await listing.call(listing.defaultLimit)
        #expect(listing.rows(in: result.text, of: listing.defaultLimit).count == listing.defaultLimit)
        #expect(!result.text.contains("Showing"))
        #expect(!result.text.contains("is outside"))
    }

    @Test("limit at its maximum is used as asked, and a full page of the widest rows fits a result", arguments: listings)
    private func limitAtItsMaximum(_ listing: Listing) async {
        let maximum = listing.limits.upperBound
        let total = maximum + 10
        let result = await listing.call(total, ["limit": .int(maximum)])
        #expect(!result.text.contains("is outside"))
        #expect(
            result.text.contains(
                "Showing 1–\(maximum) of \(total) \(listing.things). Pass offset=\(maximum) for the next page.\n"
            ))
        #expect(listing.rows(in: result.text, of: total) == Array(0..<maximum))
        #expect(result.text.utf16.count <= ToolStandard.longestResult)
    }

    @Test("limit one past either end is moved to the nearest value, and the result says which", arguments: listings)
    private func limitPastItsRange(_ listing: Listing) async {
        let maximum = listing.limits.upperBound
        let total = maximum + 10

        let over = await listing.call(total, ["limit": .int(maximum + 1)])
        #expect(
            over.text.hasPrefix(
                "limit=\(maximum + 1) is outside 1–\(maximum); \(maximum) was used.\n"))
        #expect(listing.rows(in: over.text, of: total) == Array(0..<maximum))

        let under = await listing.call(total, ["limit": .int(0)])
        #expect(under.text.hasPrefix("limit=0 is outside 1–\(maximum); 1 was used.\nShowing 1–1 of \(total) "))
        #expect(listing.rows(in: under.text, of: total) == [0])
    }

    @Test("Each page starts where the last one ended, and the last says that is all", arguments: listings)
    private func pagesChain(_ listing: Listing) async {
        let first = await listing.call(7, ["limit": .int(3)])
        #expect(first.text.hasPrefix("Showing 1–3 of 7 \(listing.things). Pass offset=3 for the next page.\n"))
        #expect(listing.rows(in: first.text, of: 7) == [0, 1, 2])

        let second = await listing.call(7, ["limit": .int(3), "offset": .int(3)])
        #expect(second.text.hasPrefix("Showing 4–6 of 7 \(listing.things). Pass offset=6 for the next page.\n"))
        #expect(listing.rows(in: second.text, of: 7) == [3, 4, 5])

        let last = await listing.call(7, ["limit": .int(3), "offset": .int(6)])
        #expect(last.text.hasPrefix("Showing 7–7 of 7 \(listing.things). That is all.\n"))
        #expect(listing.rows(in: last.text, of: 7) == [6])
    }

    @Test("An offset past the end returns no row and says so; a negative one is moved to zero", arguments: listings)
    private func offsetEdges(_ listing: Listing) async {
        let past = await listing.call(7, ["offset": .int(7)])
        #expect(!past.isError)
        #expect(past.text.hasPrefix("Showing 0 of 7 \(listing.things): offset=7 is past the end. That is all.\n"))
        #expect(past.text.contains("(nothing at this offset)"))
        #expect(listing.rows(in: past.text, of: 7).isEmpty)

        let negative = await listing.call(7, ["offset": .int(-1)])
        let range = Configuration.offsetRange
        #expect(negative.text.hasPrefix("offset=-1 is outside \(range.lowerBound)–\(range.upperBound); 0 was used.\n"))
        #expect(listing.rows(in: negative.text, of: 7) == Array(0..<7))

        let beyond = await listing.call(7, ["offset": .int(range.upperBound + 1)])
        #expect(beyond.text.hasPrefix("offset=\(range.upperBound + 1) is outside "))
    }

    @Test("A listing states its order, and nothing matching says so without a page notice")
    func orderAndEmptiness() async {
        let some = await Self.search.call(2)
        #expect(some.text.contains("ordered by due date (soonest first, undated last), then priority, title, id"))
        let lists = await Self.lists.call(2)
        #expect(lists.text.contains("ordered by name, then account"))

        let none = await Self.search.call(0)
        #expect(none.text.contains("Nothing matches."))
        #expect(!none.text.contains("Showing"))
    }

    @Test("Pages follow the stated order even when the store hands rows back in another")
    func orderIsTheToolsOwn() async {
        // The fake returns its matches in reverse of the stated order.
        let result = await Self.search.call(12, ["limit": .int(5), "offset": .int(5)])
        #expect(Self.search.rows(in: result.text, of: 12) == [5, 6, 7, 8, 9])
    }

    @Test("Two reminders alike in every shown field keep a fixed order, by id")
    func idEndsTheOrder() async {
        let same = (0..<4).map {
            Fixtures.reminder(id: "id-\($0)", title: "Same title", due: Fixtures.wholeDay(2026, 9, 1))
        }
        var seen: [[String]] = []
        for _ in 0..<2 {
            let result = await Self.call(
                ToolCatalog.searchName, ["limit": .int(2)],
                store: FakeReminderStore(reminders: same.shuffled()))
            seen.append((0..<4).filter { result.text.contains("id=id-\($0)") }.map { "id-\($0)" })
        }
        #expect(seen == [["id-0", "id-1"], ["id-0", "id-1"]])
    }

    // MARK: Rows wider than any maximum foresaw

    @Test("A page of lists too wide to fit holds fewer of them and says where to resume")
    func widePageShrinks() async throws {
        // A list name is never clipped, because it is the list's address.
        let wide = String(repeating: "w", count: 1000)
        let names = (0..<200).map { "list-\(Self.padded($0))-\(wide)" }
        func store() -> FakeReminderStore {
            FakeReminderStore(
                lists: names.map {
                    ListInfo(
                        title: $0, sourceName: "Invented", isWritable: true,
                        isDefaultForNewReminders: false)
                }, reminders: [])
        }
        var offset = 0
        var seen: [Int] = []
        while offset < names.count {
            let result = await Self.call(
                ToolCatalog.listsName, ["limit": .int(200), "offset": .int(offset)], store: store())
            #expect(result.text.utf16.count <= ToolStandard.longestResult)
            let shown = (0..<names.count).filter { result.text.contains("list-\(Self.padded($0))-") }
            let last = try #require(shown.last)
            #expect(shown.first == offset)
            #expect(shown.count < 200)
            let next = last + 1 < names.count ? "Pass offset=\(last + 1) for the next page." : "That is all."
            #expect(result.text.contains("Showing \(offset + 1)–\(last + 1) of 200 lists. \(next)\n\n"))
            seen += shown
            offset = last + 1
        }
        #expect(seen == Array(0..<names.count))
    }

    // MARK: Clipping

    @Test("A title or list name longer than a row shows is clipped, and the notice says so before the data")
    func clippedRows() async {
        let result = await Self.search.call(3)
        let notices = [
            Notice.clipped(field: "Title", width: Configuration.rowFieldWidth, tool: "reminder_get"),
            Notice.clipped(field: "List name", width: Configuration.rowFieldWidth, tool: "reminder_get"),
        ]
        for notice in notices { #expect(result.text.contains(notice + "\n")) }
        let firstNotice = result.text.range(of: notices[0])!.lowerBound
        let firstRow = result.text.range(of: "row-0000-")!.lowerBound
        #expect(firstNotice < firstRow)
        #expect(!result.text.contains(Self.longTitle("row", 0)))
        #expect(result.text.contains(String(Self.longTitle("row", 0).prefix(Configuration.rowFieldWidth)) + "…"))
    }

    @Test("Nothing is announced as clipped when no row was")
    func nothingClipped() async {
        let result = await Self.call(ToolCatalog.searchName, store: FakeReminderStore())
        #expect(!result.text.contains("clipped"))
    }

    // MARK: Dates

    @Test("to_date is inclusive at the precision written, and from_date starts at its own")
    func dateRangeIsInclusive() async {
        let store = FakeReminderStore(reminders: [
            Fixtures.reminder(id: "a", title: "At nine", due: Fixtures.due(2026, 8, 12, 9, 0)),
            Fixtures.reminder(id: "b", title: "One past nine", due: Fixtures.due(2026, 8, 12, 9, 1)),
            Fixtures.reminder(id: "c", title: "Late that day", due: Fixtures.due(2026, 8, 12, 23, 59)),
            Fixtures.reminder(id: "d", title: "Next day", due: Fixtures.wholeDay(2026, 8, 13)),
        ])
        func titles(_ arguments: [String: Value]) async -> [String] {
            let text = await Self.call(ToolCatalog.searchName, arguments, store: store).text
            return ["At nine", "One past nine", "Late that day", "Next day"].filter(text.contains)
        }
        #expect(await titles(["to_date": "2026-08-12T09:00"]) == ["At nine"])
        #expect(await titles(["to_date": "2026-08-12T09:00:00+02:00"]) == ["At nine"])
        #expect(await titles(["to_date": "2026-08-12"]) == ["At nine", "One past nine", "Late that day"])
        #expect(await titles(["from_date": "2026-08-12T09:01"]) == ["One past nine", "Late that day", "Next day"])
        #expect(await titles(["from_date": "2026-08-12", "to_date": "2026-08-12"]) == ["At nine", "One past nine", "Late that day"])
    }

    @Test("A day or time that does not exist, a backwards range and the old names are refused")
    func badDates() async {
        let store = FakeReminderStore()
        for value in ["2026-02-30", "2026-04-31T09:00", "2026-03-29T02:30"] {
            let result = await Self.call(ToolCatalog.searchName, ["from_date": .string(value)], store: store)
            #expect(result.isError, "\(value)")
            #expect(result.text.contains("does not exist"), "\(value)")
        }
        let backwards = await Self.call(
            ToolCatalog.searchName,
            ["from_date": "2026-08-12T10:00", "to_date": "2026-08-12T09:00"], store: store)
        #expect(backwards.isError)
        #expect(backwards.text.contains("'to_date' is earlier than 'from_date'"))

        for old in ["due_from", "due_to"] {
            let result = await Self.call(ToolCatalog.searchName, [old: "2026-08-12"], store: store)
            #expect(result.isError)
            #expect(result.text.contains("Not an argument of this tool: \(old)."))
            #expect(result.text.contains("from_date") && result.text.contains("to_date"))
        }
    }

    @Test("A wrong type is refused with the form expected")
    func wrongTypes() async {
        let store = FakeReminderStore()
        let limit = await Self.call(ToolCatalog.searchName, ["limit": "ten"], store: store)
        #expect(limit.isError && limit.text.contains("a whole number was expected"))
        let flag = await Self.call(
            ToolCatalog.deleteName, ["id": "rem-open", "confirm": "yes"], store: store)
        #expect(flag.isError && flag.text.contains("true or false was expected"))
        let alarm = await Self.call(
            ToolCatalog.createName,
            ["list": "Personal", "title": "x", "due": "2026-09-01T09:00", "alarms": ["-400d"]],
            store: store)
        #expect(alarm.isError && alarm.text.contains("outside"))
    }

    // MARK: Unknown arguments and errors

    @Test("An argument the schema does not list is refused by every tool, with the names allowed")
    func unknownArguments() async {
        for tool in ToolCatalog.all() {
            let result = await Self.call(tool.name, ["no_such_argument": "x"], store: FakeReminderStore())
            #expect(result.isError, "\(tool.name)")
            #expect(result.text.contains("Not an argument of this tool: no_such_argument."), "\(tool.name)")
            for name in ToolCatalog.argumentNames(of: tool) {
                #expect(result.text.contains(name), "\(tool.name) should name \(name)")
            }
        }
    }

    @Test("An error repeats a caller's text only clipped, and lists only a few candidates")
    func errorsAreShort() async {
        let long = String(repeating: "z", count: 5_000)
        let store = FakeReminderStore(
            lists: (0..<30).map {
                ListInfo(
                    title: "Candidate \($0)", sourceName: "Invented", isWritable: true,
                    isDefaultForNewReminders: false)
            })
        let unknownReminder = await Self.call(ToolCatalog.getName, ["id": .string(long)], store: store)
        let unknownList = await Self.call(
            ToolCatalog.createName, ["list": .string(long), "title": "x"], store: store)
        let unknownAccount = await Self.call(
            ToolCatalog.createListName, ["title": "x", "account": .string(long)], store: store)
        for result in [unknownReminder, unknownList, unknownAccount] {
            #expect(result.isError)
            #expect(result.text.utf16.count < 1_500)
            #expect(!result.text.contains(long))
        }
        #expect(unknownList.text.contains("and 25 more"))
    }

    // MARK: A reminder read through a window

    private static let marker = "NOTES-MARKER-"

    private static func storeWithLongNotes(_ length: Int) -> FakeReminderStore {
        FakeReminderStore(reminders: [
            Fixtures.reminder(
                id: "long", title: "Invented long one",
                notes: marker + String(repeating: "x", count: length))
        ])
    }

    @Test("A long record comes as one default window, announced before the data")
    func defaultWindow() async {
        let result = await Self.call(
            ToolCatalog.getName, ["id": "long"], store: Self.storeWithLongNotes(30_000))
        let size = Configuration.defaultMaxCharacters
        #expect(result.text.hasPrefix("Characters 1–\(size) of "))
        #expect(result.text.contains(" Pass character_offset=\(size) for the rest.\n\n[ ] Invented long one"))
        #expect(result.text.utf16.count <= ToolStandard.usualPage + 200)
    }

    @Test("Windows chain: each starts where the last ended, and together they are the whole record")
    func windowsChain() async throws {
        let store = Self.storeWithLongNotes(30_000)
        var offset = 0
        var joined = ""
        var total = Int.max
        while offset < total {
            let result = await Self.call(
                ToolCatalog.getName,
                ["id": "long", "character_offset": .int(offset), "max_characters": .int(7000)],
                store: store)
            let separator = try #require(result.text.range(of: "\n\n"))
            let notice = String(result.text[..<separator.lowerBound])
            let window = String(result.text[separator.upperBound...])
            let parts = try #require(
                notice.range(of: #"Characters (\d+)–(\d+) of (\d+)\."#, options: .regularExpression))
            let numbers = notice[parts].split(whereSeparator: { !$0.isNumber }).compactMap { Int($0) }
            #expect(numbers[0] == offset + 1)
            #expect(numbers[1] == offset + window.count)
            total = numbers[2]
            let next = numbers[1] < total ? "Pass character_offset=\(numbers[1]) for the rest." : "That is all."
            #expect(notice.hasSuffix(next))
            joined += window
            offset = numbers[1]
        }
        #expect(joined.count == total)
        #expect(joined.contains(Self.marker))
    }

    @Test("A record that fits one window carries no notice, and the notes are whole")
    func shortRecord() async {
        let result = await Self.call(ToolCatalog.getName, ["id": "rem-open"], store: FakeReminderStore())
        #expect(!result.text.contains("Characters"))
        #expect(result.text.contains("The one in the green tin."))
    }

    @Test("max_characters and character_offset past their ranges are moved and reported")
    func windowRanges() async {
        let store = Self.storeWithLongNotes(100)
        let maximum = Configuration.maxCharactersRange.upperBound
        let over = await Self.call(
            ToolCatalog.getName, ["id": "long", "max_characters": .int(maximum + 1)], store: store)
        #expect(over.text.hasPrefix("max_characters=\(maximum + 1) is outside 1–\(maximum); \(maximum) was used.\n"))
        let past = await Self.call(
            ToolCatalog.getName, ["id": "long", "character_offset": .int(5_000)], store: store)
        #expect(past.text.contains("character_offset=5000 is past the end. That is all."))
    }

    @Test("A record of multi-unit characters at the largest window still fits a result")
    func windowOfWideCharacters() async {
        let store = FakeReminderStore(reminders: [
            Fixtures.reminder(
                id: "wide", title: "Invented wide one", notes: String(repeating: "🧾", count: 60_000))
        ])
        let result = await Self.call(
            ToolCatalog.getName,
            ["id": "wide", "max_characters": .int(Configuration.maxCharactersRange.upperBound)],
            store: store)
        #expect(result.text.utf16.count <= ToolStandard.longestResult)
        #expect(!result.text.contains("Cut at"))
        #expect(result.text.contains("Pass character_offset="))
    }

    // MARK: Receipts

    @Test("A receipt clips every long text, says so first, and points to reminder_get")
    func receiptsClip() async {
        let notes = Self.marker + String(repeating: "n\n", count: 20_000)
        let title = String(repeating: "T", count: 5_000)
        let create = await Self.call(
            ToolCatalog.createName,
            [
                "list": "Personal", "title": .string(title), "notes": .string(notes),
                "url": .string("https://example.com/" + String(repeating: "u", count: 5_000)),
            ], store: FakeReminderStore())
        let notice = Notice.clipped(field: "Notes", width: Configuration.rowFieldWidth, tool: "reminder_get")
        #expect(!create.isError)
        #expect(create.text.hasPrefix("Title is clipped") || create.text.contains(notice + "\n"))
        #expect(create.text.contains(notice))
        #expect(create.text.utf16.count < 2_000)

        let store = Self.storeWithLongNotes(50_000)
        let update = await Self.call(
            ToolCatalog.updateName, ["id": "long", "title": "Renamed"], store: store)
        #expect(update.text.contains(notice))
        #expect(update.text.utf16.count < 2_000)
        let complete = await Self.call(ToolCatalog.completeName, ["id": "long"], store: store)
        #expect(complete.text.contains(notice))
        #expect(complete.text.utf16.count < 2_000)
        let unchanged = await Self.call(ToolCatalog.completeName, ["id": "long"], store: store)
        #expect(unchanged.text.contains(notice))
    }

    @Test("A receipt of short texts carries no clipping notice")
    func receiptsOfShortTextsAreClean() async {
        let result = await Self.call(
            ToolCatalog.updateName, ["id": "rem-open", "title": "Short"], store: FakeReminderStore())
        #expect(!result.text.contains("clipped"))
        #expect(result.text.contains("The one in the green tin."))
    }

    @Test("A receipt lists a few alarms and counts the rest")
    func receiptAlarms() async {
        let store = FakeReminderStore(reminders: [
            Fixtures.reminder(
                id: "alarms", title: "Many alarms", due: Fixtures.due(2026, 9, 1, 9, 0),
                alarms: Array(0..<9).map { -$0 })
        ])
        let result = await Self.call(ToolCatalog.updateName, ["id": "alarms", "title": "Still many"], store: store)
        #expect(result.text.contains("and 4 more"))
    }

    // MARK: Receipts of what can never be read again

    @Test("A deleted reminder's notes appear once, cut with the fixed sentence when too long")
    func deleteReceiptCutsNotes() async {
        let store = FakeReminderStore(reminders: [
            Fixtures.reminder(
                id: "gone", title: "Invented doomed one",
                due: Fixtures.due(2026, 9, 1, 9, 0),
                notes: Self.marker + String(repeating: "line\n", count: 60_000),
                url: "https://example.com/gone")
        ])
        let result = await Self.call(
            ToolCatalog.deleteName, ["id": "gone", "confirm": true], store: store)
        #expect(!result.isError)
        #expect(result.text.utf16.count <= ToolStandard.longestResult)
        #expect(!result.text.contains("Cut at \(ToolStandard.longestResult)"))
        #expect(result.text.components(separatedBy: Self.marker).count == 2, "the notes appear once")
        let limit = Configuration.deletedRecordCharacters
        #expect(result.text.hasPrefix("Cut at \(limit) of "))
        #expect(result.text.contains(" characters; the rest cannot be read again.\n\n"))
        #expect(store.deleted == ["gone"])
    }

    @Test("A deleted reminder's notes of multi-unit characters still fit a result")
    func deleteReceiptWideCharacters() async {
        let store = FakeReminderStore(reminders: [
            Fixtures.reminder(id: "gone", title: "Invented", notes: String(repeating: "🧾", count: 60_000))
        ])
        let result = await Self.call(ToolCatalog.deleteName, ["id": "gone", "confirm": true], store: store)
        #expect(result.text.utf16.count <= ToolStandard.longestResult)
        #expect(result.text.contains("the rest cannot be read again."))
    }

    @Test("A deleted reminder that fits is returned whole, with no notice")
    func deleteReceiptWhole() async {
        let result = await Self.call(
            ToolCatalog.deleteName, ["id": "rem-open", "confirm": true], store: FakeReminderStore())
        #expect(!result.text.contains("cannot be read again"))
        #expect(result.text.components(separatedBy: "The one in the green tin.").count == 2)
    }

    @Test("A deleted list's name is cut only past its limit")
    func deleteListReceipt() async {
        let name = String(repeating: "L", count: Configuration.deletedFieldCharacters + 10)
        let store = FakeReminderStore(
            lists: [
                ListInfo(
                    title: name, sourceName: "Invented", isWritable: true,
                    isDefaultForNewReminders: false)
            ], reminders: [])
        let result = await Self.call(
            ToolCatalog.deleteListName, ["list": .string(name), "confirm": true], store: store)
        #expect(!result.isError)
        #expect(result.text.hasPrefix("Cut at \(Configuration.deletedFieldCharacters) of \(name.count) characters; the rest cannot be read again."))
        #expect(result.text.utf16.count < 10_000)
    }

    @Test("A list receipt clips a long name and points to reminder_lists")
    func listReceiptClips() async {
        let name = String(repeating: "N", count: 500)
        let result = await Self.call(ToolCatalog.createListName, ["title": .string(name)], store: FakeReminderStore())
        #expect(result.text.hasPrefix(Notice.clipped(field: "List name", width: Configuration.rowFieldWidth, tool: "reminder_lists")))
        #expect(result.text.utf16.count < 1_000)
    }

    // MARK: The deadline

    /// A store whose reads and lookups never finish, as an EventKit call that hangs would.
    private final class StallingStore: ReminderStore, @unchecked Sendable {
        let inner = FakeReminderStore()
        private func stall() async throws { try await Task.sleep(for: .seconds(60)) }

        func authorization() -> ReminderAuthorization { inner.authorization() }
        func requestAccess() async -> ReminderAuthorization { await inner.requestAccess() }
        func lists() async throws -> [ListInfo] { try await stall(); return try await inner.lists() }
        func createList(_ draft: ListDraft) async throws -> ListInfo { try await inner.createList(draft) }
        func updateList(title: String, accountName: String, changes: ListChanges) async throws -> ListInfo {
            try await inner.updateList(title: title, accountName: accountName, changes: changes)
        }
        func reminderCount(inList title: String, accountName: String) async throws -> Int {
            try await inner.reminderCount(inList: title, accountName: accountName)
        }
        func deleteList(title: String, accountName: String) async throws -> ListInfo {
            try await inner.deleteList(title: title, accountName: accountName)
        }
        func search(
            query: String?, listTitles: [String], status: CompletionFilter, dueFrom: Date?,
            dueTo: Date?
        ) async throws -> [ReminderSummary] {
            try await stall()
            return []
        }
        func fetch(id: String) async throws -> ReminderDetail? { try await stall(); return nil }
        func create(_ draft: ReminderDraft) async throws -> ReminderDetail { try await inner.create(draft) }
        func update(id: String, changes: ReminderChanges) async throws -> ReminderDetail {
            try await inner.update(id: id, changes: changes)
        }
        func setCompleted(id: String, completed: Bool) async throws -> ReminderDetail {
            try await inner.setCompleted(id: id, completed: completed)
        }
        func delete(id: String) async throws -> ReminderDetail { try await inner.delete(id: id) }
    }

    @Test("A call that does not finish in time is answered, and a write says it may have happened")
    func deadline() async {
        let started = ContinuousClock.now
        let read = await Self.call(ToolCatalog.searchName, store: StallingStore(), timeout: .milliseconds(200))
        #expect(read.isError)
        #expect(read.text.contains("did not finish within 0 seconds"))
        #expect(read.text.contains("Nothing was changed."))

        let write = await Self.call(
            ToolCatalog.createName, ["list": "Personal", "title": "x"], store: StallingStore(),
            timeout: .milliseconds(200))
        #expect(write.isError)
        #expect(write.text.contains("The change may still have been made"))
        #expect(ContinuousClock.now - started < .seconds(10))
    }

    @Test("The deadline is inside the time a call may take")
    func deadlineIsInsideTheLimit() {
        #expect(Configuration.callTimeout < ToolStandard.timeLimit)
    }

    // MARK: The texts the model reads

    @Test("The instructions and every description are within the limit a client cuts at")
    func textsAreWithinTheLimit() {
        #expect(
            ToolStandard.overlongTexts(
                instructions: RemindersMCPServer.instructions, catalog: ToolCatalog.all()
            ).isEmpty)
    }

    @Test("Every bound a description or the instructions state is the constant the code enforces")
    func statedBoundsMatchTheCode() {
        func description(_ name: String) -> String {
            ToolCatalog.all().first { $0.name == name }?.description ?? ""
        }
        let search = description(ToolCatalog.searchName)
        #expect(search.contains("\(Configuration.defaultSearchLimit) a page"))
        #expect(search.contains("(\(Configuration.searchLimitRange.lowerBound)–\(Configuration.searchLimitRange.upperBound))"))
        #expect(search.contains("\(Configuration.rowFieldWidth) characters"))
        let lists = description(ToolCatalog.listsName)
        #expect(lists.contains("\(Configuration.defaultListLimit) a page"))
        #expect(lists.contains("\(Configuration.listLimitRange.upperBound)"))
        let get = description(ToolCatalog.getName)
        #expect(get.contains("\(Configuration.defaultMaxCharacters) characters"))
        #expect(get.contains("\(Configuration.maxCharactersRange.upperBound)"))
        #expect(description(ToolCatalog.deleteName).contains("\(Configuration.deletedRecordCharacters)"))

        for tool in [ToolCatalog.search, ToolCatalog.lists, ToolCatalog.get] {
            let properties = tool.inputSchema.objectValue?["properties"]?.objectValue ?? [:]
            for (name, expected) in [
                ("limit", tool.name == "reminders_search" ? Configuration.searchLimitRange : Configuration.listLimitRange),
                ("max_characters", Configuration.maxCharactersRange),
                ("offset", Configuration.offsetRange),
                ("character_offset", Configuration.offsetRange),
            ] {
                guard let schema = properties[name]?.objectValue else { continue }
                #expect(schema["minimum"]?.intValue == expected.lowerBound, "\(tool.name).\(name)")
                #expect(schema["maximum"]?.intValue == expected.upperBound, "\(tool.name).\(name)")
            }
        }
        #expect(RemindersMCPServer.instructions.contains("\(Configuration.defaultSearchLimit)"))
    }

    @Test("A schema states a default only where the code applies it")
    func updateSchemaStatesNoPriorityDefault() {
        let update = ToolCatalog.update.inputSchema.objectValue?["properties"]?.objectValue
        #expect(update?["priority"]?.objectValue?["default"] == nil)
        let create = ToolCatalog.create.inputSchema.objectValue?["properties"]?.objectValue
        #expect(create?["priority"]?.objectValue?["default"]?.stringValue == "none")
    }

    @Test("README and manifest quote no figure that a constant could change")
    func prosesCarryNoFigures() throws {
        let figures = [
            Configuration.defaultSearchLimit, Configuration.searchLimitRange.upperBound,
            Configuration.defaultListLimit, Configuration.listLimitRange.upperBound,
            Configuration.defaultMaxCharacters, Configuration.maxCharactersRange.upperBound,
            Configuration.rowFieldWidth, Configuration.deletedRecordCharacters,
            Configuration.deletedFieldCharacters, ToolStandard.longestResult,
        ]
        for file in ["README.md", "extension/manifest.json"] {
            let text = try String(
                contentsOf: ManifestTests.root.appending(path: file), encoding: .utf8)
            for figure in figures {
                #expect(
                    text.range(of: #"(?<![\d.])\#(figure)(?![\d])"#, options: .regularExpression) == nil,
                    "\(file) quotes \(figure)")
            }
        }
    }
}
