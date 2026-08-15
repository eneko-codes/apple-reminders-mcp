import Foundation

@testable import RemindersMCPCore

/// In-memory `ReminderStore` for the tests.
///
/// Every fixture here is invented. The test suite must never reach the real reminder
/// store: see the hard rule in CLAUDE.md.
final class FakeReminderStore: ReminderStore, @unchecked Sendable {
    var status: ReminderAuthorization
    var listCatalogue: [ListInfo]
    var reminders: [ReminderDetail]
    private(set) var deleted: [String] = []
    private(set) var updated: [String] = []
    private(set) var completionWrites: [(id: String, completed: Bool)] = []
    private(set) var accessRequests = 0
    private(set) var createdReminders: [ReminderDraft] = []
    private(set) var createdLists: [ListDraft] = []
    private(set) var updatedLists: [String] = []
    private(set) var deletedLists: [String] = []

    init(
        status: ReminderAuthorization = .fullAccess,
        lists: [ListInfo] = Fixtures.lists,
        reminders: [ReminderDetail] = Fixtures.reminders
    ) {
        self.status = status
        self.listCatalogue = lists
        self.reminders = reminders
    }

    func authorization() -> ReminderAuthorization { status }

    @discardableResult
    func requestAccess() async -> ReminderAuthorization {
        accessRequests += 1
        if status == .notDetermined { status = .fullAccess }
        return status
    }

    func lists() async throws -> [ListInfo] { listCatalogue }

    func createList(_ draft: ListDraft) async throws -> ListInfo {
        createdLists.append(draft)
        let created = ListInfo(
            title: draft.title,
            // Mirrors the store: with no account named, a new list joins the one the
            // default list already lives in.
            sourceName: draft.accountName
                ?? listCatalogue.first(where: \.isDefaultForNewReminders)?.sourceName ?? "iCloud",
            isWritable: true,
            isDefaultForNewReminders: false,
            color: draft.color)
        listCatalogue.append(created)
        return created
    }

    func updateList(title: String, accountName: String, changes: ListChanges) async throws
        -> ListInfo
    {
        guard let index = index(ofList: title, in: accountName) else {
            throw ToolError.listNotFound(title: title, available: listCatalogue.map(\.title))
        }
        updatedLists.append(title)
        let current = listCatalogue[index]
        let next = ListInfo(
            title: changes.title ?? current.title,
            sourceName: current.sourceName,
            isWritable: current.isWritable,
            allowsListChanges: current.allowsListChanges,
            isDefaultForNewReminders: current.isDefaultForNewReminders,
            color: changes.color ?? current.color)
        listCatalogue[index] = next
        return next
    }

    /// Counts by title alone, because a `ReminderDetail` records the list it is in but not
    /// the account. That makes the fake *more* conservative than the real store — the safe
    /// direction for the guard this feeds, and the reason the account-exact behaviour is
    /// verified by hand rather than here.
    func reminderCount(inList title: String, accountName: String) async throws -> Int {
        reminders.filter { $0.listTitle == title }.count
    }

    func deleteList(title: String, accountName: String) async throws -> ListInfo {
        guard let index = index(ofList: title, in: accountName) else {
            throw ToolError.listNotFound(title: title, available: listCatalogue.map(\.title))
        }
        deletedLists.append(title)
        return listCatalogue.remove(at: index)
    }

    /// Matches on the title/account pair, as the real store does — a fake that resolved a
    /// list by title alone could not fail the way an ambiguous title fails for real.
    private func index(ofList title: String, in accountName: String) -> Int? {
        listCatalogue.firstIndex { $0.title == title && $0.sourceName == accountName }
    }

