import EventKit
import Foundation

/// `ReminderStore` backed by the real reminder database.
///
/// A fresh `EKEventStore` is built per operation. Apple does not document one as safe to
/// share across tasks, and this server answers a handful of human-paced calls a minute —
/// correctness is worth more than the setup it saves.
public struct SystemReminderStore: ReminderStore {
    public init() {}

    // MARK: Authorisation

    public func authorization() -> ReminderAuthorization {
        switch EKEventStore.authorizationStatus(for: .reminder) {
        case .fullAccess: return .fullAccess
        case .writeOnly: return .writeOnly
        case .denied: return .denied
        case .restricted: return .restricted
        case .notDetermined: return .notDetermined
        // `.authorized` is the pre-macOS-14 spelling of full access, kept as a deprecated
        // alias; it maps to the same thing.
        @unknown default: return .denied
        }
    }

    @discardableResult
    public func requestAccess() async -> ReminderAuthorization {
        let store = EKEventStore()
        // Reminders were never split into full and write-only the way calendars were —
        // this is the only request there is.
        _ = try? await store.requestFullAccessToReminders()
        return authorization()
    }

    // MARK: Lists

    public func lists() async throws -> [ListInfo] {
        let store = EKEventStore()
        let defaultIdentifier = store.defaultCalendarForNewReminders()?.calendarIdentifier
        return store.calendars(for: .reminder)
            .map { Self.info(from: $0, defaultIdentifier: defaultIdentifier) }
            .sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
    }

    static func info(from list: EKCalendar, defaultIdentifier: String?) -> ListInfo {
        ListInfo(
            title: list.title,
            sourceName: list.source?.title ?? "unknown",
            isWritable: list.allowsContentModifications,
            // `immutable` is EventKit's own word for "no attribute of this calendar can be
            // changed, and it cannot be deleted". Its header is explicit that this does
            // *not* imply the contents are locked, which is why it is tracked separately.
            allowsListChanges: !list.isImmutable,
            isDefaultForNewReminders: list.calendarIdentifier == defaultIdentifier,
            color: list.cgColor.flatMap(Self.color(from:)))
    }

    // MARK: List writes

    public func createList(_ draft: ListDraft) async throws -> ListInfo {
        let store = EKEventStore()

        let source: EKSource
        if let wanted = draft.accountName {
            guard let match = Self.reminderSources(in: store).first(where: { $0.title == wanted })
            else {
                throw ToolError.accountNotFound(
                    name: wanted, available: Self.reminderSources(in: store).map(\.title))
            }
            source = match
        } else {
            // Wherever the existing default list lives, which is the account the owner
            // already puts reminders in. Falling back to the first source that can hold
            // reminders at all keeps a Mac with no reminder lists yet from being stuck.
            guard
                let fallback = store.defaultCalendarForNewReminders()?.source
                    ?? Self.reminderSources(in: store).first
            else {
                throw ToolError.accountNotFound(name: "(default)", available: [])
            }
            source = fallback
        }

        let list = EKCalendar(for: .reminder, eventStore: store)
        list.title = draft.title
        // Assignable only while the calendar is new; EKCalendar's header notes it is
        // effectively read-only once saved, so a list cannot be moved between accounts.
        list.source = source
        if let color = draft.color { list.cgColor = Self.cgColor(from: color) }

        try saveList(list, in: store)
        return Self.info(
            from: list, defaultIdentifier: store.defaultCalendarForNewReminders()?.calendarIdentifier
        )
    }

    public func updateList(title: String, accountName: String, changes: ListChanges) async throws
        -> ListInfo
    {
        let store = EKEventStore()
        guard let list = Self.locateList(title: title, accountName: accountName, in: store) else {
            throw ToolError.listNotFound(
                title: title,
                available: store.calendars(for: .reminder)
                    .filter { !$0.isImmutable }.map(\.title))
        }

        if let newTitle = changes.title { list.title = newTitle }
        if let color = changes.color { list.cgColor = Self.cgColor(from: color) }

        try saveList(list, in: store)
        return Self.info(
            from: list, defaultIdentifier: store.defaultCalendarForNewReminders()?.calendarIdentifier
        )
    }

