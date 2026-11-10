// The behaviours layer: current guidance derived from memories. The model (rules vs habits,
// noisy-OR strength, half-life decay, supersession, conflicts), the seed rows, the views that
// compute strength and the REVERTING recipe are in consolidator\behaviours.sql; these are the
// rail-enforcing procedures the consolidation pass calls:
//
//   sp_upsert_behaviour, sp_link_evidence, sp_supersede_evidence, sp_retire_behaviour  (capped)
//   sp_resolve_behaviour, sp_refresh_behaviours, sp_mark_reviewed          (bookkeeping, uncapped)
//
// Ported statement by statement from the MySQL stored procedures. As there, problems are LOGGED
// (consolidation_log action 'error', 'capped', 'supersede_refused', 'review_deferred_capped',
// 'link_skipped_duplicate', 'skipped') and the CALL itself succeeds; only a bad argument (too
// long, out of range), a malformed config value or a constraint failure aborts the CALL, with
// MySQL's own message. Unlike MySQL (autocommit per statement), an aborted CALL leaves no writes.
//
// MySQL semantics kept on purpose:
//   * weights are DECIMAL(3,2), strength DECIMAL(4,3): compared and rounded as System.Decimal,
//     so 0.80 sits exactly on the edge of a 0.85 +/- 0.05 band, as it did under MySQL;
//   * text comparisons the procedures make themselves follow utf8mb4_unicode_ci (case- and
//     accent-insensitive, trailing spaces ignored);
//   * ENUM columns (source_type, stance) store the canonical lowercase member;
//   * a config value is read like STRICT-mode CAST(cfg_value AS SIGNED / DECIMAL(3,2)) INTO v:
//     a missing key leaves the procedure's DECLARE default, a malformed one is an error.
using System;
using System.Collections.Generic;
using System.Globalization;
using System.Text;
using System.Text.RegularExpressions;

namespace MemDb
{
    public static partial class Procs
    {
        static partial void RegisterBehaviours()
        {
            Reg("sp_resolve_behaviour", 2, BhResolveProc);
            Reg("sp_refresh_behaviours", 1, BhRefreshProc);
            Reg("sp_upsert_behaviour", 5, BhUpsertProc);
            Reg("sp_link_evidence", 11, BhLinkProc);
            Reg("sp_supersede_evidence", 4, BhSupersedeProc);
            Reg("sp_retire_behaviour", 4, BhRetireProc);
            Reg("sp_mark_reviewed", 4, BhMarkReviewedProc);
        }

        const string BhCountedActions = "('upsert_behaviour','link_evidence','supersede_evidence','retire_behaviour')";

        // ------------------------------------------------------------------------------------
        // sp_resolve_behaviour(p_behaviour_id, p_run_id)
        // Recompute kind, strength and status from live evidence. Derived bookkeeping: not
        // counted against the cap, and logged only when something changed.
        // ------------------------------------------------------------------------------------
        static List<ResultSet> BhResolveProc(Db db, object[] a)
        {
            long? id = BhUInt(a, 0, "p_behaviour_id");
            string run = BhVarchar(a, 1, 40, "p_run_id");
            BhResolve(db, id, run);
            return None();
        }

        static void BhResolve(Db db, long? id, string run)
        {
            long enabled = BhCfgInt(db, "enabled", 0);
            long dry = BhCfgInt(db, "dry_run", 1);
            if (enabled == 0) return;

            string kindOld = null, statusOld = null, noteOld = null;
            decimal? strOld = null;
            Dictionary<string, object> old = id.HasValue
                ? db.Row("SELECT kind, strength, status, conflict_note FROM behaviours WHERE id = ?", id.Value) : null;
            if (old != null)
            {
                kindOld = Db.ToStr(old["kind"]);
                strOld = BhDec(old["strength"], 3);
                statusOld = Db.ToStr(old["status"]);
                noteOld = Db.ToStr(old["conflict_note"]);
            }
            if (statusOld == null) return;

            string kind = "habit";
            decimal? str = 0m;
            long? opp = 0;
            decimal? oppW = null;
            Dictionary<string, object> s = db.Row(
                "SELECT kind, strength, opposing_events, max_opposing_weight FROM v_behaviour_strength WHERE behaviour_id = ?", id.Value);
            if (s != null)
            {
                kind = Db.ToStr(s["kind"]);
                str = BhDec(s["strength"], 3);
                opp = Db.ToLong(s["opposing_events"]);
                oppW = BhDec(s["max_opposing_weight"], 4);
            }

            // retired stays retired until sp_upsert_behaviour revives it; any live opposing
            // evidence is a conflict for the user to settle, never a silent win
            string status, note;
            if (BhCiEq(statusOld, "retired"))
            {
                status = "retired";
                note = noteOld;
            }
            else if (opp.HasValue && opp.Value > 0)
            {
                status = "conflict";
                note = oppW.HasValue   // CONCAT() is NULL when any part is
                    ? opp.Value.ToString(CultureInfo.InvariantCulture) + " opposing event(s), strongest at "
                      + BhFmt(Math.Round(oppW.Value, 2, MidpointRounding.AwayFromZero), 2)
                      + "; only a newer statement from " + BhUserName(db) + " can settle it"
                    : null;
            }
            else
            {
                status = "active";
                note = null;
            }

            bool same = BhCiEq(kind, kindOld)
                     && str.HasValue && strOld.HasValue && str.Value == strOld.Value
                     && BhCiEq(status, statusOld)
                     && ((note == null && noteOld == null) || BhCiEq(note, noteOld));
            if (same)
            {
                if (dry == 0)
                    db.Exec("UPDATE behaviours SET resolved_at = now(), resolved_run_id = ? WHERE id = ?", run, id.Value);
                return;
            }

            BhLog(db, run, "resolve_behaviour", "behaviours", id,
                BhJson(db, "kind", kindOld, "strength", strOld, "status", statusOld, "conflict_note", noteOld),
                BhJson(db, "kind", kind, "strength", str, "status", status, "conflict_note", note),
                "recomputed from live evidence", dry);

            if (dry == 0)
                db.Exec("UPDATE behaviours SET kind = ?, strength = ?, status = ?, conflict_note = ?, " +
                        "resolved_at = now(), resolved_run_id = ? WHERE id = ?",
                        kind, BhDbl(str), status, note, run, id.Value);
        }

