import Foundation
import MCP

/// Typed access to a `tools/call` argument bag.
///
/// As in the sibling calendar and contacts servers, an absent key and an explicit `null`
/// mean different things: omitting `notes` leaves it alone, passing `notes: null` clears
/// it.
public struct Arguments {
    private let values: [String: Value]
    private let calendar: Calendar

    public init(_ values: [String: Value]?, calendar: Calendar) {
        self.values = values ?? [:]
        self.calendar = calendar
    }

    // MARK: Scalars

    public func requiredString(_ name: String) throws -> String {
        guard let raw = values[name]?.stringValue else { throw ToolError.missingArgument(name) }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw ToolError.badArgument(name: name, reason: "it is empty")
        }
        return trimmed
    }

    public func optionalString(_ name: String) -> String? {
        guard let text = values[name]?.stringValue else { return nil }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    public func bool(_ name: String, default fallback: Bool = false) -> Bool {
        values[name]?.boolValue ?? fallback
    }

    /// Clamps rather than rejects: a model asking for 500 results means "as many as you
    /// will give me".
    public func int(_ name: String, default fallback: Int, in range: ClosedRange<Int>) throws
        -> Int
    {
        guard let raw = values[name] else { return fallback }
        guard let number = raw.intValue else {
            throw ToolError.badArgument(name: name, reason: "an integer was expected")
        }
        return Swift.min(Swift.max(number, range.lowerBound), range.upperBound)
    }

    public func stringArray(_ name: String) throws -> [String] {
        guard let raw = values[name] else { return [] }
        if case .null = raw { return [] }
        // A single string where an array is expected is a common and harmless slip.
        if let single = raw.stringValue { return [single] }
        guard let entries = raw.arrayValue else {
            throw ToolError.badArgument(name: name, reason: "an array of strings was expected")
        }
        return entries.compactMap(\.stringValue)
    }

    // MARK: Dates

    public func requiredDate(_ name: String) throws -> ParsedDate {
        try DateParsing.parse(try requiredString(name), argument: name, calendar: calendar)
    }

    public func optionalDate(_ name: String) throws -> ParsedDate? {
        guard let raw = optionalString(name) else { return nil }
        return try DateParsing.parse(raw, argument: name, calendar: calendar)
    }

    // MARK: Enumerations

    /// Absent means no priority, which is also what Reminders.app shows for a new task.
    public func priority(_ name: String) throws -> Priority {
        guard let raw = optionalString(name) else { return .none }
        guard let priority = Priority(rawValue: raw.lowercased()) else {
            throw ToolError.badArgument(
                name: name,
                reason: "expected \(Self.list(Priority.allCases.map(\.rawValue))), got \"\(raw)\"")
        }
        return priority
    }

    public func status(_ name: String) throws -> CompletionFilter {
        guard let raw = optionalString(name) else { return .incomplete }
        guard let status = CompletionFilter(rawValue: raw.lowercased()) else {
            throw ToolError.badArgument(
                name: name,
                reason:
                    "expected \(Self.list(CompletionFilter.allCases.map(\.rawValue))), got \"\(raw)\""
            )
        }
        return status
    }

    /// A palette name, or `#RRGGBB`. Absent means the caller said nothing about colour,
    /// which for a new list leaves the choice to Reminders.
    public func listColor(_ name: String) throws -> ListColor? {
        guard let raw = optionalString(name) else { return nil }
        if let named = ListColor.named(raw) { return named }
        // Tried second so a palette name always wins: "red" is unambiguous, and a caller
        // writing it means the swatch, not some particular shade of it.
        if let parsed = ListColor(hex: raw) { return parsed }
        throw ToolError.badArgument(
            name: name,
            reason: """
                expected \(Self.list(ListColor.paletteNames)) or a hex value like \
                "#FF9500", got "\(raw)"
                """)
    }

    private static func list(_ values: [String]) -> String {
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
                reason: "\"\(raw)\" is not an offset; use \"-15m\", \"-1h\", \"-1d\" or \"0\"")
        }
        return magnitude * multiplier
    }

    /// nil when the caller said nothing, empty when they explicitly asked for none.
    public func alarms(_ name: String) throws -> [Int]? {
        guard let raw = values[name] else { return nil }
        if case .null = raw { return [] }
        guard let entries = raw.arrayValue else {
            throw ToolError.badArgument(name: name, reason: "an array of offsets was expected")
        }
        return try entries.map { entry in
            guard let text = entry.stringValue else {
                if let number = entry.intValue { return number }
                throw ToolError.badArgument(
                    name: name, reason: "each alarm must be a string like \"-15m\"")
            }
            return try Self.alarmMinutes(text)
        }
    }

    // MARK: Edits

    public func stringEdit(_ name: String) -> FieldEdit<String> {
        guard let raw = values[name] else { return .unchanged }
        if case .null = raw { return .cleared }
        guard let text = raw.stringValue else { return .unchanged }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
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
        if case .null = raw { return .cleared }
        guard let text = raw.stringValue else { return .unchanged }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .cleared }
        return .set(try DateParsing.parse(trimmed, argument: name, calendar: calendar).due)
    }

    /// `"none"` and null both mean the same thing to EventKit — priority 0 — so both are
    /// reported as a clear.
    public func priorityEdit(_ name: String) throws -> FieldEdit<Priority> {
        guard let raw = values[name] else { return .unchanged }
        if case .null = raw { return .cleared }
        guard raw.stringValue != nil else { return .unchanged }
        let priority = try priority(name)
        return priority == .none ? .cleared : .set(priority)
    }

    public func alarmEdit(_ name: String) throws -> FieldEdit<[Int]> {
        guard let parsed = try alarms(name) else { return .unchanged }
        return parsed.isEmpty ? .cleared : .set(parsed)
    }
}
