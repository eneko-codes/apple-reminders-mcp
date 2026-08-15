import Foundation
import MCP

/// Routes a `tools/call` to the store and renders the answer.
///
/// Never touches EventKit directly — everything goes through `ReminderStore`, which is
/// what lets the tests drive every branch below against an in-memory double with no
/// reminders and no consent dialog.
public struct ReminderTools: Sendable {
    private let store: any ReminderStore
    private let calendar: Calendar
    private let format: Format
    /// Injected so "is this overdue?" can be tested at a fixed instant instead of
    /// depending on when the suite happens to run.
    private let now: @Sendable () -> Date

    public init(
        store: any ReminderStore,
        calendar: Calendar = .current,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.store = store
        self.calendar = calendar
        self.format = Format(calendar: calendar)
        self.now = now
    }

    public func handle(_ parameters: CallTool.Parameters) async -> CallTool.Result {
        do {
            let text = try await run(parameters)
            return .init(content: [.text(text: text, annotations: nil, _meta: nil)], isError: false)
        } catch let error as ToolError {
            return .init(
                content: [.text(text: error.message, annotations: nil, _meta: nil)], isError: true)
        } catch {
            return .init(
                content: [
                    .text(
                        text: ToolError.storeFailure(error.localizedDescription).message,
                        annotations: nil, _meta: nil)
                ], isError: true)
        }
    }

    private func run(_ parameters: CallTool.Parameters) async throws -> String {
        let arguments = Arguments(parameters.arguments, calendar: calendar)

        if parameters.name == ToolCatalog.statusName {
            return format.status(store.authorization(), binaryPath: Self.binaryPath)
        }

        try await requireAccess()

        switch parameters.name {
        case ToolCatalog.listsName:
            return format.listCatalogue(try await store.lists())

        case ToolCatalog.searchName:
            return try await search(arguments)

        case ToolCatalog.getName:
            let id = try arguments.requiredString("id")
            guard let reminder = try await store.fetch(id: id) else {
                throw ToolError.notFound(id: id)
            }
            return format.detail(reminder, now: now())

        case ToolCatalog.createName:
            return try await create(arguments)

        case ToolCatalog.updateName:
            return try await update(arguments)

        case ToolCatalog.completeName:
            return try await complete(arguments)

        case ToolCatalog.deleteName:
            return try await delete(arguments)

        case ToolCatalog.createListName:
            return try await createList(arguments)

        case ToolCatalog.updateListName:
            return try await updateList(arguments)

        case ToolCatalog.deleteListName:
            return try await deleteList(arguments)

        default:
            throw ToolError.badArgument(
                name: "name", reason: "'\(parameters.name)' is not a tool of this server")
        }
    }

    private func requireAccess() async throws {
        var authorization = store.authorization()
        if authorization == .notDetermined {
            authorization = await store.requestAccess()
        }
        guard authorization.isUsable else { throw ToolError.notAuthorized(authorization) }
    }

    // MARK: Tools

    private func search(_ arguments: Arguments) async throws -> String {
        let titles = try arguments.stringArray("lists")

        let requestedFrom = try arguments.optionalDate("due_from")
        let requestedTo = try arguments.optionalDate("due_to")

        let dueFrom = requestedFrom?.date
        // A plain day as the upper bound means "through the end of that day". Taking it at
        // face value would put the boundary at midnight and silently drop everything due
        // on the very day the caller asked about.
        let dueTo = requestedTo.map { parsed -> Date in
            guard parsed.isDateOnly else { return parsed.date }
            return calendar.date(byAdding: .day, value: 1, to: parsed.date) ?? parsed.date
        }
        if let dueFrom, let dueTo, dueTo < dueFrom { throw ToolError.dueRangeBackwards }

        let status = try arguments.status("status")
        let limit = try arguments.int(
            "limit", default: Configuration.searchLimit, in: Configuration.searchLimitRange)
        let offset = try arguments.int("offset", default: 0, in: Configuration.offsetRange)

        let page = try await store.search(
            query: arguments.optionalString("query"), listTitles: titles, status: status,
            dueFrom: dueFrom, dueTo: dueTo, limit: limit, offset: offset)
        return format.searchResults(
            page, status: status, dueWindow: dueWindow(from: requestedFrom, to: requestedTo),
            listTitles: titles, offset: offset, now: now())
    }

