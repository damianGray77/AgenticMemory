// memdb: the command-line client for the memory database. It stands in for mysql.exe:
//
//   memdb -e "SELECT ..."          run statements given on the command line
//   memdb -f script.sql            run a file
//   memdb < script.sql             run stdin
//
// Output is tab-separated with a header row, like `mysql -B`. Flags:
//   -N  no header     -r  raw (do not escape \t \n \\ in values)     -E  vertical, one field per line
//   --db PATH         database file (default: $CLAUDE_MEMORY_DB, else memdb.dbpath, else ..\claude_memory.db)
//   --create          allow creating the database file (the installer uses this; nothing else should)
//   --force           keep going after an error (the exit code is still 1)
//
// Two statements are handled by memdb rather than SQLite:
//   CALL sp_name(arg, ...);   runs a consolidation procedure (see Procs*.cs) in one transaction.
//                             Arguments are any SQLite expressions, evaluated with SELECT.
//   USE anything;             ignored, so MySQL-era habits ("USE claude_memory; SELECT ...") still work.
using System;
using System.Collections.Generic;
using System.Globalization;
using System.IO;
using System.Runtime.InteropServices;
using System.Text;

namespace MemDb
{
    public sealed class Printer
    {
        readonly Stream _out;
        public bool Header = true, Raw, Vertical;
        static readonly byte[] Tab = { 9 }, Nl = { 10 };

        public Printer(Stream s) { _out = s; }

        void W(byte[] b) { _out.Write(b, 0, b.Length); }
        void W(string s) { W(Encoding.UTF8.GetBytes(s)); }

        static byte[] Bytes(object v)
        {
            if (v == null) return Encoding.ASCII.GetBytes("NULL");
            if (v is byte[]) return (byte[])v;
            if (v is double) return Encoding.ASCII.GetBytes(((double)v).ToString("G15", CultureInfo.InvariantCulture));
            return Encoding.UTF8.GetBytes(Db.ToStr(v));
        }

        void Value(object v, bool escape)
        {
            byte[] b = Bytes(v);
            if (!escape || v == null) { W(b); return; }
            List<byte> e = null;
            for (int i = 0; i < b.Length; i++)
            {
                byte c = b[i];
                byte esc = c == 9 ? (byte)'t' : c == 10 ? (byte)'n' : c == 92 ? (byte)'\\' : c == 0 ? (byte)'0' : (byte)0;
                if (esc == 0) { if (e != null) e.Add(c); continue; }
                if (e == null) { e = new List<byte>(b.Length + 16); for (int k = 0; k < i; k++) e.Add(b[k]); }
                e.Add(92); e.Add(esc);
            }
            W(e == null ? b : e.ToArray());
        }

        public void Print(ResultSet rs)
        {
            if (rs == null) return;
            if (Vertical)
            {
                int width = 0;
                foreach (string c in rs.Columns) width = Math.Max(width, c.Length);
                for (int r = 0; r < rs.Rows.Count; r++)
                {
                    W("*************************** " + (r + 1) + ". row ***************************\n");
                    for (int c = 0; c < rs.Columns.Count; c++)
                    {
                        W(rs.Columns[c].PadLeft(width) + ": ");
                        Value(rs.Rows[r][c], false);
                        W(Nl);
                    }
                }
                _out.Flush();
                return;
            }
            if (Header && rs.Columns.Count > 0)
            {
                W(string.Join("\t", rs.Columns.ToArray()));
                W(Nl);
            }
            foreach (object[] row in rs.Rows)
            {
                for (int c = 0; c < row.Length; c++)
                {
                    if (c > 0) W(Tab);
                    Value(row[c], !Raw);
                }
                W(Nl);
            }
            _out.Flush();
        }
    }

    public static class Cli
    {
        const string Usage =
            "usage: memdb [--db PATH] [--create] [-N] [-r] [-E] [--force] (-e SQL | -f FILE | < FILE)\n" +
            "       memdb --version | --path | --procs";

