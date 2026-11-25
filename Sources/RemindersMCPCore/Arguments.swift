import Foundation

/// Typed access to a `tools/call` argument bag.
///
/// A class, not a struct, so that reading a number can also record that it was moved into
/// its range without every reader having to be `mutating`. One instance serves one call and
/// never leaves it. The tool puts `notices` before the data.
///
/// For a field an update may empty, an absent key and an explicit `null` mean different
/// things: omitting `notes` leaves it alone, passing `notes: null` clears it. Everywhere
/// else `null` is the same as not given.
public final class Arguments {
    private let values: [String: Value]
    private let calendar: Calendar

    /// One sentence for each number that was moved into its range, in the order read.
    public private(set) var notices: [String] = []

    public init(_ values: [String: Value]?, calendar: Calendar) {
        self.values = values ?? [:]
        self.calendar = calendar
    }

    /// `nil` when the argument is absent or null.
    private func given(_ name: String) -> Value? {
        guard let raw = values[name], !raw.isNull else { return nil }
        return raw
    }

    private func text(_ raw: Value, _ name: String) throws -> String {
        guard let text = raw.stringValue else {
            throw ToolError.badArgument(name: name, reason: "text was expected")
        }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Refuses a name the tool's schema does not list, with the names that are allowed.
    public func only(_ allowed: [String]) throws {
        let unknown = values.keys.filter { !allowed.contains($0) }.sorted()
        guard unknown.isEmpty else {
            throw ToolError.unknownArguments(names: unknown, allowed: allowed.sorted())
        }
    }

    // MARK: Scalars

    public func requiredString(_ name: String) throws -> String {
        guard let raw = given(name) else { throw ToolError.missingArgument(name) }
        let trimmed = try text(raw, name)
        guard !trimmed.isEmpty else {
            throw ToolError.badArgument(name: name, reason: "it is empty")
        }
        return trimmed
    }

    public func optionalString(_ name: String) throws -> String? {
        guard let raw = given(name) else { return nil }
        let trimmed = try text(raw, name)
        return trimmed.isEmpty ? nil : trimmed
    }

    public func bool(_ name: String, default fallback: Bool = false) throws -> Bool {
        guard let raw = given(name) else { return fallback }
        guard let flag = raw.boolValue else {
            throw ToolError.badArgument(name: name, reason: "true or false was expected")
        }
        return flag
    }

    /// A quantity: a size or a count. Outside its range it is moved to the nearest allowed
    /// value, and `notices` gains the sentence that says which value was used.
    public func int(_ name: String, default fallback: Int, in range: ClosedRange<Int>) throws
        -> Int
    {
        guard let raw = given(name) else { return fallback }
        guard let number = raw.intValue else {
            throw ToolError.badArgument(name: name, reason: "a whole number was expected")
        }
        return ToolStandard.clamp(number, to: range, argument: name, notices: &notices)
    }

    /// The `limit` and `offset` of a listing, read the same way by every tool that pages.
    public func page(defaultLimit: Int, limits: ClosedRange<Int>) throws -> (limit: Int, offset: Int) {
        (
            try int("limit", default: defaultLimit, in: limits),
            try int("offset", default: 0, in: Configuration.offsetRange)
        )
    }

    /// The `character_offset` and `max_characters` of a window on one long text.
    public func window() throws -> (characterOffset: Int, maxCharacters: Int) {
        (
            try int("character_offset", default: 0, in: Configuration.offsetRange),
            try int(
                "max_characters", default: Configuration.defaultMaxCharacters,
                in: Configuration.maxCharactersRange)
        )
    }

    public func stringArray(_ name: String) throws -> [String] {
        guard let raw = given(name) else { return [] }
        // A single string where an array is expected is a common and harmless slip.
        let entries = raw.stringValue.map { [Value.string($0)] } ?? raw.arrayValue
        guard let entries, entries.allSatisfy({ $0.stringValue != nil }) else {
            throw ToolError.badArgument(name: name, reason: "an array of text was expected")
        }
        // An empty entry is not given, as an empty text argument is not.
        return entries.compactMap(\.stringValue)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
    }

    // MARK: Dates

    public func optionalDate(_ name: String) throws -> ParsedDate? {
        guard let raw = try optionalString(name) else { return nil }
        return try DateParsing.parse(raw, argument: name, calendar: calendar)
    }

    // MARK: Enumerations

    /// One of a fixed set of words, compared case-insensitively. `nil` when not given.
    private func word<Word: RawRepresentable & CaseIterable>(_ name: String, _ raw: Value) throws
        -> Word? where Word.RawValue == String
    {
        let written = try text(raw, name)
        guard !written.isEmpty else { return nil }
        guard let word = Word(rawValue: written.lowercased()) else {
            throw ToolError.badArgument(
                name: name,
                reason:
                    "expected \(Self.quoted(Word.allCases.map(\.rawValue))), got \"\(ToolStandard.echo(written))\""
            )
        }
        return word
    }

    /// Absent means no priority, which is also what Reminders.app shows for a new task.
    public func priority(_ name: String) throws -> Priority {
        guard let raw = given(name) else { return .none }
        return try word(name, raw) ?? .none
    }

    public func status(_ name: String) throws -> CompletionFilter {
        guard let raw = given(name) else { return .incomplete }
        return try word(name, raw) ?? .incomplete
    }

    /// A palette name, or `#RRGGBB`. Absent means the caller said nothing about colour,
    /// which for a new list leaves the choice to Reminders.
    public func listColor(_ name: String) throws -> ListColor? {
        guard let raw = try optionalString(name) else { return nil }
        if let named = ListColor.named(raw) { return named }
        // Tried second so a palette name always wins: "red" is unambiguous, and a caller
        // writing it means the swatch, not some particular shade of it.
        if let parsed = ListColor(hex: raw) { return parsed }
        throw ToolError.badArgument(
            name: name,
            reason: """
                expected \(Self.quoted(ListColor.paletteNames)) or a hex value like \
                "#FF9500", got "\(ToolStandard.echo(raw))"
                """)
    }

    private static func quoted(_ values: [String]) -> String {
        values.map { "\"\($0)\"" }.joined(separator: ", ")
    }

    // MARK: Alarms

    /// `-15m`, `-1h`, `-1d`, `0`. Returns minutes, negative meaning before the due date.
    ///
    /// A bare number is read as minutes so `-15` behaves like `-15m` rather than being
    /// rejected on a technicality.
    public static func alarmMinutes(_ raw: String) throws -> Int {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !text.isEmpty else {
            throw ToolError.badArgument(name: "alarms", reason: "an alarm entry is empty")
        }

        let multiplier: Int
        var digits = text
        switch text.last {
        case "m": multiplier = 1; digits = String(text.dropLast())
        case "h": multiplier = 60; digits = String(text.dropLast())
        case "d": multiplier = 1440; digits = String(text.dropLast())
        default: multiplier = 1
        }

        guard let magnitude = Int(digits) else {
            throw ToolError.badArgument(
                name: "alarms",
                reason:
                    "\"\(ToolStandard.echo(raw))\" is not an offset; use \"-15m\", \"-1h\", \"-1d\" or \"0\"")
        }
        // Multiplied with a check, because a number of days near the top of Int would
        // otherwise trap and take the server down with it.
        let (minutes, overflow) = magnitude.multipliedReportingOverflow(by: multiplier)
        guard !overflow else { throw ToolError.alarmTooFar }
        return try alarmWithinReach(minutes)
    }

    /// An alarm outside the range is refused, not moved: the nearest allowed offset would
    /// be a different alarm from the one asked for.
    private static func alarmWithinReach(_ minutes: Int) throws -> Int {
        guard Configuration.alarmMinutesRange.contains(minutes) else { throw ToolError.alarmTooFar }
        return minutes
    }

    /// `nil` when not given; empty when given as `null` or `[]`.
    public func alarms(_ name: String) throws -> [Int]? {
        guard let raw = values[name] else { return nil }
        if raw.isNull { return [] }
        guard let entries = raw.arrayValue else {
            throw ToolError.badArgument(name: name, reason: "an array of offsets was expected")
        }
        return try entries.map { entry in
            guard let text = entry.stringValue else {
                if let number = entry.intValue { return try Self.alarmWithinReach(number) }
                throw ToolError.badArgument(
                    name: name, reason: "each alarm must be text like \"-15m\"")
            }
            return try Self.alarmMinutes(text)
        }
    }

    // MARK: Edits

    public func stringEdit(_ name: String) throws -> FieldEdit<String> {
        guard let raw = values[name] else { return .unchanged }
        if raw.isNull { return .cleared }
        let trimmed = try text(raw, name)
        return trimmed.isEmpty ? .cleared : .set(trimmed)
    }

    /// Unlike a calendar event, a reminder is perfectly valid with no due date at all, so
    /// emptying this field clears the deadline rather than being an error.
    ///
    /// An empty string is the form the schema can advertise — see `ToolCatalog` on why a
    /// nullable type cannot survive to the model — and null does the same thing for any
    /// caller that sends it.
    public func dueEdit(_ name: String) throws -> FieldEdit<DueDate> {
        guard let raw = values[name] else { return .unchanged }
        if raw.isNull { return .cleared }
        let trimmed = try text(raw, name)
        guard !trimmed.isEmpty else { return .cleared }
        return .set(try DateParsing.parse(trimmed, argument: name, calendar: calendar).due)
    }

    /// `"none"`, an empty string and null all mean the same thing to EventKit — priority
    /// 0 — so all three are reported as a clear.
    public func priorityEdit(_ name: String) throws -> FieldEdit<Priority> {
        guard let raw = values[name] else { return .unchanged }
        if raw.isNull { return .cleared }
        guard let priority: Priority = try word(name, raw), priority != .none else {
            return .cleared
        }
        return .set(priority)
    }

    public func alarmEdit(_ name: String) throws -> FieldEdit<[Int]> {
        guard let parsed = try alarms(name) else { return .unchanged }
        return parsed.isEmpty ? .cleared : .set(parsed)
    }
}
