// sp_consolidate_mechanical: the safe, deterministic tier (see home/consolidator/tier1_mechanical.sql).
// Decays stale observations and expires past-TTL memories. Logs every proposed action and only
// mutates when dry_run = 0. Throttled to one real run per calendar day, so session boot (which
// replaced MySQL's hourly event), the consolidation skill and manual calls cannot stack decays.
using System.Collections.Generic;

namespace MemDb
{
    public static partial class Procs
    {
        static partial void RegisterMechanical()
        {
            Reg("sp_consolidate_mechanical", 1, ConsolidateMechanical);
        }

        static List<ResultSet> ConsolidateMechanical(Db db, object[] a)
        {
            string run = S(a, 0);
            long enabled = CfgLong(db, "enabled", 0);
            long dry = CfgLong(db, "dry_run", 1);
            long days = CfgLong(db, "observation_decay_days", 30);
            double step = Dec(CfgDouble(db, "observation_decay_step", 0.05), 2).Value;

            if (enabled == 0)
            {
                Log(db, run, "skipped", null, null, null, null, "enabled=0 (kill switch)", dry != 0);
                return None();
            }

            // Daily throttle ('test-%' runs are exempt and do not count).
            bool isTest = run != null && run.StartsWith("test-", System.StringComparison.OrdinalIgnoreCase);
            if (!isTest && db.ScalarLong(
                    "SELECT EXISTS (SELECT 1 FROM consolidation_log WHERE action = 'mechanical_run' " +
                    "AND created_at >= curdate() AND run_id NOT LIKE 'test-%')") == 1)
                return None();

            Log(db, run, "mechanical_run", null, null, null, null, "mechanical tier; dry_run=" + dry, dry != 0);

            // MySQL's NOW() is fixed for the whole CALL; take the cut-off once so the log and the update agree.
            string now = db.ScalarString("SELECT now()");
            string cutoff = db.ScalarString("SELECT datetime(?, ?)", now, "-" + days + " days");

            // (1) decay stale observations: log first, then apply unless dry.
            db.Exec("INSERT INTO consolidation_log (run_id, action, target_table, target_id, before_json, after_json, reason, dry_run) " +
                    "SELECT ?, 'decay_observation', 'user_observations', id, json_object('confidence', confidence), " +
                    "json_object('confidence', round(max(0, confidence - ?), 2)), 'unseen since ' || date(last_seen), ? " +
                    "FROM user_observations WHERE is_active = 1 AND confidence > 0 AND last_seen < ?",
                    run, step, dry, cutoff);
            if (dry == 0)
                db.Exec("UPDATE user_observations SET confidence = round(max(0, confidence - ?), 2) " +
                        "WHERE is_active = 1 AND confidence > 0 AND last_seen < ?", step, cutoff);

            // (2) expire past-TTL memories (soft delete).
            db.Exec("INSERT INTO consolidation_log (run_id, action, target_table, target_id, before_json, after_json, reason, dry_run) " +
                    "SELECT ?, 'expire_memory', 'memories', id, json_object('is_active', is_active), json_object('is_active', 0), " +
                    "'expires_at ' || expires_at || ' < now', ? " +
                    "FROM memories WHERE is_active = 1 AND expires_at IS NOT NULL AND expires_at < ?",
                    run, dry, now);
            if (dry == 0)
                db.Exec("UPDATE memories SET is_active = 0 WHERE is_active = 1 AND expires_at IS NOT NULL AND expires_at < ?", now);

            return None();
        }
    }
}