    public func reminderCount(inList title: String, accountName: String) async throws -> Int {
        let store = EKEventStore()
        guard let list = Self.locateList(title: title, accountName: accountName, in: store) else {
            throw ToolError.listNotFound(title: title, available: [])
        }

        // Exactly one calendar, so the empty-array trap that `resolveLists` guards against
        // cannot arise here. This predicate covers both completion states, which is the
        // point: a list holding nothing but finished reminders is precisely the case where
        // a cascade would destroy the record.
        let predicate = store.predicateForReminders(in: [list])
        let counted: Int? = await withCheckedContinuation { continuation in
            store.fetchReminders(matching: predicate) { reminders in
                continuation.resume(returning: reminders?.count)
            }
        }
        // nil means the fetch failed or was cancelled. Reporting zero would let a list
        // delete through on the strength of a query that never ran — the one direction
        // this guard must never fail in.
        guard let counted else {
            throw ToolError.storeFailure(
                "the contents of '\(title)' could not be read, so it will not be deleted")
        }
        return counted
    }

    public func deleteList(title: String, accountName: String) async throws -> ListInfo {
        let store = EKEventStore()
        guard let list = Self.locateList(title: title, accountName: accountName, in: store) else {
            throw ToolError.listNotFound(
                title: title,
                available: store.calendars(for: .reminder)
                    .filter { !$0.isImmutable }.map(\.title))
        }

        let snapshot = Self.info(
            from: list, defaultIdentifier: store.defaultCalendarForNewReminders()?.calendarIdentifier
        )
        do {
            try store.removeCalendar(list, commit: true)
        } catch {
            throw ToolError.storeFailure(error.localizedDescription)
        }
        return snapshot
    }

    /// Sources that can hold reminders at all.
    ///
    /// Subscribed and birthday sources are read-only feeds of someone else's data;
    /// offering them as a home for a new list would only produce a save that fails with
    /// EventKit's own error text.
    private static func reminderSources(in store: EKEventStore) -> [EKSource] {
        store.sources.filter { $0.sourceType != .subscribed && $0.sourceType != .birthdays }
    }

    /// Resolves the (title, account) pair the tool layer has already proved unique.
    ///
    /// Returns nil rather than guessing if the pair somehow matches more than one list —
    /// another client is free to create two lists with the same name in one account, and
    /// renaming an arbitrary one of them is worse than refusing.
    private static func locateList(title: String, accountName: String, in store: EKEventStore)
        -> EKCalendar?
    {
        let matches = store.calendars(for: .reminder).filter {
            $0.title == title && ($0.source?.title ?? "unknown") == accountName
        }
        return matches.count == 1 ? matches.first : nil
    }

    private func saveList(_ list: EKCalendar, in store: EKEventStore) throws {
        do {
            try store.saveCalendar(list, commit: true)
        } catch {
            throw ToolError.storeFailure(error.localizedDescription)
        }
    }

    // MARK: Colour

    private static let sRGB = CGColorSpace(name: CGColorSpace.sRGB)

    /// Converts into sRGB before reading components.
    ///
    /// A `CGColor` carries whatever colour space it was created in, and a grey list colour
    /// arrives with two components rather than four. Reading `components[0...2]` directly
    /// would silently report a grey list as pure red.
    static func color(from cgColor: CGColor) -> ListColor? {
        guard let sRGB,
            let converted = cgColor.converted(to: sRGB, intent: .defaultIntent, options: nil),
            let components = converted.components, components.count >= 3
        else { return nil }
        func byte(_ value: CGFloat) -> UInt8 {
            UInt8(max(0, min(255, (value * 255).rounded())))
        }
        return ListColor(
            red: byte(components[0]), green: byte(components[1]), blue: byte(components[2]))
    }

    static func cgColor(from color: ListColor) -> CGColor {
        CGColor(
            red: CGFloat(color.red) / 255, green: CGFloat(color.green) / 255,
            blue: CGFloat(color.blue) / 255, alpha: 1)
    }

