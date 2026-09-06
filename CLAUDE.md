# CLAUDE.md

Guidance for Claude Code (claude.ai/code) when working in this repository.

## HARD RULE — THE OWNER'S REMINDERS ARE NOT YOURS TO EDIT

**It is FORBIDDEN to modify, complete or delete any reminder the owner made.** This rule
outranks every other instruction in this file. It applies to every agent and every
session, with no "just this once" and no restoring-it-afterwards.

Reminders are this owner's operational state: a reminder ticked off by an agent is a task
they believe is done. `complete_reminder` is therefore as destructive here as a delete,
whatever its annotation says.

Never:

- update, complete or delete a pre-existing reminder, for any reason;
- read a real reminder to "see what the shape is" — the fixtures show the shape;
- create a scratch list, or write into a list the owner did not sanction;
- read the Reminders store directly from disk;
- leave anything behind that was not there when the session started.

**One narrow exception, granted by the owner.** A **temporary test reminder** may be
created, exercised and deleted, provided that:

- its title marks it as disposable at a glance (`ZZTest …`);
- it carries no due date that would fire an alarm at the owner;
- it is deleted in the same session that made it, even if the session is going badly;
- the owner is told it existed and that it is gone.

The exception covers reminders this agent created and nothing else.

**Fixtures first, always.** `FakeReminderStore` drives the whole tool layer with invented
titles and dates, and that is where a change is proven. Reach for a live test only for
code the fake cannot reach at all — everything below the `ReminderStore` seam, where
`SystemReminderStore` talks to Apple.

Allowed without asking, because none of it touches reminder data:

| Action | Why it is safe |
|---|---|
| `swift build`, `swift test` | Tests run against the in-memory fake |
| `initialize`, `tools/list` over stdio | Protocol only; no store is opened |
| `EKEventStore.authorizationStatus(for: .reminder)` | Returns an enum, reads no reminders |
| `otool -P` on the built binary | Inspects the embedded Info.plist |

Full verification against a real reminder store remains the **owner's** job, by hand,
with MCP Inspector. `verification.md` is the script for it. The test-reminder
exception above is for proving one specific below-the-seam behaviour, not for running
that script.

## Language

