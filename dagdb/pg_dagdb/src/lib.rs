/// pg_dagdb — PostgreSQL extension for DagDB graph engine.
///
/// Stateless client that connects to dagdb_daemon via Unix domain socket.
/// Reads results from shared memory (zero-copy on Apple Silicon UMA).
/// Exposes dagdb_exec(text) → SETOF record as the primary SQL interface.

use pgrx::prelude::*;
use std::io::{Read, Write, BufRead, BufReader};
use std::os::unix::net::UnixStream;

::pgrx::pg_module_magic!();

// This SQL runs before the generated CREATE
// FUNCTION statements, so the script also applies over a database that ran
// the 0.0.0 pg_dagdb. Its dagdb_exec(text) returned (node_id integer, rank
// smallint, truth smallint, node_type smallint, message text); this build's
// returns bigint node_id and rank and adds mode and trit. A
// return type cannot change in place and CREATE FUNCTION refuses a name that
// exists, so the 0.0.0 extension's three functions are dropped when they exist. CASCADE
// takes the views that read dagdb_exec (setup_views.sql's dagdb_nodes,
// dagdb_status_view, dagdb_info and dagdb_map, and any of the operator's
// own, which the changed columns would break anyway); setup_views.sql
// re-creates its own. On a fresh database each DROP is a notice.
// This covers main's functions loaded without CREATE EXTENSION. An extension
// created at 0.0.0 (main) is brought to 0.1.0 by ALTER EXTENSION pg_dagdb
// UPDATE, which runs sql/pg_dagdb--0.0.0--0.1.0.sql, not this script.
pgrx::extension_sql!(
    r#"
-- Upgrade over main's pg_dagdb (TERNARY_GATES_FROZEN.md AMENDMENT 8 item 1):
-- drop main's functions when they exist; CASCADE drops the views reading
-- dagdb_exec. Run setup_views.sql after this script to re-create them.
-- (An extension created at 0.0.0 updates with ALTER EXTENSION pg_dagdb
-- UPDATE instead: pg_dagdb--0.0.0--0.1.0.sql.)
DROP FUNCTION IF EXISTS dagdb_exec(text) CASCADE;
DROP FUNCTION IF EXISTS dagdb_status();
DROP FUNCTION IF EXISTS dagdb_tick(integer);
"#,
    name = "upgrade_over_main",
    bootstrap
);

/// Today's defaults. The paths come from the
/// environment of the Postgres backend — DAGDB_SOCK and DAGDB_SHM_FILE — the
/// same two a daemon started with --socket / --shm-file uses.
const DEFAULT_SOCKET_PATH: &str = "/tmp/dagdb.sock";
const DEFAULT_SHM_PATH: &str = "/tmp/dagdb_shm_file";

fn env_or(key: &str, default: &str) -> String {
    match std::env::var(key) {
        Ok(v) if !v.is_empty() => v,
        _ => default.to_string(),
    }
}

fn socket_path() -> String { env_or("DAGDB_SOCK", DEFAULT_SOCKET_PATH) }
fn shm_path() -> String { env_or("DAGDB_SHM_FILE", DEFAULT_SHM_PATH) }

/// Send a DSL command to the daemon and return the response line.
fn daemon_command(cmd: &str) -> Result<String, String> {
    let socket = socket_path();
    let mut stream = UnixStream::connect(&socket)
        .map_err(|e| format!("Cannot connect to dagdb_daemon at {}: {}", socket, e))?;

    stream.write_all(cmd.as_bytes())
        .map_err(|e| format!("Write failed: {}", e))?;
    stream.write_all(b"\n")
        .map_err(|e| format!("Write failed: {}", e))?;
    read_reply(stream)
}

/// Half-close, then read the reply line. The daemon stops reading at the
/// newline, answers and closes; when it has closed first, macOS reports
/// NotConnected (ENOTCONN) on this shutdown although the whole reply is
/// waiting in the socket — that is not an error.
fn read_reply(stream: UnixStream) -> Result<String, String> {
    match stream.shutdown(std::net::Shutdown::Write) {
        Ok(()) => {}
        Err(e) if e.kind() == std::io::ErrorKind::NotConnected => {}
        Err(e) => return Err(format!("Shutdown failed: {}", e)),
    }

    let mut reader = BufReader::new(stream);
    let mut response = String::new();
    reader.read_line(&mut response)
        .map_err(|e| format!("Read failed: {}", e))?;

    Ok(response.trim().to_string())
}

