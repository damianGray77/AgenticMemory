// The consolidation procedures. Under MySQL these were stored procedures; SQLite has none, so
// they live here and memdb runs them when a script says CALL sp_name(...). Each file
// Procs.<Area>.cs registers its procedures through a partial Register<Area>() method.
//
// The design is unchanged: the consolidation skill supplies judgment, these procedures enforce
// the rails -- the `enabled` kill switch, dry_run, thresholds, per-run caps -- and record every
// action, applied or only proposed, in consolidation_log with before/after JSON.
//
// Every CALL runs inside a savepoint (see Call): a procedure that throws leaves no partial
// writes. Procedures that "log instead of raising" (MySQL EXIT HANDLERs) catch their own
// failure, roll back their own savepoint, and write the error row, so the CALL still succeeds.
using System;
using System.Collections.Generic;
using System.Globalization;
using System.Linq;

namespace MemDb
{
    public delegate List<ResultSet> ProcFn(Db db, object[] a);

    public static partial class Procs
    {
        sealed class Entry { public int Arity; public ProcFn Fn; }

        static readonly Dictionary<string, Entry> Map = new Dictionary<string, Entry>(StringComparer.OrdinalIgnoreCase);
        static bool _init;

        static partial void RegisterMechanical();
        static partial void RegisterJudgment();
        static partial void RegisterConfirm();
        static partial void RegisterBehaviours();
        static partial void RegisterDigest();

        static void Init()
        {
            if (_init) return;
            _init = true;
            RegisterMechanical();
            RegisterJudgment();
            RegisterConfirm();
            RegisterBehaviours();
            RegisterDigest();
        }

        static void Reg(string name, int arity, ProcFn fn)
        {
            Entry e = new Entry();
            e.Arity = arity;
            e.Fn = fn;
            Map[name] = e;
        }

        public static List<string> Names()
        {
            Init();
            List<string> n = new List<string>(Map.Keys);
            n.Sort(StringComparer.OrdinalIgnoreCase);
            return n;
        }

        public static List<ResultSet> Call(Db db, string name, object[] args)
        {
            Init();
            Entry e;
            if (!Map.TryGetValue(name, out e))
                throw new MemDbException("unknown procedure " + name + " (known: " + string.Join(", ", Names().ToArray()) + ")");
            if (e.Arity >= 0 && args.Length != e.Arity)
                throw new MemDbException(name + " takes " + e.Arity + " argument(s), got " + args.Length);
            string sp = db.Begin();
            try
            {
                List<ResultSet> r = e.Fn(db, args) ?? new List<ResultSet>();
                db.Commit(sp);
                return r;
            }
            catch
            {
                try { db.Rollback(sp); } catch { }
                throw;
            }
        }

        // ---------------------------------------------------------------------------------
        // Helpers shared by the procedure files.
        // ---------------------------------------------------------------------------------

        /// <summary>Argument i as a string (NULL stays null).</summary>
        internal static string S(object[] a, int i) { return Db.ToStr(a[i]); }
        internal static long? L(object[] a, int i) { return Db.ToLong(a[i]); }
        internal static double? D(object[] a, int i) { return Db.ToDouble(a[i]); }

        /// <summary>consolidation_config value, or null when the key is missing.</summary>
        internal static string Cfg(Db db, string key)
        {
            return db.ScalarString("SELECT cfg_value FROM consolidation_config WHERE cfg_key = ?", key);
        }
        internal static long CfgLong(Db db, string key, long fallback)
        {
            long? v = Db.ToLong(Cfg(db, key));
            return v.HasValue ? v.Value : fallback;
        }
        internal static double CfgDouble(Db db, string key, double fallback)
        {
            double? v = Db.ToDouble(Cfg(db, key));
            return v.HasValue ? v.Value : fallback;
        }

        /// <summary>Append one consolidation_log row; returns its id. JSON arguments are JSON text (or null).</summary>
        internal static long Log(Db db, string runId, string action, string targetTable, long? targetId,
                                 string beforeJson, string afterJson, string reason, bool dryRun)
        {
            db.Exec("INSERT INTO consolidation_log (run_id, action, target_table, target_id, before_json, after_json, reason, dry_run) " +
                    "VALUES (?, ?, ?, ?, ?, ?, ?, ?)",
                    runId, action, targetTable, targetId, beforeJson, afterJson, Clip(reason, 500), dryRun ? 1 : 0);
            return db.LastInsertId;
        }

        /// <summary>MySQL SIGNAL SQLSTATE '45000': abort the CALL (its savepoint is rolled back).</summary>
        internal static Exception Fail(string message) { return new MemDbException(message); }

        /// <summary>A one-row, one-column result, like a procedure's closing SELECT 'x' AS col.</summary>
        internal static List<ResultSet> One(string column, object value)
        {
            ResultSet rs = new ResultSet(column);
            rs.Add(value);
            List<ResultSet> l = new List<ResultSet>();
            l.Add(rs);
            return l;
        }

        internal static List<ResultSet> None() { return new List<ResultSet>(); }

        internal static string Clip(string s, int max)
        {
            if (s == null || s.Length <= max) return s;
            return s.Substring(0, max);
        }

        internal static string Inv(double d) { return d.ToString("R", CultureInfo.InvariantCulture); }

        /// <summary>JSON object from key, value, key, value ... built by SQLite's json_object (types preserved).</summary>
        internal static string Json(Db db, params object[] kv)
        {
            string marks = string.Join(", ", Enumerable.Repeat("?", kv.Length).ToArray());
            return db.ScalarString("SELECT json_object(" + marks + ")", kv);
        }

        /// <summary>MySQL CONCAT: NULL if any argument is NULL; numbers in plain form.</summary>
        internal static string MyConcat(params object[] parts)
        {
            System.Text.StringBuilder sb = new System.Text.StringBuilder();
            foreach (object p in parts)
            {
                if (p == null) return null;
                sb.Append(p is double ? Inv((double)p) : Db.ToStr(p));
            }
            return sb.ToString();
        }

        /// <summary>
        /// MySQL `UPDATE t SET ..., updated_at = updated_at` (change the row, keep its timestamp). The
        /// SQLite touch trigger cannot see an explicit self-assignment, so run the update, then put the
        /// old value back: the second update changes only updated_at, which the trigger lets through.
        /// </summary>
        internal static void KeepTimestamp(Db db, string table, string column, string keyColumn, object key, object oldValue)
        {
            db.Exec("UPDATE " + table + " SET " + column + " = ? WHERE " + keyColumn + " = ?", oldValue, key);
        }

        /// <summary>DECIMAL(p,s) parameter semantics: round half away from zero to s places.</summary>
        internal static double? Dec(double? v, int scale)
        {
            if (!v.HasValue) return null;
            return Math.Round(v.Value, scale, MidpointRounding.AwayFromZero);
        }
    }
}