    /// Returns nil for "every list", or the matching lists.
    ///
    /// The empty array is deliberately not a possible return value. EventKit reads an
    /// empty `calendars:` argument as *every* calendar, so a scope that matched nothing
    /// would silently widen into no scope at all. Observed live in the sibling calendar
    /// server: a filter naming one calendar that did not exist returned events from every
    /// calendar on the machine. A restriction that fails open is worse than one that
    /// errors.
    private func resolveLists(_ titles: [String], in store: EKEventStore) -> ResolvedScope {
        guard !titles.isEmpty else { return .everyList }
        let wanted = Set(titles)
        let matched = store.calendars(for: .reminder).filter { wanted.contains($0.title) }
        return matched.isEmpty ? .nothingMatched : .lists(matched)
    }

    enum ResolvedScope {
        case everyList
        case lists([EKCalendar])
        /// Names were given and none of them exist. Must produce no results, never all.
        case nothingMatched
    }

    // MARK: Reads

    public func search(
        query: String?, listTitles: [String], status: CompletionFilter,
        dueFrom: Date?, dueTo: Date?, limit: Int, offset: Int
    ) async throws -> ReminderSearchPage {
        let store = EKEventStore()

        let calendars: [EKCalendar]?
        switch resolveLists(listTitles, in: store) {
        case .everyList: calendars = nil
        case .lists(let list): calendars = list
        // Fail closed: a filter that matched no list means no reminders, not all of them.
        case .nothingMatched: return ReminderSearchPage(results: [], total: 0)
        }

        // Each branch is EventKit's own indexed query for that completion state, which is
        // the filter worth pushing down: completed reminders are the set that grows
        // without bound. The due-date window is deliberately *not* pushed down — every
        // predicate would interpret its bounds slightly differently, and one in-memory
        // filter that decides the semantics for all three states is easier to trust than
        // three that nearly agree.
        let predicate: NSPredicate
        switch status {
        case .incomplete:
            predicate = store.predicateForIncompleteReminders(
                withDueDateStarting: nil, ending: nil, calendars: calendars)
        case .completed:
            predicate = store.predicateForCompletedReminders(
                withCompletionDateStarting: nil, ending: nil, calendars: calendars)
        case .any:
            predicate = store.predicateForReminders(in: calendars)
        }

        return await page(matching: predicate, in: store) { details in
            var matches = details
            if let needle = query?.trimmingCharacters(in: .whitespacesAndNewlines), !needle.isEmpty
            {
                matches = matches.filter { detail in
                    [detail.title, detail.notes]
                        .compactMap { $0 }
                        .contains { $0.localizedCaseInsensitiveContains(needle) }
                }
            }
            if dueFrom != nil || dueTo != nil {
                // A reminder with no due date sits outside every window by definition.
                matches = matches.filter { detail in
                    guard let due = detail.due?.date else { return false }
                    if let dueFrom, due < dueFrom { return false }
                    if let dueTo, due >= dueTo { return false }
                    return true
                }
            }
            return matches.sorted(by: Self.ordering)
        } page: { sorted in
            let window = sorted.dropFirst(offset).prefix(limit).map(Self.summary(from:))
            return ReminderSearchPage(results: Array(window), total: sorted.count)
        }
    }

    /// Soonest first, undated last, then by priority and finally by title.
    ///
    /// The tie-breakers exist so paging is stable: two reminders with the same due date
    /// must not swap places between the call that returned page one and the call that
    /// returns page two.
    static func ordering(_ left: ReminderDetail, _ right: ReminderDetail) -> Bool {
        switch (left.due?.date, right.due?.date) {
        case let (leftDue?, rightDue?) where leftDue != rightDue: return leftDue < rightDue
        case (nil, .some): return false
        case (.some, nil): return true
        default: break
        }
        if left.priority != right.priority {
            // rfc5545 runs 1 (highest) to 9 (lowest), with 0 meaning none — which has to
            // sort after every real priority rather than before all of them.
            let rank = { (priority: Priority) in priority == .none ? Int.max : priority.rfc5545 }
            return rank(left.priority) < rank(right.priority)
        }
        return left.title.localizedCaseInsensitiveCompare(right.title) == .orderedAscending
    }

