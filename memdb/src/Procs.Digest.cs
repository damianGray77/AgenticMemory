// The recent-work digest: an OptMem-style merge tree over sessions. consolidator/digest.sql holds
// the design notes, the config rows, the views and how to revert a run; these are its procedures,
// ported statement by statement from the MySQL stored procedures of the same names.
//
//   sp_digest_put_leaf(session_id, line, run_id)               the next leaf of the session's project
//   sp_digest_skip(session_id, reason, run_id)                 mark a session read without a leaf
//   sp_digest_put_block(project_id, level, seq_lo, line, run)  a block's rolled-up line
//   sp_digest_forget(project_id, level, seq_lo, reason, run)   drop a block and every block built on it
//   sp_digest_tile(scope, t, alpha)                            one cover of a tree, into tmp_digest_cover
//   sp_digest_cover(project_id, lines)                         what session boot prints for one tree
//
// The four writers honor `enabled` (kill switch), `digest_enabled` and `dry_run`, cap real
// mutations per run at max_digest_actions_per_run, and log every action to consolidation_log.
// MySQL ran each statement of a procedure in autocommit, so a CALL that failed half-way kept its
// earlier writes; memdb runs the whole CALL in one savepoint, so a failed CALL leaves nothing.
using System;
using System.Collections.Generic;
using System.Globalization;
using System.Text;

namespace MemDb
{
    public static partial class Procs
    {
        static partial void RegisterDigest()
        {
            Reg("sp_digest_put_leaf", 3, DigestPutLeaf);
            Reg("sp_digest_skip", 3, DigestSkip);
            Reg("sp_digest_put_block", 5, DigestPutBlock);
            Reg("sp_digest_forget", 5, DigestForget);
            Reg("sp_digest_tile", 3, DigestTile);
            Reg("sp_digest_cover", 2, DigestCover);
        }

        const long DigestIntUnsigned = 4294967295L;   // INT UNSIGNED parameters
        const long DigestTinyUnsigned = 255L;         // TINYINT UNSIGNED parameters

        // Real mutations so far in this run, counted against max_digest_actions_per_run.
        const string DigestActedSql =
            "SELECT COUNT(*) FROM consolidation_log WHERE run_id = ? AND dry_run = 0 " +
            "AND action IN ('digest_leaf','digest_skip','digest_block','digest_forget')";