    /// Mirrors `SystemReminderStore`, and deliberately shares its comparator rather than
    /// reimplementing it: a fake that sorts differently from the real store would let a
    /// paging bug pass the suite.
    func search(
        query: String?, listTitles: [String], status: CompletionFilter,
        dueFrom: Date?, dueTo: Date?, limit: Int, offset: Int
    ) async throws -> ReminderSearchPage {
        var matches = reminders
        switch status {
        case .incomplete: matches = matches.filter { !$0.isCompleted }
        case .completed: matches = matches.filter(\.isCompleted)
        case .any: break
        }
        if !listTitles.isEmpty {
            matches = matches.filter { listTitles.contains($0.listTitle) }
        }
        if let needle = query, !needle.isEmpty {
            matches = matches.filter {
                $0.title.localizedCaseInsensitiveContains(needle)
                    || ($0.notes ?? "").localizedCaseInsensitiveContains(needle)
            }
        }
        if dueFrom != nil || dueTo != nil {
            matches = matches.filter { reminder in
                guard let due = reminder.due?.date else { return false }
                if let dueFrom, due < dueFrom { return false }
                if let dueTo, due >= dueTo { return false }
                return true
            }
        }
        matches.sort(by: SystemReminderStore.ordering)
        let page = matches.dropFirst(offset).prefix(limit).map(SystemReminderStore.summary(from:))
        return ReminderSearchPage(results: Array(page), total: matches.count)
    }

    func fetch(id: String) async throws -> ReminderDetail? {
        reminders.first { $0.id == id }
    }

    /// Resolves the (title, account) pair as the real store does, so a draft that reached
    /// here naming the wrong account fails instead of quietly landing somewhere. A fake
    /// that keyed on the title alone could not tell a resolved account from an ignored one.
    func create(_ draft: ReminderDraft) async throws -> ReminderDetail {
        guard index(ofList: draft.listTitle, in: draft.listAccountName) != nil else {
            throw ToolError.listNotFound(
                title: draft.listTitle, available: listCatalogue.filter(\.isWritable).map(\.title))
        }
        createdReminders.append(draft)
        let created = Fixtures.reminder(
            id: "created-\(reminders.count + 1)",
            title: draft.title,
            listTitle: draft.listTitle,
            due: draft.due,
            priority: draft.priority,
            notes: draft.notes,
            url: draft.url,
            alarms: draft.alarmOffsetsMinutes)
        reminders.append(created)
        return created
    }

    func update(id: String, changes: ReminderChanges) async throws -> ReminderDetail {
        guard let index = reminders.firstIndex(where: { $0.id == id }) else {
            throw ToolError.notFound(id: id)
        }
        updated.append(id)
        let current = reminders[index]
        func applied<T>(_ edit: FieldEdit<T>, _ fallback: T?) -> T? {
            switch edit {
            case .unchanged: return fallback
            case .cleared: return nil
            case .set(let value): return value
            }
        }
        let next = Fixtures.reminder(
            id: current.id,
            title: applied(changes.title, current.title) ?? current.title,
            listTitle: current.listTitle,
            listIsWritable: current.listIsWritable,
            due: applied(changes.due, current.due),
            priority: applied(changes.priority, current.priority) ?? .none,
            notes: applied(changes.notes, current.notes),
            url: applied(changes.url, current.url),
            alarms: applied(changes.alarmOffsetsMinutes, current.alarmOffsetsMinutes) ?? [],
            isCompleted: current.isCompleted,
            completionDate: current.completionDate,
            isRecurring: current.isRecurring)
        reminders[index] = next
        return next
    }

    func setCompleted(id: String, completed: Bool) async throws -> ReminderDetail {
        guard let index = reminders.firstIndex(where: { $0.id == id }) else {
            throw ToolError.notFound(id: id)
        }
        completionWrites.append((id, completed))
        let current = reminders[index]
        let next = Fixtures.reminder(
            id: current.id,
            title: current.title,
            listTitle: current.listTitle,
            listIsWritable: current.listIsWritable,
            due: current.due,
            priority: current.priority,
            notes: current.notes,
            url: current.url,
            alarms: current.alarmOffsetsMinutes,
            isCompleted: completed,
            // EventKit stamps the completion date with now and clears it on reopening.
            completionDate: completed ? Fixtures.now : nil,
            isRecurring: current.isRecurring)
        reminders[index] = next
        return next
    }

    func delete(id: String) async throws -> ReminderDetail {
        guard let index = reminders.firstIndex(where: { $0.id == id }) else {
            throw ToolError.notFound(id: id)
        }
        deleted.append(id)
        return reminders.remove(at: index)
    }
}

