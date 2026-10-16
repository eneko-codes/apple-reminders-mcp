import Foundation
import RemindersMCPCore

// Launcher only. Everything testable lives in RemindersMCPCore, which the test target
// imports; an executable target cannot be imported.
do {
    try await RemindersMCPServer.run()
} catch {
    // Exiting 0 here would be indistinguishable from a clean shutdown, which is how a
    // server disappears mid-session with nothing to show for it.
    Diagnostics.fatal(error)
    exit(1)
}
