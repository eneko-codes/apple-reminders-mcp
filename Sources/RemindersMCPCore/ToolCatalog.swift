import Foundation
import MCP

/// The catalogue is the authorisation surface: a tool that is not listed here cannot be
/// called, and the name it is listed under is the label on the permission switch in
/// Claude Desktop. Reads carry no verb prefix; writes always start with create_/update_/
/// complete_/delete_, so the ones that change something sort together.
public enum ToolCatalog {

    public static let statusName = "reminders_status"
    public static let listsName = "reminder_lists"
    public static let searchName = "reminders_search"
    public static let getName = "reminder_get"
    public static let createName = "create_reminder"
    public static let updateName = "update_reminder"
    public static let completeName = "complete_reminder"
    public static let deleteName = "delete_reminder"
    public static let createListName = "create_list"
    public static let updateListName = "update_list"
    public static let deleteListName = "delete_list"

    /// The prefixes that mark a tool as one that writes. Used by the catalogue's own test
    /// to prove the convention holds.
    public static let writePrefixes = ["create_", "update_", "complete_", "delete_"]

    public static func all() -> [Tool] {
        [
            status, lists, search, get, create, update, complete, delete,
            createList, updateList, deleteList,
        ]
    }

    // MARK: Schema helpers

    private static func object(properties: [String: Value], required: [String] = []) -> Value {
        var schema: [String: Value] = [
            "type": .string("object"),
            "properties": .object(properties),
        ]
        if !required.isEmpty {
            schema["required"] = .array(required.map { .string($0) })
        }
        schema["additionalProperties"] = .bool(false)
        return .object(schema)
    }

    private static func string(_ description: String) -> Value {
        .object(["type": .string("string"), "description": .string(description)])
    }

    private static func integer(_ description: String, minimum: Int, maximum: Int, default def: Int)
        -> Value
    {
        .object([
            "type": .string("integer"), "description": .string(description),
            "minimum": .int(minimum), "maximum": .int(maximum), "default": .int(def),
        ])
    }

    private static func enumeration(_ cases: [String], default def: String, description: String)
        -> Value
    {
        .object([
            "type": .string("string"),
            "enum": .array(cases.map { .string($0) }),
            "default": .string(def),
            "description": .string(description),
        ])
    }

    /// How to say "empty this field" in a schema that cannot advertise null.
    ///
    /// Claude Desktop's schema sanitiser drops any property whose `type` is a union such
    /// as `["string", "null"]` and hands the model a bare `{}` in its place — observed
    /// live in the sibling contacts server, where it silently turned an array argument
    /// into a string. Every property here therefore keeps a scalar `type`, and the way to
    /// clear a field is documented in prose instead, which survives sanitising.
    ///
    /// `Arguments` still accepts an explicit null for the same effect; it just is not
    /// something the schema can promise.
    private static let clearingHint = "Pass an empty string to remove it."

    private static let dateHelp = """
        Accepts 2026-08-12 (that day, no particular time), 2026-08-12T09:00 (local time), \
        or 2026-08-12T09:00:00+02:00 (explicit offset).
        """

    private static let priorityHelp = """
        One of "none", "high", "medium" or "low" — the four priorities Reminders.app shows.
        """

    private static let alarmsProperty: Value = .object([
        "type": .string("array"),
        "items": .object(["type": .string("string")]),
        "description": .string(
            """
            Notification offsets from the due date: "-15m", "-1h", "-1d", or "0" for the \
            moment it falls due. Negative means before. Requires a due date. Omit this on \
            a reminder with a due time and one is added automatically at that time, \
            because EventKit adds none by itself; pass an empty array for no alarm at all.
            """),
    ])

    // MARK: Reads

    static let status = Tool(
        name: statusName,
        title: "Reminders permission status",
        description: """
            Reports whether this server has permission to reach Reminders, and says exactly \
            what to enable and where if it does not. Reads no reminders.

            Use it when another tool here fails on permissions, or when setting the server \
            up. Do not use it to look for reminders.
            """,
        inputSchema: object(properties: [:]),
        annotations: .init(
            readOnlyHint: true, destructiveHint: false, idempotentHint: true, openWorldHint: false)
    )

    static let lists = Tool(
        name: listsName,
        title: "List reminder lists",
        description: """
            Lists every reminder list with its account, whether it accepts writes, and which \
            is the default for new reminders.

            Call this before create_reminder if you are not certain a list exists under that \
            exact name — a shared list you do not own can be read-only and will refuse writes.
            """,
        inputSchema: object(properties: [:]),
        annotations: .init(
            readOnlyHint: true, destructiveHint: false, idempotentHint: true, openWorldHint: false)
    )

