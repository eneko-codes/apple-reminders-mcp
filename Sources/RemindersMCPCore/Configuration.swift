import Foundation

/// Every size this server enforces, in one place: the schemas, the tool descriptions, the
/// instructions and `reminders_status` quote these by interpolation, so what the model
/// reads cannot drift from what the code does.
///
/// None of it is a setting. The owner's plug-and-play rule removed every option from the
/// connector: only the per-tool allow/ask/prohibit switch in Claude Desktop controls this
/// server.
public enum Configuration {

    // Pages. Each maximum is a number of rows that fits `ToolStandard.longestResult` with
    // room to spare, and each default makes a call with no optional argument about
    // `ToolStandard.usualPage` or less. `BoundsTests` renders a full page of the widest
    // rows of every listing to hold both to that.

    /// A search row holds a title and a list name, each up to `rowFieldWidth`, and the
    /// reminder's id, so the maximum is the number of such rows, every field at its
    /// widest, that still fits one result.
    public static let searchLimitRange = 1...100
    public static let defaultSearchLimit = 30

    public static let listLimitRange = 1...200
    public static let defaultListLimit = 50

    public static let offsetRange = 0...10_000_000

    /// The window `reminder_get` reads a reminder's record through. The maximum is half
    /// the longest result, so a window of ordinary text fits with its notices;
    /// `ToolStandard.fitting` shrinks one whose characters take more UTF-16 units than that.
    public static let maxCharactersRange = 1...(ToolStandard.longestResult / 2)
    public static let defaultMaxCharacters = ToolStandard.usualPage

    /// How much of a title, a list name, notes or a URL one search row or one create,
    /// update or complete receipt shows. `reminder_get` has the rest. `reminder_lists`
    /// clips nothing: a list is addressed by its whole name.
    public static let rowFieldWidth = 80

    /// The widest a padded column gets. One reminder with a long title must not make every
    /// other row of the page that wide.
    public static let widestColumn = 40

    /// How far from the due date an alarm may be set: 366 days either side, in minutes.
    /// An offset outside it is refused.
    public static let alarmMinutesRange = -527_040...527_040

    /// How many names or alarms an error or a receipt lists before it counts the others.
    public static let fewNames = 5

    /// How long any call may take before it is abandoned and answered with an error. It
    /// stays under the 60 seconds a client commonly waits, and so under
    /// `ToolStandard.timeLimit`, so the answer is this server's and not the client's
    /// generic "no result".
    public static let callTimeout = Duration.seconds(30)

    /// How much of a deleted reminder's notes `delete_reminder` returns. Nothing can read
    /// them afterwards, so this is as much as one result holds once the other fields of the
    /// receipt, each at `deletedFieldCharacters`, and the lines around them are counted.
    public static let deletedRecordCharacters = ToolStandard.longestResult - 12_000

    /// How much of a deleted reminder's title, URL or list name, or of a deleted list's
    /// name or account, a receipt returns. Each is repeated in the call that restores it.
    public static let deletedFieldCharacters = 2_000

    /// How much of EventKit's own wording a failed save or removal may repeat.
    public static let storeFailureWidth = 500
}