        // ------------------------------------------------------------------------------------
        // sp_refresh_behaviours(p_run_id)
        // Re-resolve every behaviour that is not retired, so habit decay is applied even when
        // no new evidence arrived. Walks ids with MIN(), as the original did.
        // ------------------------------------------------------------------------------------
        static List<ResultSet> BhRefreshProc(Db db, object[] a)
        {
            string run = BhVarchar(a, 0, 40, "p_run_id");
            long enabled = BhCfgInt(db, "enabled", 0);
            long dry = BhCfgInt(db, "dry_run", 1);
            if (enabled == 0)
            {
                BhLog(db, run, "skipped", null, null, null, null, "enabled=0 (kill switch)", dry);
                return None();
            }

            long last = 0;
            while (true)
            {
                long? next = db.ScalarLong("SELECT MIN(id) FROM behaviours WHERE id > ? AND status <> 'retired'", last);
                if (!next.HasValue) break;
                BhResolve(db, next, run);
                last = next.Value;
            }
            return None();
        }

        // ------------------------------------------------------------------------------------
        // sp_upsert_behaviour(p_subject, p_project_id, p_statement, p_reason, p_run_id)
        // Create a behaviour, or rewrite its statement when the user's guidance has changed.
        // Reviving a retired behaviour also goes through here.
        // ------------------------------------------------------------------------------------
        static List<ResultSet> BhUpsertProc(Db db, object[] a)
        {
            string subject = BhVarchar(a, 0, 100, "p_subject");
            long? projectId = BhUInt(a, 1, "p_project_id");          // NULL = global
            string statement = BhText(a, 2, "p_statement");
            string reason = BhVarchar(a, 3, 500, "p_reason");
            string run = BhVarchar(a, 4, 40, "p_run_id");

            long enabled = BhCfgInt(db, "enabled", 0);
            long dry = BhCfgInt(db, "dry_run", 1);
            long max = BhCfgInt(db, "max_behaviour_actions_per_run", 50);
            long beh = BhCfgInt(db, "behaviours_enabled", 0);
            if (BhSkipped(db, run, enabled, beh, dry)) return None();

            // one naming scheme, so subjects cannot drift the way memory categories did
            // (case-sensitive: the column collation would otherwise accept capitals)
            if (subject == null || !BhSubjectOk(subject))
            {
                BhLog(db, run, "error", "behaviours", null, null, null,
                    "bad subject \"" + (subject ?? "NULL") + "\": want dotted lowercase, e.g. tooling.scripting-languages", dry);
                return None();
            }
            if (statement == null || statement.Trim(' ').Length == 0)
            {
                BhLog(db, run, "error", "behaviours", null, null, null, "empty statement for " + subject, dry);
                return None();
            }

            long? id = null;
            string old = null, oldStatus = null;
            Dictionary<string, object> row = db.Row(
                "SELECT id, statement, status FROM behaviours WHERE subject = ? AND scope_project_id = ?",
                BhPad(subject), projectId ?? 0);
            if (row != null)
            {
                id = Db.ToLong(row["id"]);
                old = Db.ToStr(row["statement"]);
                oldStatus = Db.ToStr(row["status"]);
            }
            if (id.HasValue && BhCiEq(old, statement) && oldStatus != null && !BhCiEq(oldStatus, "retired"))
                return None();   // nothing to change

            if (dry == 0)
            {
                if (BhCapped(db, run, max, "behaviours", id)) return None();
                if (!id.HasValue)
                {
                    db.Exec("INSERT INTO behaviours (subject, project_id, statement, resolved_run_id) VALUES (?, ?, ?, ?)",
                        subject, projectId, statement, run);
                    id = db.LastInsertId;
                }
                else
                {
                    db.Exec("UPDATE behaviours SET statement = ?, " +
                            "status = CASE WHEN status = 'retired' THEN 'active' ELSE status END WHERE id = ?",
                            statement, id.Value);
                }
            }

            BhLog(db, run, "upsert_behaviour", "behaviours", id,
                old == null ? null : BhJson(db, "statement", old, "status", oldStatus),
                BhJson(db, "subject", subject, "project_id", projectId, "statement", statement, "created", old == null),
                reason, dry);

            if (dry == 0) BhResolve(db, id, run);
            return None();
        }