        // ---------------------------------------------------------------------------------
        // sp_digest_put_leaf: write one session's line as the next leaf of its project. A
        // session that was resumed after its first leaf gets a second leaf for the new work.
        // ---------------------------------------------------------------------------------
        static List<ResultSet> DigestPutLeaf(Db db, object[] a)
        {
            long? sessionId = DigestUInt(a, 0, "p_session_id", DigestIntUnsigned);
            string line = DigestVarchar(a, 1, "p_line", 255);
            string runId = DigestVarchar(a, 2, "p_run_id", 40);

            long enabled = DigestCfg(db, "enabled", 0, "v_enabled");
            long dry = DigestCfg(db, "dry_run", 1, "v_dry");
            long digest = DigestCfg(db, "digest_enabled", 0, "v_digest");
            long max = DigestCfg(db, "max_digest_actions_per_run", 40, "v_max");
            long chars = DigestCfg(db, "digest_line_chars", 200, "v_chars");

            if (DigestSwitchedOff(db, runId, enabled, digest, dry)) return None();
            if (DigestBadLine(line, chars))
            {
                DigestLog(db, runId, "error", "digest_lines", sessionId, null, null,
                    sessionId.HasValue
                        ? "bad line for session " + sessionId.Value + ": want one line of 1-" + chars +
                          " characters, got " + DigestLen(line)
                        : null,   // MySQL CONCAT with a NULL argument is NULL
                    dry);
                return None();
            }

            Dictionary<string, object> s = db.Row(
                "SELECT project_id, started_at, last_activity_at, reviewed_until FROM v_digest_sessions WHERE session_id = ?",
                sessionId);
            long? project = null;
            string started = null, until = null, reviewed = null;
            if (s != null)
            {
                project = Db.ToLong(s["project_id"]);
                started = Db.ToStr(s["started_at"]);
                until = Db.ToStr(s["last_activity_at"]);
                reviewed = Db.ToStr(s["reviewed_until"]);
            }
            if (started == null)
            {
                DigestLog(db, runId, "error", "digest_lines", sessionId, null, null, "no such session, or it has no notes", dry);
                return None();
            }
            if (reviewed != null && string.CompareOrdinal(until, reviewed) <= 0)
            {
                DigestLog(db, runId, "error", "digest_lines", sessionId, null, null, "session already covered up to " + reviewed, dry);
                return None();
            }
            string outcome = db.ScalarString("SELECT outcome FROM digest_session_reviews WHERE session_id = ?", sessionId);

            long? seq = null, id = null;
            if (dry == 0)
            {
                if (DigestCapped(db, runId, max, "digest_lines", sessionId)) return None();
                // next position; the unique key refuses a second writer that read the same MAX
                seq = db.ScalarLong("SELECT COALESCE(MAX(seq_lo) + 1, 0) FROM digest_lines WHERE scope_project_id = ? AND level = 0",
                    project.HasValue ? project.Value : 0);
                db.Exec("INSERT INTO digest_lines (project_id, level, seq_lo, session_id, first_session_id, last_session_id, " +
                        "session_count, first_at, last_at, line, run_id) VALUES (?, 0, ?, ?, ?, ?, 1, ?, ?, ?, ?)",
                        project, seq, sessionId, sessionId, sessionId, reviewed ?? started, until, line, runId);
                id = db.LastInsertId;
                db.Exec("INSERT INTO digest_session_reviews (session_id, reviewed_until, outcome, run_id) VALUES (?, ?, ?, ?) " +
                        "ON CONFLICT (session_id) DO UPDATE SET reviewed_until = excluded.reviewed_until, " +
                        "outcome = excluded.outcome, run_id = excluded.run_id",
                        sessionId, until, "leaf " + seq.Value, runId);
            }

            DigestLog(db, runId, "digest_leaf", "digest_lines", id,
                reviewed == null ? null : DigestJson(db, "session_id", sessionId, "reviewed_until", reviewed, "outcome", outcome),
                DigestJson(db, "session_id", sessionId, "project_id", project, "seq_lo", seq, "reviewed_until", until, "line", line),
                null, dry);
            return None();
        }

        // ---------------------------------------------------------------------------------
        // sp_digest_skip: mark a session read without a leaf -- nothing of lasting effect
        // happened (a probe, a test boot, a question with no outcome, a resume that changed nothing).
        // ---------------------------------------------------------------------------------
        static List<ResultSet> DigestSkip(Db db, object[] a)
        {
            long? sessionId = DigestUInt(a, 0, "p_session_id", DigestIntUnsigned);
            string reason = DigestVarchar(a, 1, "p_reason", 200);
            string runId = DigestVarchar(a, 2, "p_run_id", 40);

            long enabled = DigestCfg(db, "enabled", 0, "v_enabled");
            long dry = DigestCfg(db, "dry_run", 1, "v_dry");
            long digest = DigestCfg(db, "digest_enabled", 0, "v_digest");
            long max = DigestCfg(db, "max_digest_actions_per_run", 40, "v_max");

            if (DigestSwitchedOff(db, runId, enabled, digest, dry)) return None();

            Dictionary<string, object> s = db.Row(
                "SELECT started_at, last_activity_at, reviewed_until FROM v_digest_sessions WHERE session_id = ?", sessionId);
            string started = null, until = null, reviewed = null;
            if (s != null)
            {
                started = Db.ToStr(s["started_at"]);
                until = Db.ToStr(s["last_activity_at"]);
                reviewed = Db.ToStr(s["reviewed_until"]);
            }
            if (started == null)
            {
                DigestLog(db, runId, "error", "digest_session_reviews", sessionId, null, null, "no such session, or it has no notes", dry);
                return None();
            }
            string outcome = db.ScalarString("SELECT outcome FROM digest_session_reviews WHERE session_id = ?", sessionId);

            if (dry == 0)
            {
                if (DigestCapped(db, runId, max, "digest_session_reviews", sessionId)) return None();
                db.Exec("INSERT INTO digest_session_reviews (session_id, reviewed_until, outcome, run_id) VALUES (?, ?, ?, ?) " +
                        "ON CONFLICT (session_id) DO UPDATE SET reviewed_until = excluded.reviewed_until, " +
                        "outcome = excluded.outcome, run_id = excluded.run_id",
                        sessionId, until, "skipped: " + (reason ?? ""), runId);
            }

            DigestLog(db, runId, "digest_skip", "digest_session_reviews", sessionId,
                reviewed == null ? null : DigestJson(db, "session_id", sessionId, "reviewed_until", reviewed, "outcome", outcome),
                DigestJson(db, "session_id", sessionId, "reviewed_until", until),
                reason, dry);
            return None();
        }