    static let search = Tool(
        name: searchName,
        title: "Search reminders",
        description: """
            Finds reminders, optionally filtered by text, list, completion state and due \
            date. Returns one line per reminder with its id, and echoes the filters it \
            actually used.

            Searches OPEN reminders by default — pass status="completed" or "any" to see \
            ones already ticked off. Results are ordered by due date, soonest first, with \
            undated ones last; up to \(Configuration.searchLimit) are returned unless \
            'limit' says otherwise. Always search before reminder_get, update_reminder, \
            complete_reminder or delete_reminder — ids come from here.
            """,
        inputSchema: object(
            properties: [
                "query": string("Optional text to match against title and notes."),
                "lists": .object([
                    "type": .string("array"),
                    "items": .object(["type": .string("string")]),
                    "description": .string(
                        "Optional list names to search. Omit to search all of them."),
                ]),
                "status": enumeration(
                    CompletionFilter.allCases.map(\.rawValue), default: "incomplete",
                    description: """
                        Which reminders to consider. "incomplete" is what someone means by \
                        "my reminders"; "completed" looks at what has been done; "any" \
                        covers both.
                        """),
                "due_from": string(
                    """
                    Only reminders due at or after this. \(dateHelp) Undated reminders \
                    are excluded whenever either bound is given.
                    """),
                "due_to": string(
                    """
                    Only reminders due before this — except that a plain day covers \
                    that whole day, so "2026-08-12" includes something due at 18:00 \
                    on the 12th. \(dateHelp)
                    """),
                "limit": integer(
                    "Maximum number of reminders to return.",
                    minimum: Configuration.searchLimitRange.lowerBound,
                    maximum: Configuration.searchLimitRange.upperBound,
                    default: Configuration.searchLimit),
                "offset": integer(
                    "Skip this many matches; use it to page.",
                    minimum: Configuration.offsetRange.lowerBound,
                    maximum: Configuration.offsetRange.upperBound, default: 0),
            ]),
        annotations: .init(
            readOnlyHint: true, destructiveHint: false, idempotentHint: true,
            openWorldHint: false)
    )

    static let get = Tool(
        name: getName,
        title: "Full reminder record",
        description: """
            Returns everything stored for one reminder: due date, list, priority, notes, url, \
            alarms and recurrence. Also reports whether it can still be edited.

            Needs an id from reminders_search. Reminder ids are not sync-proof, so do not \
            reuse one from an earlier conversation without searching again.
            """,
        inputSchema: object(
            properties: ["id": string("Identifier returned by reminders_search.")],
            required: ["id"]),
        annotations: .init(
            readOnlyHint: true, destructiveHint: false, idempotentHint: true, openWorldHint: false)
    )

    // MARK: Writes

    static let create = Tool(
        name: createName,
        title: "Create a reminder",
        description: """
            Adds a reminder to a list. Only 'list' and 'title' are required — a reminder with \
            no due date is perfectly normal.

            A 'due' of 2026-08-12 means that day with no particular time; add a time and an \
            alarm is set for it automatically, since EventKit creates none on its own. It \
            CANNOT create a repeating reminder — that has to be done in Reminders.app.
            """,
        inputSchema: object(
            properties: [
                "list": string("Name of the list, exactly as reminder_lists shows it."),
                "account": string(accountHelp),
                "title": string("What the reminder says."),
                "due": string("Optional. When it is due. \(dateHelp)"),
                "priority": enumeration(
                    Priority.allCases.map(\.rawValue), default: "none",
                    description: priorityHelp),
                "notes": string("Optional notes."),
                "url": string("Optional URL."),
                "alarms": alarmsProperty,
            ],
            required: ["list", "title"]),
        annotations: .init(
            readOnlyHint: false, destructiveHint: false, idempotentHint: false, openWorldHint: false
        )
    )

    static let update = Tool(
        name: updateName,
        title: "Modify a reminder",
        description: """
            Changes fields on an existing reminder. Omitting a field leaves it as it is; \
            passing an empty string clears it — including 'due', since a reminder is allowed \
            to have no due date at all.

            REFUSES any reminder that is already completed: a ticked-off reminder is the \
            record that the thing was done. Reopen it with complete_reminder(completed=false) \
            if it needs changing. Does not tick reminders off — complete_reminder does that.
            """,
        inputSchema: object(
            properties: [
                "id": string("Identifier returned by reminders_search."),
                "title": string("New title."),
                "due": string("New due date. \(dateHelp) \(clearingHint)"),
                "priority": enumeration(
                    Priority.allCases.map(\.rawValue), default: "none",
                    description: "New priority. \(priorityHelp) \"none\" clears it."),
                "notes": string("New notes. \(clearingHint)"),
                "url": string("New URL. \(clearingHint)"),
                "alarms": .object([
                    "type": .string("array"),
                    "items": .object(["type": .string("string")]),
                    "description": .string(
                        """
                        Replaces ALL alarms. An empty array removes them. Offsets from the \
                        due date: "-15m", "-1h", "-1d", "0".
                        """
                    ),
                ]),
            ],
            required: ["id"]),
        annotations: .init(
            readOnlyHint: false, destructiveHint: false, idempotentHint: true, openWorldHint: false)
    )

