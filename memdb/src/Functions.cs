// SQL functions memdb adds to every connection.
//
// Two reasons they exist:
//  1. The Windows build of SQLite is compiled with OMIT_LOCALTIME and without zlib, so local
//     time and transcript compression have to come from .NET.
//  2. A handful of MySQL functions the memory system's SQL (and Claude's habits) lean on --
//     NOW(), DATE_FORMAT, TIMESTAMPDIFF, LEFT, LOCATE, COMPRESS/UNCOMPRESS -- are provided with
//     MySQL semantics, so queries port with fewer silent behaviour changes.
//
// Every timestamp the system stores is LOCAL time as 'YYYY-MM-DD HH:MM:SS', as it was under
// MySQL's NOW(). Transcript message timestamps are the exception: they are UTC (from Claude
// Code's JSONL), and to_utc()/to_local() convert between the two with DST handled by Windows.
using System;
using System.Collections.Generic;
using System.Globalization;
using System.IO;
using System.IO.Compression;
using System.Runtime.InteropServices;
using System.Security.Cryptography;
using System.Text;
using System.Text.RegularExpressions;

namespace MemDb
{
    internal static class Functions
    {
        delegate object Fn(object[] args);

        // Delegates handed to native code must stay reachable or the GC collects them mid-call.
        static readonly List<Native.XFunc> Keep = new List<Native.XFunc>();

        static void Add(Db db, string name, int nArg, bool deterministic, Fn fn)
        {
            Native.XFunc x = delegate (IntPtr ctx, int argc, IntPtr argv)
            {
                try
                {
                    object[] a = new object[argc];
                    for (int i = 0; i < argc; i++) a[i] = Value(Marshal.ReadIntPtr(argv, i * IntPtr.Size));
                    Result(ctx, fn(a));
                }
                catch (Exception e)
                {
                    byte[] m = Encoding.UTF8.GetBytes(name + "(): " + e.Message);
                    Native.sqlite3_result_error(ctx, m, m.Length);
                }
            };
            Keep.Add(x);
            int flags = Native.SQLITE_UTF8 | (deterministic ? Native.SQLITE_DETERMINISTIC : 0);
            int rc = Native.sqlite3_create_function_v2(db.Handle, Native.Z(name), nArg, flags, IntPtr.Zero, x, IntPtr.Zero, IntPtr.Zero, IntPtr.Zero);
            if (rc != Native.SQLITE_OK) throw new MemDbException("cannot register function " + name + ": " + db.LastError);
        }

        static object Value(IntPtr v)
        {
            switch (Native.sqlite3_value_type(v))
            {
                case Native.SQLITE_INTEGER: return Native.sqlite3_value_int64(v);
                case Native.SQLITE_FLOAT: return Native.sqlite3_value_double(v);
                case Native.SQLITE_TEXT:
                    {
                        IntPtr p = Native.sqlite3_value_text(v);
                        return Encoding.UTF8.GetString(Native.Bytes(p, Native.sqlite3_value_bytes(v)));
                    }
                case Native.SQLITE_BLOB:
                    {
                        IntPtr p = Native.sqlite3_value_blob(v);
                        return Native.Bytes(p, Native.sqlite3_value_bytes(v));
                    }
                default: return null;
            }
        }

        static void Result(IntPtr ctx, object r)
        {
            if (r == null) { Native.sqlite3_result_null(ctx); return; }
            if (r is string) { byte[] b = Encoding.UTF8.GetBytes((string)r); Native.sqlite3_result_text(ctx, b, b.Length, Native.SQLITE_TRANSIENT); return; }
            if (r is byte[]) { byte[] b = (byte[])r; Native.sqlite3_result_blob(ctx, b, b.Length, Native.SQLITE_TRANSIENT); return; }
            if (r is bool) { Native.sqlite3_result_int64(ctx, (bool)r ? 1 : 0); return; }
            if (r is double) { Native.sqlite3_result_double(ctx, (double)r); return; }
            Native.sqlite3_result_int64(ctx, Convert.ToInt64(r, CultureInfo.InvariantCulture));
        }

        static byte[] AsBytes(object v)
        {
            if (v == null) return null;
            if (v is byte[]) return (byte[])v;
            return Encoding.UTF8.GetBytes(Db.ToStr(v));
        }