    /// Echoes the bounds **as the caller wrote them**, not as they were resolved.
    ///
    /// The upper bound of a plain day is pushed to the following midnight so the day
    /// itself is covered; reporting that resolved value back would tell someone who asked
    /// for the 12th that they searched up to the 13th.
    private func dueWindow(from: ParsedDate?, to: ParsedDate?) -> String? {
        guard from != nil || to != nil else { return nil }
        func text(_ parsed: ParsedDate?) -> String {
            guard let parsed else { return "any" }
            return DateParsing.roundTrip(
                parsed.date, isDateOnly: parsed.isDateOnly, calendar: calendar)
        }
        return "due \(text(from)) → \(text(to))"
    }

    private func create(_ arguments: Arguments) async throws -> String {
        // Resolved here rather than in the store so the error can list what is actually
        // available — and so that error is reachable from the tests. Shares `resolveList`
        // with the list tools: a name held by two accounts is refused rather than filed
        // into whichever one EventKit enumerated first.
        let target = try await resolveList(arguments, nameArgument: "list", offering: \.isWritable)
        guard target.isWritable else { throw ToolError.listReadOnly(title: target.title) }

        var draft = ReminderDraft(
            listTitle: target.title,
            listAccountName: target.sourceName,
            title: try arguments.requiredString("title"),
            due: try arguments.optionalDate("due")?.due,
            priority: try arguments.priority("priority"))
        draft.notes = arguments.optionalString("notes")
        draft.url = arguments.optionalString("url")

        let requested = try arguments.alarms("alarms")
        let implied = Self.impliedAlarms(for: draft.due, given: requested)
        draft.alarmOffsetsMinutes = requested ?? implied
        guard draft.alarmOffsetsMinutes.isEmpty || draft.due != nil else {
            throw ToolError.alarmWithoutDueDate
        }

        return format.created(
            try await store.create(draft), now: now(),
            alarmWasImplied: requested == nil && !implied.isEmpty)
    }

    /// A due *time* with no alarm produces a reminder that never actually reminds:
    /// EventKit does not create one implicitly the way Reminders.app does. A whole-day due
    /// date gets none, because that is exactly what Reminders.app does for a task due
    /// "today" with no time — it appears in the list without interrupting anyone.
    ///
    /// Only ever consulted when the caller said nothing about alarms; an explicit empty
    /// array means silence and is honoured.
    static func impliedAlarms(for due: DueDate?, given requested: [Int]?) -> [Int] {
        guard requested == nil, let due, !due.isDateOnly else { return [] }
        return [0]
    }

    private func update(_ arguments: Arguments) async throws -> String {
        let id = try arguments.requiredString("id")
        let existing = try await requireEditable(id)

        var changes = ReminderChanges()
        changes.title = arguments.stringEdit("title")
        changes.due = try arguments.dueEdit("due")
        changes.priority = try arguments.priorityEdit("priority")
        changes.notes = arguments.stringEdit("notes")
        changes.url = arguments.stringEdit("url")
        changes.alarmOffsetsMinutes = try arguments.alarmEdit("alarms")

        // An alarm is an offset from the due date, so removing the due date has to take the
        // alarms with it. Leaving them would keep a notification pinned to a date that no
        // longer exists — and the caller would never see it reported.
        if changes.due == .cleared, changes.alarmOffsetsMinutes == .unchanged,
            !existing.alarmOffsetsMinutes.isEmpty
        {
            changes.alarmOffsetsMinutes = .cleared
        }

        guard !changes.isEmpty else { throw ToolError.nothingToUpdate }

        // Checked against the values that will actually apply, so setting an alarm in the
        // same call that clears the due date is caught.
        let resultingDue: DueDate?
        switch changes.due {
        case .unchanged: resultingDue = existing.due
        case .cleared: resultingDue = nil
        case .set(let value): resultingDue = value
        }
        if case .set = changes.alarmOffsetsMinutes, resultingDue == nil {
            throw ToolError.alarmWithoutDueDate
        }

        let updated = try await store.update(id: id, changes: changes)
        return format.updated(updated, fields: changes.changedFields, now: now())
    }