        // ---------------------------------------------------------------------------------
        // sp_digest_put_block: write the rolled-up line for block (level, seq_lo) once both
        // halves exist. p_project_id NULL = the no-project stream.
        // ---------------------------------------------------------------------------------
        static List<ResultSet> DigestPutBlock(Db db, object[] a)
        {
            long? project = DigestUInt(a, 0, "p_project_id", DigestIntUnsigned);
            long? level = DigestUInt(a, 1, "p_level", DigestTinyUnsigned);
            long? seqLo = DigestUInt(a, 2, "p_seq_lo", DigestIntUnsigned);
            string line = DigestVarchar(a, 3, "p_line", 255);
            string runId = DigestVarchar(a, 4, "p_run_id", 40);

            long enabled = DigestCfg(db, "enabled", 0, "v_enabled");
            long dry = DigestCfg(db, "dry_run", 1, "v_dry");
            long digest = DigestCfg(db, "digest_enabled", 0, "v_digest");
            long max = DigestCfg(db, "max_digest_actions_per_run", 40, "v_max");
            long chars = DigestCfg(db, "digest_line_chars", 200, "v_chars");
            long scope = project.HasValue ? project.Value : 0;
            // 'block <scope>/<level>/<seq_lo>' -- NULL when either is NULL, as MySQL's CONCAT was
            string name = level.HasValue && seqLo.HasValue ? "block " + scope + "/" + level.Value + "/" + seqLo.Value : null;

            if (DigestSwitchedOff(db, runId, enabled, digest, dry)) return None();
            if (DigestBadLine(line, chars))
            {
                DigestLog(db, runId, "error", "digest_lines", null, null, null,
                    name == null ? null : "bad line for " + name + ": want one line of 1-" + chars + " characters, got " + DigestLen(line),
                    dry);
                return None();
            }
            // Evaluated in SQL for MySQL's three-valued logic: a NULL level or seq_lo is not caught here.
            if (db.ScalarLong("SELECT ?1 < 1 OR ?2 % (1 << ?1) <> 0", level, seqLo) == 1)
            {
                DigestLog(db, runId, "error", "digest_lines", null, null, null,
                    seqLo.HasValue
                        ? "not a block: level " + level.Value + " at " + seqLo.Value + " (want level >= 1, seq_lo a multiple of 2^level)"
                        : null,
                    dry);
                return None();
            }
            if (db.ScalarLong("SELECT EXISTS (SELECT 1 FROM digest_lines WHERE scope_project_id = ? AND level = ? AND seq_lo = ?)",
                              scope, level, seqLo) == 1)
            {
                DigestLog(db, runId, "error", "digest_lines", null, null, null, name + " already exists", dry);
                return None();
            }
            long halves = db.ScalarLong(
                "SELECT COUNT(*) FROM digest_lines WHERE scope_project_id = ?1 AND level = ?2 - 1 " +
                "AND seq_lo IN (?3, ?3 + (1 << (?2 - 1)))", scope, level, seqLo) ?? 0;
            if (halves < 2)
            {
                DigestLog(db, runId, "error", "digest_lines", null, null, null,
                    name == null ? null : name + " is not ready: a half is missing", dry);
                return None();
            }

            long? id = null;
            if (dry == 0)
            {
                if (DigestCapped(db, runId, max, "digest_lines", null)) return None();
                db.Exec("INSERT INTO digest_lines (project_id, level, seq_lo, session_id, first_session_id, last_session_id, " +
                        "session_count, first_at, last_at, line, run_id) " +
                        "SELECT ?1, ?2, ?3, NULL, MIN(session_id), MAX(session_id), COUNT(DISTINCT session_id), " +
                        "MIN(first_at), MAX(last_at), ?4, ?5 FROM digest_lines " +
                        "WHERE scope_project_id = ?6 AND level = 0 AND seq_lo BETWEEN ?3 AND ?3 + (1 << ?2) - 1",
                        project, level, seqLo, line, runId, scope);
                id = db.LastInsertId;
            }

            DigestLog(db, runId, "digest_block", "digest_lines", id, null,
                DigestJson(db, "project_id", project, "level", level, "seq_lo", seqLo, "line", line),
                null, dry);
            return None();
        }

