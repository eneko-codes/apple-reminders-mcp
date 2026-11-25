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

    /// `text` on one line and at most `rowFieldWidth` characters, and `field` recorded in
    /// `clipped` when something was cut, so that the result can say so once.
    static func clip(_ text: String, field: String, into clipped: inout [String]) -> String {
        let line = oneLine(text)
        guard line.count > Configuration.rowFieldWidth else { return line }
        if !clipped.contains(field) { clipped.append(field) }
        return String(line.prefix(Configuration.rowFieldWidth)) + "…"
    }

    /// One notice for each field `clip` cut. `tool` reads one item in full.
    static func clippedNotices(_ clipped: [String], tool: String) -> [String] {
        clipped.map {
            Notice.clipped(field: $0, width: Configuration.rowFieldWidth, tool: tool)
        }
    }

    /// A text that can never be read again (a receipt of what was just deleted) cut to at
    /// most `limit` characters, and the sentence that says so. The count of characters kept
    /// is lowered until the UTF-16 length fits too, so the receipt cannot outgrow a result.
    static func unrecoverable(_ text: String, limit: Int) -> (text: String, notice: String?) {
        var kept = Swift.min(limit, text.count)
        var cut = String(text.prefix(kept))
        while cut.utf16.count > limit, kept > 1 {
            kept /= 2
            cut = String(text.prefix(kept))
        }
        guard kept < text.count else { return (text, nil) }
        return (
            cut, "Cut at \(kept) of \(text.count) characters; the rest cannot be read again."
        )
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

    /// A page of `rows` rendered by `render`, which also reports the fields it clipped.
    /// Renders again with half the rows while the text is longer than a result may be, and
    /// builds every notice from what was rendered last, so none of them overstates.
    private func paged<Row>(
        _ rows: [Row], limit: Int, offset: Int, things: String, notices: [String],
        clippedTool: String, render: ([Row], inout [String]) -> String
    ) -> String {
        ToolStandard.fitting(limit) { size in
            let page = Array(rows.dropFirst(offset).prefix(size))
            var clipped: [String] = []
            let text = render(page, &clipped)
            let position = Notice.page(
                offset: offset, count: page.count, total: rows.count, things: things)
            return ToolStandard.withNotices(
                notices + [position].compactMap { $0 }
                    + Self.clippedNotices(clipped, tool: clippedTool),
                text)
        }
    }

    /// The order a listing of lists is in: by name, then account, and then by what the row
    /// shows, so that no two rows that look different can swap places between pages.
    private static func isOrderedBefore(_ left: ListInfo, _ right: ListInfo) -> Bool {
        let titles = left.title.localizedCaseInsensitiveCompare(right.title)
        if titles != .orderedSame { return titles == .orderedAscending }
        if left.title != right.title { return left.title < right.title }
        if left.sourceName != right.sourceName { return left.sourceName < right.sourceName }
        func key(_ list: ListInfo) -> String {
            "\(list.isWritable)\(list.allowsListChanges)\(list.isDefaultForNewReminders)"
                + (list.color?.hex ?? "")
        }
        return key(left) < key(right)
    }

    public func listCatalogue(
        _ lists: [ListInfo], limit: Int, offset: Int, notices: [String]
    ) -> String {
        guard !lists.isEmpty else {
            return ToolStandard.withNotices(notices, "No reminder lists found.")
        }
        let sorted = lists.sorted(by: Self.isOrderedBefore)
        // Nothing is clipped here: a list is addressed by its whole name, so a clipped one
        // could not be passed to another tool.
        return paged(
            sorted, limit: limit, offset: offset, things: "lists", notices: notices,
            clippedTool: ToolCatalog.listsName
        ) { page, _ in
            let titleWidth = Swift.min(page.map(\.title.count).max() ?? 0, Configuration.widestColumn)
            let sourceWidth = Swift.min(
                page.map(\.sourceName.count).max() ?? 0, Configuration.widestColumn)
            let colourWidth = page.compactMap { $0.color?.described.count }.max() ?? 0

            var lines = [
                "\(sorted.count) list\(sorted.count == 1 ? "" : "s") · time zone "
                    + "\(calendar.timeZone.identifier) · ordered by name, then account"
            ]
            if page.isEmpty { lines.append("(nothing at this offset)") }
            for entry in page {
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
    }

    /// The shared body of every list receipt, so a created, renamed and deleted list are
    /// all described in the same shape. `title` and `account` are as the receipt shows them.
    private func listBlock(_ list: ListInfo, title: String, account: String) -> String {
        Self.block([
            ("list", title),
            ("account", account),
            ("color", list.color?.described),
            (
                "writes",
                list.isWritable ? "reminders can be added" : "read-only, reminders cannot be added"
            ),
            ("locked", list.allowsListChanges ? nil : "cannot be renamed, recoloured or deleted"),
            ("default", list.isDefaultForNewReminders ? "new reminders land here" : nil),
        ])
    }

    /// A receipt for a list that still exists: its name and account clipped, with the
    /// notice that `reminder_lists` has them whole.
    private func listReceipt(
        _ list: ListInfo, headline: (_ title: String, _ account: String) -> String
    ) -> String {
        var clipped: [String] = []
        let title = Self.clip(list.title, field: "List name", into: &clipped)
        let account = Self.clip(list.sourceName, field: "Account name", into: &clipped)
        return ToolStandard.withNotices(
            Self.clippedNotices(clipped, tool: ToolCatalog.listsName),
            headline(title, account) + "\n\n" + listBlock(list, title: title, account: account))
    }

    public func createdList(_ list: ListInfo) -> String {
        listReceipt(list) { title, account in "Created list '\(title)' in \(account). It is empty." }
    }

    public func updatedList(_ list: ListInfo, fields: [String], from previous: ListInfo) -> String {
        // The old name is worth stating outright: after a rename every other tool has to be
        // called with the new one, and a caller holding the old name gets listNotFound.
        listReceipt(list) { title, _ in
            var ignored: [String] = []
            let old = Self.clip(previous.title, field: "List name", into: &ignored)
            let headline =
                previous.title == list.title
                ? "Updated list '\(title)'."
                : "Renamed list '\(old)' to '\(title)'."
            return headline + " Fields changed: " + fields.joined(separator: ", ") + "."
        }
    }

    /// Nothing was written because the list already looked like that.
    public func listUnchanged(_ list: ListInfo) -> String {
        listReceipt(list) { title, _ in
            "List '\(title)' already has those values. Nothing was changed."
        }
    }

    public func deletedList(_ list: ListInfo) -> String {
        // What was deleted cannot be read again, so the receipt keeps as much of it as a
        // result may hold and says when it did not.
        let limit = Configuration.deletedFieldCharacters
        let title = Self.unrecoverable(list.title, limit: limit)
        let account = Self.unrecoverable(list.sourceName, limit: limit)

        var text = "Deleted the empty list '\(title.text)' from \(account.text).\n\n"
        text += listBlock(list, title: title.text, account: account.text)

        var arguments = ["title=\"\(title.text)\"", "account=\"\(account.text)\""]
        if let color = list.color { arguments.append("color=\"\(color.described)\"") }
        text += "\n\nTo recreate it:\n  create_list(\(arguments.joined(separator: ", ")))"
        return ToolStandard.withNotices([title.notice, account.notice].compactMap { $0 }, text)
    }

    public func searchResults(
        _ matches: [ReminderSummary], status: CompletionFilter, dueWindow: String?,
        listTitles: [String], limit: Int, offset: Int, notices: [String], now: Date
    ) -> String {
        let scope = listTitles.isEmpty ? "all" : ToolError.few(listTitles)
        // The filters and zone are echoed so a model can catch its own mistake — an empty
        // result because it searched completed reminders — before the reader has to.
        var header =
            "\(matches.count) reminder\(matches.count == 1 ? "" : "s") · \(status.rawValue) · "
            + "lists: \(scope) · \(calendar.timeZone.identifier)"
        if let dueWindow { header += " · " + dueWindow }
        header +=
            " · ordered by due date (soonest first, undated last), then priority, title, id"

        guard !matches.isEmpty else {
            return ToolStandard.withNotices(notices, header + "\nNothing matches.")
        }

        return paged(
            matches, limit: limit, offset: offset, things: "reminders", notices: notices,
            clippedTool: ToolCatalog.getName
        ) { page, clipped in
            let titles = page.map { Self.clip($0.title, field: "Title", into: &clipped) }
            let listNames = page.map { Self.clip($0.listTitle, field: "List name", into: &clipped) }
            let dueTexts = page.map { $0.due.map { due($0) } ?? "—" }
            let dueWidth = dueTexts.map(\.count).max() ?? 0
            // Capped, so that one long title does not widen every other row of the page.
            let titleWidth = Swift.min(titles.map(\.count).max() ?? 0, Configuration.widestColumn)

            var lines = [header]
            if page.isEmpty { lines.append("(nothing at this offset)") }
            for (index, reminder) in page.enumerated() {
                var line = reminder.isCompleted ? "[x]" : "[ ]"
                line += "  " + Self.pad(dueTexts[index], to: dueWidth)
                line += "  " + Self.pad(titles[index], to: titleWidth)
                line += "  [\(listNames[index])]"
                if let mark = Self.priority(reminder.priority) { line += "  " + mark }
                if !reminder.isCompleted, let due = reminder.due, isOverdue(due, now: now) {
                    line += "  overdue"
                }
                if reminder.isRecurring { line += "  repeats" }
                lines.append(line + "  id=\(reminder.id)")
            }
            return lines.joined(separator: "\n")
        }
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

    /// The record of one reminder. With `width` set, every text field is clipped to it and
    /// recorded in `clipped`, and only the first few alarms are listed: that is a receipt.
    /// Without it nothing is cut, and `reminder_get` windows the whole.
    private func detailText(
        _ reminder: ReminderDetail, now: Date, width: Int?, clipped: inout [String]
    ) -> String {
        func shown(_ text: String, _ field: String) -> String {
            guard width != nil else { return text }
            // Notes keep their line breaks in a receipt, which clips by length alone.
            guard field == "Notes" else { return Self.clip(text, field: field, into: &clipped) }
            guard text.count > Configuration.rowFieldWidth else { return text }
            if !clipped.contains(field) { clipped.append(field) }
            return String(text.prefix(Configuration.rowFieldWidth)) + "…"
        }

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

        var alarmOffsets = reminder.alarmOffsetsMinutes
        var moreAlarms = ""
        if width != nil, alarmOffsets.count > Configuration.fewNames {
            moreAlarms = " and \(alarmOffsets.count - Configuration.fewNames) more"
            alarmOffsets = Array(alarmOffsets.sorted { abs($0) < abs($1) }.prefix(Configuration.fewNames))
        }

        var rows: [(String, String?)] = [
            ("due", reminder.due.map { due($0, withYear: true) } ?? "none"),
            (
                "list",
                shown(reminder.listTitle, "List name") + (reminder.listIsWritable ? "" : " (read-only)")
            ),
            ("priority", reminder.priority == .none ? nil : reminder.priority.rawValue),
            ("alarms", Self.alarms(alarmOffsets).map { $0 + moreAlarms }),
            (
                "repeats",
                reminder.isRecurring
                    ? shown(reminder.recurrenceSummary ?? "yes", "Repeat rule") : nil
            ),
        ]
        if let completionDate = reminder.completionDate {
            rows.append(("done", DateParsing.dayWithYear(completionDate, calendar: calendar)
                + " " + DateParsing.time(completionDate, calendar: calendar)))
        }
        rows.append(("url", reminder.url.map { shown($0, "URL") }))
        rows.append(("notes", reminder.notes.map { shown($0, "Notes") }))
        rows.append(("id", reminder.id))
        rows.append(("state", state))

        return (reminder.isCompleted ? "[x] " : "[ ] ") + shown(reminder.title, "Title") + "\n"
            + Self.block(rows)
    }

    /// `reminder_get`: the whole record, read through a window.
    public func detailWindow(
        _ reminder: ReminderDetail, characterOffset: Int, maxCharacters: Int, notices: [String],
        now: Date
    ) -> String {
        var unused: [String] = []
        let whole = detailText(reminder, now: now, width: nil, clipped: &unused)
        return ToolStandard.fitting(maxCharacters) { size in
            let window = ToolStandard.window(
                of: whole, characterOffset: characterOffset, maxCharacters: size)
            return ToolStandard.withNotices(
                notices + [window.notice].compactMap { $0 }, window.text)
        }
    }

    /// A receipt: what a write did, then the record clipped to the width of a row. The
    /// notices that say what was clipped go first.
    private func receipt(
        _ reminder: ReminderDetail, now: Date, headline: (_ title: String) -> String,
        between: String = ""
    ) -> String {
        var clipped: [String] = []
        let title = Self.clip(reminder.title, field: "Title", into: &clipped)
        let record = detailText(
            reminder, now: now, width: Configuration.rowFieldWidth, clipped: &clipped)
        return ToolStandard.withNotices(
            Self.clippedNotices(clipped, tool: ToolCatalog.getName),
            headline(title) + between + "\n\n" + record)
    }

    public func created(_ reminder: ReminderDetail, now: Date, alarmWasImplied: Bool) -> String {
        var extra = ""
        if alarmWasImplied {
            // Never silent: the server added something the caller did not ask for, and a
            // notification arriving unannounced is exactly the kind of surprise that
            // makes people distrust a tool.
            extra += "\n\nAn alarm was set for the due time. EventKit does not add one by"
            extra += "\nitself, so a reminder saved with a time would never actually notify."
            extra += "\nPass alarms=[] to create one that stays silent."
        }
        if reminder.isOverdue(asOf: now, calendar: calendar) {
            extra += "\n\n⚠ This reminder is already overdue."
        }
        return receipt(
            reminder, now: now,
            headline: { "Created reminder '\($0)' in \(Self.listName(reminder.listTitle))." },
            between: extra)
    }

    public func updated(_ reminder: ReminderDetail, fields: [String], now: Date) -> String {
        // An update with nothing to change is refused before it reaches the store, so
        // `fields` is never empty here.
        receipt(
            reminder, now: now,
            headline: { "Updated reminder '\($0)'. Fields changed: " + fields.joined(separator: ", ") + "." })
    }

    public func completed(_ reminder: ReminderDetail, now: Date) -> String {
        var extra = ""
        if reminder.isCompleted && reminder.isRecurring {
            // Completing a repeating reminder does not close it, it rolls it forward.
            // A caller told only "completed" would reasonably expect it to be gone.
            extra += "\n\nThis one repeats, so Reminders may roll it forward to its next due"
            extra += "\ndate rather than closing it. The record below is what the store"
            extra += "\nreturned immediately after the change."
        }
        return receipt(
            reminder, now: now,
            headline: {
                reminder.isCompleted
                    ? "Completed '\($0)'."
                    : "Reopened '\($0)'. It is an ordinary open reminder again."
            }, between: extra)
    }

    /// Nothing was written, and saying so matters: re-completing a completed reminder
    /// would have reset its completion date to now and destroyed the record of when the
    /// thing was actually done.
    public func completionUnchanged(_ reminder: ReminderDetail, now: Date) -> String {
        let state = reminder.isCompleted ? "already completed" : "already open"
        return receipt(
            reminder, now: now,
            headline: { "'\($0)' is \(state). Nothing was changed." })
    }

    /// A delete has to leave behind enough to undo it by hand, and what it removed cannot
    /// be read again. Each text is shown once, in the call that would restore it, and cut
    /// at a stated width so that the receipt stays inside a result.
    public func deleted(_ reminder: ReminderDetail) -> String {
        var ignored: [String] = []
        let fieldLimit = Configuration.deletedFieldCharacters
        let title = Self.unrecoverable(reminder.title, limit: fieldLimit)
        let list = Self.unrecoverable(reminder.listTitle, limit: fieldLimit)
        let url = reminder.url.map { Self.unrecoverable($0, limit: fieldLimit) }
        // Escaped before it is cut: the escape makes the text longer, and the cut is what
        // keeps it inside a result.
        let notes = reminder.notes.flatMap { $0.isEmpty ? nil : $0 }.map {
            Self.unrecoverable(
                $0.replacingOccurrences(of: "\n", with: "\\n"),
                limit: Configuration.deletedRecordCharacters)
        }

        var text =
            "Deleted '\(Self.clip(reminder.title, field: "Title", into: &ignored))' from "
            + "\(Self.clip(reminder.listTitle, field: "List name", into: &ignored)).\n\n"
        text += Self.block([
            ("title", title.text),
            ("due", reminder.due.map { due($0, withYear: true) } ?? "none"),
            ("priority", reminder.priority == .none ? nil : reminder.priority.rawValue),
            ("id", "\(reminder.id) (no longer exists)"),
        ])

        var arguments = [
            "list=\"\(list.text)\"",
            "title=\"\(title.text)\"",
        ]
        if let due = reminder.due {
            arguments.append("due=\"\(DateParsing.roundTrip(due, calendar: calendar))\"")
        }
        if reminder.priority != .none {
            arguments.append("priority=\"\(reminder.priority.rawValue)\"")
        }
        if let notes { arguments.append("notes=\"\(notes.text)\"") }
        if let url { arguments.append("url=\"\(url.text)\"") }
        text += "\n\nTo recreate it:\n  create_reminder(\(arguments.joined(separator: ", ")))"

        if reminder.isRecurring {
            // Being explicit beats a recreate call that quietly produces a one-off.
            text += "\n\nNote: this reminder repeated. The call above recreates a single"
            text += "\nreminder, not the recurrence rule."
        }
        let notices = [title.notice, list.notice, notes?.notice, url?.notice].compactMap { $0 }
        return ToolStandard.withNotices(notices, text)
    }

    /// A list name as a receipt headline shows it: one line, clipped. The record below it
    /// has the same clip and the notice.
    private static func listName(_ name: String) -> String {
        var ignored: [String] = []
        return clip(name, field: "List name", into: &ignored)
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
            ("default results", "\(Configuration.defaultSearchLimit)"),
        ])
        if authorization != .fullAccess {
            text += "\n\n" + ToolError.authorizationMessage(authorization)
        }
        return text
    }
}
