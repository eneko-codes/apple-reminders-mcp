# Manual verification

Everything below runs against **your real reminders**, which is why no agent may run it
(see the hard rule in `CLAUDE.md`). Work through it yourself, in order.

```bash
npx @modelcontextprotocol/inspector ./.build/release/apple-reminders-mcp
```

`pack.sh` builds universally and leaves the binary in `.build/apple/Products/Release/`
instead; the signed, staged copy at `extension/server/` is the one worth testing, because
it is the one that actually ships.

## Spawning it so macOS will even ask

**A server launched straight from a terminal never gets a consent dialog.** Without the
disclaim attribute the process is not its own TCC subject: macOS attributes the request to
the responsible ancestor — the terminal, or Claude Code — and neither declares
`NSRemindersFullAccessUsageDescription`. The request then returns with the status still
`notDetermined` and **no dialog is ever shown**. That looks identical to a missing
`Info.plist`, and it is the single most confusing way this can fail.

Claude Desktop avoids it by spawning through its own helper, which calls
`responsibility_spawnattrs_setdisclaim`. Do the same by hand and the prompt names
`apple-reminders-mcp` and quotes *its* usage description:

```bash
/Applications/Claude.app/Contents/Helpers/disclaimer ./extension/server/apple-reminders-mcp
```

Verified on macOS 26.5: launched directly, `reminder_lists` returns "macOS has not asked
yet" forever; launched through `disclaimer`, the dialog appears on the first call.

## 0 — Before you start

In Reminders.app, create a list named `ZZTest` and put four reminders in it:

| Reminder | Set up as | Why |
|---|---|---|
| `ZZ Open` | due tomorrow at 16:00, notes "green tin" | the normal path |
| `ZZ Whole day` | due tomorrow, no time | all-day inference |
| `ZZ Done` | completed | the completion rule |
| `ZZ Repeats` | repeating weekly, due in two days | recurrence and roll-forward |

Delete the whole `ZZTest` list when you finish. Nothing in this script should touch
anything outside it.

## 1 — Permission plumbing

| Step | Call | Expected |
|---|---|---|
| 1.1 | `reminders_status` | Before granting: `not requested yet`, with the System Settings path and the time zone. |
| 1.2 | `reminder_lists` | Consent dialog appears, quoting the usage description. |
| 1.3 | Approve, then `reminders_status` | `GRANTED (full access)`. |
| 1.4 | Revoke in System Settings, restart, call `reminders_status` | `DENIED`, naming the pane and the switch. Restore afterwards. |

There is no write-only state to test: reminders were never split the way calendars were.

## 2 — Lists

| Step | Call | Expected |
|---|---|---|
| 2.1 | `reminder_lists` | `ZZTest` present and `writable`; exactly one row marked `(default)`. |
| 2.2 | If you have a shared list you do not own | It shows `read-only`, and `create_reminder` into it is refused. |
| 2.3 | `reminder_lists` | Each row shows a colour — a palette name where it matches, otherwise a hex value. Compare a few against the swatches in Reminders.app. |
| 2.4 | If you subscribe to a list, or an account manages one | It shows `locked`, meaning its **name** cannot be changed — a separate fact from `read-only`, which is about its contents. |

Creating, renaming and deleting lists is §12, at the end, because it is the only part that
can destroy more than one reminder at a time.

## 3 — Search

| Step | Call | Expected |
|---|---|---|
| 3.1 | `reminders_search` with `"lists":["ZZTest"]` | Header echoes `incomplete`, the lists and your time zone. `ZZ Done` absent. |
| 3.2 | Same with `"status":"completed"` | Only `ZZ Done`. |
| 3.3 | Same with `"status":"any"` | Both. |
| 3.4 | `"query":"green tin"` | `ZZ Open` found — the match came from its notes, not its title. |
| 3.5 | `"due_to"` set to **tomorrow's date as a plain day** | `ZZ Open` is included even though it is due at 16:00. |
| 3.6 | `"due_from"` after `"due_to"` | Refused. |
| 3.7 | Any search with a due bound | An undated reminder never appears. |
| 3.8 | `"limit":1` | One row plus `…N more · call again with offset=1`. |
| 3.9 | `"status":"pending"` | Refused, naming the valid values. |

Step 3.5 is the one to check carefully: it is where an off-by-one would hide everything
due on the day you asked about.

**Overdue check.** Add a reminder due yesterday. It must show `overdue`. Add one due
**today with no time** — it must *not* show `overdue` until tomorrow.

## 4 — Detail

| Step | Call | Expected |
|---|---|---|
| 4.1 | `reminder_get` on `ZZ Open` | `state: open · editable`; alarm shown as `when due`; notes present. |
| 4.2 | `reminder_get` on `ZZ Done` | `state: completed … · NOT editable`, telling you to reopen it first. |
| 4.3 | `reminder_get` on `ZZ Repeats` | `repeats: every week`. |
| 4.4 | `reminder_get` on `ZZ Whole day` | The due line shows a date with **no time**. |