    /// Bridges EventKit's callback-based fetch into async, converting inside the callback.
    ///
    /// `EKReminder` is not `Sendable`, so it must not escape the completion block; the
    /// filtering closure therefore works on already-converted values. The block is
    /// documented to run once, and `withCheckedContinuation` traps rather than corrupting
    /// anything if that ever stops being true.
    private func page(
        matching predicate: NSPredicate,
        in store: EKEventStore,
        filter: @escaping @Sendable ([ReminderDetail]) -> [ReminderDetail],
        page: @escaping @Sendable ([ReminderDetail]) -> ReminderSearchPage
    ) async -> ReminderSearchPage {
        await withCheckedContinuation { continuation in
            store.fetchReminders(matching: predicate) { reminders in
                let details = (reminders ?? []).map(Self.detail(from:))
                continuation.resume(returning: page(filter(details)))
            }
        }
    }

    public func fetch(id: String) async throws -> ReminderDetail? {
        let store = EKEventStore()
        guard let reminder = locate(id, in: store) else { return nil }
        return Self.detail(from: reminder)
    }

    private func locate(_ id: String, in store: EKEventStore) -> EKReminder? {
        store.calendarItem(withIdentifier: id) as? EKReminder
    }

    // MARK: Writes

    public func create(_ draft: ReminderDraft) async throws -> ReminderDetail {
        let store = EKEventStore()
        // The (title, account) pair the tool layer has already proved unique, resolved the
        // same way the list writes resolve theirs. Matching on the title alone would put
        // the reminder in whichever same-named list came first, and the saved reminder
        // reports only its list's title — so nothing in the answer would give it away.
        guard
            let list = Self.locateList(
                title: draft.listTitle, accountName: draft.listAccountName, in: store)
        else {
            throw ToolError.listNotFound(
                title: draft.listTitle,
                available: store.calendars(for: .reminder)
                    .filter(\.allowsContentModifications).map(\.title))
        }

        let reminder = EKReminder(eventStore: store)
        reminder.calendar = list
        reminder.title = draft.title
        reminder.notes = draft.notes
        reminder.url = draft.url.flatMap(URL.init(string:))
        reminder.priority = draft.priority.rfc5545
        reminder.dueDateComponents = draft.due.map {
            DateParsing.dueComponents($0, calendar: .current)
        }
        Self.alarms(draft.alarmOffsetsMinutes, due: draft.due).forEach(reminder.addAlarm)

        try save(reminder, in: store)
        return Self.detail(from: reminder)
    }

    public func update(id: String, changes: ReminderChanges) async throws -> ReminderDetail {
        let store = EKEventStore()
        guard let reminder = locate(id, in: store) else { throw ToolError.notFound(id: id) }

        if case .set(let value) = changes.title { reminder.title = value }

        switch changes.due {
        case .unchanged: break
        case .cleared: reminder.dueDateComponents = nil
        case .set(let value):
            reminder.dueDateComponents = DateParsing.dueComponents(value, calendar: .current)
        }
        switch changes.priority {
        case .unchanged: break
        case .cleared: reminder.priority = Priority.none.rfc5545
        case .set(let value): reminder.priority = value.rfc5545
        }
        switch changes.notes {
        case .unchanged: break
        case .cleared: reminder.notes = nil
        case .set(let value): reminder.notes = value
        }
        switch changes.url {
        case .unchanged: break
        case .cleared: reminder.url = nil
        case .set(let value): reminder.url = URL(string: value)
        }

        // Read back rather than reusing the requested value: the due date that alarms hang
        // off is whatever survived the edits above, including an unchanged one.
        let resultingDue = DateParsing.due(from: reminder.dueDateComponents, calendar: .current)
        switch changes.alarmOffsetsMinutes {
        case .unchanged: break
        case .cleared: reminder.alarms?.forEach(reminder.removeAlarm)
        case .set(let offsets):
            reminder.alarms?.forEach(reminder.removeAlarm)
            Self.alarms(offsets, due: resultingDue).forEach(reminder.addAlarm)
        }
        // An alarm is an absolute instant derived from the due date. With no due date left
        // there is nothing for it to mean, and a notification pinned to a deleted deadline
        // would still fire. The tool layer clears them too; this is the backstop for any
        // path that does not.
        if resultingDue == nil { reminder.alarms?.forEach(reminder.removeAlarm) }

        try save(reminder, in: store)
        return Self.detail(from: reminder)
    }

