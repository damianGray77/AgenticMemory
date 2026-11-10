// sp_confirm_memory: record the outcome of checking one unconfirmed memory against its transcript
// (see home/consolidator/confirm.sql for the model).
//   faithful   confirm as is (title / content must be NULL)
//   corrected  replace title and/or content with the faithful version, then confirm
//   no_source  nothing to check against: stays unconfirmed, marked so it is not retried
// A confirmed memory is refused: it is the append-only record from then on.
// 'faithful' and 'no_source' keep updated_at, so they do not requeue the memory for behaviours;
// 'corrected' bumps it, so the behaviours step re-reads the corrected text.
using System.Collections.Generic;

namespace MemDb
{
    public static partial class Procs
    {
        static partial void RegisterConfirm()
        {
            Reg("sp_confirm_memory", 6, ConfirmMemory);
        }

        static List<ResultSet> ConfirmMemory(Db db, object[] a)
        {
            long? id = L(a, 0);
            string given = S(a, 1), title = S(a, 2), content = S(a, 3), reason = S(a, 4), run = S(a, 5);
            // MySQL compared the outcome case-insensitively. (A NULL outcome slipped through to the
            // no_source branch there; here it is rejected as a bad outcome.)
            string outcome = given == null ? null : given.ToLowerInvariant();

            long enabled = CfgLong(db, "enabled", 0);
            long dry = CfgLong(db, "dry_run", 1);
            long cenabled = CfgLong(db, "confirm_enabled", 0);
            long cdry = CfgLong(db, "confirm_dry_run", 1);
            long max = CfgLong(db, "max_confirm_actions_per_run", 30);
            dry = System.Math.Max(dry, cdry);

            if (enabled == 0)
            {
                Log(db, run, "skipped", null, null, null, null, "enabled=0 (kill switch)", dry != 0);
                return None();
            }
            if (cenabled == 0)
            {
                Log(db, run, "skipped", null, null, null, null, "confirm_enabled=0", dry != 0);
                return None();
            }

            if ((db.ScalarLong("SELECT COUNT(*) FROM memories WHERE id = ? AND is_active = 1", id) ?? 0) == 0)
            {
                Log(db, run, "error", "memories", id, null, null, "memory not found or inactive", dry != 0);
                return None();
            }

            Dictionary<string, object> m = db.Row(
                "SELECT confirmed, source_session, updated_at, json_object('title', title, 'content', content, 'confirmed', confirmed, " +
                "'confirm_outcome', confirm_outcome, 'confirm_checked_at', confirm_checked_at, 'updated_at', updated_at) AS before " +
                "FROM memories WHERE id = ?", id);
            long confirmed = Db.ToLong(m["confirmed"]) ?? 0;
            long? session = Db.ToLong(m["source_session"]);
            object updatedAt = m["updated_at"];
            string before = Db.ToStr(m["before"]);

            if (confirmed == 1)
            {
                Log(db, run, "error", "memories", id, null, null, "already confirmed: confirmed memories are append-only", dry != 0);
                return None();
            }
            if (outcome != "faithful" && outcome != "corrected" && outcome != "no_source")
            {
                Log(db, run, "error", "memories", id, null, null, "bad outcome: " + (given ?? "NULL"), dry != 0);
                return None();
            }
            if (outcome == "corrected" && title == null && content == null)
            {
                Log(db, run, "error", "memories", id, null, null, "corrected needs a new title or content", dry != 0);
                return None();
            }
            if (outcome != "corrected" && (title != null || content != null))
            {
                Log(db, run, "error", "memories", id, null, null, given + " takes no new title or content", dry != 0);
                return None();
            }

            if (dry == 0)
            {
                long acted = db.ScalarLong("SELECT COUNT(*) FROM consolidation_log WHERE run_id = ? AND dry_run = 0 AND action = 'confirm_memory'", run) ?? 0;
                if (acted >= max)
                {
                    Log(db, run, "capped", "memories", id, null, null, "max_confirm_actions_per_run=" + max + " reached", false);
                    return None();
                }

                if (outcome == "faithful")
                {
                    db.Exec("UPDATE memories SET confirmed = 1, confirm_outcome = 'faithful', confirm_checked_at = now() WHERE id = ?", id);
                    KeepTimestamp(db, "memories", "updated_at", "id", id, updatedAt);
                }
                else if (outcome == "corrected")
                {
                    db.Exec("UPDATE memories SET title = COALESCE(?, title), content = COALESCE(?, content), confirmed = 1, " +
                            "confirm_outcome = 'corrected', confirm_checked_at = now() WHERE id = ?", title, content, id);
                }
                else
                {
                    db.Exec("UPDATE memories SET confirm_outcome = 'no_source', confirm_checked_at = now() WHERE id = ?", id);
                    KeepTimestamp(db, "memories", "updated_at", "id", id, updatedAt);
                }
            }

            Log(db, run, "confirm_memory", "memories", id, before,
                Json(db, "outcome", given, "title", title, "content", content),
                Clip(given + ": " + (reason ?? ""), 500), dry != 0);

            // a checked memory should point at what it was checked against
            if (dry == 0 && outcome != "no_source" && session.HasValue) BackpointMemory(db, id, session, run);
            return None();
        }
    }
}