        // ----------------------------------------------------------------------------------
        // Time
        // ----------------------------------------------------------------------------------
        public const string Fmt = "yyyy-MM-dd HH:mm:ss";
        static readonly string[] Formats = { "yyyy-MM-dd HH:mm:ss", "yyyy-MM-dd HH:mm", "yyyy-MM-dd", "yyyy-MM-ddTHH:mm:ss", "yyyy-MM-ddTHH:mm" };

        public static DateTime? ParseTime(object v)
        {
            string s = Db.ToStr(v);
            if (string.IsNullOrWhiteSpace(s)) return null;
            s = s.Trim();
            if (s.EndsWith("Z")) s = s.Substring(0, s.Length - 1);
            int dot = s.IndexOf('.');
            if (dot > 0) s = s.Substring(0, dot);          // fractional seconds
            int plus = s.IndexOf('+', 10);
            if (plus > 0) s = s.Substring(0, plus);        // +00:00 offsets
            DateTime d;
            if (DateTime.TryParseExact(s, Formats, CultureInfo.InvariantCulture, DateTimeStyles.None, out d)) return d;
            return null;
        }

        static string Iso(DateTime d) { return d.ToString(Fmt, CultureInfo.InvariantCulture); }

        public static string Now() { return Iso(DateTime.Now); }

        static object ToUtc(DateTime local)
        {
            DateTime d = DateTime.SpecifyKind(local, DateTimeKind.Unspecified);
            TimeZoneInfo tz = TimeZoneInfo.Local;
            if (tz.IsInvalidTime(d)) d = d.AddHours(1);    // inside a spring-forward gap
            return Iso(TimeZoneInfo.ConvertTimeToUtc(d, tz));
        }

        static object ToLocal(DateTime utc)
        {
            return Iso(TimeZoneInfo.ConvertTimeFromUtc(DateTime.SpecifyKind(utc, DateTimeKind.Unspecified), TimeZoneInfo.Local));
        }

        // MySQL DATE_FORMAT specifiers the system uses (and the common rest).
        static string DateFormat(DateTime d, string f)
        {
            CultureInfo c = CultureInfo.InvariantCulture;
            StringBuilder sb = new StringBuilder();
            for (int i = 0; i < f.Length; i++)
            {
                char ch = f[i];
                if (ch != '%' || i + 1 >= f.Length) { sb.Append(ch); continue; }
                char s = f[++i];
                switch (s)
                {
                    case 'Y': sb.Append(d.ToString("yyyy", c)); break;
                    case 'y': sb.Append(d.ToString("yy", c)); break;
                    case 'm': sb.Append(d.ToString("MM", c)); break;
                    case 'c': sb.Append(d.Month); break;
                    case 'd': sb.Append(d.ToString("dd", c)); break;
                    case 'e': sb.Append(d.Day); break;
                    case 'H': sb.Append(d.ToString("HH", c)); break;
                    case 'k': sb.Append(d.Hour); break;
                    case 'h': case 'I': sb.Append(d.ToString("hh", c)); break;
                    case 'l': sb.Append(d.ToString("%h", c)); break;
                    case 'i': sb.Append(d.ToString("mm", c)); break;
                    case 's': case 'S': sb.Append(d.ToString("ss", c)); break;
                    case 'p': sb.Append(d.ToString("tt", c)); break;
                    case 'b': sb.Append(d.ToString("MMM", c)); break;
                    case 'M': sb.Append(d.ToString("MMMM", c)); break;
                    case 'a': sb.Append(d.ToString("ddd", c)); break;
                    case 'W': sb.Append(d.ToString("dddd", c)); break;
                    case 'j': sb.Append(d.DayOfYear.ToString("000", c)); break;
                    case 'T': sb.Append(d.ToString("HH:mm:ss", c)); break;
                    case 'r': sb.Append(d.ToString("hh:mm:ss tt", c)); break;
                    case 'f': sb.Append("000000"); break;
                    case '%': sb.Append('%'); break;
                    default: sb.Append(s); break;
                }
            }
            return sb.ToString();
        }

