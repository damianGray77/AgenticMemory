---
name: recall
description: Recall past work from the archived session history — full transcripts plus distilled notes and memories — and return the verbatim source with traceable back-pointers. TRIGGER when the user refers to prior work not present in the current conversation ("what did we decide about X", "last time / before / previously", "continue / pick up the Y work", "remember when we…"), or names a past session, decision, feature, or bug. Full-text searches transcripts + session_notes + memories, reads the surrounding exchange, and cites each hit as a [[transcript:id#uuid]] back-pointer. Also runs as /recall <keywords>. SKIP when the request is self-contained or the needed context is already in this conversation.
argument-hint: <topic or keywords>
---

Recall prior work from the lossless session archive (full transcripts) plus the distilled `session_notes` / `memories`, and return the verbatim source with traceable back-pointers. This is the lookup layer for the transcript-retention system — use it instead of reconstructing from a lossy summary or guessing.

Use `$ARGUMENTS` as the search keywords when invoked as `/recall`. Otherwise derive 2–5 keywords from the prior work the user referenced (feature name, decision, bug, concept). FULLTEXT needs words ≥3 chars; if a search returns nothing, retry with synonyms or fewer/broader terms.

DB CLI: `"{{MYSQL_EXE_POSIX}}" -u {{MYSQL_USER}} -p{{MYSQL_PASSWORD}} -e "USE {{DB_NAME}}; <SQL>" 2>/dev/null`

## 1. Search the transcript archive (verbatim history)
Canonical reference_query: `search-transcripts`.
```sql
SELECT t.id AS transcript_id, tm.message_uuid, tm.seq, tm.role, tm.ts, LEFT(tm.msg_text,160) AS preview
FROM transcript_messages tm JOIN transcripts t ON t.id = tm.transcript_id
WHERE MATCH(tm.msg_text) AGAINST('<keywords>' IN NATURAL LANGUAGE MODE)
ORDER BY tm.ts DESC LIMIT 20;
```

## 2. Also search the distilled records
```sql
SELECT session_id, note_type, title, LEFT(content,160) AS preview FROM session_notes
WHERE MATCH(title, content) AGAINST('<keywords>' IN NATURAL LANGUAGE MODE) LIMIT 15;
SELECT id, memory_type, category, confirmed, title FROM memories
WHERE is_active = 1 AND MATCH(title, content) AGAINST('<keywords>' IN NATURAL LANGUAGE MODE) LIMIT 15;
```
A memory with `confirmed = 0` has not yet been checked against its transcript by the consolidation pass. Mark it "(unconfirmed)" when you cite it, and prefer the transcript over it where they differ.

## 3. Read the actual discussion around a promising hit
Canonical reference_query: `read-transcript-context`.
```sql
SELECT seq, role, ts, msg_text FROM transcript_messages
WHERE transcript_id = <transcript_id> AND seq BETWEEN <seq>-3 AND <seq>+3 ORDER BY seq;
```
For the full verbatim bytes of a span (including tool calls/results), resolve via offsets: `SUBSTRING(UNCOMPRESS(raw_jsonl), byte_offset+1, byte_length)` on `transcripts`. To pull a memory's recorded sources, use reference_query `resolve-memory-sources` (or `resolve-note-sources`).

## 4. Present the findings
- Summarize what was discussed or decided, and WHEN (session id + date) — lead with the directly relevant exchange; don't dump raw rows.
- Cite each source as a back-pointer token `[[transcript:<transcript_id>#<message_uuid>]]` (or a span `#<start_uuid>..<end_uuid>`) so the user (and future sessions) can re-open the verbatim record. A topic often spans several hits — cite each.

## 5. If this recall feeds a new or updated memory/note
Attach a back-pointer so the compressed memory stays traceable (see CLAUDE.md Rule 11): insert a `memory_sources` row (`source_type`, `memory_id` or `note_id`, `transcript_id`, `start_message_uuid`, optional `end_message_uuid`) and/or embed the `[[transcript:…]]` token in the content.