        // ---------------------------------------------------------------------------------
        // sp_digest_forget: drop a bad block and every block built on it; the next pass
        // rebuilds them. Leaves are the record and are never dropped.
        // ---------------------------------------------------------------------------------
        static List<ResultSet> DigestForget(Db db, object[] a)
        {
            long? project = DigestUInt(a, 0, "p_project_id", DigestIntUnsigned);
            long? level = DigestUInt(a, 1, "p_level", DigestTinyUnsigned);
            long? seqLo = DigestUInt(a, 2, "p_seq_lo", DigestIntUnsigned);
            string reason = DigestVarchar(a, 3, "p_reason", 500);
            string runId = DigestVarchar(a, 4, "p_run_id", 40);

            long enabled = DigestCfg(db, "enabled", 0, "v_enabled");
            long dry = DigestCfg(db, "dry_run", 1, "v_dry");
            long digest = DigestCfg(db, "digest_enabled", 0, "v_digest");
            long max = DigestCfg(db, "max_digest_actions_per_run", 40, "v_max");
            long scope = project.HasValue ? project.Value : 0;

            if (DigestSwitchedOff(db, runId, enabled, digest, dry)) return None();
            if (db.ScalarLong("SELECT ?2 < 1 OR NOT EXISTS (SELECT 1 FROM digest_lines " +
                              "WHERE scope_project_id = ?1 AND level = ?2 AND seq_lo = ?3)", scope, level, seqLo) == 1)
            {
                DigestLog(db, runId, "error", "digest_lines", null, null, null,
                    level.HasValue && seqLo.HasValue
                        ? "no block " + scope + "/" + level.Value + "/" + seqLo.Value + " (leaves cannot be forgotten)"
                        : null,
                    dry);
                return None();
            }

            if (dry == 0 && DigestCapped(db, runId, max, "digest_lines", null)) return None();

            // the block, and each block above it: the one at every higher level that contains p_seq_lo
            const string Above = "scope_project_id = ?4 AND level >= ?5 AND seq_lo = ?6 - (?6 % (1 << level))";
            db.Exec("INSERT INTO consolidation_log (run_id, action, target_table, target_id, before_json, reason, dry_run) " +
                    "SELECT ?1, 'digest_forget', 'digest_lines', id, " +
                    "json_object('project_id', project_id, 'level', level, 'seq_lo', seq_lo, 'line', line), ?2, ?3 " +
                    "FROM digest_lines WHERE " + Above + " ORDER BY level, seq_lo",
                    runId, reason, dry, scope, level, seqLo);
            if (dry == 0)
                db.Exec("DELETE FROM digest_lines WHERE " + Above.Replace("?4", "?1").Replace("?5", "?2").Replace("?6", "?3"),
                        scope, level, seqLo);
            return None();
        }

