import Foundation

/// A reminder list, which EventKit models as an `EKCalendar` of the reminder entity.
///
/// Called a "list" everywhere in this server because that is the word Reminders.app puts
/// on screen. Borrowing EventKit's internal vocabulary would only make the model guess.
///
/// Lists are addressed by title, and by account when a title is not unique. There is a
/// `calendarIdentifier`, but EventKit's own header warns it is no more sync-proof than a
/// reminder's, so exposing it would only invite callers to cache something that expires.
public struct ListInfo: Sendable, Equatable {
    public let title: String
    public let sourceName: String
    /// Whether reminders can be added to, edited in and removed from this list.
    public let isWritable: Bool
    /// Whether the list *itself* can be renamed, recoloured or deleted.
    ///
    /// A different question from `isWritable`, and EventKit answers them separately: a
    /// subscribed list refuses attribute changes while still reporting on its contents.
    /// Conflating the two would produce a rename that fails with EventKit's own error
    /// text rather than a sentence explaining why.
    public let allowsListChanges: Bool
    public let isDefaultForNewReminders: Bool
    public let color: ListColor?

    public init(
        title: String, sourceName: String, isWritable: Bool, allowsListChanges: Bool = true,
        isDefaultForNewReminders: Bool, color: ListColor? = nil
    ) {
        self.title = title
        self.sourceName = sourceName
        self.isWritable = isWritable
        self.allowsListChanges = allowsListChanges
        self.isDefaultForNewReminders = isDefaultForNewReminders
        self.color = color
    }
}

/// A list colour, held as 8-bit sRGB — which is exactly what a `#RRGGBB` string carries.
///
/// Deliberately not stored as floating-point components. A colour read back out of
/// EventKit arrives as `CGFloat`s that have been through at least one colour-space
/// conversion, so `0.2` comes back as `0.20000000298`; comparing those to a palette table
/// would make "is this still blue?" depend on rounding. Quantising to the byte values the
/// colour is displayed and round-tripped in makes equality mean what a reader expects.
public struct ListColor: Sendable, Equatable, Hashable {
    public let red: UInt8
    public let green: UInt8
    public let blue: UInt8

    public init(red: UInt8, green: UInt8, blue: UInt8) {
        self.red = red
        self.green = green
        self.blue = blue
    }

    /// `#RRGGBB`, with or without the leading `#`. Any other shape is rejected rather than
    /// guessed at — a three-digit shorthand or a stray alpha channel would otherwise
    /// silently produce a colour nobody asked for.
    public init?(hex: String) {
        var text = hex.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        if text.hasPrefix("#") { text.removeFirst() }
        guard text.count == 6, let value = UInt32(text, radix: 16) else { return nil }
        self.init(
            red: UInt8((value >> 16) & 0xFF),
            green: UInt8((value >> 8) & 0xFF),
            blue: UInt8(value & 0xFF))
    }

    public var hex: String { String(format: "#%02X%02X%02X", red, green, blue) }

    /// Apple's system palette, which is what Reminders.app draws its swatches from.
    ///
    /// Named colours exist because a model asked for "a blue list" would otherwise invent
    /// a hex code, and the owner would end up with a shade that appears nowhere in the
    /// app's own picker. These are the standard system values; a swatch chosen by hand in
    /// Reminders.app is drawn from the same palette but is not promised to be byte-equal,
    /// which is why reading a colour reports the hex whenever it does not match a name.
    public static let palette: [(name: String, color: ListColor)] = [
        ("red", ListColor(red: 0xFF, green: 0x3B, blue: 0x30)),
        ("orange", ListColor(red: 0xFF, green: 0x95, blue: 0x00)),
        ("yellow", ListColor(red: 0xFF, green: 0xCC, blue: 0x00)),
        ("green", ListColor(red: 0x34, green: 0xC7, blue: 0x59)),
        ("mint", ListColor(red: 0x00, green: 0xC7, blue: 0xBE)),
        ("teal", ListColor(red: 0x30, green: 0xB0, blue: 0xC7)),
        ("blue", ListColor(red: 0x00, green: 0x7A, blue: 0xFF)),
        ("indigo", ListColor(red: 0x58, green: 0x56, blue: 0xD6)),
        ("purple", ListColor(red: 0xAF, green: 0x52, blue: 0xDE)),
        ("pink", ListColor(red: 0xFF, green: 0x2D, blue: 0x55)),
        ("brown", ListColor(red: 0xA2, green: 0x84, blue: 0x5E)),
        ("gray", ListColor(red: 0x8E, green: 0x8E, blue: 0x93)),
    ]