## 5 — Create

| Step | Call | Expected |
|---|---|---|
| 5.1 | `create_reminder` into `Nonexistent` | Refused under `Lists this tool can use:`, naming the ones that accept reminders and no read-only list. |
| 5.2 | `create_reminder` with only `list` and `title` | Created, `due none`. |
| 5.3 | `create_reminder` with `"due":"<tomorrow>T09:00"` | Created; response says an alarm was set. |
| 5.4 | **Open Reminders.app and look at 5.3** | It shows a time **and** a notification, not a bare date. |
| 5.5 | `create_reminder` with a plain-day `due` | All-day in Reminders.app; response mentions no alarm. |
| 5.6 | `create_reminder` with `"alarms":[]` and a due time | No alarm in Reminders.app. |
| 5.7 | `create_reminder` with `"alarms":["-1h"]` and no `due` | Refused. |
| 5.8 | `create_reminder` with a due date in the past | Created, flagged `⚠ This reminder is already overdue.` |
| 5.9 | `create_reminder` with `"priority":"high"` | Reminders.app shows `!` |

**Step 5.4 — settled, 2026-08-09, macOS 26.5.** Two reminders were created against the
real store with the same due time, one with `alarms: []` and one with `alarms` omitted.
The suppressed one came back carrying **no alarm at all**; only the implied one had one.
EventKit therefore adds nothing of its own, and `Dispatch.impliedAlarms` is load-bearing:
without it a reminder saved with a due time would never fire.

Re-check it if a future macOS changes the behaviour. If Reminders.app ever shows *two*
notifications for the same instant, EventKit has started adding its own and
`Dispatch.impliedAlarms` should go.

**Wait for it.** Leave 5.3 due a few minutes out and confirm the notification actually
arrives. This is the part that was *not* checked: that an alarm exists in the store is
not the same as a notification reaching you.

## 6 — The completion rule

| Step | Call | Expected |
|---|---|---|
| 6.1 | `update_reminder` on `ZZ Done` | Refused, telling you to reopen it first. |
| 6.2 | `delete_reminder` on `ZZ Done` with `confirm:true` | Refused. Confirm in Reminders.app that it is still there. |
| 6.3 | `complete_reminder` on `ZZ Done` with `completed:true` | `already completed. Nothing was changed.` |
| 6.4 | **Check the completion date in Reminders.app after 6.3** | Unchanged — it must still say when you actually finished it. |
| 6.5 | `complete_reminder` on `ZZ Done` with `completed:false` | Reopened. |
| 6.6 | `update_reminder` on it now | **Accepted.** |
| 6.7 | `complete_reminder` on `ZZ Open` | Ticked off in Reminders.app. |

Step 6.4 is the reason `complete_reminder` compares before writing: EventKit would
otherwise overwrite the completion date with the current time.

## 7 — Update

| Step | Call | Expected |
|---|---|---|
| 7.1 | `update_reminder` with no fields | Refused: nothing to change. |
| 7.2 | `update_reminder {"notes":""}` | Notes cleared; the title survives. |
| 7.3 | `update_reminder {"due":""}` on a reminder with an alarm | Due **and** alarms cleared; response lists `due, alarms`. |
| 7.4 | Check that reminder in Reminders.app | No date, and no pending notification. |
| 7.5 | `update_reminder {"due":"", "alarms":["-1h"]}` | Refused. |
| 7.6 | `update_reminder {"priority":"none"}` | Priority cleared. |
| 7.7 | `update_reminder {"alarms":["-1h"]}` on a dated reminder | Reminders.app shows a notification an hour before. |

Step 7.4 matters because a stale alarm still fires even though nothing in the UI explains
why.

## 8 — Delete

| Step | Call | Expected |
|---|---|---|
| 8.1 | `delete_reminder` without `confirm` | Refused; reminder still present. |
| 8.2 | `delete_reminder` on `ZZ Open` with `confirm:true` | Deleted, with the full record and a `create_reminder(...)` line. |
| 8.3 | Paste that `create_reminder` call back | The reminder returns with the same due date, priority and notes. |
| 8.4 | `delete_reminder` on `ZZ Repeats` | Response warns the recreate call is a one-off, not the rule. |

Step 8.3 is the real test of the recreate block: if it does not round-trip, the delete
output is not the audit record it claims to be.

## 9 — Recurrence

| Step | Action | Expected |
|---|---|---|
| 9.1 | `complete_reminder` on `ZZ Repeats` | Response notes that Reminders may roll it forward. |
| 9.2 | Look at it in Reminders.app | It is due again on the next occurrence rather than closed. |
| 9.3 | `reminders_search` for it | It appears as open, with the next due date. |

