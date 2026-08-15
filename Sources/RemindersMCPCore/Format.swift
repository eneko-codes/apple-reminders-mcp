import Foundation

/// Plain-text rendering of every tool result.
public struct Format: Sendable {
    let calendar: Calendar

    public init(calendar: Calendar) {
        self.calendar = calendar
    }

    // MARK: Helpers

    static func pad(_ text: String, to width: Int) -> String {
        let shortfall = width - text.count
        return shortfall > 0 ? text + String(repeating: " ", count: shortfall) : text
    }

    static func block(_ rows: [(String, String?)]) -> String {
        let present = rows.compactMap { label, value -> (String, String)? in
            guard let value, !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            else { return nil }
            return (label, value)
        }
        guard let width = present.map(\.0.count).max() else { return "" }
        let indent = String(repeating: " ", count: width + 3)
        return present.map { label, value in
            let wrapped = value.split(separator: "\n", omittingEmptySubsequences: false)
                .joined(separator: "\n" + indent)
            return "  \(pad(label, to: width)) \(wrapped)"
        }.joined(separator: "\n")
    }

    /// Collapses a multi-line value onto one line, so the one-line-per-result contract
    /// that makes a search scannable survives a reminder with notes in it.
    static func oneLine(_ text: String) -> String {
        text.split(separator: "\n", omittingEmptySubsequences: true)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .joined(separator: ", ")
    }

    /// Rough, deliberately. "completed 6 days ago" is what the reader needs; the exact
    /// timestamp is on the line above it.
    func elapsed(since date: Date, now: Date) -> String {
        let seconds = Int(now.timeIntervalSince(date))
        switch seconds {
        case ..<0: return "in the future"
        case 0..<3600: return "\(max(seconds / 60, 1)) min ago"
        case 3600..<86400: return "\(seconds / 3600) h ago"
        default: return "\(seconds / 86400) days ago"
        }
    }

    /// Sorted nearest-to-the-due-date first, and expressed in the largest unit that still
    /// reads exactly, so a 1440-minute offset appears as `1d before`.
    static func alarms(_ offsets: [Int]) -> String? {
        guard !offsets.isEmpty else { return nil }
        return offsets.sorted { abs($0) < abs($1) }.map { minutes -> String in
            let magnitude = abs(minutes)
            guard magnitude != 0 else { return "when due" }

            let days = magnitude / 1440
            let hours = (magnitude % 1440) / 60
            let mins = magnitude % 60
            var parts: [String] = []
            if days > 0 { parts.append("\(days)d") }
            if hours > 0 { parts.append("\(hours)h") }
            if mins > 0 || parts.isEmpty { parts.append("\(mins)m") }
            return parts.joined(separator: " ") + (minutes < 0 ? " before" : " after")
        }.joined(separator: ", ")
    }

    /// `Wed 12 Aug 09:00`, or `Wed 12 Aug` for a whole-day due date.
    func due(_ due: DueDate, withYear: Bool = false) -> String {
        let day =
            withYear
            ? DateParsing.dayWithYear(due.date, calendar: calendar)
            : DateParsing.day(due.date, calendar: calendar)
        guard !due.isDateOnly else { return day }
        return day + " " + DateParsing.time(due.date, calendar: calendar)
    }

    /// `!high`, and nothing at all for a reminder nobody prioritised.
    static func priority(_ priority: Priority) -> String? {
        priority == .none ? nil : "!\(priority.rawValue)"
    }

    // MARK: Tools

    public func listCatalogue(_ lists: [ListInfo]) -> String {
        guard !lists.isEmpty else { return "No reminder lists found." }
        let titleWidth = lists.map(\.title.count).max() ?? 0
        let sourceWidth = lists.map(\.sourceName.count).max() ?? 0
        let colourWidth = lists.compactMap { $0.color?.described.count }.max() ?? 0

        var lines = [
            "\(lists.count) list\(lists.count == 1 ? "" : "s") · time zone \(calendar.timeZone.identifier)"
        ]
        for entry in lists {
            var line = Self.pad(entry.title, to: titleWidth)
            line += "  " + Self.pad(entry.sourceName, to: sourceWidth)
            line += "  " + (entry.isWritable ? "writable " : "read-only")
            if colourWidth > 0 {
                line += "  " + Self.pad(entry.color?.described ?? "—", to: colourWidth)
            }
            // Two different questions, so both are answerable from one line: 'read-only'
            // above is about the reminders inside, 'locked' is about the list itself.
            if !entry.allowsListChanges { line += "  locked" }
            if entry.isDefaultForNewReminders { line += "  (default)" }
            lines.append(line)
        }
        return lines.joined(separator: "\n")
    }

    /// The shared body of every list result, so a created, renamed and deleted list are
    /// all described in the same shape.
    func listBlock(_ list: ListInfo) -> String {
        Self.block([
            ("list", list.title),
            ("account", list.sourceName),
            ("color", list.color?.described),
            (
                "writes",
                list.isWritable ? "reminders can be added" : "read-only, reminders cannot be added"
            ),
            ("locked", list.allowsListChanges ? nil : "cannot be renamed, recoloured or deleted"),
            ("default", list.isDefaultForNewReminders ? "new reminders land here" : nil),
        ])
    }