**Everything in this repository is written in English** — code, comments, tool
descriptions, error messages, documentation and commit messages. The one exception is
literal macOS UI strings quoted inside permission instructions, which must match what is
on screen (for example the System Settings pane name in the user's locale).

## What this is

A local MCP server (Swift 6, stdio transport) exposing the macOS Reminders app through
`EventKit`. There is no network, no credential and no cloud API: iCloud is only the sync
engine that fills the local store, and the gate is TCC consent.

This server covers **reminders only**. Calendar events are a separate EventKit entity
with a separate TCC permission and live in `apple-calendar-mcp`, alongside
`apple-contacts-mcp`. The three are deliberately built the same way; when something here
looks arbitrary, the sibling probably explains it.

## Commands

```bash
swift build
swift build -c release
swift test
```

Protocol smoke test without touching a single reminder. The trailing delay matters: the
server exits on stdin EOF, and without it the process can terminate before flushing its
replies — a redirect straight from a file produces **no output at all**, which looks
exactly like a crash.

```bash
{ printf '%s\n' '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"smoke","version":"0"}}}' '{"jsonrpc":"2.0","id":2,"method":"tools/list"}'; sleep 3; } | ./.build/release/apple-reminders-mcp
```

```bash
otool -P .build/release/apple-reminders-mcp | grep NSRemindersFullAccessUsageDescription
```

## Architecture

`Sources/RemindersMCPCore` holds everything; `Sources/apple-reminders-mcp/main.swift` is
a launcher that exists only because a Swift executable target cannot be imported by a
test target.

**`ReminderStore` is the seam.** Dispatch, formatting and argument decoding go through
the protocol and never touch EventKit, so the tool layer is fully testable against
`FakeReminderStore`. Only `SystemReminderStore` talks to Apple, and it is deliberately
the thinnest file that can do the job, because it is the one part no test can reach.

**`ToolCatalog` is the authorisation surface.** A tool absent from `ToolCatalog.all()`
cannot be called, and its name is the label on the permission switch in Claude Desktop.
Its `reminders_search` description reads `Configuration.searchLimit` directly, so it
cannot state a limit the running server does not enforce.

## Invariants worth protecting

### The rule this server exists to keep

- **Completion is the record.** `update_reminder` and `delete_reminder` refuse a reminder
  that is already completed. Ticking something off is evidence that it was done, and this
  server does not rewrite evidence. This is the reminders analogue of the calendar
  server's "history is not editable", and it is a design rule, not a technical limit.
- **Reopening is the one door left open.** `complete_reminder(completed=false)` always
  works, whatever the state. Without it the rule would be a trap: a mistaken tick would
  freeze a reminder forever. It parallels the calendar server allowing an event that is
  currently overrunning to be extended — the rule is about finished things, and reopening
  makes a thing unfinished again rather than falsifying it.
- **Re-completing is not a write.** EventKit keeps `completed` and `completionDate` in
  lockstep, so setting `isCompleted = true` on something already completed stamps the
  date with *now* and destroys the record of when the thing was actually done. The tool
  layer compares first and writes nothing when the state already matches. The same guard
  covers a redundant reopen, and a `update_list` that sets a name or colour already in
  place, for symmetry rather than necessity.
- **Deleting a list is the cascade that would get round all of it.**
  `removeCalendar(_:commit:)` deletes every reminder in the list, completed ones included,
  in one call and with no per-reminder confirmation. `delete_list` therefore counts the
  contents first and refuses anything non-empty — checked *before* `confirm`, so the
  refusal never reads as though the flag could get past it. There is deliberately no
  override. This is the same rule as "completion is the record", enforced one level up.

  The count comes from `reminderCount(inList:accountName:)` rather than `search`, because
  `search` scopes by title alone and would add up two same-named lists in different
  accounts. It must also **throw rather than return zero** when the fetch fails: EventKit
  hands `fetchReminders` a nil array on failure, and reading that as "empty" would let the
  cascade through on the strength of a query that never ran.

### Things that would crash or corrupt

- **Due date components must be Gregorian.** `EKReminder` raises an Objective-C exception
  — which Swift cannot catch, so the process dies and the server vanishes mid-session —
  if `dueDateComponents` carries any other calendar. `Calendar.current` follows the region
  setting in System Settings, so on a Mac configured for the Buddhist or Islamic calendar
  the obvious code hands EventKit exactly the thing it refuses. `DateParsing.gregorian`
  exists solely for this, and every component leaving `DateParsing.dueComponents` has its
  `calendar` set explicitly rather than inherited.
- **`EKReminder` is not `Sendable`.** `fetchReminders(matching:completion:)` is
  callback-based, so the conversion to the domain model happens *inside* the completion
  block and only Sendable values cross the continuation. Letting an `EKReminder` escape
  would not compile under Swift 6, and the shape that does compile is worth keeping.

### Things EventKit gets subtly wrong for you

- **A due time with no alarm never notifies.** EventKit adds no alarm of its own, unlike
  Reminders.app. `create_reminder` therefore adds one at the due time when the caller gave
  a time and said nothing about alarms — and says so in the response, because a
  notification nobody asked for is exactly the kind of surprise that makes a tool
  untrustworthy. An explicit empty array means silence and is honoured. A whole-day due
  date gets no alarm, matching what Reminders.app does for a task due "today".

  Observed live on macOS 26.5, not inferred: two reminders written to the real store with
  the same due time, one with `alarms: []` and one with `alarms` omitted, read back with
  no alarm and one alarm respectively. `Dispatch.impliedAlarms` is load-bearing.
- **All-day is inferred from the absence of time components**, not from a flag. EventKit
  reads components with no hour as all-day, so a whole-day due date must never carry a
  zeroed hour, and two sources of truth for the same fact would drift apart.
- **Alarms are absolute instants derived from the due date.** `EKAlarm.relativeOffset` is
  documented against an event's *start*, and what it means on a reminder is not something
  to guess at. They are stored absolute and reported back as offsets, so the caller's
  vocabulary stays "before the deadline" either way.
- **Clearing the due date clears the alarms.** An alarm computed from a deadline that no
  longer exists would still fire. The tool layer does it and reports `alarms` among the
  changed fields; `SystemReminderStore` repeats the guard for any path that does not.
- **A plain day as `due_to` covers that whole day.** Taken at face value the boundary
  would land at midnight and silently drop everything due on the very day asked about.
- **The list scope must fail closed.** `predicateForReminders(in:)` reads an **empty**
  array as *every* list, so a filter that matched nothing would silently widen into no
  filter at all. `resolveLists` returns a three-way `ResolvedScope` and never an empty
  array — a restriction that fails open is worse than one that errors. This lives below
  the `ReminderStore` seam, so no test can reach it; the guard is the type.
- **A list title is not unique.** An iCloud "Reminders" beside a local one is ordinary, and
  every tool here addresses a list by name. `resolveList` refuses an ambiguous title rather
  than taking the first match — a rename picks the wrong list silently, a delete does so
  irreversibly, and `create_reminder` files the reminder where nobody will look for it.
  `account=` breaks the tie, and `create_list` refuses to manufacture a duplicate within one
  account precisely because the pair could never be addressed again.

  **The pair has to survive the seam.** `ReminderDraft` carries `listAccountName` beside
  `listTitle`, and `SystemReminderStore.create` resolves through the same `locateList` as
  the list writes. Resolving the ambiguity in the tool layer and then handing the store a
  title alone would leave the guess exactly where it was, one layer down and out of reach
  of every test.

  **Reads are deliberately left alone.** `reminders_search` unions every list of a given
  name rather than refusing, because a read that returns *more* than one list called
  "Personal" hides nothing — the failure this rule exists to prevent is a silent
  substitution, and a union is not one. It could not be narrowed cheaply either: `lists` is
  an array, so an account would have to pair with it positionally, and `ReminderSummary`
  carries no account to report the result against. `reminder_get` addresses a reminder by
  id, so no name is ever resolved at all.
- **A `CGColor` is not implicitly RGB.** It carries whatever colour space it was made in,
  and a grey list colour arrives with two components rather than four; reading
  `components[0...2]` would report grey as pure red. `SystemReminderStore.color(from:)`
  converts to sRGB first. Colours are then quantised to `UInt8` — a value that has been
  through a colour-space conversion comes back as `0.20000000298`, so a float comparison
  against the palette would make "is this still blue?" a question about rounding.

### Shape of the interface

- **No schema property may declare a union `type`.** Claude Desktop's schema sanitiser
  drops a property whose `type` is `["string", "null"]` or `["array", "null"]` and hands
  the model a bare `{}` in its place. Observed live in `apple-contacts-mcp`, where an
  array argument was consequently serialised as a string; text fields hid the fault
  because an untyped string still arrives as a string. Every schema here stays in the
  scalar-`type` subset, "pass an empty string to clear it" is documented in prose that
  survives sanitising, and a test walks the whole catalogue to enforce it. `Arguments`
  still accepts an explicit null — it just is not something the schema can promise.
- **Search defaults to open reminders.** "My reminders" means the ones still to do. A
  default of *any* would fill every answer with things finished months ago.
- **Ordering is total.** Due date, then priority, then title — so a reminder cannot swap
  places between the call that returned page one and the call that returns page two.
  `FakeReminderStore` shares the real comparator rather than reimplementing it, because a
  fake that sorts differently would let a paging bug pass the suite.
- **Reads carry no verb prefix; writes start with `create_`/`update_`/`complete_`/
  `delete_`**, so the ones that change something sort together in the switch list. A test
  enforces it against `ToolCatalog.writePrefixes`.
- **Annotations must stay honest.** A client treats an unannotated tool as write-capable
  and destructive; `readOnlyHint` on a tool that writes would be a lie the client acts on.
- **A truncated search must say what it withheld.** Silence reads as "that was
  everything".
- **stdout carries JSON-RPC and nothing else.**

### Sections do not exist below Reminders.app — do not go looking again

This was researched against the macOS 26.5 SDK and system, and the answer is not "not yet
implemented", it is "there is nothing to call":

| Surface | Finding |
|---|---|
| `EventKit.framework` headers | `grep -i section` matches nothing but `EKParticipantTypeGroup`. No section property on `EKCalendar`, `EKReminder` or `EKCalendarItem`. |
| `sdef /System/Applications/Reminders.app` | Classes are `account`, `list`, `reminder`. That is all. |
| Reminders' `Metadata.appintents` | No section intent, so Shortcuts is not a way round it either. |
| `Reminders` binary | `sectionIDByReminderID`, `TTRMEditSectionsPresenterType` and friends are Swift symbols **in the app**, not in any linkable framework. Sections live above the store. |

The only remaining routes are private `ReminderKit` symbols, accessibility UI scripting,
and reading the store's SQLite directly. The first two are unauditable and break without
warning; the third is forbidden by the hard rule at the top of this file. **None of them
is to be attempted.**

What the code does instead is refuse to be mistaken for section support: `create_list` and
`update_list` both say so in their descriptions, and `Server.instructions` says it in
capitals. That is not decoration — the realistic failure is not an error but a silent
substitution, a model asked for a section creating a top-level list and reporting success.
`sectionsAreDeclaredUnreachable` in the suite is what keeps those sentences from being
edited away.

Two smaller absences, for the same reason:

- **Groups of lists** (a folder of lists in Reminders.app) are not in EventKit either; its
  calendar list is flat. The AppleScript dictionary does model them — a `list` whose
  `container` is another `list` — but that is Reminders.app's surface, not EventKit's.
- **List icons** (`emblem` in the scripting dictionary) have no EventKit equivalent.
  Colour does, and is exposed; the icon cannot be.

### Simpler here than in the calendar server

- **A repeating reminder is one object.** EventKit rolls its due date forward on
  completion rather than materialising occurrences, so there is no analogue of the
  calendar server's composite `<identifier>|<occurrence-start>` id and no `span`
  argument. A plain `calendarItemIdentifier` addresses a reminder completely.
- **Identifiers are still not durable.** `calendarItemIdentifier` is explicitly not
  sync-proof: a full account resync regenerates it. Every workflow starts with a search.

## Packaging as a Claude extension

`extension/manifest.json` plus `scripts/pack.sh` produce `dist/apple-reminders-mcp.mcpb`,
a zip with `manifest.json` at its root. `server.type` is `"binary"` — no Node, no Python,
just the Swift binary.

**The `tools` array is what creates the per-tool switches.** Claude Desktop lists and
toggles tools from the manifest, before the server has ever run. A tool missing from that
array has no switch. `ManifestTests` compares the array against `ToolCatalog`, along with
the versions and the bundle identifier — none of which anything else reconciles.

There is no `user_config` and `mcp_config.args` is empty: every former setting — the list
allow-list and the default search page size — is now a constant in `Configuration`, per
the owner's plug-and-play rule. The only place left for a person to change this server's
behaviour is the per-tool permission switch.

`pack.sh` checks everything here that fails silently otherwise: that the embedded
`Info.plist` survived both linking and signing, that the signature is not `linker-signed`,
that a designated requirement exists at all, and that the executable bit survived the zip.
The MCPB spec does not promise the installer preserves file modes; if a future Claude
release drops it, the symptom is a server that never starts and the fix is `chmod +x` on
the installed copy under `~/Library/Application Support/Claude/Claude Extensions/`.

## TCC notes

Claude Desktop spawns MCP servers through `Contents/Helpers/disclaimer`, which calls
`responsibility_spawnattrs_setdisclaim`. The child is therefore **its own TCC subject**
and cannot borrow the host app's usage descriptions — Claude.app declares none for
Reminders. Hence the embedded `Resources/Info.plist`.

**The corollary bites during development.** Launched straight from a terminal the binary is
*not* disclaimed, so macOS attributes the request to the responsible ancestor instead — the
terminal, or Claude Code, neither of which declares
`NSRemindersFullAccessUsageDescription`. The request returns with the status still
`notDetermined` and **no dialog is ever shown**, which is indistinguishable from a missing
`Info.plist` or a linker-signed binary. Verified on macOS 26.5: direct launch never
prompts; launching through `disclaimer` by hand prompts on the first call and the grant
then names `apple-reminders-mcp`. `verification.md` opens with the command.

That grant survives a rebuild, confirmed the same day: repacking with the same signing
identity changed the cdhash, and `reminders_status` still reported `GRANTED (full access)`
without a second prompt. It is the designated requirement doing that work, which is the
whole argument for signing with a real certificate.

**Reminders were never split into full and write-only** the way calendars were in macOS 14.
`requestFullAccessToReminders()` is the only request, and
`NSRemindersFullAccessUsageDescription` is the only usage description key that matches it.
`EKAuthorizationStatus.writeOnly` can still be spelled, so `ReminderAuthorization` keeps
the case and explains it rather than reporting it as a denial the owner never chose.
Verified against the macOS 26.5 SDK headers.

**A linker-signed binary gets no TCC prompt at all.** `swift build` leaves exactly that,
and it produces no designated requirement, so nothing is ever logged and the status stays
"not determined". `pack.sh` re-signs and prints the requirement; if that line is empty the
build is broken in a way nothing else will show.
