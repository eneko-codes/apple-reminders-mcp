import Foundation

public enum ReminderAuthorization: Sendable, Equatable {
    case notDetermined
    case restricted
    case denied
    /// macOS never grants this for reminders — the full/write-only split introduced in
    /// macOS 14 applies to calendars only, and `requestFullAccessToReminders` is the only
    /// request there is. The case exists because `EKAuthorizationStatus` can still return
    /// it, and silently reporting it as "denied" would blame the owner for a state they
    /// never chose.
    case writeOnly
    case fullAccess

    public var isUsable: Bool { self == .fullAccess }
}

public enum ToolError: Error, Equatable {
    case notAuthorized(ReminderAuthorization)
    case missingArgument(String)
    case badArgument(name: String, reason: String)
    case badDate(argument: String, value: String)
    case dueRangeBackwards
    case notFound(id: String)
    case listNotFound(title: String, available: [String])
    case listReadOnly(title: String)
    case listAmbiguous(title: String, accounts: [String])
    case listAlreadyExists(title: String, accountName: String)
    case listImmutable(title: String)
    case listNotEmpty(title: String, count: Int)
    case accountNotFound(name: String, available: [String])
    case nothingToChangeOnList
    case reminderCompleted(title: String, completed: String)
    case alarmWithoutDueDate
    case confirmationRequired(action: String)
    case nothingToUpdate
    case storeFailure(String)

    public var message: String {
        switch self {
        case .notAuthorized(let status):
            return Self.authorizationMessage(status)

        case .missingArgument(let name):
            return "Missing required argument '\(name)'."

        case .badArgument(let name, let reason):
            return "Argument '\(name)' is not valid: \(reason)"

        case .badDate(let argument, let value):
            return """
                Argument '\(argument)' is not a date this server accepts: '\(value)'

                Use one of:
                \(DateParsing.acceptedForms)

                A plain day means due that day with no particular time.
                """

        case .dueRangeBackwards:
            return "'due_to' is earlier than 'due_from'. That range can never match."

        case .notFound(let id):
            return """
                No reminder exists with id '\(id)'.

                Reminder identifiers are not sync-proof: resynchronising an account
                regenerates them. Find it again with reminders_search rather than reusing
                an earlier id.
                """

        case .listNotFound(let title, let available):
            // Deliberately not labelled "writable": what `available` holds depends on the
            // caller. Creating a reminder needs a list that accepts contents, renaming one
            // needs a list whose own attributes can change, and EventKit answers those two
            // questions separately — so a fixed label would misdescribe one of them.
            let usable =
                available.isEmpty
                ? "(none this tool can use)" : available.joined(separator: ", ")
            return """
                No reminder list named '\(title)'.

                Lists this tool can use: \(usable)

                Call reminder_lists for the full picture. A list missing above still
                exists — it just does not accept what this tool is trying to do.
                """

        case .listReadOnly(let title):
            return """
                List '\(title)' is read-only, so nothing can be written to it.

                Shared lists you do not own can be read-only. Call reminder_lists to see
                which ones accept writes.
                """

        case .listAmbiguous(let title, let accounts):
            return """
                More than one reminder list is called '\(title)'.

                It exists in: \(accounts.joined(separator: ", "))

                This server will not guess which one you mean: a reminder filed in the
                wrong one is lost until someone goes looking, and renaming or deleting the
                wrong one is not recoverable. Say which account you mean:
                  account="\(accounts.first ?? "…")"
                """

        case .listAlreadyExists(let title, let accountName):
            return """
                A list called '\(title)' already exists in \(accountName).

                Two lists sharing a name in one account cannot be told apart afterwards:
                every tool here addresses a list by its name, so neither could be renamed
                or deleted again. Pick a different name, or put it in another account.
                """

        case .listImmutable(let title):
            return """
                List '\(title)' cannot be renamed, recoloured or deleted.

                Reminders marks some lists as fixed — a subscribed list, or one managed by
                the account rather than by you. This is the account's rule, not this
                server's, so there is no confirmation that would get past it.
                """

        case .listNotEmpty(let title, let count):
            return """
                List '\(title)' still holds \(count) reminder\(count == 1 ? "" : "s").

                Deleting a list deletes every reminder in it, completed ones included, and
                that is exactly the record this server refuses to destroy. There is no
                confirmation flag that overrides it.

                Empty it first — delete_reminder handles open reminders one at a time — or
                delete the list in Reminders.app, where you can see what you are losing.
                """

        case .accountNotFound(let name, let available):
            let accounts = available.isEmpty ? "(none available)" : available.joined(separator: ", ")
            return """
                No account named '\(name)' can hold reminder lists.

                Available: \(accounts)

                Call reminder_lists to see which account each existing list belongs to.
                """

        case .nothingToChangeOnList:
            return """
                No change was given.

                Pass 'title' to rename the list, 'color' to recolour it, or both. Neither
                can be emptied: a list always has a name, and Reminders always gives it a
                colour.
                """

        case .reminderCompleted(let title, let completed):
            return """
                Cannot change a reminder that is already completed.

                  \(title) · completed \(completed)

                A completed reminder is the record that the thing was done, and this server
                does not rewrite or delete that record even with permission.

                If it was ticked off by mistake, reopen it first:
                  complete_reminder(id=…, completed=false)
                It is then an ordinary open reminder again and can be edited or removed.
                """

        case .alarmWithoutDueDate:
            return """
                Alarms are offsets from the due date, so a reminder needs one before it can
                carry an alarm.

                Pass 'due' in the same call, or drop 'alarms'.
                """

        case .confirmationRequired(let action):
            return """
                \(action) requires confirm=true.

                This is destructive. Call again with confirm=true only if you really mean
                to delete it.
                """

        case .nothingToUpdate:
            return """
                No field to change was given.

                Pass a field with a value to set it, or with null to clear it. Omitting a
                field leaves it untouched.

                To tick a reminder off or reopen it, use complete_reminder instead.
                """

        case .storeFailure(let detail):
            return "Reminders returned an error: \(detail)"
        }
    }

    static func authorizationMessage(_ status: ReminderAuthorization) -> String {
        switch status {
        case .fullAccess:
            return "Reminders access granted (full)."

        case .notDetermined:
            return """
                No Reminders access: macOS has not asked yet.

                Restart Claude Desktop and call this tool again; the consent dialog should
                appear.

                If it does not, check that the binary still carries its embedded Info.plist:
                  otool -P .build/release/apple-reminders-mcp | grep NSReminders
                """

        case .denied:
            return """
                No Reminders access: it is denied.

                Grant it in:
                  System Settings → Privacy & Security → Reminders → enable "apple-reminders-mcp"
                  (Spanish UI: Ajustes del Sistema → Privacidad y seguridad → Recordatorios)

                Then restart Claude Desktop: the permission is resolved when the process
                starts.
                """

        case .writeOnly:
            return """
                Reminders reports write-only access, which macOS is not supposed to grant
                for this permission at all — the full/write-only split applies to calendars.

                Whatever produced it, this server cannot work with it: it could neither read
                back what it created nor tell a completed reminder from an open one.

                Try revoking and re-granting in:
                  System Settings → Privacy & Security → Reminders → "apple-reminders-mcp"
                """

        case .restricted:
            return """
                No Reminders access: restricted by a system policy (parental controls or a
                device management profile).

                This cannot be granted from System Settings; the policy imposing it has to
                be lifted.
                """
        }
    }
}