    public func createdList(_ list: ListInfo) -> String {
        "Created list '\(list.title)' in \(list.sourceName). It is empty.\n\n" + listBlock(list)
    }

    public func updatedList(_ list: ListInfo, fields: [String], from previous: ListInfo) -> String {
        // The old name is worth stating outright: after a rename every other tool has to be
        // called with the new one, and a caller holding the old name gets listNotFound.
        let headline =
            previous.title == list.title
            ? "Updated list '\(list.title)'."
            : "Renamed list '\(previous.title)' to '\(list.title)'."
        return headline + " Fields changed: " + fields.joined(separator: ", ") + ".\n\n"
            + listBlock(list)
    }

    /// Nothing was written because the list already looked like that.
    public func listUnchanged(_ list: ListInfo) -> String {
        "List '\(list.title)' already has those values. Nothing was changed.\n\n" + listBlock(list)
    }

    public func deletedList(_ list: ListInfo) -> String {
        var text = "Deleted the empty list '\(list.title)' from \(list.sourceName).\n\n"
        text += listBlock(list)

        var arguments = ["title=\"\(list.title)\"", "account=\"\(list.sourceName)\""]
        if let color = list.color { arguments.append("color=\"\(color.described)\"") }
        text += "\n\nTo recreate it:\n  create_list(\(arguments.joined(separator: ", ")))"
        return text
    }

    public func searchResults(
        _ page: ReminderSearchPage, status: CompletionFilter, dueWindow: String?,
        listTitles: [String], offset: Int, now: Date
    ) -> String {
        let scope = listTitles.isEmpty ? "all" : listTitles.joined(separator: ", ")
        // The filters and zone are echoed so a model can catch its own mistake — an empty
        // result because it searched completed reminders — before the reader has to.
        var header =
            "\(page.total) reminder\(page.total == 1 ? "" : "s") · \(status.rawValue) · "
            + "lists: \(scope) · \(calendar.timeZone.identifier)"
        if let dueWindow { header += " · " + dueWindow }

        guard !page.results.isEmpty else { return header + "\nNothing matches." }

        let dueTexts = page.results.map { $0.due.map { due($0) } ?? "—" }
        let dueWidth = dueTexts.map(\.count).max() ?? 0
        let titleWidth = page.results.map(\.title.count).max() ?? 0

        var lines = [header]
        for (reminder, dueText) in zip(page.results, dueTexts) {
            var line = reminder.isCompleted ? "[x]" : "[ ]"
            line += "  " + Self.pad(dueText, to: dueWidth)
            line += "  " + Self.pad(reminder.title, to: titleWidth)
            line += "  [\(reminder.listTitle)]"
            if let mark = Self.priority(reminder.priority) { line += "  " + mark }
            if !reminder.isCompleted, let due = reminder.due, isOverdue(due, now: now) {
                line += "  overdue"
            }
            if reminder.isRecurring { line += "  repeats" }
            lines.append(line + "  id=\(reminder.id)")
        }

        let shown = offset + page.results.count
        if shown < page.total {
            lines.append("…\(page.total - shown) more · call again with offset=\(shown)")
        }
        return lines.joined(separator: "\n")
    }

