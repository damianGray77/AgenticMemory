// The rail-enforcing mutation API for the judgment tier (see home/consolidator/judgment_procs.sql).
// The consolidation pass NEVER writes memories/session_notes directly; it calls only these:
//   * honor enabled (kill switch) and dry_run (log-only) from consolidation_config
//   * cap real mutations per run at max_actions_per_run (blast radius)
//   * soft operations only (is_active = 0 / is_consolidated = 1; never a hard DELETE)
//   * before/after JSON in consolidation_log for full reversibility
using System.Collections.Generic;

namespace MemDb
{
    public static partial class Procs
    {
        static partial void RegisterJudgment()
        {
            Reg("sp_backpoint_memory", 3, BackpointMemory);
            Reg("sp_promote_note", 6, PromoteNote);
            Reg("sp_normalize_category", 3, NormalizeCategory);
            Reg("sp_merge_memory", 5, MergeMemory);
            Reg("sp_dismiss_note", 3, DismissNote);
            Reg("sp_defer_note", 3, DeferNote);
        }

        const string JudgmentActions = "('promote_note','merge_memory','normalize_category','dismiss_note')";

        static bool JudgmentCapped(Db db, string run, long max)
        {
            long acted = db.ScalarLong("SELECT COUNT(*) FROM consolidation_log WHERE run_id = ? AND dry_run = 0 AND action IN " +
                                       JudgmentActions, run) ?? 0;
            return acted >= max;
        }

        // Stamp a coarse session-span back-pointer: memory -> the transcript of its origin session,
        // spanning that transcript's messages. Skips quietly if the transcript is not archived yet.
        static List<ResultSet> BackpointMemory(Db db, object[] a)
        {
            BackpointMemory(db, L(a, 0), L(a, 1), S(a, 2));
            return None();
        }

        internal static void BackpointMemory(Db db, long? memoryId, long? sessionId, string run)
        {
            long enabled = CfgLong(db, "enabled", 0);
            long dry = CfgLong(db, "dry_run", 1);
            if (enabled == 0 || !sessionId.HasValue) return;

            // the session's transcript: direct link first, then via the session uuid
            long? tid = db.ScalarLong("SELECT id FROM transcripts WHERE session_id = ? ORDER BY id LIMIT 1", sessionId);
            if (!tid.HasValue)
                tid = db.ScalarLong("SELECT t.id FROM transcripts t JOIN sessions s ON s.session_uuid = t.session_uuid " +
                                    "WHERE s.id = ? ORDER BY t.id LIMIT 1", sessionId);
            if (!tid.HasValue)
            {
                Log(db, run, "backpoint_skipped", "memories", memoryId, null, null,
                    MyConcat("no archived transcript for session ", sessionId), dry != 0);
                return;
            }

            // already linked: no duplicate provenance rows
            if (db.ScalarLong("SELECT EXISTS (SELECT 1 FROM memory_sources WHERE memory_id = ? AND transcript_id = ?)", memoryId, tid) == 1)
                return;

            string start = db.ScalarString("SELECT message_uuid FROM transcript_messages WHERE transcript_id = ? ORDER BY seq ASC LIMIT 1", tid);
            string end = db.ScalarString("SELECT message_uuid FROM transcript_messages WHERE transcript_id = ? ORDER BY seq DESC LIMIT 1", tid);
            if (start == null) return;

            if (dry == 0)
                db.Exec("INSERT INTO memory_sources (source_type, memory_id, transcript_id, start_message_uuid, end_message_uuid, rationale) " +
                        "VALUES ('memory', ?, ?, ?, ?, 'coarse session-span back-pointer (auto)')", memoryId, tid, start, end);

            Log(db, run, "add_backpointer", "memories", memoryId, null,
                Json(db, "transcript_id", tid, "start", start, "end", end),
                MyConcat("link memory ", memoryId, " -> transcript ", tid), dry != 0);
        }