    private func complete(_ arguments: Arguments) async throws -> String {
        let id = try arguments.requiredString("id")
        let completed = arguments.bool("completed", default: true)
        let existing = try await requireWritable(id)

        // Re-completing an already-completed reminder would reset its completion date to
        // now, quietly overwriting the record of when the thing was actually done. There
        // is nothing to change here, so nothing is written.
        guard existing.isCompleted != completed else {
            return format.completionUnchanged(existing, now: now())
        }

        return format.completed(
            try await store.setCompleted(id: id, completed: completed), now: now())
    }

    private func delete(_ arguments: Arguments) async throws -> String {
        let id = try arguments.requiredString("id")
        _ = try await requireEditable(id)

        guard arguments.bool("confirm") else {
            throw ToolError.confirmationRequired(action: "Deleting a reminder")
        }
        return format.deleted(try await store.delete(id: id))
    }

    // MARK: Lists

    private func createList(_ arguments: Arguments) async throws -> String {
        let title = try arguments.requiredString("title")

        let existing = try await store.lists()
        let accounts = Self.accounts(in: existing)

        let requestedAccount = arguments.optionalString("account")
        if let requestedAccount, !accounts.contains(requestedAccount) {
            throw ToolError.accountNotFound(name: requestedAccount, available: accounts)
        }
        // Resolved here rather than left to the store so the clash check below tests the
        // account the list will actually land in.
        let account =
            requestedAccount ?? existing.first(where: \.isDefaultForNewReminders)?.sourceName

        let clashes = existing.filter {
            // With no account resolved there is nothing to compare against, so any list of
            // that name counts — refusing on a name that might be free is far cheaper than
            // creating a pair that cannot be told apart.
            $0.title == title && (account == nil || $0.sourceName == account)
        }
        if let clash = clashes.first {
            throw ToolError.listAlreadyExists(title: title, accountName: clash.sourceName)
        }

        let draft = ListDraft(
            title: title, accountName: account, color: try arguments.listColor("color"))
        return format.createdList(try await store.createList(draft))
    }

    private func updateList(_ arguments: Arguments) async throws -> String {
        let target = try await resolveList(
            arguments, nameArgument: "list", offering: \.allowsListChanges)
        guard target.allowsListChanges else { throw ToolError.listImmutable(title: target.title) }

        let requestedTitle = arguments.optionalString("title")
        let requestedColor = try arguments.listColor("color")
        guard requestedTitle != nil || requestedColor != nil else {
            throw ToolError.nothingToChangeOnList
        }

        if let requestedTitle, requestedTitle != target.title {
            let existing = try await store.lists()
            if existing.contains(where: {
                $0.title == requestedTitle && $0.sourceName == target.sourceName
            }) {
                throw ToolError.listAlreadyExists(
                    title: requestedTitle, accountName: target.sourceName)
            }
        }

        // Values already in place are dropped rather than written, which is why this can
        // end up with nothing to do. Same reasoning as re-completing a completed reminder:
        // a write that changes nothing still touches the record.
        var changes = ListChanges()
        if let requestedTitle, requestedTitle != target.title { changes.title = requestedTitle }
        if let requestedColor, requestedColor != target.color { changes.color = requestedColor }
        guard !changes.isEmpty else { return format.listUnchanged(target) }

        let updated = try await store.updateList(
            title: target.title, accountName: target.sourceName, changes: changes)
        return format.updatedList(updated, fields: changes.changedFields, from: target)
    }