        // ------------------------------------------------------------------------------------
        // sp_link_evidence(p_subject, p_project_id, p_source_type, p_source_id, p_kind, p_weight,
        //                  p_stance, p_occurred_at, p_event_key, p_rationale, p_run_id)
        // Link one piece of evidence (a memory, observation or session note) to a behaviour,
        // then re-resolve it. The weight must sit within tolerance of the anchor for its kind.
        // ------------------------------------------------------------------------------------
        static List<ResultSet> BhLinkProc(Db db, object[] a)
        {
            string subject = BhVarchar(a, 0, 100, "p_subject");
            long? projectId = BhUInt(a, 1, "p_project_id");          // NULL = global
            string srcType = BhVarchar(a, 2, 20, "p_source_type");    // memory | observation | session_note
            long? srcId = BhUInt(a, 3, "p_source_id");
            string kind = BhVarchar(a, 4, 40, "p_kind");              // a behaviour_evidence_kinds.kind
            decimal? weightArg = BhDecArg(a, 5, 3, 2, "p_weight");    // NULL = the anchor weight for p_kind
            string stanceArg = BhVarchar(a, 6, 10, "p_stance");       // supports | opposes; NULL = supports
            string occurred = BhDateArg(a, 7, "p_occurred_at");       // NULL = taken from the source row
            string eventKey = BhVarchar(a, 8, 100, "p_event_key");    // NULL = one event per source row
            string rationale = BhVarchar(a, 9, 500, "p_rationale");
            string run = BhVarchar(a, 10, 40, "p_run_id");

            long enabled = BhCfgInt(db, "enabled", 0);
            long dry = BhCfgInt(db, "dry_run", 1);
            long max = BhCfgInt(db, "max_behaviour_actions_per_run", 50);
            decimal tol = BhCfgDec(db, "behaviour_weight_tolerance", 0.05m);
            long beh = BhCfgInt(db, "behaviours_enabled", 0);
            if (BhSkipped(db, run, enabled, beh, dry)) return None();

            decimal? anchor = kind == null ? null
                : BhDec(db.Scalar("SELECT anchor_weight FROM behaviour_evidence_kinds WHERE kind = ?", kind), 2);
            if (!anchor.HasValue)
            {
                BhLog(db, run, "error", "behaviour_evidence", null, null, null,
                    "unknown evidence kind \"" + (kind ?? "NULL") + "\"", dry);
                return None();
            }
            decimal weight = weightArg.HasValue ? weightArg.Value : anchor.Value;
            if (Math.Abs(weight - anchor.Value) > tol || weight < 0 || weight > 1)
            {
                BhLog(db, run, "error", "behaviour_evidence", null, null, null,
                    "weight " + BhFmt(weight, 2) + " is outside the " + kind + " band " + BhFmt(anchor.Value, 2) + " +/- " + BhFmt(tol, 2), dry);
                return None();
            }
            string stance = stanceArg ?? "supports";
            string stanceEnum = BhCiEq(stance, "supports") ? "supports" : BhCiEq(stance, "opposes") ? "opposes" : null;
            if (stanceEnum == null)
            {
                BhLog(db, run, "error", "behaviour_evidence", null, null, null, "bad stance \"" + stance + "\"", dry);
                return None();
            }

            // the source must exist and still be live; its own date is the default
            // "when it happened" (an observation is dated by its latest sighting)
            string srcEnum = null, when = null;
            bool srcOk = false;
            object found = null;
            if (BhCiEq(srcType, "memory"))
            {
                srcEnum = "memory";
                found = BhFirst(db, "SELECT created_at FROM memories WHERE id = ? AND is_active = 1", srcId, out srcOk);
            }
            else if (BhCiEq(srcType, "observation"))
            {
                srcEnum = "observation";
                found = BhFirst(db, "SELECT last_seen FROM user_observations WHERE id = ? AND is_active = 1", srcId, out srcOk);
            }
            else if (BhCiEq(srcType, "session_note"))
            {
                srcEnum = "session_note";
                found = BhFirst(db, "SELECT created_at FROM session_notes WHERE id = ?", srcId, out srcOk);
            }
            if (!srcOk)
            {
                BhLog(db, run, "error", "behaviour_evidence", null, null, null,
                    (srcType ?? "NULL") + " " + BhId(srcId) + " not found, inactive, or not a valid source type", dry);
                return None();
            }
            when = occurred ?? BhTime(found);
            string trimmedKey = eventKey == null ? null : eventKey.Trim(' ');
            string key = string.IsNullOrEmpty(trimmedKey) ? srcType + ":" + BhId(srcId) : trimmedKey;

            long? bid = db.ScalarLong("SELECT id FROM behaviours WHERE subject = ? AND scope_project_id = ?",
                BhPad(subject), projectId ?? 0);
            // in a dry run the subject may exist only in this run's log, so carry on and log it
            if (!bid.HasValue && dry == 0)
            {
                BhLog(db, run, "error", "behaviour_evidence", null, null, null,
                    "no behaviour \"" + (subject ?? "NULL") + "\"; call sp_upsert_behaviour first", dry);
                return None();
            }

            if (bid.HasValue && db.Scalar(
                    "SELECT 1 FROM behaviour_evidence WHERE behaviour_id = ? AND event_key = ? AND source_type = ? AND source_id = ?",
                    bid.Value, key, srcEnum, srcId) != null)
            {
                BhLog(db, run, "link_skipped_duplicate", "behaviours", bid, null, null,
                    srcType + " " + BhId(srcId) + " already linked as " + key, dry);
                return None();
            }

            long? newId = null;
            if (dry == 0)
            {
                if (BhCapped(db, run, max, "behaviours", bid)) return None();
                db.Exec("INSERT INTO behaviour_evidence (behaviour_id, source_type, source_id, evidence_kind, weight, stance, " +
                        "occurred_at, event_key, rationale, run_id) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)",
                        bid.Value, srcEnum, srcId, kind, (double)weight, stanceEnum, when, key, rationale, run);
                newId = db.LastInsertId;
            }

            BhLog(db, run, "link_evidence", "behaviour_evidence", newId, null,
                BhJson(db, "behaviour_id", bid, "subject", subject, "source_type", srcType, "source_id", srcId,
                           "kind", kind, "weight", weight, "stance", stance, "occurred_at", when, "event_key", key),
                rationale, dry);

            if (dry == 0) BhResolve(db, bid, run);
            return None();
        }