    /// A whole-day due date is late only once the day is over: a task due today is not
    /// overdue at nine in the morning.
    private func isOverdue(_ due: DueDate, now: Date) -> Bool {
        guard due.isDateOnly else { return due.date < now }
        let dayAfter =
            calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: due.date))
            ?? due.date
        return dayAfter <= now
    }

    public func detail(_ reminder: ReminderDetail, now: Date) -> String {
        // Stated up front so a caller knows whether a write will be accepted without
        // having to attempt one and read the refusal.
        let state: String
        if reminder.isCompleted {
            let when = reminder.completionDate.map { elapsed(since: $0, now: now) }
            state =
                "completed \(when ?? "at an unrecorded time") · NOT editable"
                + " (reopen with complete_reminder(completed=false) first)"
        } else if reminder.isOverdue(asOf: now, calendar: calendar) {
            state = "open · OVERDUE · editable"
        } else {
            state = "open · editable"
        }

        var rows: [(String, String?)] = [
            ("due", reminder.due.map { due($0, withYear: true) } ?? "none"),
            (
                "list",
                reminder.listTitle + (reminder.listIsWritable ? "" : " (read-only)")
            ),
            ("priority", reminder.priority == .none ? nil : reminder.priority.rawValue),
            ("alarms", Self.alarms(reminder.alarmOffsetsMinutes)),
            ("repeats", reminder.isRecurring ? (reminder.recurrenceSummary ?? "yes") : nil),
        ]
        if let completionDate = reminder.completionDate {
            rows.append(("done", DateParsing.dayWithYear(completionDate, calendar: calendar)
                + " " + DateParsing.time(completionDate, calendar: calendar)))
        }
        rows.append(("url", reminder.url))
        rows.append(("notes", reminder.notes))
        rows.append(("id", reminder.id))
        rows.append(("state", state))

        return (reminder.isCompleted ? "[x] " : "[ ] ") + reminder.title + "\n" + Self.block(rows)
    }

    public func created(_ reminder: ReminderDetail, now: Date, alarmWasImplied: Bool) -> String {
        var text = "Created reminder '\(reminder.title)' in \(reminder.listTitle)."
        if alarmWasImplied {
            // Never silent: the server added something the caller did not ask for, and a
            // notification arriving unannounced is exactly the kind of surprise that
            // makes people distrust a tool.
            text += "\n\nAn alarm was set for the due time. EventKit does not add one by"
            text += "\nitself, so a reminder saved with a time would never actually notify."
            text += "\nPass alarms=[] to create one that stays silent."
        }
        if reminder.isOverdue(asOf: now, calendar: calendar) {
            text += "\n\n⚠ This reminder is already overdue."
        }
        return text + "\n\n" + detail(reminder, now: now)
    }

    public func updated(_ reminder: ReminderDetail, fields: [String], now: Date) -> String {
        // An update with nothing to change is refused before it reaches the store, so
        // `fields` is never empty here.
        return "Updated reminder '\(reminder.title)'. Fields changed: "
            + fields.joined(separator: ", ") + ".\n\n" + detail(reminder, now: now)
    }

    public func completed(_ reminder: ReminderDetail, now: Date) -> String {
        let headline =
            reminder.isCompleted
            ? "Completed '\(reminder.title)'."
            : "Reopened '\(reminder.title)'. It is an ordinary open reminder again."
        var text = headline
        if reminder.isCompleted && reminder.isRecurring {
            // Completing a repeating reminder does not close it, it rolls it forward.
            // A caller told only "completed" would reasonably expect it to be gone.
            text += "\n\nThis one repeats, so Reminders may roll it forward to its next due"
            text += "\ndate rather than closing it. The record below is what the store"
            text += "\nreturned immediately after the change."
        }
        return text + "\n\n" + detail(reminder, now: now)
    }

    /// Nothing was written, and saying so matters: re-completing a completed reminder
    /// would have reset its completion date to now and destroyed the record of when the
    /// thing was actually done.
    public func completionUnchanged(_ reminder: ReminderDetail, now: Date) -> String {
        let state = reminder.isCompleted ? "already completed" : "already open"
        return "'\(reminder.title)' is \(state). Nothing was changed.\n\n"
            + detail(reminder, now: now)
    }

    /// A delete has to leave behind enough to undo it by hand.
    public func deleted(_ reminder: ReminderDetail) -> String {
        var text = "Deleted '\(reminder.title)' from \(reminder.listTitle).\n\n"
        text += Self.block([
            ("title", reminder.title),
            ("due", reminder.due.map { due($0, withYear: true) } ?? "none"),
            ("priority", reminder.priority == .none ? nil : reminder.priority.rawValue),
            ("notes", reminder.notes),
            ("id", "\(reminder.id) (no longer exists)"),
        ])

        var arguments = [
            "list=\"\(reminder.listTitle)\"",
            "title=\"\(reminder.title)\"",
        ]
        if let due = reminder.due {
            arguments.append("due=\"\(DateParsing.roundTrip(due, calendar: calendar))\"")
        }
        if reminder.priority != .none {
            arguments.append("priority=\"\(reminder.priority.rawValue)\"")
        }
        if let notes = reminder.notes, !notes.isEmpty {
            arguments.append("notes=\"\(notes.replacingOccurrences(of: "\n", with: "\\n"))\"")
        }
        if let url = reminder.url, !url.isEmpty { arguments.append("url=\"\(url)\"") }
        text += "\n\nTo recreate it:\n  create_reminder(\(arguments.joined(separator: ", ")))"

        if reminder.isRecurring {
            // Being explicit beats a recreate call that quietly produces a one-off.
            text += "\n\nNote: this reminder repeated. The call above recreates a single"
            text += "\nreminder, not the recurrence rule."
        }
        return text
    }

    public func status(_ authorization: ReminderAuthorization, binaryPath: String) -> String {
        let headline: String
        switch authorization {
        case .fullAccess: headline = "Reminders permission: GRANTED (full access)."
        case .writeOnly: headline = "Reminders permission: WRITE-ONLY, which is not enough."
        case .denied: headline = "Reminders permission: DENIED."
        case .restricted: headline = "Reminders permission: RESTRICTED by system policy."
        case .notDetermined: headline = "Reminders permission: not requested yet."
        }

        var text = headline + "\n\n"
        text += Self.block([
            ("binary", binaryPath),
            ("time zone", calendar.timeZone.identifier),
            ("process", "pid \(ProcessInfo.processInfo.processIdentifier)"),
            ("default results", "\(Configuration.searchLimit)"),
        ])
        if authorization != .fullAccess {
            text += "\n\n" + ToolError.authorizationMessage(authorization)
        }
        return text
    }
}