        // ---------------------------------------------------------------------------------
        // sp_digest_tile: tile leaves [0, p_t) of one tree into temp table tmp_digest_cover,
        // oldest first. As in MySQL, the caller must have created tmp_digest_cover
        // (seq_lo, level); sp_digest_cover does its tiling in memory with the same rule.
        // ---------------------------------------------------------------------------------
        static List<ResultSet> DigestTile(Db db, object[] a)
        {
            long? scope = DigestUInt(a, 0, "p_scope", DigestIntUnsigned);
            long? t = DigestUInt(a, 1, "p_t", DigestIntUnsigned);
            double? alpha = DigestDouble(a, 2, "p_alpha");

            db.Exec("DELETE FROM tmp_digest_cover");
            Dictionary<long, string> built = scope.HasValue ? DigestLines(db, scope.Value) : new Dictionary<long, string>();
            foreach (long[] c in DigestTileCore(built, t, alpha))
                db.Exec("INSERT INTO tmp_digest_cover (seq_lo, level) VALUES (?, ?)", c[0], c[1]);
            return None();
        }

        // At each position, the largest aligned block that is built, ends inside the tree, and is
        // at most alpha times its age (in leaves); a leaf when nothing larger fits. This is
        // OptMem's cover rule, walked left to right instead of top down. Returns (seq_lo, level)
        // pairs in position order. A NULL t tiles nothing; a NULL alpha behaves as MySQL's
        // three-valued NOT(... AND NULL AND ...) did: a built block that fits is kept.
        static List<long[]> DigestTileCore(Dictionary<long, string> built, long? t, double? alpha)
        {
            List<long[]> cover = new List<long[]>();
            if (!t.HasValue) return cover;
            long total = t.Value;
            int root = 0;
            while ((1L << root) < total) root++;
            long pos = 0;
            while (pos < total)
            {
                // the largest alignment pos allows
                int level = 0;
                if (pos == 0) level = root;
                else while (pos % (1L << (level + 1)) == 0) level++;
                while (level > 0)
                {
                    bool fits = pos + (1L << level) <= total;
                    bool exists = built.ContainsKey(DigestKey(level, pos));
                    bool young = !alpha.HasValue || (double)(1L << level) <= alpha.Value * (double)(total - pos);
                    if (fits && young && exists) break;   // keep this block
                    level--;
                }
                cover.Add(new long[] { pos, level });
                pos += 1L << level;
            }
            return cover;
        }