## 10 — Restart behaviour

| Step | Action | Expected |
|---|---|---|
| 10.1 | Restart Claude Desktop, `reminders_status` | Still granted, no second prompt. |
| 10.2 | Rebuild with the same signing identity, reinstall, `reminders_status` | Still granted. With ad-hoc signing it prompts **again** — the cdhash changed. |

## 11 — The non-Gregorian crash guard

`EKReminder` raises an uncatchable Objective-C exception if a due date's components carry
a non-Gregorian calendar, and `Calendar.current` follows the region setting. The unit tests
cover `DateParsing`, but only this proves the whole path.

| Step | Action | Expected |
|---|---|---|
| 11.1 | System Settings → General → Language & Region → Calendar → **Buddhist** | — |
| 11.2 | Restart Claude Desktop, `create_reminder` with a due time | Created normally, with the correct Gregorian year. |
| 11.3 | Restore your usual calendar | — |

If step 11.2 kills the server rather than returning an error, something below
`DateParsing.dueComponents` is passing components through unstamped.

## 12 — Lists: create, rename, delete

Left until last on purpose. Every other write in this script risks one reminder;
`removeCalendar` would take a whole list at once, so this is the section to run slowly and
with Reminders.app open beside the Inspector.

Use a **second** throwaway list, `ZZList`, so the guard in 12.6 is tested against `ZZTest`
while it still has things in it.

| Step | Call | Expected |
|---|---|---|
| 12.1 | `create_list {"title":"ZZList"}` | Created, `It is empty.`, and its account is the one your default list lives in. It appears in Reminders.app immediately. |
| 12.2 | `create_list {"title":"ZZList"}` again | Refused: already exists. Reminders.app still shows **one** `ZZList`. |
| 12.3 | `create_list {"title":"ZZColour","color":"orange"}` | Created orange. Check the swatch in Reminders.app, not just the response. |
| 12.4 | `create_list {"title":"ZZBad","color":"burgundy"}` | Refused, listing the accepted names. Nothing created. |
| 12.5 | `update_list {"list":"ZZList","title":"ZZMoved","color":"purple"}` | Renamed and recoloured in one call; `Fields changed: title, color`. **The reminders inside stay put** — put one in first if you want to see it. |
| 12.6 | `delete_list {"list":"ZZTest","confirm":true}` | **Refused**, naming how many reminders are in the way. Confirm in Reminders.app that `ZZTest` and everything in it survived. |
| 12.7 | `delete_list {"list":"ZZMoved"}` (no confirm) | Refused for want of `confirm=true`. |
| 12.8 | `delete_list {"list":"ZZMoved","confirm":true}` | Deleted, with a `create_list(...)` line. |
| 12.9 | Paste that `create_list` call back | The list returns with the same name, account and colour. |
| 12.10 | `delete_list` on a `locked` list from 2.4 | Refused as not yours to change. |

**Step 12.6 is the one that matters.** It is the only guard standing between
`delete_list` and a cascade that would delete completed reminders — the exact record the
rest of this server refuses to touch. If it ever succeeds against a non-empty list, stop
and fix that before anything else.

**The ambiguity guard.** If you have two lists with the same name in different accounts —
create one in a second account if not — then:

| Step | Call | Expected |
|---|---|---|
| 12.11 | `update_list` naming just that title | Refused, naming both accounts. Nothing renamed. |
| 12.12 | Same call plus `"account":"…"` | Renames exactly one of them; the other is untouched. |
| 12.13 | `create_reminder {"list":"<shared name>","title":"ZZTest"}` | Refused, naming both accounts. Nothing created in either list. |
| 12.14 | Same call plus `"account":"…"` | Created. **Check in Reminders.app which of the two lists it landed in** — it must be the account you named. |

**12.14 is the only live proof that the account survives the seam.** The tool layer
resolves the pair and `ReminderDraft` carries it, but `SystemReminderStore.create` is
below `ReminderStore` and no test reaches it. Both lists have the same name, so the
response says `Created reminder 'ZZTest' in <name>` either way — the response cannot tell
you it went to the wrong one, which is the whole reason this step reads the answer off
Reminders.app instead. Delete `ZZTest` as soon as you have looked.

**Sections.** Not a step, because there is nothing to call. In Reminders.app, add a section
to a list by hand, put a reminder in it, then `reminders_search` that list: the reminder
comes back with no trace of which section it is in, and no tool here can create, read or
remove one. That is EventKit, not this server — see the table in `README.md`.

## Clean up

Delete `ZZTest`, and any `ZZ…` list left over from §12. `delete_list` refuses a list with
anything in it, so either empty each one first or delete it in Reminders.app — which is
the intended way round, not a workaround.

Record the date and macOS version you verified on.