        // ------------------------------------------------------------------------------------
        // sp_supersede_evidence(p_old_id, p_new_id, p_reason, p_run_id)
        // Replace older evidence with a newer statement from the user. The old row is kept and
        // points at its replacement. Refused unless the replacement is at or above the rule
        // threshold and no older than what it replaces.
        // ------------------------------------------------------------------------------------
        static List<ResultSet> BhSupersedeProc(Db db, object[] a)
        {
            long? oldId = BhUInt(a, 0, "p_old_id");
            long? newId = BhUInt(a, 1, "p_new_id");
            string reason = BhVarchar(a, 2, 500, "p_reason");
            string run = BhVarchar(a, 3, 40, "p_run_id");

            long enabled = BhCfgInt(db, "enabled", 0);
            long dry = BhCfgInt(db, "dry_run", 1);
            long max = BhCfgInt(db, "max_behaviour_actions_per_run", 50);
            decimal rule = BhCfgDec(db, "behaviour_rule_threshold", 0.75m);
            long beh = BhCfgInt(db, "behaviours_enabled", 0);
            if (BhSkipped(db, run, enabled, beh, dry)) return None();

            long? oldB = null, newB = null, oldSup = null, newSup = null;
            string oldWhen = null, newWhen = null;
            decimal? newW = null;
            Dictionary<string, object> o = oldId.HasValue
                ? db.Row("SELECT behaviour_id, occurred_at, superseded_by FROM behaviour_evidence WHERE id = ?", oldId.Value) : null;
            if (o != null)
            {
                oldB = Db.ToLong(o["behaviour_id"]);
                oldWhen = BhTime(o["occurred_at"]);
                oldSup = Db.ToLong(o["superseded_by"]);
            }
            Dictionary<string, object> n = newId.HasValue
                ? db.Row("SELECT behaviour_id, occurred_at, superseded_by, weight FROM behaviour_evidence WHERE id = ?", newId.Value) : null;
            if (n != null)
            {
                newB = Db.ToLong(n["behaviour_id"]);
                newWhen = BhTime(n["occurred_at"]);
                newSup = Db.ToLong(n["superseded_by"]);
                newW = BhDec(n["weight"], 2);
            }

            if (!oldB.HasValue || !newB.HasValue || oldId == newId || oldB.Value != newB.Value)
            {
                BhLog(db, run, "error", "behaviour_evidence", oldId, null, null,
                    "supersede " + BhId(oldId) + " by " + BhId(newId) + ": need two different existing evidence rows on the same behaviour", dry);
                return None();
            }
            if (oldSup.HasValue || newSup.HasValue)
            {
                BhLog(db, run, "error", "behaviour_evidence", oldId, null, null,
                    "supersede " + BhId(oldId) + " by " + BhId(newId) + ": one of them is already superseded", dry);
                return None();
            }
            if ((newW.HasValue && newW.Value < rule) || BhTimeLess(newWhen, oldWhen))
            {
                BhLog(db, run, "supersede_refused", "behaviour_evidence", oldId,
                    BhJson(db, "old_id", oldId, "old_occurred_at", oldWhen, "new_id", newId,
                               "new_occurred_at", newWhen, "new_weight", newW, "rule_threshold", rule),
                    null,
                    "only a newer statement from " + BhUserName(db) + " (at or above the rule threshold) can supersede; " +
                    "link it as opposing evidence instead", dry);
                return None();
            }

            if (dry == 0)
            {
                if (BhCapped(db, run, max, "behaviour_evidence", oldId)) return None();
                db.Exec("UPDATE behaviour_evidence SET superseded_by = ? WHERE id = ?", newId.Value, oldId.Value);
            }

            BhLog(db, run, "supersede_evidence", "behaviour_evidence", oldId,
                BhJson(db, "superseded_by", null),
                BhJson(db, "superseded_by", newId, "behaviour_id", oldB),
                reason, dry);

            if (dry == 0) BhResolve(db, oldB, run);
            return None();
        }