        public static int Main(string[] argv)
        {
            string dbPath = null, sql = null, file = null;
            bool create = false, force = false, showPath = false;
            Stream stdout = Console.OpenStandardOutput();
            Printer pr = new Printer(new BufferedStream(stdout, 1 << 16));

            for (int i = 0; i < argv.Length; i++)
            {
                string a = argv[i];
                switch (a)
                {
                    case "--db": dbPath = Next(argv, ref i, a); break;
                    case "-e": case "--execute": sql = Next(argv, ref i, a); break;
                    case "-f": case "--file": file = Next(argv, ref i, a); break;
                    case "-N": case "--skip-column-names": pr.Header = false; break;
                    case "-r": case "--raw": pr.Raw = true; break;
                    case "-E": case "--vertical": pr.Vertical = true; break;
                    case "-B": case "--batch": break;
                    case "--create": create = true; break;
                    case "--force": force = true; break;
                    case "--path": showPath = true; break;
                    case "--procs":
                        foreach (string p in Procs.Names()) Console.WriteLine(p);
                        return 0;
                    case "--version":
                        Console.WriteLine("memdb 1.0 on SQLite " + Native.Utf8(Native.sqlite3_libversion()));
                        return 0;
                    case "-h": case "--help": case "/?":
                        Console.WriteLine(Usage);
                        return 0;
                    default:
                        if (a.Length > 2 && a[0] == '-' && a[1] != '-' && a.Substring(1).Trim("NrEB".ToCharArray()).Length == 0)
                        {
                            // bundled short flags such as -Nr
                            foreach (char ch in a.Substring(1))
                            {
                                if (ch == 'N') pr.Header = false;
                                else if (ch == 'r') pr.Raw = true;
                                else if (ch == 'E') pr.Vertical = true;
                            }
                            break;
                        }
                        Console.Error.WriteLine("memdb: unknown argument " + a + "\n" + Usage);
                        return 2;
                }
            }

            // Database location: --db, else $CLAUDE_MEMORY_DB, else the path in memdb.dbpath next to
            // the exe (written by install.ps1 -DbPath), else ..\claude_memory.db relative to the exe.
            if (dbPath == null) dbPath = Environment.GetEnvironmentVariable("CLAUDE_MEMORY_DB");
            string exeDir = Path.GetDirectoryName(System.Reflection.Assembly.GetExecutingAssembly().Location);
            if (string.IsNullOrEmpty(dbPath))
            {
                string cfg = Path.Combine(exeDir, "memdb.dbpath");
                if (File.Exists(cfg))
                    foreach (string line in File.ReadAllLines(cfg))
                        if (line.Trim().Length > 0 && !line.TrimStart().StartsWith("#")) { dbPath = Environment.ExpandEnvironmentVariables(line.Trim()); break; }
            }
            if (string.IsNullOrEmpty(dbPath)) dbPath = Path.GetFullPath(Path.Combine(exeDir, "..", "claude_memory.db"));
            if (showPath) { Console.WriteLine(dbPath); return 0; }

            byte[] script;
            try
            {
                if (sql != null) script = Encoding.UTF8.GetBytes(sql);
                else if (file != null) script = File.ReadAllBytes(file);
                else if (Console.IsInputRedirected)
                {
                    using (MemoryStream ms = new MemoryStream()) { Console.OpenStandardInput().CopyTo(ms); script = ms.ToArray(); }
                }
                else { Console.Error.WriteLine(Usage); return 2; }
            }
            catch (Exception e) { Console.Error.WriteLine("memdb: " + e.Message); return 2; }

            try
            {
                // SQLite creates the file but not its folder.
                if (create)
                {
                    string dir = Path.GetDirectoryName(Path.GetFullPath(dbPath));
                    if (!string.IsNullOrEmpty(dir)) Directory.CreateDirectory(dir);
                }
                using (Db db = Db.Open(dbPath, create))
                    return RunScript(db, script, pr, force);
            }
            catch (MemDbException e) { Console.Error.WriteLine("ERROR: " + e.Message); return 1; }
            finally { try { stdout.Flush(); } catch { } }
        }

        static string Next(string[] argv, ref int i, string flag)
        {
            if (i + 1 >= argv.Length) throw new ArgumentException(flag + " needs a value");
            return argv[++i];
        }

        // ------------------------------------------------------------------------------------
        // Statement loop. The script stays one pinned UTF-8 buffer and is consumed with
        // sqlite3_prepare_v2's tail pointer, so a 50 MB ingest script is never re-encoded.
        // All SQL syntax characters are ASCII and never occur inside a UTF-8 multi-byte
        // sequence, so scanning for CALL / quotes / parentheses byte-wise is safe.
        // ------------------------------------------------------------------------------------
        public static int RunScript(Db db, byte[] sql, Printer pr, bool force)
        {
            int n = sql.Length, off = 0, no = 0, failed = 0;
            if (n >= 3 && sql[0] == 0xEF && sql[1] == 0xBB && sql[2] == 0xBF) off = 3;
            GCHandle pin = GCHandle.Alloc(sql, GCHandleType.Pinned);
            try
            {
                IntPtr basePtr = pin.AddrOfPinnedObject();
                while (true)
                {
                    off = SkipSpace(sql, off);
                    if (off >= n) break;
                    no++;
                    int start = off;
                    try
                    {
                        if (IsWord(sql, off, "CALL")) { off = RunCall(db, sql, off, pr); continue; }
                        if (IsWord(sql, off, "USE")) { off = SkipStatement(sql, off); continue; }

                        IntPtr stmt, tail;
                        IntPtr p = IntPtr.Add(basePtr, off);
                        int rc = Native.sqlite3_prepare_v2(db.Handle, p, n - off, out stmt, out tail);
                        if (rc != Native.SQLITE_OK)
                        {
                            off = SkipStatement(sql, start);
                            throw new MemDbException(db.LastError + "\n  in: " + Snippet(sql, start));
                        }
                        off += (int)(tail.ToInt64() - p.ToInt64());
                        if (stmt == IntPtr.Zero) continue;
                        pr.Print(db.Run(stmt, Snippet(sql, start)));
                    }
                    catch (MemDbException e)
                    {
                        failed++;
                        Console.Error.WriteLine("ERROR (statement " + no + "): " + e.Message);
                        if (!force) return 1;
                        if (off <= start) off = SkipStatement(sql, start);
                    }
                }
            }
            finally { pin.Free(); }
            return failed > 0 ? 1 : 0;
        }