        // MySQL TIMESTAMPDIFF: whole units from a to b, truncated toward zero.
        static object TimestampDiff(string unit, DateTime a, DateTime b)
        {
            TimeSpan t = b - a;
            switch (unit.ToUpperInvariant())
            {
                case "SECOND": return (long)t.TotalSeconds;
                case "MINUTE": return (long)t.TotalMinutes;
                case "HOUR": return (long)t.TotalHours;
                case "DAY": return (long)t.TotalDays;
                case "WEEK": return (long)(t.TotalDays / 7);
                case "MONTH":
                case "YEAR":
                    {
                        int months = (b.Year - a.Year) * 12 + b.Month - a.Month;
                        if (b >= a && b.AddMonths(-months) < a) months--;
                        if (b < a && b.AddMonths(-months) > a) months++;
                        return unit.ToUpperInvariant() == "YEAR" ? (long)(months / 12) : (long)months;
                    }
                default: throw new ArgumentException("unsupported unit " + unit);
            }
        }

        // ----------------------------------------------------------------------------------
        // MySQL COMPRESS() format, so transcripts archived by MySQL copy across byte for byte:
        //   4-byte little-endian uncompressed length, then a zlib stream (0x78 0x9C header,
        //   raw deflate, Adler-32 trailer). Empty input compresses to empty output.
        // ----------------------------------------------------------------------------------
        public static byte[] Compress(byte[] data)
        {
            if (data == null) return null;
            if (data.Length == 0) return new byte[0];
            using (MemoryStream ms = new MemoryStream())
            {
                ms.Write(BitConverter.GetBytes((uint)data.Length), 0, 4);   // little-endian on Windows
                ms.WriteByte(0x78); ms.WriteByte(0x9C);
                using (DeflateStream z = new DeflateStream(ms, CompressionLevel.Optimal, true)) z.Write(data, 0, data.Length);
                uint a = Adler32(data);
                ms.WriteByte((byte)(a >> 24)); ms.WriteByte((byte)(a >> 16)); ms.WriteByte((byte)(a >> 8)); ms.WriteByte((byte)a);
                return ms.ToArray();
            }
        }

        public static byte[] Uncompress(byte[] data)
        {
            if (data == null) return null;
            if (data.Length == 0) return new byte[0];
            if (data.Length < 7) return null;
            int len = (int)(BitConverter.ToUInt32(data, 0) & 0x3FFFFFFF);
            if ((data[4] & 0x0F) != 8) return null;                       // not a deflate zlib stream
            byte[] outBuf = new byte[len];
            using (MemoryStream src = new MemoryStream(data, 6, data.Length - 6))
            using (DeflateStream z = new DeflateStream(src, CompressionMode.Decompress))
            {
                int got = 0;
                while (got < len)
                {
                    int n = z.Read(outBuf, got, len - got);
                    if (n <= 0) break;
                    got += n;
                }
                if (got != len) return null;
            }
            return outBuf;
        }

        static uint Adler32(byte[] data)
        {
            uint a = 1, b = 0;
            int i = 0;
            while (i < data.Length)
            {
                int n = Math.Min(5552, data.Length - i);
                for (int k = 0; k < n; k++) { a += data[i++]; b += a; }
                a %= 65521; b %= 65521;
            }
            return (b << 16) | a;
        }

        // ----------------------------------------------------------------------------------
        // Full-text: turn natural-language keywords into an FTS5 query that matches ANY of them,
        // like MySQL's MATCH ... AGAINST (... IN NATURAL LANGUAGE MODE). FTS5 alone ANDs terms.
        // Words under 3 characters and MySQL's default InnoDB stopwords are dropped, as MySQL did.
        // ----------------------------------------------------------------------------------
        static readonly HashSet<string> Stop = new HashSet<string>(StringComparer.OrdinalIgnoreCase)
        {
            "a", "about", "an", "are", "as", "at", "be", "by", "com", "de", "en", "for", "from", "how", "i", "in", "is", "it",
            "la", "of", "on", "or", "that", "the", "this", "to", "was", "what", "when", "where", "who", "will", "with", "und", "www"
        };
        static readonly Regex Word = new Regex(@"[\p{L}\p{N}_]+", RegexOptions.Compiled);

        public static string FtsAny(string text)
        {
            List<string> terms = new List<string>();
            HashSet<string> seen = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
            if (text != null)
                foreach (Match m in Word.Matches(text))
                {
                    string w = m.Value;
                    if (w.Length < 3 || Stop.Contains(w) || !seen.Add(w)) continue;
                    terms.Add("\"" + w + "\"");
                }
            if (terms.Count == 0) return "\"\u0001nomatch\u0001\"";
            return string.Join(" OR ", terms.ToArray());
        }

        static readonly Dictionary<string, Regex> RegexCache = new Dictionary<string, Regex>();