        // ------------------------------------------------------------------------------------
        // sp_retire_behaviour(p_subject, p_project_id, p_reason, p_run_id)
        // Retire a behaviour that no longer applies at all (a change goes through
        // sp_upsert_behaviour). Soft and revivable.
        // ------------------------------------------------------------------------------------
        static List<ResultSet> BhRetireProc(Db db, object[] a)
        {
            string subject = BhVarchar(a, 0, 100, "p_subject");
            long? projectId = BhUInt(a, 1, "p_project_id");
            string reason = BhVarchar(a, 2, 500, "p_reason");
            string run = BhVarchar(a, 3, 40, "p_run_id");

            long enabled = BhCfgInt(db, "enabled", 0);
            long dry = BhCfgInt(db, "dry_run", 1);
            long max = BhCfgInt(db, "max_behaviour_actions_per_run", 50);
            long beh = BhCfgInt(db, "behaviours_enabled", 0);
            if (BhSkipped(db, run, enabled, beh, dry)) return None();

            long? id = null;
            string status = null;
            Dictionary<string, object> row = db.Row(
                "SELECT id, status FROM behaviours WHERE subject = ? AND scope_project_id = ?", BhPad(subject), projectId ?? 0);
            if (row != null)
            {
                id = Db.ToLong(row["id"]);
                status = Db.ToStr(row["status"]);
            }
            if (!id.HasValue)
            {
                BhLog(db, run, "error", "behaviours", null, null, null, "no behaviour \"" + (subject ?? "NULL") + "\"", dry);
                return None();
            }
            if (BhCiEq(status, "retired")) return None();

            if (dry == 0)
            {
                if (BhCapped(db, run, max, "behaviours", id)) return None();
                db.Exec("UPDATE behaviours SET status = 'retired', resolved_at = now(), resolved_run_id = ? WHERE id = ?", run, id.Value);
            }

            BhLog(db, run, "retire_behaviour", "behaviours", id,
                BhJson(db, "status", status), BhJson(db, "status", "retired"), reason, dry);
            return None();
        }

