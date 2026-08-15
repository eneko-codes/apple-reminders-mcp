import Foundation

/// The seam between the tool layer and EventKit.
///
/// Everything above this protocol is exercised by the tests against an in-memory double;
/// everything below it can only be verified against real reminders. Keeping the boundary
/// this thin is what makes the untested surface small enough to check by hand — and it is
/// what lets the suite run without ever opening the owner's reminders.
public protocol ReminderStore: Sendable {
    func authorization() -> ReminderAuthorization

    @discardableResult
    func requestAccess() async -> ReminderAuthorization

    func lists() async throws -> [ListInfo]

    /// Adds a list. The account is resolved by the store, because the sensible default —
    /// wherever the existing default list lives — is something only EventKit can answer.
    func createList(_ draft: ListDraft) async throws -> ListInfo

    /// Renames or recolours a list.
    ///
    /// Addressed by title **and** account rather than title alone: the same name in two
    /// accounts is ordinary (an iCloud "Reminders" alongside a local one), and picking the
    /// first match would rename whichever EventKit happened to enumerate first. The tool
    /// layer refuses an ambiguous title before it reaches here; passing both keeps the
    /// store's own resolution deterministic rather than relying on that.
    func updateList(title: String, accountName: String, changes: ListChanges) async throws
        -> ListInfo

    /// How many reminders a list holds, completed ones included.
    ///
    /// Separate from `search` rather than a special case of it, because `search` scopes by
    /// title alone: with the same name in two accounts it would count both lists together.
    /// The one caller is the guard in `delete_list`, where an over-count refuses a delete
    /// that should succeed and quotes a number the owner can see is wrong.
    ///
    /// Must fail rather than return zero if the count cannot be established. Zero is the
    /// answer that lets the delete through.
    func reminderCount(inList title: String, accountName: String) async throws -> Int

    /// Removes a list, returning it as it was so the caller can describe what disappeared.
    ///
    /// **Only ever called for a list the tool layer has already proved empty.**
    /// `removeCalendar` takes every reminder in the list with it, completed ones included,
    /// which would be a way round the rule that a completed reminder is the record.
    func deleteList(title: String, accountName: String) async throws -> ListInfo

    /// `dueFrom`/`dueTo` bound the due date. Reminders with no due date fall outside any
    /// window by definition, so they are excluded whenever either bound is given and
    /// included — sorted last — when neither is.
    ///
    /// `offset` indexes into the matches. EventKit has no cursor of its own, and it hands
    /// back the whole matching set in one callback regardless.
    func search(
        query: String?, listTitles: [String], status: CompletionFilter,
        dueFrom: Date?, dueTo: Date?, limit: Int, offset: Int
    ) async throws -> ReminderSearchPage

    func fetch(id: String) async throws -> ReminderDetail?

    /// Adds a reminder to the list the draft names.
    ///
    /// The draft carries the account as well as the title, for the same reason the list
    /// writes above take both: resolving by title alone would file the reminder into
    /// whichever same-named list EventKit enumerated first, and nothing about the result
    /// would show it went to the wrong one. The tool layer refuses an ambiguous title
    /// before it reaches here; passing the pair keeps the store's own resolution
    /// deterministic rather than relying on that.
    func create(_ draft: ReminderDraft) async throws -> ReminderDetail
    func update(id: String, changes: ReminderChanges) async throws -> ReminderDetail

    /// Ticking a reminder off, or putting it back. Separate from `update` because it is
    /// the one write this server allows against a completed reminder.
    func setCompleted(id: String, completed: Bool) async throws -> ReminderDetail

    /// Returns the reminder as it was immediately before removal, so the caller can
    /// describe precisely what disappeared.
    func delete(id: String) async throws -> ReminderDetail
}