        // ----------------------------------------------------------------------------------
        public static void Register(Db db)
        {
            Add(db, "now", 0, false, delegate (object[] a) { return Now(); });
            Add(db, "utc_now", 0, false, delegate (object[] a) { return Iso(DateTime.UtcNow); });
            Add(db, "curdate", 0, false, delegate (object[] a) { return DateTime.Now.ToString("yyyy-MM-dd", CultureInfo.InvariantCulture); });
            Add(db, "to_utc", 1, false, delegate (object[] a) { DateTime? d = ParseTime(a[0]); return d.HasValue ? ToUtc(d.Value) : null; });
            Add(db, "to_local", 1, false, delegate (object[] a) { DateTime? d = ParseTime(a[0]); return d.HasValue ? ToLocal(d.Value) : null; });
            Add(db, "date_format", 2, true, delegate (object[] a)
            {
                DateTime? d = ParseTime(a[0]);
                return d.HasValue && a[1] != null ? DateFormat(d.Value, Db.ToStr(a[1])) : null;
            });
            Add(db, "timestampdiff", 3, true, delegate (object[] a)
            {
                DateTime? x = ParseTime(a[1]), y = ParseTime(a[2]);
                return x.HasValue && y.HasValue && a[0] != null ? TimestampDiff(Db.ToStr(a[0]), x.Value, y.Value) : null;
            });
            Add(db, "datediff", 2, true, delegate (object[] a)
            {
                DateTime? x = ParseTime(a[0]), y = ParseTime(a[1]);
                return x.HasValue && y.HasValue ? (object)(long)(x.Value.Date - y.Value.Date).TotalDays : null;
            });

            Add(db, "left", 2, true, delegate (object[] a)
            {
                string s = Db.ToStr(a[0]); long? n = Db.ToLong(a[1]);
                if (s == null || !n.HasValue) return null;
                return n.Value <= 0 ? "" : (n.Value >= s.Length ? s : s.Substring(0, (int)n.Value));
            });
            Add(db, "right", 2, true, delegate (object[] a)
            {
                string s = Db.ToStr(a[0]); long? n = Db.ToLong(a[1]);
                if (s == null || !n.HasValue) return null;
                return n.Value <= 0 ? "" : (n.Value >= s.Length ? s : s.Substring(s.Length - (int)n.Value));
            });
            Add(db, "char_length", 1, true, delegate (object[] a) { string s = Db.ToStr(a[0]); return s == null ? null : (object)(long)s.Length; });
            Add(db, "locate", -1, true, delegate (object[] a)
            {
                if (a.Length < 2 || a.Length > 3) throw new ArgumentException("locate(substr, str[, pos])");
                string sub = Db.ToStr(a[0]), s = Db.ToStr(a[1]);
                if (sub == null || s == null) return null;
                int start = a.Length == 3 ? (int)(Db.ToLong(a[2]) ?? 1) : 1;
                if (start < 1 || start > s.Length + 1) return 0L;
                return (long)(s.IndexOf(sub, start - 1, StringComparison.OrdinalIgnoreCase) + 1);
            });
            Add(db, "regexp", 2, true, delegate (object[] a)
            {
                string p = Db.ToStr(a[0]), s = Db.ToStr(a[1]);
                if (p == null || s == null) return null;
                Regex r;
                if (!RegexCache.TryGetValue(p, out r)) { r = new Regex(p, RegexOptions.IgnoreCase); RegexCache[p] = r; }
                return r.IsMatch(s) ? 1L : 0L;
            });

            Add(db, "compress", 1, true, delegate (object[] a) { return Compress(AsBytes(a[0])); });
            Add(db, "uncompress", 1, true, delegate (object[] a) { return Uncompress(AsBytes(a[0])); });
            Add(db, "uncompressed_length", 1, true, delegate (object[] a)
            {
                byte[] b = AsBytes(a[0]);
                if (b == null) return null;
                return b.Length < 4 ? 0L : (long)(BitConverter.ToUInt32(b, 0) & 0x3FFFFFFF);
            });
            Add(db, "sha256", 1, true, delegate (object[] a)
            {
                byte[] b = AsBytes(a[0]);
                if (b == null) return null;
                using (SHA256 h = SHA256.Create()) return BitConverter.ToString(h.ComputeHash(b)).Replace("-", "").ToLowerInvariant();
            });
            Add(db, "readfile", 1, false, delegate (object[] a)
            {
                string p = Db.ToStr(a[0]);
                if (p == null || !File.Exists(p)) return null;
                using (FileStream fs = new FileStream(p, FileMode.Open, FileAccess.Read, FileShare.ReadWrite))
                using (MemoryStream ms = new MemoryStream()) { fs.CopyTo(ms); return ms.ToArray(); }
            });
            Add(db, "writefile", 2, false, delegate (object[] a)
            {
                string p = Db.ToStr(a[0]); byte[] b = AsBytes(a[1]);
                if (p == null || b == null) return null;
                File.WriteAllBytes(p, b);
                return (long)b.Length;
            });
            Add(db, "fts_any", 1, true, delegate (object[] a) { return FtsAny(Db.ToStr(a[0])); });

            // Math. This SQLite build is compiled without SQLITE_ENABLE_MATH_FUNCTIONS.
            Math1(db, "exp", Math.Exp);
            Math1(db, "ln", Math.Log);
            Math1(db, "log2", delegate (double x) { return Math.Log(x, 2); });
            Math1(db, "log10", Math.Log10);
            Math1(db, "sqrt", Math.Sqrt);
            Add(db, "log", -1, true, delegate (object[] a)   // MySQL: LOG(x) = ln x; LOG(b, x) = log base b
            {
                if (a.Length == 1) { double? x = Db.ToDouble(a[0]); return x.HasValue && x.Value > 0 ? (object)Math.Log(x.Value) : null; }
                if (a.Length != 2) throw new ArgumentException("log(x) or log(b, x)");
                double? b = Db.ToDouble(a[0]), v = Db.ToDouble(a[1]);
                return b.HasValue && v.HasValue && b.Value > 0 && b.Value != 1 && v.Value > 0 ? (object)Math.Log(v.Value, b.Value) : null;
            });
            ProcPow(db, "pow"); ProcPow(db, "power");
            IntRound(db, "floor", Math.Floor); IntRound(db, "ceil", Math.Ceiling); IntRound(db, "ceiling", Math.Ceiling);
            Add(db, "mod", 2, true, delegate (object[] a)
            {
                if (a[0] == null || a[1] == null) return null;
                if (a[0] is long && a[1] is long) { long d = (long)a[1]; return d == 0 ? null : (object)((long)a[0] % d); }
                double y = Db.ToDouble(a[1]).Value;
                return y == 0 ? null : (object)(Db.ToDouble(a[0]).Value % y);
            });
            Add(db, "truncate", 2, true, delegate (object[] a)   // MySQL TRUNCATE(x, d)
            {
                double? x = Db.ToDouble(a[0]); long? d = Db.ToLong(a[1]);
                if (!x.HasValue || !d.HasValue) return null;
                double f = Math.Pow(10, d.Value);
                return Math.Truncate(x.Value * f) / f;
            });
            Add(db, "sign", 1, true, delegate (object[] a) { double? x = Db.ToDouble(a[0]); return x.HasValue ? (object)(long)Math.Sign(x.Value) : null; });
            Add(db, "pi", 0, true, delegate (object[] a) { return Math.PI; });
        }

        delegate double D1(double x);

        static void Math1(Db db, string name, D1 f)
        {
            Add(db, name, 1, true, delegate (object[] a)
            {
                double? x = Db.ToDouble(a[0]);
                if (!x.HasValue) return null;
                double r = f(x.Value);
                return double.IsNaN(r) || double.IsInfinity(r) ? null : (object)r;   // MySQL returns NULL for a domain error
            });
        }

        static void ProcPow(Db db, string name)
        {
            Add(db, name, 2, true, delegate (object[] a)
            {
                double? x = Db.ToDouble(a[0]), y = Db.ToDouble(a[1]);
                if (!x.HasValue || !y.HasValue) return null;
                double r = Math.Pow(x.Value, y.Value);
                return double.IsNaN(r) || double.IsInfinity(r) ? null : (object)r;
            });
        }

        static void IntRound(Db db, string name, D1 f)
        {
            Add(db, name, 1, true, delegate (object[] a)
            {
                if (a[0] == null) return null;
                if (a[0] is long) return a[0];
                double r = f(Db.ToDouble(a[0]).Value);
                return Math.Abs(r) < 9.2e18 ? (object)(long)r : r;
            });
        }
    }
}