        // ------------------------------------------------------------------------------------
        // sp_mark_reviewed(p_source_type, p_source_id, p_outcome, p_run_id)
        // Record that the pass has finished with a source, whatever it decided, so it leaves
        // v_behaviour_worklist. Bookkeeping, not counted against the cap. Refused once this run
        // has hit the cap: a link that never went in must leave its source queued.
        // ------------------------------------------------------------------------------------
        static List<ResultSet> BhMarkReviewedProc(Db db, object[] a)
        {
            string srcType = BhVarchar(a, 0, 20, "p_source_type");    // memory | observation | session_note
            long? srcId = BhUInt(a, 1, "p_source_id");
            string outcome = BhVarchar(a, 2, 255, "p_outcome");
            string run = BhVarchar(a, 3, 40, "p_run_id");

            long enabled = BhCfgInt(db, "enabled", 0);
            long dry = BhCfgInt(db, "dry_run", 1);
            long beh = BhCfgInt(db, "behaviours_enabled", 0);
            if (BhSkipped(db, run, enabled, beh, dry)) return None();

            string srcEnum = BhCiEq(srcType, "memory") ? "memory"
                           : BhCiEq(srcType, "observation") ? "observation"
                           : BhCiEq(srcType, "session_note") ? "session_note" : null;
            if (srcEnum == null)
            {
                BhLog(db, run, "error", "behaviour_source_reviews", null, null, null,
                    "bad source type \"" + (srcType ?? "NULL") + "\"", dry);
                return None();
            }

            if (db.Scalar("SELECT 1 FROM consolidation_log WHERE run_id = ? AND action = 'capped' " +
                          "AND target_table IN ('behaviours','behaviour_evidence') LIMIT 1", run) != null)
            {
                BhLog(db, run, "review_deferred_capped", "behaviour_source_reviews", srcId, null, null,
                    srcId.HasValue ? srcType + " " + BhId(srcId) + " left queued: this run hit max_behaviour_actions_per_run" : null,
                    dry);
                return None();
            }

            string prevAt = null, prevOut = null;
            Dictionary<string, object> prev = srcId.HasValue
                ? db.Row("SELECT reviewed_at, outcome FROM behaviour_source_reviews WHERE source_type = ? AND source_id = ?", srcEnum, srcId.Value)
                : null;
            if (prev != null)
            {
                prevAt = BhTime(prev["reviewed_at"]);
                prevOut = Db.ToStr(prev["outcome"]);
            }

            BhLog(db, run, "mark_reviewed", "behaviour_source_reviews", srcId,
                prevAt == null ? null : BhJson(db, "reviewed_at", prevAt, "outcome", prevOut),
                BhJson(db, "source_type", srcType, "source_id", srcId, "outcome", outcome),
                outcome, dry);

            if (dry == 0)
                db.Exec("INSERT INTO behaviour_source_reviews (source_type, source_id, reviewed_at, run_id, outcome) " +
                        "VALUES (?, ?, now(), ?, ?) " +
                        "ON CONFLICT (source_type, source_id) DO UPDATE SET reviewed_at = now(), run_id = excluded.run_id, outcome = excluded.outcome",
                        srcEnum, srcId, run, outcome);
            return None();
        }

        // ====================================================================================
        // Helpers (Bh-prefixed: the Procs class is shared with the other areas)
        // ====================================================================================

        static bool BhSkipped(Db db, string run, long enabled, long beh, long dry)
        {
            if (enabled == 0)
            {
                BhLog(db, run, "skipped", null, null, null, null, "enabled=0 (kill switch)", dry);
                return true;
            }
            if (beh == 0)
            {
                BhLog(db, run, "skipped", null, null, null, null, "behaviours_enabled=0", dry);
                return true;
            }
            return false;
        }

        /// <summary>The per-run cap on real behaviour mutations; logs 'capped' and returns true when reached.</summary>
        static bool BhCapped(Db db, string run, long max, string table, long? targetId)
        {
            long acted = db.ScalarLong("SELECT COUNT(*) FROM consolidation_log WHERE run_id = ? AND dry_run = 0 " +
                                       "AND action IN " + BhCountedActions, run) ?? 0;
            if (acted < max) return false;
            BhLog(db, run, "capped", table, targetId, null, null,
                "max_behaviour_actions_per_run=" + max.ToString(CultureInfo.InvariantCulture) + " reached", 0);
            return true;
        }

        static void BhLog(Db db, string run, string action, string table, long? targetId,
                          string before, string after, string reason, long dry)
        {
            Log(db, run, action, table, targetId, before, after, reason, dry != 0);
        }

        /// <summary>json_object(k1, v1, ...): decimals become JSON numbers, bools JSON true/false.</summary>
        static string BhJson(Db db, params object[] kv)
        {
            StringBuilder sql = new StringBuilder("SELECT json_object(");
            object[] args = new object[kv.Length];
            for (int i = 0; i < kv.Length; i++)
            {
                if (i > 0) sql.Append(", ");
                object v = kv[i];
                if (v is bool) { sql.Append("json(?)"); args[i] = (bool)v ? "true" : "false"; }
                else { sql.Append('?'); args[i] = v is decimal ? (object)(double)(decimal)v : v; }
            }
            sql.Append(')');
            return db.ScalarString(sql.ToString(), args);
        }

        /// <summary>The user's name for log text; consolidator\behaviours.sql fills it into v_behaviour_config.</summary>
        static string BhUserName(Db db)
        {
            try
            {
                string n = db.ScalarString("SELECT user_name FROM v_behaviour_config");
                if (!string.IsNullOrEmpty(n) && n.IndexOf("{{", StringComparison.Ordinal) < 0) return n;
            }
            catch (MemDbException) { }
            return "the user";
        }

