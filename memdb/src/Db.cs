// A thin, synchronous wrapper over one SQLite connection. Everything the CLI and the
// consolidation procedures do goes through these few calls.
using System;
using System.Collections.Generic;
using System.Globalization;
using System.Runtime.InteropServices;
using System.Text;

namespace MemDb
{
    public sealed class MemDbException : Exception
    {
        public MemDbException(string message) : base(message) { }
    }

    /// <summary>One result set: column names plus rows of long / double / string / byte[] / null.</summary>
    public sealed class ResultSet
    {
        public readonly List<string> Columns = new List<string>();
        public readonly List<object[]> Rows = new List<object[]>();

        public ResultSet() { }
        public ResultSet(params string[] columns) { Columns.AddRange(columns); }
        public void Add(params object[] row) { Rows.Add(row); }
    }

    public sealed class Db : IDisposable
    {
        public IntPtr Handle { get; private set; }
        public string Path { get; private set; }

        Db(IntPtr h, string path) { Handle = h; Path = path; }

        public static Db Open(string path, bool create)
        {
            if (!create && !System.IO.File.Exists(path))
                throw new MemDbException("database not found: " + path + " (run install.ps1, pass --db, or set CLAUDE_MEMORY_DB)");
            IntPtr h;
            int flags = Native.SQLITE_OPEN_READWRITE | (create ? Native.SQLITE_OPEN_CREATE : 0);
            int rc = Native.sqlite3_open_v2(Native.Z(path), out h, flags, IntPtr.Zero);
            if (rc != Native.SQLITE_OK)
            {
                string msg = h != IntPtr.Zero ? Native.Utf8(Native.sqlite3_errmsg(h)) : "rc=" + rc;
                if (h != IntPtr.Zero) Native.sqlite3_close_v2(h);
                throw new MemDbException("cannot open " + path + ": " + msg);
            }
            Native.sqlite3_busy_timeout(h, 30000);   // hooks and sessions overlap; wait rather than fail
            Db db = new Db(h, path);
            db.Exec("PRAGMA foreign_keys = ON");
            Functions.Register(db);
            return db;
        }

        public void Dispose()
        {
            if (Handle != IntPtr.Zero) { Native.sqlite3_close_v2(Handle); Handle = IntPtr.Zero; }
        }

        public string LastError { get { return Native.Utf8(Native.sqlite3_errmsg(Handle)); } }
        public int Changes { get { return Native.sqlite3_changes(Handle); } }
        public long LastInsertId { get { return Native.sqlite3_last_insert_rowid(Handle); } }
        public bool InTransaction { get { return Native.sqlite3_get_autocommit(Handle) == 0; } }

        // ------------------------------------------------------------------------------
        // Statements. Each takes ONE statement with ? placeholders bound positionally.
        // ------------------------------------------------------------------------------

        IntPtr Prepare(string sql, object[] args)
        {
            byte[] bytes = Encoding.UTF8.GetBytes(sql);
            GCHandle pin = GCHandle.Alloc(bytes, GCHandleType.Pinned);
            IntPtr stmt, tail;
            try
            {
                int rc = Native.sqlite3_prepare_v2(Handle, pin.AddrOfPinnedObject(), bytes.Length, out stmt, out tail);
                if (rc != Native.SQLITE_OK) throw new MemDbException(LastError + "\n  in: " + Clip(sql));
            }
            finally { pin.Free(); }
            if (stmt == IntPtr.Zero) return IntPtr.Zero;   // only whitespace / comments
            Bind(stmt, args);
            return stmt;
        }

        void Bind(IntPtr stmt, object[] args)
        {
            int n = Native.sqlite3_bind_parameter_count(stmt);
            int given = args == null ? 0 : args.Length;
            if (n != given)
            {
                Native.sqlite3_finalize(stmt);
                throw new MemDbException("statement has " + n + " parameter(s) but " + given + " value(s) were given");
            }
            for (int i = 0; i < given; i++) BindValue(stmt, i + 1, args[i]);
        }

        static void BindValue(IntPtr stmt, int i, object v)
        {
            if (v == null || v is DBNull) { Native.sqlite3_bind_null(stmt, i); return; }
            if (v is string) { byte[] b = Encoding.UTF8.GetBytes((string)v); Native.sqlite3_bind_text(stmt, i, b, b.Length, Native.SQLITE_TRANSIENT); return; }
            if (v is byte[]) { byte[] b = (byte[])v; Native.sqlite3_bind_blob(stmt, i, b, b.Length, Native.SQLITE_TRANSIENT); return; }
            if (v is bool) { Native.sqlite3_bind_int64(stmt, i, (bool)v ? 1 : 0); return; }
            if (v is int || v is long || v is short || v is byte || v is uint) { Native.sqlite3_bind_int64(stmt, i, Convert.ToInt64(v)); return; }
            if (v is double || v is float || v is decimal) { Native.sqlite3_bind_double(stmt, i, Convert.ToDouble(v)); return; }
            byte[] s = Encoding.UTF8.GetBytes(Convert.ToString(v, CultureInfo.InvariantCulture));
            Native.sqlite3_bind_text(stmt, i, s, s.Length, Native.SQLITE_TRANSIENT);
        }

