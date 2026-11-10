---
name: memory
description: Write to the {{DB_NAME}} database - session notes, memories, user observations, session close, and Rule 11 back-pointers - through a bundled script instead of hand-written SQL. Use for EVERY write to memories / session_notes / user_observations / sessions, which per the global rules means: logging a decision, attempt, discovery, blocker or milestone as work happens; recording completed work, a preference, an architecture decision or a limitation; noting a passive observation about the user; closing a session; or attaching a transcript span to something you just promoted. Also runs as /memory. Do NOT hand-write INSERT INTO memories / session_notes / user_observations - the escaping is fragile, and every literal command mints a single-use permission rule. READS are not here: use /recall or the reference_queries.
argument-hint: [what you want to record]
---

Every write to `{{DB_NAME}}` goes through the bundled script. Reads do not - `/recall` and the
`reference_queries` table already cover those.

```
powershell -NoProfile -ExecutionPolicy Bypass -File "{{CLAUDE_HOME_WIN}}\skills\memory\scripts\mem.ps1" -Action note -SessionId <id> -Type decision -Title "..." -ContentFile <path>
```

`-ExecutionPolicy Bypass` is required: LocalMachine policy is `Restricted`, so a script launched
from a fresh shell is blocked without it. It is a per-process flag and changes no system setting.

## Actions

| Action | Writes | Required |
|---|---|---|
| `note` | `session_notes` (Rule 4) | `-SessionId`, `-Title`, body; `-Type` defaults to `context` |
| `memory` | `memories` (Rule 5) | `-Type` (user\|feedback\|project\|reference), `-Title`, body; `-Category`, `-ProjectId`, `-SessionId` optional (defaults to the current Claude Code session) |
| `observe` | `user_observations`, upserting (Rule 6) | `-Category`, `-Title`, body |
| `close` | `sessions` (Rule 7) | `-SessionId`; `-Summary`, `-Files`, `-Topics` optional |
| `source` | `memory_sources` (Rule 11) | `-MemoryId` or `-NoteId`, `-TranscriptId`, `-StartUuid`; `-EndUuid` optional |

`-ProjectId 0` (the default) writes NULL - a global memory. Pass the real project id for anything
project-scoped. `observe` upserts on the unique title: re-observing bumps `observed_count` and
raises `confidence`, so record the same pattern again rather than inventing a near-duplicate title.

Every action prints the inserted id. `-DryRun` prints the SQL and writes nothing.

## Pass the body as a file, not a string

```
Write the body to the scratchpad, then: -ContentFile "<abs path>"
```

Use an absolute path - the script's working directory is not the shell's. `-Content` exists for
one-liners; anything with an apostrophe, a newline, a Windows path or an em dash should go through
a file. That is most memory content.

This is not a style preference. The script handles the escaping, but a long body on the command
line is also what mints a 3,000-character single-use permission rule, and what made hand-written
SQL fail often enough that sessions kept writing throwaway `.sql` files first.

## What to write, and when

The script is the mechanism; deciding what deserves storing is the part that needs judgment.

**Notes, as work happens** - not batched at the end. A `decision` when you choose an approach over
an alternative, an `attempt` when something did not work, a `discovery` when you learn something
non-obvious about the codebase, a `blocker`, a `milestone` when a piece lands. Write the reasoning,
not just the outcome: "chose X" is nearly worthless later; "chose X over Y because Y breaks Z" is
what a future session actually needs.

**Memories, for what outlives the session** - completed work, architecture decisions, limitations,
references. The test is whether a session three months from now would be worse off not knowing it.
Include enough specifics to act on: file paths, commit SHAs, the failure mode, what was verified.

**Observations, silently** - no permission needed, and no announcement. Communication style,
decision-making patterns, what the user pushes back on.

**Preferences need permission first (Rule 9).** When the user expresses how they want things done,
ask before storing it, then write it as a `user` or `feedback` memory. Do not quietly convert an
offhand remark into a standing rule.

**Back-pointers when you compress (Rule 11).** Promoting a note to a memory, or summarising an
exchange, loses the verbatim record. Attach the span with `-Action source` so it can be recovered:
find the transcript id and message uuids via the `search-transcripts` reference query.

## Do not

- Hand-write `INSERT INTO memories` / `session_notes` / `user_observations`. That is the thing this
  replaces.
- Store memory in `.md` files. The database is the only destination.
- Use this for reads. `/recall <topic>` searches transcripts, notes and memories together and
  returns back-pointers.