        /// <summary>First column of the first row of a one-parameter query; ok = a row existed.</summary>
        static object BhFirst(Db db, string sql, long? id, out bool ok)
        {
            ok = false;
            if (!id.HasValue) return null;
            ResultSet rs = db.Query(sql, id.Value);
            if (rs == null || rs.Rows.Count == 0) return null;
            ok = true;
            return rs.Rows[0][0];
        }

        // ---------------- utf8mb4_unicode_ci equality and the subject pattern ----------------

        /// <summary>a = b under utf8mb4_unicode_ci: case- and accent-insensitive, trailing spaces ignored.</summary>
        static bool BhCiEq(string a, string b)
        {
            if (a == null || b == null) return false;
            return string.Compare(a.TrimEnd(' '), b.TrimEnd(' '), CultureInfo.InvariantCulture,
                CompareOptions.IgnoreCase | CompareOptions.IgnoreNonSpace | CompareOptions.IgnoreKanaType | CompareOptions.IgnoreWidth) == 0;
        }

        /// <summary>A lookup key with the trailing spaces a PAD SPACE collation ignored.</summary>
        static string BhPad(string s) { return s == null ? null : s.TrimEnd(' '); }

        static readonly Regex BhSubjectRx = new Regex(@"^[a-z0-9-]+([.][a-z0-9-]+)+\z", RegexOptions.CultureInvariant);

        static readonly char[] BhLineEnds = { (char)0x0A, (char)0x0D, (char)0x0B, (char)0x0C, (char)0x85, (char)0x2028, (char)0x2029 };

        /// <summary>REGEXP_LIKE(s, '^[a-z0-9-]+([.][a-z0-9-]+)+$', 'c'): ICU's $ also matches before one final line terminator.</summary>
        static bool BhSubjectOk(string s)
        {
            string t = s;
            if (t.EndsWith("\r\n", StringComparison.Ordinal)) t = t.Substring(0, t.Length - 2);
            else if (t.Length > 0 && Array.IndexOf(BhLineEnds, t[t.Length - 1]) >= 0) t = t.Substring(0, t.Length - 1);
            return BhSubjectRx.IsMatch(t);
        }

        // ---------------- arguments, typed as the MySQL parameters were (STRICT mode) ----------------

        static string BhVarchar(object[] a, int i, int max, string name)
        {
            string s = S(a, i);
            if (s != null && BhChars(s) > max) throw Fail("Data too long for column '" + name + "' at row 1");
            return s;
        }

        static string BhText(object[] a, int i, string name)
        {
            string s = S(a, i);
            if (s != null && Encoding.UTF8.GetByteCount(s) > 65535) throw Fail("Data too long for column '" + name + "' at row 1");
            return s;
        }

        static int BhChars(string s)
        {
            int n = 0;
            for (int i = 0; i < s.Length; i++) if (!char.IsLowSurrogate(s[i])) n++;
            return n;
        }

        /// <summary>An INT UNSIGNED parameter: rounded to a whole number, 0 .. 4294967295.</summary>
        static long? BhUInt(object[] a, int i, string name)
        {
            object v = a[i];
            if (v == null) return null;
            decimal d;
            if (!BhToDecimal(v, out d))
                throw Fail("Incorrect integer value: '" + Db.ToStr(v) + "' for column '" + name + "' at row 1");
            d = Math.Round(d, 0, MidpointRounding.AwayFromZero);
            if (d < 0 || d > 4294967295m) throw Fail("Out of range value for column '" + name + "' at row 1");
            return (long)d;
        }

        /// <summary>A DECIMAL(prec,scale) parameter: rounded half away from zero, range-checked.</summary>
        static decimal? BhDecArg(object[] a, int i, int prec, int scale, string name)
        {
            object v = a[i];
            if (v == null) return null;
            decimal d;
            if (!BhToDecimal(v, out d))
                throw Fail("Incorrect decimal value: '" + Db.ToStr(v) + "' for column '" + name + "' at row 1");
            d = Math.Round(d, scale, MidpointRounding.AwayFromZero);
            decimal lim = BhDecMax(prec, scale);
            if (d > lim || d < -lim) throw Fail("Out of range value for column '" + name + "' at row 1");
            return d;
        }

        /// <summary>A DATETIME parameter, as 'YYYY-MM-DD HH:MM:SS'.</summary>
        static string BhDateArg(object[] a, int i, string name)
        {
            object v = a[i];
            if (v == null) return null;
            string s = Db.ToStr(v);
            DateTime? d = Functions.ParseTime(s);
            if (!d.HasValue) throw Fail("Incorrect datetime value: '" + s + "' for column '" + name + "' at row 1");
            return d.Value.ToString(Functions.Fmt, CultureInfo.InvariantCulture);
        }

