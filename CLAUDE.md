# CLAUDE.md

Guidance for Claude Code (claude.ai/code) when working in this repository.

## Data rule

Do not modify, complete, or delete an existing reminder or list. Test reminders may be created but must be clearly named `TESTING: ...` and cleaned up when done.

## What this is

A local MCP server (Swift 6, stdio transport) exposing the macOS Reminders app through `EventKit`. No network, no credential, no cloud API — iCloud is only the sync engine, gated by TCC consent.

## Commands

```bash
swift build
swift build -c release
swift test
```

```bash
otool -P .build/release/apple-reminders-mcp | grep NSRemindersFullAccessUsageDescription
```
