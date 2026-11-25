import Foundation

#if DEBUG || DAGDB_FAULT_INJECTION
/// The fault seams through which the paths that only an allocation or I/O
/// fault can reach are reproduced. Compiled only into DEBUG builds (the test
/// suites) and into a release build made with `-Xswiftc -DDAGDB_FAULT_INJECTION`
/// (for daemons run under test); a plain release build has none of this code,
/// and none of the variable names below appear in its binary.
///
/// Each seam reads one environment variable, `DAGDB_FI_<NAME>`, at the moment
/// the fault would happen (getenv, no cache), so a test can set and clear it
/// in process and a test daemon takes it from its launch environment.
///   TABLE_ALLOC=1          the table library's growth (`ensureTableCapacity`)
///                          finds no buffer.
///   WAL_FAIL_OPCODE=<hex>  the WAL's next record with that opcode fails to
///                          write, as a full disk would; `4c` = IMPORT_MORTON.
///   WRITE_FAIL=<name>      a multi-file writer's file whose last path component
///                          is <name> fails to write (SAVE CSV, EXPORT MORTON,
///                          SAVE TILED: the staging is what keeps the target whole).
///   SHM_CAP=<bytes>        the handler's result file is that many bytes.
///   TILED_TICK_ERROR=<k>   TILED TICK's k-th tile flush of the call (1-based)
///                          throws a router error that is neither a write step
///                          nor a GPU failure.
///   SKIP_HOOK_SWEEP=1      the sweep after recovery is not run, so a test can
///                          read the state exactly as replay left it.
///   IMPORT_CHUNK_BYTES=<n> an import record carries at most n
///                          file bytes (2 GiB otherwise), so a test daemon splits
///                          a small import into IMPORT_PART records.
public enum DagDBFaultInjection {
    public static func value(_ name: String) -> String? {
        guard let p = getenv("DAGDB_FI_" + name) else { return nil }
        let s = String(cString: p)
        return s.isEmpty ? nil : s
    }

    public static func fires(_ name: String) -> Bool { value(name) != nil }

    /// WRITE_FAIL: true when `path`'s last component is the named file.
    public static func writeFails(_ path: String) -> Bool {
        guard let n = value("WRITE_FAIL") else { return false }
        return (path as NSString).lastPathComponent == n
    }

    public struct InjectedFault: Error, CustomStringConvertible {
        public let what: String
        public var description: String { "injected fault (DAGDB_FI_\(what))" }
    }
}
#endif
