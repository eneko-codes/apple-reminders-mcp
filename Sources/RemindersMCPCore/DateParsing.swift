import Foundation

public struct ParsedDate: Sendable, Equatable {
    public let date: Date
    /// True when the caller wrote only a day. `create_reminder` uses this to decide
    /// whether the due date carries a time: there is no separate flag, because two
    /// sources of truth for the same fact drift apart.
    public let isDateOnly: Bool

    public init(date: Date, isDateOnly: Bool) {
        self.date = date
        self.isDateOnly = isDateOnly
    }

    public var due: DueDate { DueDate(date: date, isDateOnly: isDateOnly) }
}

/// Parsing and rendering of the three date forms this server accepts.
///
/// Deliberately strict. A lenient parser that guesses at `10/08/2026` will one day read
/// it as 8 October for a caller who meant 10 August, and a server that silently moves a
/// deadline by two months is worse than one that refuses the input.
public enum DateParsing {

    public static let acceptedForms = """
        - 2026-08-12                  that day, no particular time
        - 2026-08-12T09:00            local time
        - 2026-08-12T09:00:00+02:00   explicit offset
        """

    public static func parse(_ raw: String, argument: String, calendar: Calendar) throws
        -> ParsedDate
    {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)

        if let components = dayComponents(text) {
            guard let day = calendar.date(from: components) else {
                throw ToolError.badDate(argument: argument, value: text)
            }
            return ParsedDate(date: calendar.startOfDay(for: day), isDateOnly: true)
        }

        if let components = localComponents(text) {
            guard let moment = calendar.date(from: components) else {
                throw ToolError.badDate(argument: argument, value: text)
            }
            return ParsedDate(date: moment, isDateOnly: false)
        }

        // Only reached for a string carrying its own offset or Z suffix, where the
        // machine's time zone is irrelevant.
        let optionSets: [ISO8601DateFormatter.Options] = [
            [.withInternetDateTime],
            [.withInternetDateTime, .withFractionalSeconds],
        ]
        for options in optionSets {
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = options
            if let moment = formatter.date(from: text) {
                return ParsedDate(date: moment, isDateOnly: false)
            }
        }