    public func setCompleted(id: String, completed: Bool) async throws -> ReminderDetail {
        let store = EKEventStore()
        guard let reminder = locate(id, in: store) else { throw ToolError.notFound(id: id) }

        // EventKit keeps `completed` and `completionDate` in lockstep: setting this to true
        // stamps the completion date with now, and setting it to false clears it. That is
        // exactly why the tool layer refuses to re-complete something already completed.
        reminder.isCompleted = completed

        try save(reminder, in: store)
        return Self.detail(from: reminder)
    }

    public func delete(id: String) async throws -> ReminderDetail {
        let store = EKEventStore()
        guard let reminder = locate(id, in: store) else { throw ToolError.notFound(id: id) }

        // Snapshot before removal: afterwards there is nothing left to describe, and a
        // delete that cannot say what it removed is not auditable.
        let snapshot = Self.detail(from: reminder)
        do {
            try store.remove(reminder, commit: true)
        } catch {
            throw ToolError.storeFailure(error.localizedDescription)
        }
        return snapshot
    }

    private func save(_ reminder: EKReminder, in store: EKEventStore) throws {
        do {
            try store.save(reminder, commit: true)
        } catch {
            throw ToolError.storeFailure(error.localizedDescription)
        }
    }

    // MARK: Conversion

    /// Absolute alarms, computed from the due date.
    ///
    /// `EKAlarm.relativeOffset` is documented against an event's start, and what it means
    /// on a reminder is not something to guess at. An absolute instant means exactly one
    /// thing, and the offset is reconstructed on the way out by subtracting the due date —
    /// so the vocabulary the caller sees stays "before the deadline" either way.
    private static func alarms(_ offsetsInMinutes: [Int], due: DueDate?) -> [EKAlarm] {
        guard let due else { return [] }
        return offsetsInMinutes.map {
            EKAlarm(absoluteDate: due.date.addingTimeInterval(TimeInterval($0 * 60)))
        }
    }

    private static func alarmOffsets(_ reminder: EKReminder, due: DueDate?) -> [Int] {
        guard let alarms = reminder.alarms, let due else { return [] }
        return alarms.compactMap { alarm in
            guard let absolute = alarm.absoluteDate else {
                // Written by another client. Its offset is relative to the due date, which
                // is the same thing this server reports.
                return Int(alarm.relativeOffset / 60)
            }
            return Int(absolute.timeIntervalSince(due.date) / 60)
        }
    }

    private static func recurrenceSummary(_ reminder: EKReminder) -> String? {
        guard let rule = reminder.recurrenceRules?.first else { return nil }
        let unit: String
        switch rule.frequency {
        case .daily: unit = "day"
        case .weekly: unit = "week"
        case .monthly: unit = "month"
        case .yearly: unit = "year"
        @unknown default: unit = "period"
        }
        var text = rule.interval <= 1 ? "every \(unit)" : "every \(rule.interval) \(unit)s"
        if let end = rule.recurrenceEnd {
            if let until = end.endDate {
                text += " until " + DateParsing.roundTrip(until, isDateOnly: true, calendar: .current)
            } else if end.occurrenceCount > 0 {
                text += ", \(end.occurrenceCount) times"
            }
        }
        return text
    }

    static func summary(from detail: ReminderDetail) -> ReminderSummary {
        ReminderSummary(
            id: detail.id, title: detail.title, listTitle: detail.listTitle, due: detail.due,
            priority: detail.priority, isCompleted: detail.isCompleted,
            isRecurring: detail.isRecurring)
    }

    static func detail(from reminder: EKReminder) -> ReminderDetail {
        let due = DateParsing.due(from: reminder.dueDateComponents, calendar: .current)
        return ReminderDetail(
            id: reminder.calendarItemIdentifier,
            title: reminder.title ?? "(no title)",
            listTitle: reminder.calendar?.title ?? "unknown",
            listIsWritable: reminder.calendar?.allowsContentModifications ?? false,
            due: due,
            priority: Priority(rfc5545: reminder.priority),
            isCompleted: reminder.isCompleted,
            completionDate: reminder.completionDate,
            notes: reminder.notes,
            url: reminder.url?.absoluteString,
            alarmOffsetsMinutes: alarmOffsets(reminder, due: due),
            isRecurring: reminder.hasRecurrenceRules,
            recurrenceSummary: recurrenceSummary(reminder))
    }
}