        // ---------------------------------------------------------------------------------
        // sp_digest_cover: what session boot prints for one tree (p_project_id NULL = the
        // no-project stream), newest first, in at most p_lines lines: sessions not digested yet
        // (up to half the budget, as raw note titles), then the cover of the tree.
        // ---------------------------------------------------------------------------------
        static List<ResultSet> DigestCover(Db db, object[] a)
        {
            long? project = DigestUInt(a, 0, "p_project_id", DigestIntUnsigned);
            long? lines = DigestUInt(a, 1, "p_lines", DigestIntUnsigned);
            long scope = project.HasValue ? project.Value : 0;

            // MySQL built the result in temporary tables tmp_digest_cover and tmp_digest_out and
            // dropped them on the way in and out; memdb works in memory but drops them the same way.
            db.Exec("DROP TABLE IF EXISTS temp.tmp_digest_cover");
            db.Exec("DROP TABLE IF EXISTS temp.tmp_digest_out");

            ResultSet output = new ResultSet("display");

            // Sessions not digested yet, newest first (their sort key in MySQL was
            // UNIX_TIMESTAMP(last_activity_at), the same order).
            List<object[]> waitingRows = db.Query(
                "SELECT 'S' || w.session_id || ' ' || " + DigestDay("w.started_at") +
                " || '  (not digested yet) ' || substr(w.note_titles, 1, 200) AS display " +
                "FROM v_digest_session_worklist w WHERE w.scope_project_id = ? ORDER BY w.last_activity_at DESC",
                scope).Rows;
            long waiting = waitingRows.Count;
            long? shown = lines.HasValue ? Math.Min(waiting, lines.Value / 2) : (long?)null;
            // LIMIT v_shown: MySQL treats a NULL limit variable as no rows
            long take = shown.HasValue ? shown.Value : 0;
            for (int i = 0; i < take; i++) output.Add(DigestNotNull(waitingRows[i][0]));
            if (shown.HasValue && waiting > shown.Value)
            {
                output.Add("... and " + (waiting - shown.Value) + " older sessions not digested yet");
                shown = shown.Value + 1;
            }

            long? budget = lines.HasValue && shown.HasValue ? lines.Value - shown.Value : (long?)null;
            Dictionary<long, string> built = DigestLines(db, scope);
            long t = 0;
            foreach (long key in built.Keys) if (key < DigestKey(1, 0)) t++;   // level-0 keys are the leaf positions

            if (t > 0 && budget.HasValue && budget.Value > 0)
            {
                List<long[]> cover;
                if (t <= budget.Value)
                {
                    cover = DigestTileCore(built, t, 0);
                }
                else
                {
                    // the smallest alpha whose cover fits the budget
                    double lo = 0, hi = 1, mid;
                    for (int i = 0; i < 24; i++)
                    {
                        mid = (lo + hi) / 2;
                        if (DigestTileCore(built, t, mid).Count > budget.Value) lo = mid; else hi = mid;
                    }
                    cover = DigestTileCore(built, t, hi);
                    // block sizes jump in powers of two, so spend what is left on the newest
                    // blocks; their halves are always built, since a block is built from them.
                    SortedDictionary<long, long> map = new SortedDictionary<long, long>();
                    foreach (long[] c in cover) map[c[0]] = c[1];
                    while (map.Count < budget.Value)
                    {
                        long split = -1;
                        foreach (KeyValuePair<long, long> kv in map) if (kv.Value > 0) split = kv.Key;   // ascending: last wins
                        if (split < 0) break;
                        long lvl = map[split] - 1;
                        map[split] = lvl;
                        map[split + (1L << (int)lvl)] = lvl;
                    }
                    cover = new List<long[]>();
                    foreach (KeyValuePair<long, long> kv in map) cover.Add(new long[] { kv.Key, kv.Value });
                }

                // newest first; a cover entry with no line (an inner join in MySQL) is left out
                for (int i = cover.Count - 1; i >= 0; i--)
                {
                    string display;
                    if (built.TryGetValue(DigestKey(cover[i][1], cover[i][0]), out display))
                        output.Add(DigestNotNull(display));
                }
            }

            List<ResultSet> result = new List<ResultSet>();
            result.Add(output);
            return result;
        }

        // Every line of one tree, keyed by (level, seq_lo), with the text boot prints for it.
        static Dictionary<long, string> DigestLines(Db db, long scope)
        {
            Dictionary<long, string> d = new Dictionary<long, string>();
            ResultSet rs = db.Query(
                "SELECT level, seq_lo, CASE WHEN level = 0 " +
                "THEN 'S' || session_id || ' ' || " + DigestDay("first_at") + " || '  ' || line " +
                "ELSE '[' || seq_lo || '-' || (seq_lo + (1 << level) - 1) || '] S' || first_session_id || '-S' || last_session_id || ' ' || " +
                DigestDay("first_at") + " || ' to ' || " + DigestDay("last_at") +
                " || ' (' || session_count || ' sessions)  ' || line END " +
                "FROM digest_lines WHERE scope_project_id = ?", scope);
            foreach (object[] r in rs.Rows)
                d[DigestKey(Db.ToLong(r[0]).Value, Db.ToLong(r[1]).Value)] = Db.ToStr(r[2]);
            return d;
        }

        // 'Nov 3' this year, 'Nov 3 2025' before it (MySQL: IF(YEAR(x) = YEAR(CURDATE()), ...)).
        static string DigestDay(string col)
        {
            return "iif(strftime('%Y', " + col + ") = strftime('%Y', curdate()), date_format(" + col + ", '%b %e'), date_format(" + col + ", '%b %e %Y'))";
        }

        static long DigestKey(long level, long seqLo) { return level * 8589934592L + seqLo; }   // seq_lo < 2^33