    static let complete = Tool(
        name: completeName,
        title: "Tick off or reopen a reminder",
        description: """
            Marks a reminder done, or puts it back. This is the only change allowed against \
            an already-completed reminder, so it is also the way to undo a mistaken tick: \
            call it with completed=false and the reminder becomes editable again.

            A repeating reminder is rolled forward to its next due date rather than closed.
            """,
        inputSchema: object(
            properties: [
                "id": string("Identifier returned by reminders_search."),
                "completed": .object([
                    "type": .string("boolean"),
                    "default": .bool(true),
                    "description": .string(
                        "true ticks it off, false reopens it. Defaults to true."),
                ]),
            ],
            required: ["id"]),
        annotations: .init(
            readOnlyHint: false, destructiveHint: false, idempotentHint: true, openWorldHint: false)
    )

    // MARK: List writes

    /// Stated on every list tool, not just once in the server instructions.
    ///
    /// A model asked to "create a section" and offered only a list-creating tool will
    /// reach for it, and the owner then finds a new top-level list where they expected a
    /// heading inside an existing one. Sections are a Reminders.app construct that exists
    /// nowhere in EventKit — not on the list, not on the reminder — so the honest move is
    /// to say so at the point of temptation.
    private static let sectionsHint = """
        Sections INSIDE a list (the headings Reminders.app can group a list under) are not \
        reachable through EventKit and this server cannot create, rename or delete one. A \
        list is not a section: if someone asks for a section, say it has to be done in \
        Reminders.app rather than making a list instead.
        """

    private static let colorHelp = """
        Optional colour: a name from \(ListColor.paletteNames.joined(separator: ", ")), or \
        a hex value like "#FF9500".
        """

    private static let accountHelp = """
        Optional account name, exactly as reminder_lists shows it. Only needed when two \
        lists share a name.
        """

    static let createList = Tool(
        name: createListName,
        title: "Create a reminder list",
        description: """
            Adds an empty reminder list. Only 'title' is required; it lands in the same \
            account as your default list unless 'account' says otherwise.

            \(sectionsHint)
            """,
        inputSchema: object(
            properties: [
                "title": string("Name for the new list."),
                "account": string(
                    """
                    Optional account to create it in, exactly as reminder_lists shows it. \
                    Defaults to wherever your default list lives.
                    """),
                "color": string(colorHelp),
            ],
            required: ["title"]),
        annotations: .init(
            readOnlyHint: false, destructiveHint: false, idempotentHint: false, openWorldHint: false
        )
    )

    static let updateList = Tool(
        name: updateListName,
        title: "Rename or recolour a list",
        description: """
            Changes a list's name or colour. Pass 'title', 'color', or both — neither can be \
            emptied, since a list always has a name and a colour.

            Renaming moves nothing: the reminders stay exactly where they are. \(sectionsHint)
            """,
        inputSchema: object(
            properties: [
                "list": string("Current name of the list, exactly as reminder_lists shows it."),
                "account": string(accountHelp),
                "title": string("New name for the list."),
                "color": string("New colour. \(colorHelp)"),
            ],
            required: ["list"]),
        annotations: .init(
            readOnlyHint: false, destructiveHint: false, idempotentHint: true, openWorldHint: false)
    )

    static let deleteList = Tool(
        name: deleteListName,
        title: "Delete an empty list",
        description: """
            Permanently deletes a reminder list. Requires confirm=true.

            REFUSES any list that still holds reminders, completed ones included — deleting \
            a list takes its whole contents with it, and this server does not destroy the \
            record of what was done. Empty it first, or use Reminders.app. There is no flag \
            that overrides this.
            """,
        inputSchema: object(
            properties: [
                "list": string("Name of the list, exactly as reminder_lists shows it."),
                "account": string(accountHelp),
                "confirm": .object([
                    "type": .string("boolean"),
                    "description": .string("Must be true. Without it the call is refused."),
                ]),
            ],
            required: ["list", "confirm"]),
        annotations: .init(
            readOnlyHint: false, destructiveHint: true, idempotentHint: false, openWorldHint: false)
    )

    static let delete = Tool(
        name: deleteName,
        title: "Delete a reminder",
        description: """
            Permanently deletes a reminder. Requires confirm=true and returns the full record \
            it removed together with a create_reminder call that would restore it.

            REFUSES any reminder that is already completed. Clearing finished reminders in \
            bulk is a job for Reminders.app, not for this server.
            """,
        inputSchema: object(
            properties: [
                "id": string("Identifier returned by reminders_search."),
                "confirm": .object([
                    "type": .string("boolean"),
                    "description": .string("Must be true. Without it the call is refused."),
                ]),
            ],
            required: ["id", "confirm"]),
        annotations: .init(
            readOnlyHint: false, destructiveHint: true, idempotentHint: false, openWorldHint: false)
    )
}