        static bool BhToDecimal(object v, out decimal d)
        {
            d = 0m;
            if (v is long) { d = (long)v; return true; }
            if (v is double)
            {
                double x = (double)v;
                if (double.IsNaN(x) || double.IsInfinity(x) || Math.Abs(x) > 1e20) { d = x < 0 ? -1e20m : 1e20m; return !double.IsNaN(x); }
                d = (decimal)x;
                return true;
            }
            string s = Db.ToStr(v);
            if (s == null) return false;
            return decimal.TryParse(s.Trim(), NumberStyles.Float, CultureInfo.InvariantCulture, out d);
        }

        static decimal BhDecMax(int prec, int scale)
        {
            decimal m = 1m;
            for (int k = 0; k < prec - scale; k++) m *= 10m;
            decimal step = 1m;
            for (int k = 0; k < scale; k++) step /= 10m;
            return m - step;
        }

        // ---------------- config: SELECT CAST(cfg_value AS ...) INTO v (missing key = default) ----------------
        // The live server runs in STRICT mode, where a cast that has to truncate or clip inside a
        // procedure is an error, not a warning: a malformed value aborts the CALL. Mirrored here
        // with MySQL's own messages; surrounding spaces are tolerated, as they were.

        static readonly Regex BhIntRx = new Regex(@"^[+-]?\d+$", RegexOptions.CultureInvariant);
        static readonly Regex BhNumPrefixRx = new Regex(@"^[+-]?(\d+\.?\d*|\.\d+)([eE][+-]?\d+)?", RegexOptions.CultureInvariant);

        /// <summary>SELECT CAST(cfg_value AS SIGNED) INTO v.</summary>
        static long BhCfgInt(Db db, string key, long fallback)
        {
            string v = Cfg(db, key);
            if (v == null) return fallback;
            string t = v.Trim(' ');
            long l;
            if (!BhIntRx.IsMatch(t) || !long.TryParse(t, NumberStyles.AllowLeadingSign, CultureInfo.InvariantCulture, out l))
                throw Fail("Truncated incorrect INTEGER value: '" + v + "'");
            return l;
        }

        /// <summary>SELECT CAST(cfg_value AS DECIMAL(3,2)) INTO v.</summary>
        static decimal BhCfgDec(Db db, string key, decimal fallback)
        {
            string v = Cfg(db, key);
            if (v == null) return fallback;
            string t = v.Trim(' ');
            Match m = BhNumPrefixRx.Match(t);
            if (!m.Success) throw Fail("Incorrect DECIMAL value: '0' for column '' at row -1");
            if (m.Length != t.Length) throw Fail("Truncated incorrect DECIMAL value: '" + v + "'");
            decimal d;
            if (!decimal.TryParse(t, NumberStyles.Float, CultureInfo.InvariantCulture, out d) ||
                Math.Abs(Math.Round(d, 2, MidpointRounding.AwayFromZero)) > 9.99m)
                throw Fail("Out of range value for column 'CAST(cfg_value AS DECIMAL(3,2))' at row 1");
            return Math.Round(d, 2, MidpointRounding.AwayFromZero);
        }

        // ---------------- values ----------------

        /// <summary>A stored REAL read back as the DECIMAL(p,scale) MySQL held.</summary>
        static decimal? BhDec(object v, int scale)
        {
            if (v == null) return null;
            decimal d;
            if (!BhToDecimal(v, out d)) return null;
            return Math.Round(d, scale, MidpointRounding.AwayFromZero);
        }

        static object BhDbl(decimal? d) { return d.HasValue ? (object)(double)d.Value : null; }

        /// <summary>A DECIMAL as CONCAT() printed it: fixed scale, e.g. 0.50.</summary>
        static string BhFmt(decimal d, int scale)
        {
            return d.ToString("F" + scale.ToString(CultureInfo.InvariantCulture), CultureInfo.InvariantCulture);
        }

        static string BhId(long? id) { return id.HasValue ? id.Value.ToString(CultureInfo.InvariantCulture) : "NULL"; }

        /// <summary>A stored timestamp as 'YYYY-MM-DD HH:MM:SS' (left as it is when it does not parse).</summary>
        static string BhTime(object v)
        {
            if (v == null) return null;
            DateTime? d = Functions.ParseTime(v);
            return d.HasValue ? d.Value.ToString(Functions.Fmt, CultureInfo.InvariantCulture) : Db.ToStr(v);
        }

        /// <summary>a &lt; b as DATETIMEs; false when either is NULL.</summary>
        static bool BhTimeLess(string a, string b)
        {
            DateTime? x = Functions.ParseTime(a), y = Functions.ParseTime(b);
            if (!x.HasValue || !y.HasValue) return false;
            return x.Value < y.Value;
        }
    }
}