        // tmp_digest_out.display was NOT NULL: a NULL line (CONCAT with a NULL part) failed the CALL.
        static string DigestNotNull(object v)
        {
            string s = Db.ToStr(v);
            if (s == null) throw Fail("Column 'display' cannot be null");
            return s;
        }

        // ---------------------------------------------------------------------------------
        // Rails shared by the writers
        // ---------------------------------------------------------------------------------
        static bool DigestSwitchedOff(Db db, string runId, long enabled, long digest, long dry)
        {
            if (enabled == 0)
            {
                DigestLog(db, runId, "skipped", null, null, null, null, "enabled=0 (kill switch)", dry);
                return true;
            }
            if (digest == 0)
            {
                DigestLog(db, runId, "skipped", null, null, null, null, "digest_enabled=0", dry);
                return true;
            }
            return false;
        }

        static bool DigestCapped(Db db, string runId, long max, string table, long? targetId)
        {
            long acted = db.ScalarLong(DigestActedSql, runId) ?? 0;
            if (acted < max) return false;
            DigestLog(db, runId, "capped", table, targetId, null, null, "max_digest_actions_per_run=" + max + " reached", 0);
            return true;
        }

        // p_line IS NULL OR TRIM(p_line) = '' OR p_line REGEXP '[\r\n]' OR CHAR_LENGTH(p_line) > v_chars
        static bool DigestBadLine(string line, long chars)
        {
            return line == null || DigestBlank(line) || line.IndexOf('\r') >= 0 || line.IndexOf('\n') >= 0
                || DigestLen(line) > chars;
        }

        // TRIM(x) = '' under utf8mb4_unicode_ci: TRIM drops spaces, and the PAD SPACE collation then
        // ignores characters without a collation weight (controls, format characters, combining
        // marks) and space-like ones (no-break and other Unicode spaces). Tab, LF, VT, FF, CR, NEL
        // and the soft hyphen have weight. Approximates UCA 4.0.0 by Unicode category; the two
        // disagree only on rare marks of non-Latin scripts.
        static bool DigestBlank(string s)
        {
            foreach (char c in s)
            {
                if (c == ' ') continue;
                if ((c >= '\t' && c <= '\r') || c == (char)0x85 || c == (char)0xAD) return false;
                UnicodeCategory k = char.GetUnicodeCategory(c);
                if (k == UnicodeCategory.Control || k == UnicodeCategory.Format || k == UnicodeCategory.NonSpacingMark
                    || k == UnicodeCategory.EnclosingMark || k == UnicodeCategory.SpaceSeparator) continue;
                return false;
            }
            return true;
        }

        // CHAR_LENGTH: code points, as MySQL (utf8mb4) and SQLite's length() count them.
        static int DigestLen(string s)
        {
            if (s == null) return 0;
            int n = 0;
            for (int i = 0; i < s.Length; i++)
            {
                if (char.IsHighSurrogate(s[i]) && i + 1 < s.Length && char.IsLowSurrogate(s[i + 1])) i++;
                n++;
            }
            return n;
        }

        static void DigestLog(Db db, string runId, string action, string table, long? targetId,
                              string beforeJson, string afterJson, string reason, long dry)
        {
            // dry_run takes v_dry as it is, as MySQL's INSERT did
            db.Exec("INSERT INTO consolidation_log (run_id, action, target_table, target_id, before_json, after_json, reason, dry_run) " +
                    "VALUES (?, ?, ?, ?, ?, ?, ?, ?)",
                    runId, action, table, targetId, beforeJson, afterJson, reason, dry);
        }

        // JSON_OBJECT(k, v, ...) built by SQLite, so strings are escaped and NULL stays null.
        static string DigestJson(Db db, params object[] keysAndValues)
        {
            StringBuilder sql = new StringBuilder("SELECT json_object(");
            for (int i = 0; i < keysAndValues.Length; i++) sql.Append(i == 0 ? "?" : ", ?");
            sql.Append(')');
            return db.ScalarString(sql.ToString(), keysAndValues);
        }

