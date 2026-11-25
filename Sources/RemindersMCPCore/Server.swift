import Foundation

public enum RemindersMCPServer {

    public static let name = "apple-reminders-mcp"
    public static let version = "1.0.1"

    /// Returned from `initialize`. It carries what per-tool descriptions cannot state
    /// once: the id workflow, the rule about completed reminders, and where policy
    /// actually lives.
    public static let instructions = """
        Access to the macOS Reminders app through EventKit.

        Workflow: reminders_search first, then use the id it returns. Reminder identifiers \
        are not sync-proof — resynchronising an account regenerates them — so do not reuse \
        an id from an earlier conversation without searching again.

        Search looks at OPEN reminders unless told otherwise. Pass status="completed" or \
        status="any" when the question is about what has already been done.

        Dates accept three forms: 2026-08-12 (that day, no particular time), \
        2026-08-12T09:00 (local time), or 2026-08-12T09:00:00+02:00 (explicit offset). A \
        reminder with no due date at all is perfectly normal.

        A completed reminder is the record that the thing was done, and this server will \
        not modify or delete one. complete_reminder(completed=false) reopens it, which is \
        how a mistaken tick is undone; it is then an ordinary reminder again.

        Lists can be created, renamed, recoloured and deleted. delete_list REFUSES any list \
        that still holds reminders, completed ones included: removing a list removes \
        everything in it, and that is the record this server will not destroy. Where a \
        title exists in two accounts, pass account= to say which one you mean.

        SECTIONS INSIDE A LIST DO NOT EXIST HERE. The headings Reminders.app can group a \
        list under live only inside that app — EventKit has no section on a list or on a \
        reminder, so this server cannot create, rename, delete or even see one. A list is \
        not a section. If someone asks for a section, tell them it has to be done in \
        Reminders.app; do not create a list instead.

        EventKit cannot create repeating reminders; that must be done in Reminders.app.

        Write tools carry a verb prefix (create_, update_, complete_, delete_). \
        delete_reminder and delete_list are permanent and require confirm=true.

        This server exposes the reminder store's full capability. What may be used at any \
        moment is decided by the permission switches in the client, not by this code.
        """

    /// The store is a parameter so the whole server can be driven by a double. Nothing in
    /// this function opens the reminder store by itself.
    public static func run(
        store: any ReminderStore = SystemReminderStore()
    ) async {
        Diagnostics.started(version: version)
        await serveStandardStreams(handler: handler(tools: ReminderTools(store: store)))
    }

    public static func handler(tools: ReminderTools) -> MCPHandler {
        MCPHandler(
            name: name, version: version, instructions: instructions,
            catalog: ToolCatalog.all(), tools: tools)
    }
}