/// One result row as the daemon writes it (24 bytes, little-endian):
/// [8: node_id u64] [8: rank u64] [1: truth] [1: node_type] [1: mode] [5: pad].
/// An earlier parser read a 4-byte id, a 1-byte rank
/// and the bytes after it — a layout the daemon stopped writing at the u64
/// widening — so every column it returned was wrong. The ternary build put the node's
/// mode in byte 18.
pub const ROW_SIZE: usize = 24;

#[derive(Debug, Clone, Copy, PartialEq)]
pub struct Row {
    pub node_id: u64,
    pub rank: u64,
    pub truth: u8,
    pub node_type: u8,
    pub mode: u8,
}

/// Parse the result-row file's bytes. Empty on a short or inconsistent file.
pub fn parse_rows(data: &[u8]) -> Vec<Row> {
    if data.len() < 8 { return vec![]; }
    let row_count = u32::from_le_bytes([data[0], data[1], data[2], data[3]]) as usize;
    let row_size = u32::from_le_bytes([data[4], data[5], data[6], data[7]]) as usize;
    if row_size < 19 || data.len() < 8 + row_count * row_size {
        return vec![];
    }
    let mut rows = Vec::with_capacity(row_count);
    for i in 0..row_count {
        let o = 8 + i * row_size;
        let mut id = [0u8; 8];
        id.copy_from_slice(&data[o..o + 8]);
        let mut rk = [0u8; 8];
        rk.copy_from_slice(&data[o + 8..o + 16]);
        rows.push(Row {
            node_id: u64::from_le_bytes(id),
            rank: u64::from_le_bytes(rk),
            truth: data[o + 16],
            node_type: data[o + 17],
            mode: data[o + 18],
        });
    }
    rows
}

/// The trit a byte reads as: 0 → −1, 1 → +1, anything else → 0.
pub fn trit_of(b: u8) -> i16 {
    match b { 0 => -1, 1 => 1, _ => 0 }
}

fn read_shm_results() -> Vec<Row> {
    match std::fs::read(shm_path()) {
        Ok(d) => parse_rows(&d),
        Err(_) => vec![],
    }
}

// ── The result row dagdb_exec builds ──

/// The row dagdb_exec builds, column by column: what its generated SQL declares.
/// The caller's expected row
/// is checked against this before anything else happens.
const EXEC_ROW: [(&str, pg_sys::Oid); 7] = [
    ("node_id", pg_sys::INT8OID),
    ("rank", pg_sys::INT8OID),
    ("truth", pg_sys::INT2OID),
    ("node_type", pg_sys::INT2OID),
    ("mode", pg_sys::INT2OID),
    ("trit", pg_sys::INT2OID),
    ("message", pg_sys::TEXTOID),
];

fn type_name(oid: pg_sys::Oid) -> String {
    unsafe {
        let p = pg_sys::format_type_be(oid);
        let s = std::ffi::CStr::from_ptr(p).to_string_lossy().into_owned();
        pg_sys::pfree(p.cast());
        s
    }
}

fn row_text(cols: &[(String, pg_sys::Oid)]) -> String {
    cols.iter().map(|(n, t)| format!("{} {}", n, type_name(*t))).collect::<Vec<_>>().join(", ")
}