enum Fixtures {
    /// Fixed so "is this overdue?" is decided by the fixtures, not by when the suite runs.
    static let timeZone = TimeZone(identifier: "Europe/Madrid")!

    static var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        return calendar
    }

    /// 2026-08-09 12:00 Europe/Madrid.
    static let now = date(2026, 8, 9, 12, 0)

    static func date(_ year: Int, _ month: Int, _ day: Int, _ hour: Int = 0, _ minute: Int = 0)
        -> Date
    {
        calendar.date(
            from: DateComponents(
                timeZone: timeZone, year: year, month: month, day: day, hour: hour, minute: minute)
        )!
    }

    static func due(_ year: Int, _ month: Int, _ day: Int, _ hour: Int, _ minute: Int) -> DueDate {
        DueDate(date: date(year, month, day, hour, minute), isDateOnly: false)
    }

    static func wholeDay(_ year: Int, _ month: Int, _ day: Int) -> DueDate {
        DueDate(date: date(year, month, day), isDateOnly: true)
    }

    static let lists: [ListInfo] = [
        ListInfo(
            title: "Personal", sourceName: "iCloud", isWritable: true,
            isDefaultForNewReminders: true, color: ListColor.named("blue")),
        ListInfo(
            title: "Work", sourceName: "iCloud", isWritable: true,
            isDefaultForNewReminders: false, color: ListColor(hex: "#123456")),
        // A shared list nobody here owns: its contents are read-only *and* its name is not
        // yours to change. The two facts are separate, and both tools have to respect them.
        ListInfo(
            title: "Household", sourceName: "Shared", isWritable: false,
            allowsListChanges: false, isDefaultForNewReminders: false,
            color: ListColor.named("green")),
    ]

    /// The same title in two accounts, which is ordinary once an iCloud list and a local
    /// one are both called "Personal". Kept out of the default catalogue so only the tests
    /// that are about ambiguity have to reason about it.
    static let listsWithDuplicateTitle: [ListInfo] =
        lists + [
            ListInfo(
                title: "Personal", sourceName: "On My Mac", isWritable: true,
                isDefaultForNewReminders: false, color: ListColor.named("orange"))
        ]

    /// A list with nothing in it, for the one delete that is allowed to succeed.
    static let emptyList = ListInfo(
        title: "Empty", sourceName: "iCloud", isWritable: true,
        isDefaultForNewReminders: false, color: ListColor.named("purple"))

    static func reminder(
        id: String,
        title: String,
        listTitle: String = "Personal",
        listIsWritable: Bool = true,
        due: DueDate? = nil,
        priority: Priority = .none,
        notes: String? = nil,
        url: String? = nil,
        alarms: [Int] = [],
        isCompleted: Bool = false,
        completionDate: Date? = nil,
        isRecurring: Bool = false
    ) -> ReminderDetail {
        ReminderDetail(
            id: id, title: title, listTitle: listTitle, listIsWritable: listIsWritable,
            due: due, priority: priority, isCompleted: isCompleted,
            completionDate: completionDate, notes: notes, url: url,
            alarmOffsetsMinutes: alarms, isRecurring: isRecurring,
            recurrenceSummary: isRecurring ? "every week" : nil)
    }

    /// One reminder in each state the rules in this server care about.
    static let reminders: [ReminderDetail] = [
        reminder(
            id: "rem-open", title: "Buy olive oil",
            due: due(2026, 8, 12, 18, 0), notes: "The one in the green tin.", alarms: [0]),
        reminder(
            id: "rem-overdue", title: "Renew the passport",
            due: wholeDay(2026, 8, 3), priority: .high),
        reminder(
            id: "rem-undated", title: "Read the migration guide", listTitle: "Work"),
        reminder(
            id: "rem-done", title: "File the quarterly expenses", listTitle: "Work",
            due: wholeDay(2026, 8, 5), isCompleted: true,
            completionDate: date(2026, 8, 5, 17, 30)),
        reminder(
            id: "rem-repeats", title: "Water the plants",
            due: due(2026, 8, 14, 9, 0), isRecurring: true),
        reminder(
            id: "rem-shared", title: "Order more candles", listTitle: "Household",
            listIsWritable: false, due: wholeDay(2026, 8, 20)),
    ]
}