        throw ToolError.badDate(argument: argument, value: text)
    }

    /// `YYYY-MM-DD` and nothing else.
    private static func dayComponents(_ text: String) -> DateComponents? {
        let parts = text.split(separator: "-", omittingEmptySubsequences: false)
        guard parts.count == 3, parts[0].count == 4, parts[1].count == 2, parts[2].count == 2,
            let year = Int(parts[0]), let month = Int(parts[1]), let day = Int(parts[2]),
            (1...12).contains(month), (1...31).contains(day)
        else { return nil }
        return DateComponents(year: year, month: month, day: day)
    }

    /// `YYYY-MM-DDTHH:MM` or `YYYY-MM-DDTHH:MM:SS`, with no offset suffix.
    private static func localComponents(_ text: String) -> DateComponents? {
        let halves = text.split(separator: "T", omittingEmptySubsequences: false)
        guard halves.count == 2, var day = dayComponents(String(halves[0])) else { return nil }

        let time = halves[1]
        // A trailing Z or offset means the string is absolute; that is the ISO path.
        guard !time.contains("Z"), !time.contains("+"), time.filter({ $0 == "-" }).isEmpty
        else { return nil }

        let pieces = time.split(separator: ":")
        guard (2...3).contains(pieces.count), pieces.allSatisfy({ $0.count == 2 }),
            let hour = Int(pieces[0]), let minute = Int(pieces[1]),
            (0...23).contains(hour), (0...59).contains(minute)
        else { return nil }
        let second = pieces.count == 3 ? Int(pieces[2]) : 0
        guard let second, (0...59).contains(second) else { return nil }

        day.hour = hour
        day.minute = minute
        day.second = second
        return day
    }

    // MARK: EventKit date components

    /// The same time zone, but always the Gregorian calendar.
    ///
    /// **This is a crash guard, not a formatting preference.** `EKReminder` raises an
    /// Objective-C exception — which Swift cannot catch, so the process dies and the
    /// server disappears mid-session — if `dueDateComponents` carries any calendar other
    /// than Gregorian. `Calendar.current` follows the region setting in System Settings,
    /// so on a Mac configured for the Buddhist or Islamic calendar the obvious code would
    /// hand EventKit exactly that.
    public static func gregorian(_ calendar: Calendar) -> Calendar {
        var gregorian = Calendar(identifier: .gregorian)
        gregorian.timeZone = calendar.timeZone
        return gregorian
    }

    /// The components EventKit stores for a due date.
    ///
    /// Omitting the time components is what makes a reminder all-day; EventKit reads their
    /// absence as the signal, so a date-only due date must not carry a zeroed hour.
    ///
    /// No time zone is set, which EventKit calls a floating date: "due at 09:00" means
    /// nine o'clock wherever the person happens to be, matching what Reminders.app does.
    public static func dueComponents(_ due: DueDate, calendar: Calendar) -> DateComponents {
        let gregorian = gregorian(calendar)
        var components = gregorian.dateComponents(
            due.isDateOnly ? [.year, .month, .day] : [.year, .month, .day, .hour, .minute],
            from: due.date)
        // dateComponents(_:from:) stamps its own calendar onto the result, and that is
        // precisely the value EventKit refuses. Set it explicitly rather than relying on
        // whatever `calendar` happened to be.
        components.calendar = gregorian
        components.timeZone = nil
        return components
    }

    /// Reads EventKit's stored components back into a due date.
    ///
    /// Returns nil rather than a guess when the components cannot be resolved: a reminder
    /// with an unusable due date is better reported as undated than as due at a date
    /// nobody set.
    public static func due(from components: DateComponents?, calendar: Calendar) -> DueDate? {
        guard let components else { return nil }
        let gregorian = gregorian(calendar)
        // The components carry their own calendar and time zone when EventKit set them;
        // resolving through a Gregorian calendar in the machine's zone is what makes a
        // floating date mean local time.
        var resolved = components
        resolved.calendar = gregorian
        guard let date = gregorian.date(from: resolved) else { return nil }
        return DueDate(date: date, isDateOnly: components.hour == nil)
    }

    // MARK: Rendering

    private static let weekdays = ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"]
    private static let months = [
        "Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec",
    ]

    /// Hand-rolled rather than `DateFormatter` so output does not change shape with the
    /// machine's locale. A model that has learned to read `Mon 10 Aug` should not be
    /// handed `lun 10 ago` on a differently configured Mac.
    public static func day(_ date: Date, calendar: Calendar) -> String {
        let parts = calendar.dateComponents([.weekday, .day, .month], from: date)
        let weekday = parts.weekday.map { weekdays[($0 - 1) % 7] } ?? "???"
        let month = parts.month.map { months[($0 - 1) % 12] } ?? "???"
        return String(format: "%@ %02d %@", weekday, parts.day ?? 0, month)
    }

    public static func dayWithYear(_ date: Date, calendar: Calendar) -> String {
        let year = calendar.component(.year, from: date)
        return "\(day(date, calendar: calendar)) \(year)"
    }

    public static func time(_ date: Date, calendar: Calendar) -> String {
        let parts = calendar.dateComponents([.hour, .minute], from: date)
        return String(format: "%02d:%02d", parts.hour ?? 0, parts.minute ?? 0)
    }

    /// `2026-08-12T09:00` — the form `create_reminder` accepts, so a delete can print a
    /// recreate call that actually parses.
    public static func roundTrip(_ date: Date, isDateOnly: Bool, calendar: Calendar) -> String {
        let parts = calendar.dateComponents([.year, .month, .day, .hour, .minute], from: date)
        let day = String(
            format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
        guard !isDateOnly else { return day }
        return day + String(format: "T%02d:%02d", parts.hour ?? 0, parts.minute ?? 0)
    }

    public static func roundTrip(_ due: DueDate, calendar: Calendar) -> String {
        roundTrip(due.date, isDateOnly: due.isDateOnly, calendar: calendar)
    }
}