/// The extension's version was 0.0.0 before the ternary build and
/// on it, so a database that ran the 0.0.0 CREATE EXTENSION kept
/// that catalog under CREATE EXTENSION IF NOT EXISTS. Since 0.1.0 the update
/// is ALTER EXTENSION pg_dagdb UPDATE; until it runs, the 0.0.0 catalog still
/// sits over this library (CREATE EXTENSION IF NOT EXISTS does not update it):
/// dagdb_exec declared with five
/// columns (node_id integer, rank smallint, truth, node_type smallint, message
/// text) over this library, which builds seven. Postgres forms each row with
/// the caller's descriptor, so the library's mode value landed in the text
/// column and the backend died with signal 11.
///
/// Here the caller's expected row (get_call_result_type) must have exactly
/// this library's column count and, column by column, its types; otherwise
/// the call is refused with ERROR 42804 (datatype_mismatch) that names both
/// rows and the remedy — before the daemon is contacted, so a refused TICK
/// does not tick. Column names are not compared (a caller may rename them).
fn check_result_row(fcinfo: pg_sys::FunctionCallInfo) {
    let this: Vec<(String, pg_sys::Oid)> = EXEC_ROW.iter().map(|(n, t)| (n.to_string(), *t)).collect();
    let mut oid = pg_sys::Oid::INVALID;
    let mut tupdesc: pg_sys::TupleDesc = std::ptr::null_mut();
    let class = unsafe { pg_sys::get_call_result_type(fcinfo, &mut oid, &mut tupdesc) };
    let caller: Option<Vec<(String, pg_sys::Oid)>> =
        if class == pg_sys::TypeFuncClass::TYPEFUNC_COMPOSITE && !tupdesc.is_null() {
            let td = unsafe { pgrx::PgTupleDesc::from_pg_unchecked(tupdesc) };
            Some(td.iter().filter(|a| !a.is_dropped()).map(|a| (a.name().to_string(), a.atttypid)).collect())
        } else {
            None
        };
    let detail = "The function's SQL declaration does not match the pg_dagdb library it calls (an older or \
                  newer catalog over this library). Nothing was sent to the daemon. Update the extension: \
                  ALTER EXTENSION pg_dagdb UPDATE; then setup_views.sql. Or re-create it: \
                  DROP EXTENSION pg_dagdb CASCADE; CREATE EXTENSION pg_dagdb; then setup_views.sql.";
    match caller {
        Some(cols) if cols.len() == this.len() && cols.iter().zip(this.iter()).all(|(a, b)| a.1 == b.1) => {}
        Some(cols) => {
            ereport!(
                ERROR,
                PgSqlErrorCode::ERRCODE_DATATYPE_MISMATCH,
                format!(
                    "dagdb_exec: the caller expects a result row of {} column(s) ({}); this library builds {} ({})",
                    cols.len(), row_text(&cols), this.len(), row_text(&this)
                ),
                detail
            );
        }
        None => {
            ereport!(
                ERROR,
                PgSqlErrorCode::ERRCODE_DATATYPE_MISMATCH,
                format!(
                    "dagdb_exec: the caller's result type is not a plain row (get_call_result_type class {}); this library builds {} ({})",
                    class, this.len(), row_text(&this)
                ),
                detail
            );
        }
    }
}

// ── SQL Functions ──

/// Execute a DagDB DSL command and return results as rows.
///
/// Usage:
///   SELECT * FROM dagdb_exec('STATUS');
///   SELECT * FROM dagdb_exec('TICK 100');
///   SELECT * FROM dagdb_exec('NODES AT RANK 2 WHERE truth=1');
///   SELECT * FROM dagdb_exec('EVAL');
///   SELECT * FROM dagdb_exec('TRAVERSE FROM 42 DEPTH 3');
/// Columns: node_id and rank as bigint (u64 on the wire), truth (the byte),
/// node_type, mode (byte 18: kind in bits 0–1, NOSKIP bit 2), trit (the
/// truth read as −1/0/+1 — meaningful for a ternary node; a binary node's
/// byte reads the same way), message.
/// `fcinfo` is pgrx's virtual argument (not in the SQL signature): the call's
/// own FunctionCallInfo, read for the caller's expected row
/// (`check_result_row`).
#[pg_extern]
fn dagdb_exec(
    command: &str,
    fcinfo: pg_sys::FunctionCallInfo,
) -> TableIterator<'static, (
    pgrx::name!(node_id, Option<i64>),
    pgrx::name!(rank, Option<i64>),
    pgrx::name!(truth, Option<i16>),
    pgrx::name!(node_type, Option<i16>),
    pgrx::name!(mode, Option<i16>),
    pgrx::name!(trit, Option<i16>),
    pgrx::name!(message, Option<String>),
)> {
    check_result_row(fcinfo);
    let response = match daemon_command(command) {
        Ok(r) => r,
        Err(e) => {
            return TableIterator::new(vec![
                (None, None, None, None, None, None, Some(format!("ERROR: {}", e)))
            ]);
        }
    };

    // Check if this is a data-returning command
    let has_rows = response.contains("rows=");

    if has_rows {
        // Read rows from shared memory
        let rows = read_shm_results();
        if rows.is_empty() {
            return TableIterator::new(vec![
                (None, None, None, None, None, None, Some(response))
            ]);
        }
        let result: Vec<_> = rows.into_iter().map(|r| {
            (Some(r.node_id as i64), Some(r.rank as i64), Some(r.truth as i16),
             Some(r.node_type as i16), Some(r.mode as i16), Some(trit_of(r.truth)), None)
        }).collect();
        TableIterator::new(result)
    } else {
        // Status/info response — return as single message row
        TableIterator::new(vec![
            (None, None, None, None, None, None, Some(response))
        ])
    }
}