        // Promote a session note into a curated memory; provenance via source_session, and a
        // back-pointer stamped as a byproduct.
        static List<ResultSet> PromoteNote(Db db, object[] a)
        {
            long? noteId = L(a, 0);
            string memoryType = S(a, 1), category = S(a, 2), title = S(a, 3), content = S(a, 4), run = S(a, 5);
            long enabled = CfgLong(db, "enabled", 0);
            long dry = CfgLong(db, "dry_run", 1);
            long max = CfgLong(db, "max_actions_per_run", 50);

            if (enabled == 0)
            {
                Log(db, run, "skipped", null, null, null, null, "enabled=0 (kill switch)", dry != 0);
                return None();
            }

            Dictionary<string, object> note = db.Row("SELECT title, session_id FROM session_notes WHERE id = ?", noteId);
            string noteTitle = note == null ? null : Db.ToStr(note["title"]);
            long? session = note == null ? null : Db.ToLong(note["session_id"]);
            if (noteTitle == null)
            {
                Log(db, run, "error", "session_notes", noteId, null, null, "note not found", dry != 0);
                return None();
            }

            long? newId = null;
            if (dry == 0)
            {
                if (JudgmentCapped(db, run, max))
                {
                    Log(db, run, "capped", "session_notes", noteId, null, null, "max_actions_per_run=" + max + " reached", false);
                    return None();
                }
                db.Exec("INSERT INTO memories (memory_type, category, title, content, source_session, is_active) VALUES (?, ?, ?, ?, ?, 1)",
                        memoryType, category, title, content, session);
                newId = db.LastInsertId;
                db.Exec("UPDATE session_notes SET is_consolidated = 1 WHERE id = ?", noteId);
            }

            Log(db, run, "promote_note", "session_notes", noteId,
                Json(db, "note_id", noteId, "title", noteTitle, "session_id", session),
                Json(db, "new_memory_id", newId, "memory_type", memoryType, "category", category, "title", title, "source_session", session),
                "promote session note to curated memory", dry != 0);

            if (dry == 0 && newId.HasValue) BackpointMemory(db, newId, session, run);
            return None();
        }

        // Collapse a drifted category label into a canonical one across active memories.
        static List<ResultSet> NormalizeCategory(Db db, object[] a)
        {
            string from = S(a, 0), to = S(a, 1), run = S(a, 2);
            long enabled = CfgLong(db, "enabled", 0);
            long dry = CfgLong(db, "dry_run", 1);

            if (enabled == 0)
            {
                Log(db, run, "skipped", null, null, null, null, "enabled=0 (kill switch)", dry != 0);
                return None();
            }

            long count = db.ScalarLong("SELECT COUNT(*) FROM memories WHERE category = ? AND is_active = 1", from) ?? 0;
            Log(db, run, "normalize_category", "memories", null,
                Json(db, "from", from, "affected", count), Json(db, "to", to),
                MyConcat("rename category \"", from, "\" -> \"", to, "\" across ", count, " active memories"), dry != 0);

            if (dry == 0) db.Exec("UPDATE memories SET category = ? WHERE category = ? AND is_active = 1", to, from);
            return None();
        }

        // Merge a duplicate memory into a survivor: soft-delete the duplicate, move its back-pointers.
        // Gated by min_merge_confidence. The dropped row is kept (inactive) and recoverable.
        static List<ResultSet> MergeMemory(Db db, object[] a)
        {
            long? keep = L(a, 0), drop = L(a, 1);
            double? conf = Dec(D(a, 2), 2);
            string reason = S(a, 3), run = S(a, 4);
            long enabled = CfgLong(db, "enabled", 0);
            long dry = CfgLong(db, "dry_run", 1);
            long max = CfgLong(db, "max_actions_per_run", 50);
            double min = Dec(CfgDouble(db, "min_merge_confidence", 0.85), 2).Value;

            if (enabled == 0)
            {
                Log(db, run, "skipped", null, null, null, null, "enabled=0 (kill switch)", dry != 0);
                return None();
            }
            if (keep.HasValue && drop.HasValue && keep.Value == drop.Value)
            {
                Log(db, run, "error", "memories", drop, null, null, "keep_id == drop_id", dry != 0);
                return None();
            }

            string keepTitle = db.ScalarString("SELECT title FROM memories WHERE id = ? AND is_active = 1", keep);
            string dropTitle = db.ScalarString("SELECT title FROM memories WHERE id = ? AND is_active = 1", drop);
            if (keepTitle == null || dropTitle == null)
            {
                Log(db, run, "error", "memories", drop, null, null, "keep or drop memory not found / inactive", dry != 0);
                return None();
            }

            // Confidence rail. (As in the MySQL original, a NULL confidence does not trip it.)
            if (conf.HasValue && conf.Value < min)
            {
                Log(db, run, "merge_skipped_low_confidence", "memories", drop,
                    Json(db, "keep_id", keep, "drop_id", drop, "confidence", conf, "threshold", min), null, reason, dry != 0);
                return None();
            }

            if (dry == 0 && JudgmentCapped(db, run, max))
            {
                Log(db, run, "capped", "memories", drop, null, null, "max_actions_per_run=" + max + " reached", false);
                return None();
            }

            Log(db, run, "merge_memory", "memories", drop,
                Json(db, "keep_id", keep, "keep_title", keepTitle, "drop_id", drop, "drop_title", dropTitle, "drop_was_active", 1),
                Json(db, "survivor", keep, "dropped", drop, "confidence", conf),
                reason, dry != 0);

            if (dry == 0)
            {
                db.Exec("UPDATE memories SET is_active = 0 WHERE id = ?", drop);
                db.Exec("UPDATE memory_sources SET memory_id = ? WHERE memory_id = ?", keep, drop);
            }
            return None();
        }