        // SELECT CAST(cfg_value AS SIGNED) INTO v_x ... (v_x INT): a missing row leaves the DECLARE
        // default. Inside a procedure on the STRICT server the CAST's truncation warning was an
        // error, so only an optionally signed whole number, with surrounding whitespace, was
        // accepted ('2.7', '1e3', '' and 'abc' failed the CALL), and it had to fit in INT.
        static long DigestCfg(Db db, string key, long fallback, string variable)
        {
            ResultSet rs = db.Query("SELECT cfg_value FROM consolidation_config WHERE cfg_key = ?", key);
            if (rs == null || rs.Rows.Count == 0) return fallback;
            string s = Db.ToStr(rs.Rows[0][0]) ?? "";
            const string Space = " \t\n\v\f\r";
            int i = 0, n = s.Length;
            while (i < n && Space.IndexOf(s[i]) >= 0) i++;
            bool neg = false;
            if (i < n && (s[i] == '+' || s[i] == '-')) { neg = s[i] == '-'; i++; }
            int digits = 0;
            decimal v = 0;
            for (; i < n && s[i] >= '0' && s[i] <= '9'; i++, digits++)
                if (v < 1e20m) v = v * 10 + (s[i] - '0');
            while (i < n && Space.IndexOf(s[i]) >= 0) i++;
            if (digits == 0 || i < n) throw Fail("Truncated incorrect INTEGER value: '" + s + "'");
            if (neg) v = -v;
            if (v < int.MinValue || v > int.MaxValue) throw Fail("Out of range value for column '" + variable + "' at row 1");
            return (long)v;
        }

        // ---------------------------------------------------------------------------------
        // CALL arguments -> typed parameters. The live MySQL server runs in STRICT mode, so a
        // value that did not fit its parameter failed the CALL before anything ran: an integer
        // out of range, text that is not a number, a VARCHAR over its length. Numbers round
        // half away from zero (2.5 -> 3); excess trailing whitespace is dropped with only a note.
        // ---------------------------------------------------------------------------------
        static long? DigestUInt(object[] a, int i, string name, long max)
        {
            object v = a[i];
            if (v == null) return null;
            decimal d;
            if (v is long) d = (long)v;
            else if (v is double)
            {
                double x = (double)v;
                if (double.IsNaN(x) || x < -1e15 || x > 1e15) throw Fail("Out of range value for column '" + name + "' at row 1");
                d = (decimal)x;
            }
            else
            {
                string s = Db.ToStr(v);
                if (!decimal.TryParse(s.Trim(), NumberStyles.Float, CultureInfo.InvariantCulture, out d))
                    throw Fail("Incorrect integer value: '" + s + "' for column '" + name + "' at row 1");
            }
            d = Math.Round(d, 0, MidpointRounding.AwayFromZero);
            if (d < 0 || d > max) throw Fail("Out of range value for column '" + name + "' at row 1");
            return (long)d;
        }

        static double? DigestDouble(object[] a, int i, string name)
        {
            object v = a[i];
            if (v == null) return null;
            double? d = v is byte[] ? Db.ToDouble(Db.ToStr(v)) : Db.ToDouble(v);
            if (!d.HasValue) throw Fail("Incorrect DOUBLE value: '" + Db.ToStr(v) + "' for column '" + name + "' at row 1");
            return d;
        }

        static string DigestVarchar(object[] a, int i, string name, int max)
        {
            string s = Db.ToStr(a[i]);
            if (s == null) return null;
            int n = 0, cut = -1;
            for (int k = 0; k < s.Length; k++)
            {
                if (n == max) { cut = k; break; }
                if (char.IsHighSurrogate(s[k]) && k + 1 < s.Length && char.IsLowSurrogate(s[k + 1])) k++;
                n++;
            }
            if (cut < 0) return s;
            for (int k = cut; k < s.Length; k++)
                if (" \t\n\v\f\r".IndexOf(s[k]) < 0) throw Fail("Data too long for column '" + name + "' at row 1");
            return s.Substring(0, cut);
        }
    }
}
