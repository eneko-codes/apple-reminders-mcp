import Foundation
import RemindersMCPCore

// Launcher only. Everything testable lives in RemindersMCPCore, which the test target
// imports; an executable target cannot be imported.
await RemindersMCPServer.run()