        // Mark an ephemeral note consolidated WITHOUT promoting it, so the backlog drains.
        // Shares the per-run cap; reversible (is_consolidated = 0).
        static List<ResultSet> DismissNote(Db db, object[] a)
        {
            long? noteId = L(a, 0);
            string reason = S(a, 1), run = S(a, 2);
            long enabled = CfgLong(db, "enabled", 0);
            long dry = CfgLong(db, "dry_run", 1);
            long max = CfgLong(db, "max_actions_per_run", 50);

            if (enabled == 0)
            {
                Log(db, run, "skipped", null, null, null, null, "enabled=0 (kill switch)", dry != 0);
                return None();
            }

            string title = db.ScalarString("SELECT title FROM session_notes WHERE id = ? AND is_consolidated = 0", noteId);
            if (title == null)
            {
                Log(db, run, "error", "session_notes", noteId, null, null, "note not found or already consolidated", dry != 0);
                return None();
            }

            if (dry == 0)
            {
                if (JudgmentCapped(db, run, max))
                {
                    Log(db, run, "capped", "session_notes", noteId, null, null, "max_actions_per_run=" + max + " reached", false);
                    return None();
                }
                db.Exec("UPDATE session_notes SET is_consolidated = 1 WHERE id = ?", noteId);
            }

            Log(db, run, "dismiss_note", "session_notes", noteId,
                Json(db, "note_id", noteId, "title", title, "is_consolidated", 0), Json(db, "is_consolidated", 1),
                reason, dry != 0);
            return None();
        }

        // Defer a note: reviewed and kept for now. Stamps last_reviewed so the batch query skips it
        // for review_interval_days. Bookkeeping only: NOT counted against the per-run cap.
        static List<ResultSet> DeferNote(Db db, object[] a)
        {
            long? noteId = L(a, 0);
            string reason = S(a, 1), run = S(a, 2);
            long enabled = CfgLong(db, "enabled", 0);
            long dry = CfgLong(db, "dry_run", 1);

            if (enabled == 0)
            {
                Log(db, run, "skipped", null, null, null, null, "enabled=0 (kill switch)", dry != 0);
                return None();
            }

            Dictionary<string, object> note = db.Row("SELECT title, last_reviewed FROM session_notes WHERE id = ? AND is_consolidated = 0", noteId);
            string title = note == null ? null : Db.ToStr(note["title"]);
            if (title == null)
            {
                Log(db, run, "error", "session_notes", noteId, null, null, "note not found or already consolidated", dry != 0);
                return None();
            }

            Log(db, run, "defer_note", "session_notes", noteId,
                Json(db, "note_id", noteId, "title", title, "last_reviewed", note["last_reviewed"]),
                Json(db, "last_reviewed", "set to now"), reason, dry != 0);

            if (dry == 0) db.Exec("UPDATE session_notes SET last_reviewed = now() WHERE id = ?", noteId);
            return None();
        }
    }
}