    private func deleteList(_ arguments: Arguments) async throws -> String {
        let target = try await resolveList(
            arguments, nameArgument: "list", offering: \.allowsListChanges)
        guard target.allowsListChanges else { throw ToolError.listImmutable(title: target.title) }

        // Checked before 'confirm', because this is not a risk the caller is allowed to
        // accept: `removeCalendar` takes every reminder in the list with it, completed ones
        // included, and those are exactly the record this server refuses to destroy.
        // Asking for confirm=true first, only to refuse anyway, would read as though the
        // flag could get past it.
        let held = try await store.reminderCount(
            inList: target.title, accountName: target.sourceName)
        guard held == 0 else {
            throw ToolError.listNotEmpty(title: target.title, count: held)
        }

        guard arguments.bool("confirm") else {
            throw ToolError.confirmationRequired(action: "Deleting a list")
        }
        return format.deletedList(
            try await store.deleteList(title: target.title, accountName: target.sourceName))
    }

    /// Resolves the one list a name — and optionally an account — refers to.
    ///
    /// Two lists can share a title across accounts (an iCloud "Reminders" beside a local
    /// one). Picking whichever EventKit enumerated first would mean renaming or deleting
    /// on a guess, and a wrong delete here is not recoverable. `create_reminder` resolves
    /// through here too: filing a reminder in the wrong "Personal" hides it just as
    /// effectively, and one resolution path is what keeps the three tools agreeing on
    /// what a list name means.
    ///
    /// `capability` names what the caller needs a list to be *able* to do, and only shapes
    /// the suggestions in `listNotFound`. `ListInfo` keeps "accepts reminders" and "can
    /// itself be renamed" apart because EventKit answers them separately, so offering a
    /// caller the wrong set would send it straight into a second refusal.
    private func resolveList(
        _ arguments: Arguments, nameArgument: String, offering capability: KeyPath<ListInfo, Bool>
    ) async throws -> ListInfo {
        let title = try arguments.requiredString(nameArgument)
        let requestedAccount = arguments.optionalString("account")

        let all = try await store.lists()
        var matches = all.filter { $0.title == title }
        if let requestedAccount {
            let accounts = Self.accounts(in: all)
            guard accounts.contains(requestedAccount) else {
                throw ToolError.accountNotFound(name: requestedAccount, available: accounts)
            }
            matches = matches.filter { $0.sourceName == requestedAccount }
        }

        guard let match = matches.first else {
            throw ToolError.listNotFound(
                title: title,
                available: all.filter { $0[keyPath: capability] }.map(\.title))
        }
        guard matches.count == 1 else {
            throw ToolError.listAmbiguous(
                title: title, accounts: matches.map(\.sourceName).sorted())
        }
        return match
    }

    private static func accounts(in lists: [ListInfo]) -> [String] {
        Array(Set(lists.map(\.sourceName))).sorted()
    }

    /// Loads the reminder and checks everything that does not depend on its completion
    /// state. `complete_reminder` stops here: reopening a completed reminder is the one
    /// write this server allows against the record.
    private func requireWritable(_ id: String) async throws -> ReminderDetail {
        guard let reminder = try await store.fetch(id: id) else {
            throw ToolError.notFound(id: id)
        }
        guard reminder.listIsWritable else {
            throw ToolError.listReadOnly(title: reminder.listTitle)
        }
        return reminder
    }

    /// Adds the one rule this server will not bend: a completed reminder is the record
    /// that the thing was done, and nothing here rewrites or destroys it.
    private func requireEditable(_ id: String) async throws -> ReminderDetail {
        let reminder = try await requireWritable(id)
        guard !reminder.isRecord else {
            throw ToolError.reminderCompleted(
                title: reminder.title,
                completed: reminder.completionDate
                    .map { format.elapsed(since: $0, now: now()) } ?? "at an unrecorded time")
        }
        return reminder
    }

    static var binaryPath: String {
        CommandLine.arguments.first.map { URL(fileURLWithPath: $0).standardizedFileURL.path }
            ?? "(unknown)"
    }
}
