// P/Invoke surface for winsqlite3.dll, the SQLite build that ships inside Windows 10/11
// (System32). Using it means the memory system needs no database download or install.
//
// C# 5 only: this compiles with the csc.exe that ships with .NET Framework 4.x.
using System;
using System.Runtime.InteropServices;

namespace MemDb
{
    internal static class Native
    {
        const string Lib = "winsqlite3.dll";
        const CallingConvention CC = CallingConvention.StdCall;   // winsqlite3 exports are __stdcall on x86; x64 has one convention

        public const int SQLITE_OK = 0;
        public const int SQLITE_ROW = 100;
        public const int SQLITE_DONE = 101;

        public const int SQLITE_INTEGER = 1;
        public const int SQLITE_FLOAT = 2;
        public const int SQLITE_TEXT = 3;
        public const int SQLITE_BLOB = 4;
        public const int SQLITE_NULL = 5;

        public const int SQLITE_OPEN_READWRITE = 0x2;
        public const int SQLITE_OPEN_CREATE = 0x4;

        public const int SQLITE_UTF8 = 1;
        public const int SQLITE_DETERMINISTIC = 0x800;

        public static readonly IntPtr SQLITE_TRANSIENT = new IntPtr(-1);

        [DllImport(Lib, CallingConvention = CC)] public static extern IntPtr sqlite3_libversion();
        [DllImport(Lib, CallingConvention = CC)] public static extern int sqlite3_open_v2(byte[] filename, out IntPtr db, int flags, IntPtr vfs);
        [DllImport(Lib, CallingConvention = CC)] public static extern int sqlite3_close_v2(IntPtr db);
        [DllImport(Lib, CallingConvention = CC)] public static extern int sqlite3_busy_timeout(IntPtr db, int ms);
        [DllImport(Lib, CallingConvention = CC)] public static extern IntPtr sqlite3_errmsg(IntPtr db);
        [DllImport(Lib, CallingConvention = CC)] public static extern int sqlite3_changes(IntPtr db);
        [DllImport(Lib, CallingConvention = CC)] public static extern long sqlite3_last_insert_rowid(IntPtr db);
        [DllImport(Lib, CallingConvention = CC)] public static extern int sqlite3_get_autocommit(IntPtr db);

        [DllImport(Lib, CallingConvention = CC)] public static extern int sqlite3_prepare_v2(IntPtr db, IntPtr sql, int nByte, out IntPtr stmt, out IntPtr tail);
        [DllImport(Lib, CallingConvention = CC)] public static extern int sqlite3_step(IntPtr stmt);
        [DllImport(Lib, CallingConvention = CC)] public static extern int sqlite3_finalize(IntPtr stmt);
        [DllImport(Lib, CallingConvention = CC)] public static extern int sqlite3_column_count(IntPtr stmt);
        [DllImport(Lib, CallingConvention = CC)] public static extern IntPtr sqlite3_column_name(IntPtr stmt, int i);
        [DllImport(Lib, CallingConvention = CC)] public static extern int sqlite3_column_type(IntPtr stmt, int i);
        [DllImport(Lib, CallingConvention = CC)] public static extern long sqlite3_column_int64(IntPtr stmt, int i);
        [DllImport(Lib, CallingConvention = CC)] public static extern double sqlite3_column_double(IntPtr stmt, int i);
        [DllImport(Lib, CallingConvention = CC)] public static extern IntPtr sqlite3_column_text(IntPtr stmt, int i);
        [DllImport(Lib, CallingConvention = CC)] public static extern IntPtr sqlite3_column_blob(IntPtr stmt, int i);
        [DllImport(Lib, CallingConvention = CC)] public static extern int sqlite3_column_bytes(IntPtr stmt, int i);
        [DllImport(Lib, CallingConvention = CC)] public static extern int sqlite3_bind_parameter_count(IntPtr stmt);
        [DllImport(Lib, CallingConvention = CC)] public static extern int sqlite3_bind_int64(IntPtr stmt, int i, long v);
        [DllImport(Lib, CallingConvention = CC)] public static extern int sqlite3_bind_double(IntPtr stmt, int i, double v);
        [DllImport(Lib, CallingConvention = CC)] public static extern int sqlite3_bind_text(IntPtr stmt, int i, byte[] v, int n, IntPtr destructor);
        [DllImport(Lib, CallingConvention = CC)] public static extern int sqlite3_bind_blob(IntPtr stmt, int i, byte[] v, int n, IntPtr destructor);
        [DllImport(Lib, CallingConvention = CC)] public static extern int sqlite3_bind_null(IntPtr stmt, int i);

        [UnmanagedFunctionPointer(CC)] public delegate void XFunc(IntPtr ctx, int argc, IntPtr argv);
        [DllImport(Lib, CallingConvention = CC)]
        public static extern int sqlite3_create_function_v2(IntPtr db, byte[] name, int nArg, int eTextRep, IntPtr pApp,
            XFunc xFunc, IntPtr xStep, IntPtr xFinal, IntPtr xDestroy);
        [DllImport(Lib, CallingConvention = CC)] public static extern int sqlite3_value_type(IntPtr v);
        [DllImport(Lib, CallingConvention = CC)] public static extern long sqlite3_value_int64(IntPtr v);
        [DllImport(Lib, CallingConvention = CC)] public static extern double sqlite3_value_double(IntPtr v);
        [DllImport(Lib, CallingConvention = CC)] public static extern IntPtr sqlite3_value_text(IntPtr v);
        [DllImport(Lib, CallingConvention = CC)] public static extern IntPtr sqlite3_value_blob(IntPtr v);
        [DllImport(Lib, CallingConvention = CC)] public static extern int sqlite3_value_bytes(IntPtr v);
        [DllImport(Lib, CallingConvention = CC)] public static extern void sqlite3_result_text(IntPtr ctx, byte[] v, int n, IntPtr destructor);
        [DllImport(Lib, CallingConvention = CC)] public static extern void sqlite3_result_blob(IntPtr ctx, byte[] v, int n, IntPtr destructor);
        [DllImport(Lib, CallingConvention = CC)] public static extern void sqlite3_result_int64(IntPtr ctx, long v);
        [DllImport(Lib, CallingConvention = CC)] public static extern void sqlite3_result_double(IntPtr ctx, double v);
        [DllImport(Lib, CallingConvention = CC)] public static extern void sqlite3_result_null(IntPtr ctx);
        [DllImport(Lib, CallingConvention = CC)] public static extern void sqlite3_result_error(IntPtr ctx, byte[] msg, int n);

        public static string Utf8(IntPtr p)
        {
            if (p == IntPtr.Zero) return null;
            int len = 0;
            while (Marshal.ReadByte(p, len) != 0) len++;
            byte[] b = new byte[len];
            Marshal.Copy(p, b, 0, len);
            return System.Text.Encoding.UTF8.GetString(b);
        }

        public static byte[] Bytes(IntPtr p, int n)
        {
            byte[] b = new byte[n];
            if (n > 0 && p != IntPtr.Zero) Marshal.Copy(p, b, 0, n);
            return b;
        }

        public static byte[] Z(string s)   // NUL-terminated UTF-8
        {
            byte[] b = System.Text.Encoding.UTF8.GetBytes(s);
            byte[] z = new byte[b.Length + 1];
            Buffer.BlockCopy(b, 0, z, 0, b.Length);
            return z;
        }
    }
}