/// Quick status check — is the daemon running?
#[pg_extern]
fn dagdb_status() -> String {
    match daemon_command("STATUS") {
        Ok(r) => r,
        Err(e) => format!("OFFLINE: {}", e),
    }
}

/// Run N ticks on the GPU engine.
#[pg_extern]
fn dagdb_tick(n: default!(i32, 1)) -> String {
    match daemon_command(&format!("TICK {}", n)) {
        Ok(r) => r,
        Err(e) => format!("ERROR: {}", e),
    }
}

#[cfg(any(test, feature = "pg_test"))]
#[pg_schema]
mod tests {
    use pgrx::prelude::*;

    #[pg_test]
    fn test_dagdb_status_format() {
        // This will fail if daemon isn't running, which is expected in CI
        let result = crate::dagdb_status();
        assert!(result.starts_with("OK") || result.starts_with("OFFLINE"));
    }
}

#[cfg(test)]
mod row_tests {
    use super::*;

    /// The daemon's 24-byte row, written here byte by byte.
    #[test]
    fn parses_the_real_24_byte_row() {
        let mut d = vec![0u8; 8 + 2 * ROW_SIZE];
        d[0..4].copy_from_slice(&2u32.to_le_bytes());
        d[4..8].copy_from_slice(&24u32.to_le_bytes());
        let rows: [(u64, u64, u8, u8, u8); 2] = [(70_000_000_123, 5_000_000_000, 2, 1, 5), (7, 3, 0, 0, 0)];
        for (i, r) in rows.iter().enumerate() {
            let o = 8 + i * ROW_SIZE;
            d[o..o + 8].copy_from_slice(&r.0.to_le_bytes());
            d[o + 8..o + 16].copy_from_slice(&r.1.to_le_bytes());
            d[o + 16] = r.2; d[o + 17] = r.3; d[o + 18] = r.4;
        }
        let got = parse_rows(&d);
        assert_eq!(got, vec![
            Row { node_id: 70_000_000_123, rank: 5_000_000_000, truth: 2, node_type: 1, mode: 5 },
            Row { node_id: 7, rank: 3, truth: 0, node_type: 0, mode: 0 },
        ]);
        assert_eq!(trit_of(0), -1);
        assert_eq!(trit_of(1), 1);
        assert_eq!(trit_of(2), 0);
        assert_eq!(trit_of(200), 0);
    }
}

#[cfg(test)]
mod client_tests {
    use super::*;
    use std::os::unix::net::UnixListener;

    /// The race forced: the fake daemon answers and closes before the client
    /// half-closes. The reply must come back as the reply.
    #[test]
    fn a_reply_sent_before_the_half_close_is_kept() {
        let dir = std::env::temp_dir().join(format!("pg-race-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        std::fs::create_dir_all(&dir).unwrap();
        let path = dir.join("d.sock");
        let listener = UnixListener::bind(&path).unwrap();
        let server = std::thread::spawn(move || {
            let (c, _) = listener.accept().unwrap();
            let mut line = String::new();
            BufReader::new(c.try_clone().unwrap()).read_line(&mut line).unwrap();
            (&c).write_all(b"OK GET node=1 truth=1\n").unwrap();
            line
        });
        let mut stream = UnixStream::connect(&path).unwrap();
        stream.write_all(b"GET 1 TRUTH\n").unwrap();
        assert_eq!(server.join().unwrap(), "GET 1 TRUTH\n");   // the daemon has closed
        let got = read_reply(stream);
        std::fs::remove_dir_all(&dir).unwrap();
        assert_eq!(got, Ok("OK GET node=1 truth=1".to_string()));
    }
}

#[cfg(test)]
pub mod pg_test {
    pub fn setup(_options: Vec<&str>) {}

    #[must_use]
    pub fn postgresql_conf_options() -> Vec<&'static str> {
        vec![]
    }
}