    public static var paletteNames: [String] { palette.map(\.name) }

    public static func named(_ name: String) -> ListColor? {
        let wanted = name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return palette.first { $0.name == wanted }?.color
    }

    /// The palette name for this colour, when it is one of them.
    public var name: String? { Self.palette.first { $0.color == self }?.name }

    /// What a reader should be shown: the name when there is one, the hex otherwise.
    public var described: String { name ?? hex }
}

public struct ListDraft: Sendable, Equatable {
    public var title: String
    /// nil means the account the default list already lives in, which is the least
    /// surprising home for a new one.
    public var accountName: String?
    /// nil leaves the choice to Reminders, which assigns one of its own.
    public var color: ListColor?

    public init(title: String, accountName: String? = nil, color: ListColor? = nil) {
        self.title = title
        self.accountName = accountName
        self.color = color
    }
}

/// Plain optionals rather than `FieldEdit`, because neither field can be cleared: a list
/// with no name cannot be addressed, and EventKit offers no way to un-set a colour once
/// one has been assigned. A three-state edit would advertise a "clear" that does not exist.
public struct ListChanges: Sendable, Equatable {
    public var title: String?
    public var color: ListColor?

    public init(title: String? = nil, color: ListColor? = nil) {
        self.title = title
        self.color = color
    }

    public var changedFields: [String] {
        var names: [String] = []
        if title != nil { names.append("title") }
        if color != nil { names.append("color") }
        return names
    }

    public var isEmpty: Bool { changedFields.isEmpty }
}

/// Named priorities, because RFC 5545 numbers say nothing on their own.
///
/// EventKit stores an integer from 0 to 9 and **refuses to save anything outside that
/// range**. Reading is deliberately more tolerant than writing: another CalDAV client may
/// legitimately have written 3, which is "high" per the RFC even though this server would
/// only ever write 1.
public enum Priority: String, Sendable, Equatable, CaseIterable {
    case none
    case high
    case medium
    case low

    /// The value this server writes. The RFC's bands are wider than these four points,
    /// but picking one representative per band keeps a round-trip stable.
    public var rfc5545: Int {
        switch self {
        case .none: return 0
        case .high: return 1
        case .medium: return 5
        case .low: return 9
        }
    }

    /// Reads the full RFC bands: 1–4 high, 5 medium, 6–9 low, 0 none.
    ///
    /// Anything outside 0...9 cannot have come from EventKit, so it is reported as no
    /// priority rather than guessed at.
    public init(rfc5545 value: Int) {
        switch value {
        case 1...4: self = .high
        case 5: self = .medium
        case 6...9: self = .low
        default: self = .none
        }
    }
}

/// Which reminders a search should consider.
public enum CompletionFilter: String, Sendable, Equatable, CaseIterable {
    case incomplete
    case completed
    case any
}

/// A due date, and whether the caller expressed it as a whole day.
///
/// EventKit stores this as `NSDateComponents`: components carrying no time make the
/// reminder all-day. The flag is kept alongside the instant because that distinction is
/// invisible once the components have been resolved to a `Date` — midnight is a perfectly
/// good time of day.
public struct DueDate: Sendable, Equatable {
    public let date: Date
    public let isDateOnly: Bool

    public init(date: Date, isDateOnly: Bool) {
        self.date = date
        self.isDateOnly = isDateOnly
    }
}

public struct ReminderSummary: Sendable, Equatable {
    public let id: String
    public let title: String
    public let listTitle: String
    public let due: DueDate?
    public let priority: Priority
    public let isCompleted: Bool
    public let isRecurring: Bool

    public init(
        id: String, title: String, listTitle: String, due: DueDate?, priority: Priority,
        isCompleted: Bool, isRecurring: Bool
    ) {
        self.id = id
        self.title = title
        self.listTitle = listTitle
        self.due = due
        self.priority = priority
        self.isCompleted = isCompleted
        self.isRecurring = isRecurring
    }
}

public struct ReminderDetail: Sendable, Equatable {
    public let id: String
    public let title: String
    public let listTitle: String
    public let listIsWritable: Bool
    public let due: DueDate?
    public let priority: Priority
    public let isCompleted: Bool
    /// Can be nil even when `isCompleted` is true: EventKit's own header warns that a
    /// reminder completed by another client may carry no completion date at all.
    public let completionDate: Date?
    public let notes: String?
    public let url: String?
    /// Minutes from the due date, negative for "before". A reminder with no due date can
    /// have no meaningful alarm, so this is empty whenever `due` is nil.
    public let alarmOffsetsMinutes: [Int]
    public let isRecurring: Bool
    public let recurrenceSummary: String?

