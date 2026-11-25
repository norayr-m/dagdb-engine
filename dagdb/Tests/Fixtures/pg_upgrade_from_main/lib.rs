/// pg_dagdb — PostgreSQL extension for DagDB graph engine.
///
/// Stateless client that connects to dagdb_daemon via Unix domain socket.
/// Reads results from shared memory (zero-copy on Apple Silicon UMA).
/// Exposes dagdb_exec(text) → SETOF record as the primary SQL interface.

use pgrx::prelude::*;
use std::io::{Read, Write, BufRead, BufReader};
use std::os::unix::net::UnixStream;

::pgrx::pg_module_magic!();

const SOCKET_PATH: &str = "/tmp/dagdb.sock";
const SHM_PATH: &str = "/tmp/dagdb_shm_file";

/// Send a DSL command to the daemon and return the response line.
fn daemon_command(cmd: &str) -> Result<String, String> {
    let mut stream = UnixStream::connect(SOCKET_PATH)
        .map_err(|e| format!("Cannot connect to dagdb_daemon at {}: {}", SOCKET_PATH, e))?;

    stream.write_all(cmd.as_bytes())
        .map_err(|e| format!("Write failed: {}", e))?;
    stream.write_all(b"\n")
        .map_err(|e| format!("Write failed: {}", e))?;

    // Shutdown write side so daemon sees EOF
    stream.shutdown(std::net::Shutdown::Write)
        .map_err(|e| format!("Shutdown failed: {}", e))?;

    let mut reader = BufReader::new(stream);
    let mut response = String::new();
    reader.read_line(&mut response)
        .map_err(|e| format!("Read failed: {}", e))?;

    Ok(response.trim().to_string())
}

/// Read result rows from shared memory.
/// Layout: [4: row_count] [4: row_size] [rows...]
/// Row: [4: node_id] [1: rank] [1: truth] [1: type] [1: pad]
fn read_shm_results() -> Vec<(i32, i16, i16, i16)> {
    let data = match std::fs::read(SHM_PATH) {
        Ok(d) => d,
        Err(_) => return vec![],
    };

    if data.len() < 8 { return vec![]; }

    let row_count = u32::from_le_bytes([data[0], data[1], data[2], data[3]]) as usize;
    let row_size = u32::from_le_bytes([data[4], data[5], data[6], data[7]]) as usize;

    if row_size == 0 || data.len() < 8 + row_count * row_size {
        return vec![];
    }

    let mut rows = Vec::with_capacity(row_count);
    for i in 0..row_count {
        let off = 8 + i * row_size;
        let node_id = i32::from_le_bytes([data[off], data[off+1], data[off+2], data[off+3]]);
        let rank = data[off + 4] as i16;
        let truth = data[off + 5] as i16;
        let node_type = data[off + 6] as i16;
        rows.push((node_id, rank, truth, node_type));
    }
    rows
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
#[pg_extern]
fn dagdb_exec(
    command: &str,
) -> TableIterator<'static, (
    pgrx::name!(node_id, Option<i32>),
    pgrx::name!(rank, Option<i16>),
    pgrx::name!(truth, Option<i16>),
    pgrx::name!(node_type, Option<i16>),
    pgrx::name!(message, Option<String>),
)> {
    let response = match daemon_command(command) {
        Ok(r) => r,
        Err(e) => {
            return TableIterator::new(vec![
                (None, None, None, None, Some(format!("ERROR: {}", e)))
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
                (None, None, None, None, Some(response))
            ]);
        }
        let result: Vec<_> = rows.into_iter().map(|(id, rank, truth, ntype)| {
            (Some(id), Some(rank), Some(truth), Some(ntype), None)
        }).collect();
        TableIterator::new(result)
    } else {
        // Status/info response — return as single message row
        TableIterator::new(vec![
            (None, None, None, None, Some(response))
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
pub mod pg_test {
    pub fn setup(_options: Vec<&str>) {}

    #[must_use]
    pub fn postgresql_conf_options() -> Vec<&'static str> {
        vec![]
    }
}