        static bool IsIdent(byte c) { return (c >= 'A' && c <= 'Z') || (c >= 'a' && c <= 'z') || (c >= '0' && c <= '9') || c == '_' || c >= 0x80; }

        static bool IsWord(byte[] s, int off, string word)
        {
            if (off + word.Length > s.Length) return false;
            for (int i = 0; i < word.Length; i++)
                if (char.ToUpperInvariant((char)s[off + i]) != word[i]) return false;
            return off + word.Length == s.Length || !IsIdent(s[off + word.Length]);
        }

        static int SkipSpace(byte[] s, int off)
        {
            int n = s.Length;
            while (off < n)
            {
                byte c = s[off];
                if (c == ' ' || c == '\t' || c == '\r' || c == '\n' || c == '\f' || c == '\v' || c == ';') { off++; continue; }
                if (c == '-' && off + 1 < n && s[off + 1] == '-') { while (off < n && s[off] != '\n') off++; continue; }
                if (c == '#') { while (off < n && s[off] != '\n') off++; continue; }
                if (c == '/' && off + 1 < n && s[off + 1] == '*')
                {
                    off += 2;
                    while (off + 1 < n && !(s[off] == '*' && s[off + 1] == '/')) off++;
                    off = Math.Min(n, off + 2);
                    continue;
                }
                break;
            }
            return off;
        }

        // Past the next ';' that is outside quotes and comments (used for USE and error recovery).
        static int SkipStatement(byte[] s, int off)
        {
            int n = s.Length;
            while (off < n)
            {
                byte c = s[off];
                if (c == '\'' || c == '"' || c == '`') { off = SkipQuoted(s, off); continue; }
                if (c == '-' && off + 1 < n && s[off + 1] == '-') { while (off < n && s[off] != '\n') off++; continue; }
                if (c == ';') return off + 1;
                off++;
            }
            return n;
        }

        static int SkipQuoted(byte[] s, int off)
        {
            byte q = s[off++];
            while (off < s.Length)
            {
                if (s[off] == q)
                {
                    if (off + 1 < s.Length && s[off + 1] == q) { off += 2; continue; }   // doubled quote
                    return off + 1;
                }
                off++;
            }
            return off;
        }

        static string Snippet(byte[] s, int off)
        {
            int len = Math.Min(240, s.Length - off);
            string t = Encoding.UTF8.GetString(s, off, len).Trim();
            int semi = t.IndexOf(";\n", StringComparison.Ordinal);
            if (semi > 0) t = t.Substring(0, semi + 1);
            return t.Replace("\r", "").Replace("\n", " ") + (len == 240 ? " ..." : "");
        }

        // CALL name(arg, ...)  ->  evaluate the args with SELECT, run the procedure in a savepoint.
        static int RunCall(Db db, byte[] s, int off, Printer pr)
        {
            int n = s.Length, start = off;
            off = SkipSpace(s, off + 4);
            int nameStart = off;
            while (off < n && IsIdent(s[off])) off++;
            string name = Encoding.UTF8.GetString(s, nameStart, off - nameStart);
            if (name.Length == 0) throw new MemDbException("CALL without a procedure name");
            off = SkipSpace(s, off);

            string inner = "";
            if (off < n && s[off] == '(')
            {
                int depth = 0, argStart = off + 1;
                while (off < n)
                {
                    byte c = s[off];
                    if (c == '\'' || c == '"' || c == '`') { off = SkipQuoted(s, off); continue; }
                    if (c == '(') depth++;
                    else if (c == ')') { depth--; if (depth == 0) break; }
                    off++;
                }
                if (off >= n) throw new MemDbException("CALL " + name + ": unbalanced parentheses");
                inner = Encoding.UTF8.GetString(s, argStart, off - argStart);
                off++;   // past ')'
            }
            // Whatever follows up to ';' must be nothing.
            int after = off;
            while (after < n && (s[after] == ' ' || s[after] == '\t' || s[after] == '\r' || s[after] == '\n')) after++;
            if (after < n && s[after] != ';') throw new MemDbException("CALL " + name + ": unexpected text after the argument list: " + Snippet(s, after));
            off = after < n ? after + 1 : after;

            object[] args = new object[0];
            if (inner.Trim().Length > 0)
            {
                ResultSet rs = db.Query("SELECT " + inner);
                args = rs.Rows[0];
            }
            foreach (ResultSet r in Procs.Call(db, name, args)) pr.Print(r);
            return off;
        }
    }
}
