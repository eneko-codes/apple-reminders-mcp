# CLAUDE.md

Guidance for Claude Code (claude.ai/code) when working in this repository.

## Data rule

Do not modify, complete or delete an existing reminder or list.

**Tests run against fakes** — in-memory doubles, fixtures, data invented for the test. Never the owner's real reminder store, and never out of convenience: the suite exists to catch breaking changes and does not need real data to do that.

**Debugging against live data is legitimate, but it is the owner's call, not yours.** Never decide it alone. Ask in chat as an explicit choice they can pick — not a remark inside a longer message — saying exactly what you will run, exactly which live data it would touch, and what it would create, change or delete and whether that is undoable. A yes covers that run only; a wider or different check needs a fresh question.

**Then take the gentlest route that answers it:** read without writing; failing that, create your own reminder or list and work on that; failing that, ask the owner to make a throwaway one; failing that, work on a copy. Touching what the owner made is the last resort, has to have been named in the ask, and has to be undoable. Anything you are allowed to create must be clearly named `TESTING: ...` and removed in the same session.

## What this is

A local MCP server (Swift 6, stdio transport) exposing the macOS Reminders app through `EventKit`. No network, no credential, no cloud API — iCloud is only the sync engine, gated by TCC consent. **No third-party dependency**: `Package.swift` lists none, and the MCP protocol (JSON-RPC over stdio) is `MCPServer.swift` over Foundation. Adding a package needs the owner's say-so.

**`MCPServer.swift`, `Value.swift`, `ToolStandard.swift` and the tests `MCPProtocolTests.swift` and `ToolStandardTests.swift` are copied unchanged into every one of the owner's MCP servers** (the test files differ only in their `@testable import`). A change to one is made to every copy in the same piece of work; never let a copy drift.

`ToolStandard.swift` holds what every tool here must keep to: the longest result, description and error, the time a call may take, the fixed wording of each notice that says what a result left out (`Notice`), and the guard `MCPServer.swift` passes every result through. A tool bounds its own result and says how to get the rest; the guard only catches the one that forgot.

## Apple frameworks

[EventKit](https://developer.apple.com/documentation/eventkit) is the whole of it. Used: `EKEventStore` (authorisation, fetch, save, remove), `EKReminder`, `EKCalendar` (a list), `EKSource`, `EKAlarm`, `EKRecurrenceRule`/`EKRecurrenceEnd` (read only). List colours go through [Core Graphics](https://developer.apple.com/documentation/coregraphics) `CGColor`. Consent key: [`NSRemindersFullAccessUsageDescription`](https://developer.apple.com/documentation/bundleresources/information-property-list/nsremindersfullaccessusagedescription).

## Native surface not used

The framework offers more than this server exposes. Before proposing a tool, check it against this list rather than assuming.

- `EKEvent` and `EKParticipant` — calendar events are a separate entity behind a separate permission.
- `EKStructuredLocation` — hence no location-based alarm.
- Constructing an `EKRecurrenceRule` — recurrence is read and summarised, never written.
- Sections inside a list — these exist in Reminders.app only. EventKit has no section on `EKCalendar` or `EKReminder`, so no tool here can see, create or rename one.

## Commands

```bash
swift build
swift build -c release
swift test
```

```bash
otool -P .build/release/apple-reminders-mcp | grep NSRemindersFullAccessUsageDescription
```

## Architecture

**Apple silicon only, deliberately.** `scripts/pack.sh` builds for arm64 alone — a plain `swift build -c release`, no `--arch` flags — and fails if the binary
holds any other architecture. A universal build doubles the bundle for an architecture
macOS 26 is the last release to support. Do not add an x86_64 slice back.

**How a tool keeps to the tool standard here.** Sizes are constants in `Configuration`, and the schemas, the descriptions and the instructions quote them by interpolation, never as literals. `Arguments.int` moves a quantity into its range and collects the sentence that says so in `notices`; `Arguments.only` refuses an argument the schema does not list. `reminders_search` and `reminder_lists` sort every row into a stated order with no ties and page it with `limit` and `offset`; `reminder_get` windows the whole record. Receipts clip each text to `Configuration.rowFieldWidth` and say so. `delete_reminder` and `delete_list` return what they removed in the call that restores it, cut with `Format.unrecoverable` because nothing can read it afterwards. `Deadline` (its own file, until the shared file has one) abandons a call at `Configuration.callTimeout`. `BoundsTests` holds every bound, notice and length to this.

## Diagnostics

Logs go to stderr through `Diagnostics`, which the host captures (Claude Desktop writes it to `~/Library/Logs/Claude/mcp-server-<name>.log`). stdout is the JSON-RPC stream: never `print`. The API takes no free-form text on purpose. Do not add one, and do not log an argument, a result, an error's `localizedDescription` or an identifier; log a fixed event, the tool name, the error's kind and a duration.