        internal static object ColumnValue(IntPtr stmt, int i)
        {
            switch (Native.sqlite3_column_type(stmt, i))
            {
                case Native.SQLITE_INTEGER: return Native.sqlite3_column_int64(stmt, i);
                case Native.SQLITE_FLOAT: return Native.sqlite3_column_double(stmt, i);
                case Native.SQLITE_TEXT:
                    {
                        IntPtr p = Native.sqlite3_column_text(stmt, i);
                        int n = Native.sqlite3_column_bytes(stmt, i);
                        return Encoding.UTF8.GetString(Native.Bytes(p, n));
                    }
                case Native.SQLITE_BLOB:
                    {
                        IntPtr p = Native.sqlite3_column_blob(stmt, i);
                        int n = Native.sqlite3_column_bytes(stmt, i);
                        return Native.Bytes(p, n);
                    }
                default: return null;
            }
        }

        internal ResultSet Run(IntPtr stmt, string sqlForErrors)
        {
            try
            {
                int cols = Native.sqlite3_column_count(stmt);
                ResultSet rs = null;
                if (cols > 0)
                {
                    rs = new ResultSet();
                    for (int c = 0; c < cols; c++) rs.Columns.Add(Native.Utf8(Native.sqlite3_column_name(stmt, c)));
                }
                while (true)
                {
                    int rc = Native.sqlite3_step(stmt);
                    if (rc == Native.SQLITE_DONE) break;
                    if (rc != Native.SQLITE_ROW) throw new MemDbException(LastError + "\n  in: " + Clip(sqlForErrors));
                    if (rs != null)
                    {
                        object[] row = new object[cols];
                        for (int c = 0; c < cols; c++) row[c] = ColumnValue(stmt, c);
                        rs.Rows.Add(row);
                    }
                }
                return rs;
            }
            finally { Native.sqlite3_finalize(stmt); }
        }

        /// <summary>Run one statement; returns its rows (null for statements without columns).</summary>
        public ResultSet Query(string sql, params object[] args)
        {
            IntPtr stmt = Prepare(sql, args);
            if (stmt == IntPtr.Zero) return null;
            return Run(stmt, sql);
        }

        public int Exec(string sql, params object[] args)
        {
            Query(sql, args);
            return Changes;
        }

        public object Scalar(string sql, params object[] args)
        {
            ResultSet rs = Query(sql, args);
            if (rs == null || rs.Rows.Count == 0) return null;
            return rs.Rows[0][0];
        }

        public long? ScalarLong(string sql, params object[] args) { return ToLong(Scalar(sql, args)); }
        public double? ScalarDouble(string sql, params object[] args) { return ToDouble(Scalar(sql, args)); }
        public string ScalarString(string sql, params object[] args) { return ToStr(Scalar(sql, args)); }

        /// <summary>First row as name -> value, or null when there is no row.</summary>
        public Dictionary<string, object> Row(string sql, params object[] args)
        {
            ResultSet rs = Query(sql, args);
            if (rs == null || rs.Rows.Count == 0) return null;
            Dictionary<string, object> d = new Dictionary<string, object>(StringComparer.OrdinalIgnoreCase);
            for (int i = 0; i < rs.Columns.Count; i++) d[rs.Columns[i]] = rs.Rows[0][i];
            return d;
        }

        public List<Dictionary<string, object>> Rows(string sql, params object[] args)
        {
            List<Dictionary<string, object>> list = new List<Dictionary<string, object>>();
            ResultSet rs = Query(sql, args);
            if (rs == null) return list;
            foreach (object[] r in rs.Rows)
            {
                Dictionary<string, object> d = new Dictionary<string, object>(StringComparer.OrdinalIgnoreCase);
                for (int i = 0; i < rs.Columns.Count; i++) d[rs.Columns[i]] = r[i];
                list.Add(d);
            }
            return list;
        }

        // ------------------------------------------------------------------------------
        // Savepoints nest, so a procedure can run inside a caller's transaction.
        // ------------------------------------------------------------------------------
        int _sp;
        public string Begin() { string name = "sp" + (++_sp); Exec("SAVEPOINT " + name); return name; }
        public void Commit(string name) { Exec("RELEASE " + name); }
        public void Rollback(string name) { Exec("ROLLBACK TO " + name); Exec("RELEASE " + name); }

        // ------------------------------------------------------------------------------
        // Conversions that tolerate SQLite's dynamic typing.
        // ------------------------------------------------------------------------------
        public static long? ToLong(object v)
        {
            if (v == null) return null;
            if (v is long) return (long)v;
            if (v is double) return (long)(double)v;
            string s = v as string;
            if (s != null)
            {
                long l; double d;
                if (long.TryParse(s.Trim(), NumberStyles.Integer, CultureInfo.InvariantCulture, out l)) return l;
                if (double.TryParse(s.Trim(), NumberStyles.Float, CultureInfo.InvariantCulture, out d)) return (long)d;
                return null;
            }
            return Convert.ToInt64(v, CultureInfo.InvariantCulture);
        }

        public static double? ToDouble(object v)
        {
            if (v == null) return null;
            if (v is double) return (double)v;
            if (v is long) return (long)v;
            string s = v as string;
            if (s != null)
            {
                double d;
                if (double.TryParse(s.Trim(), NumberStyles.Float, CultureInfo.InvariantCulture, out d)) return d;
                return null;
            }
            return Convert.ToDouble(v, CultureInfo.InvariantCulture);
        }

        public static string ToStr(object v)
        {
            if (v == null) return null;
            if (v is string) return (string)v;
            if (v is byte[]) return Encoding.UTF8.GetString((byte[])v);
            if (v is double) return ((double)v).ToString("R", CultureInfo.InvariantCulture);
            return Convert.ToString(v, CultureInfo.InvariantCulture);
        }

        public static string Clip(string sql)
        {
            sql = sql.Trim();
            return sql.Length <= 300 ? sql : sql.Substring(0, 300) + " ...";
        }
    }
}