    public init(
        id: String, title: String, listTitle: String, listIsWritable: Bool, due: DueDate?,
        priority: Priority, isCompleted: Bool, completionDate: Date?, notes: String?,
        url: String?, alarmOffsetsMinutes: [Int], isRecurring: Bool, recurrenceSummary: String?
    ) {
        self.id = id
        self.title = title
        self.listTitle = listTitle
        self.listIsWritable = listIsWritable
        self.due = due
        self.priority = priority
        self.isCompleted = isCompleted
        self.completionDate = completionDate
        self.notes = notes
        self.url = url
        self.alarmOffsetsMinutes = alarmOffsetsMinutes
        self.isRecurring = isRecurring
        self.recurrenceSummary = recurrenceSummary
    }

    /// The boundary the "completion is the record" rule turns on.
    ///
    /// Unlike a calendar event's end time this is not a function of the clock: a reminder
    /// becomes evidence the moment someone ticks it off, and stops being evidence the
    /// moment they untick it.
    public var isRecord: Bool { isCompleted }

    /// True when the reminder is past due and still not done.
    ///
    /// An all-day due date is overdue only once the day itself is over — a task due today
    /// is not late at nine in the morning.
    public func isOverdue(asOf now: Date, calendar: Calendar) -> Bool {
        guard !isCompleted, let due else { return false }
        guard due.isDateOnly else { return due.date < now }
        return (calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: due.date))
            ?? due.date) <= now
    }
}

/// Distinguishes "leave this alone" from "clear it".
///
/// An omitted argument and an explicit null must not collapse into the same value: one
/// means the caller said nothing about the field, the other means they want it emptied.
public enum FieldEdit<Value: Sendable & Equatable>: Sendable, Equatable {
    case unchanged
    case cleared
    case set(Value)
}

public struct ReminderDraft: Sendable, Equatable {
    public var listTitle: String
    /// The account holding that list, as `ListInfo.sourceName` reports it.
    ///
    /// Carried alongside the title rather than left out, for the same reason `updateList`
    /// and `deleteList` take both: a title shared across accounts is ordinary, and a store
    /// resolving by title alone would file the reminder in whichever list EventKit
    /// enumerated first. Not optional — the tool layer has already resolved the pair, and
    /// an optional would invite the store to guess again when it is nil.
    public var listAccountName: String
    public var title: String
    public var due: DueDate?
    public var priority: Priority
    public var notes: String?
    public var url: String?
    public var alarmOffsetsMinutes: [Int]

    public init(
        listTitle: String, listAccountName: String, title: String, due: DueDate? = nil,
        priority: Priority = .none, notes: String? = nil, url: String? = nil,
        alarmOffsetsMinutes: [Int] = []
    ) {
        self.listTitle = listTitle
        self.listAccountName = listAccountName
        self.title = title
        self.due = due
        self.priority = priority
        self.notes = notes
        self.url = url
        self.alarmOffsetsMinutes = alarmOffsetsMinutes
    }
}

public struct ReminderChanges: Sendable, Equatable {
    public var title: FieldEdit<String> = .unchanged
    public var due: FieldEdit<DueDate> = .unchanged
    public var priority: FieldEdit<Priority> = .unchanged
    public var notes: FieldEdit<String> = .unchanged
    public var url: FieldEdit<String> = .unchanged
    public var alarmOffsetsMinutes: FieldEdit<[Int]> = .unchanged

    public init() {}

    /// The argument names of the fields this edit actually touches, in output order.
    ///
    /// One place pairs a field with the name callers know it by; building that pairing at
    /// the call site meant writing the name twice per field, where a mismatch compiles
    /// cleanly and only shows up as a confirmation that under-reports what changed.
    public var changedFields: [String] {
        var names: [String] = []
        if title != .unchanged { names.append("title") }
        if due != .unchanged { names.append("due") }
        if priority != .unchanged { names.append("priority") }
        if notes != .unchanged { names.append("notes") }
        if url != .unchanged { names.append("url") }
        if alarmOffsetsMinutes != .unchanged { names.append("alarms") }
        return names
    }

    public var isEmpty: Bool { changedFields.isEmpty }
}

public struct ReminderSearchPage: Sendable, Equatable {
    public let results: [ReminderSummary]
    /// Total matches, not the number returned, so the formatter can say what it withheld.
    public let total: Int

    public init(results: [ReminderSummary], total: Int) {
        self.results = results
        self.total = total
    }
}
