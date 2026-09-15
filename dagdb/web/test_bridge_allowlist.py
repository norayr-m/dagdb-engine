"""Gates D4 and D5 for the WebSocket bridge's client-side allowlist.

`docs/contracts/DAEMON_BOUNDS_GATES_FROZEN.md`, from audit B findings 24,
25 and 27. No daemon required — these exercise `_command_allowed` and the
frame check directly.

Run: python3 -m pytest dagdb/web/test_bridge_allowlist.py
"""

import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

import bridge  # noqa: E402


# ---------------------------------------------------------------- D5

def test_open_reader_and_close_reader_are_not_read_only():
    """Finding 24 — OPEN_READER allocates a whole snapshot engine per call
    and registers it daemon-globally; CLOSE_READER destroys a session
    another client owns. Neither is a read."""
    assert "OPEN_READER" not in bridge.READ_ONLY_VERBS
    assert "CLOSE_READER" not in bridge.READ_ONLY_VERBS
    assert not bridge._command_allowed("OPEN_READER")
    assert not bridge._command_allowed("CLOSE_READER r00000001")


def test_reader_envelope_classifies_the_inner_command():
    """Finding 25 — `cmd.split(None, 2)` made `READER <id> <anything>` pass
    on the verb READER alone, so the inner command was gated only by the
    daemon's own reader matrix."""
    assert bridge._command_allowed("READER r00000001 STATUS")
    assert bridge._command_allowed("READER r00000001 TILED BFS x00000001 7 2")
    assert not bridge._command_allowed("READER r00000001 FOLD RUN 6 3 78 78")
    assert not bridge._command_allowed("READER r00000001 SET 3 TRUTH 1")
    assert not bridge._command_allowed("READER r00000001 OPEN_READER")
    assert not bridge._command_allowed("READER r00000001 READER r2 SET 3 TRUTH 1")


def test_fold_run_is_off_the_read_only_set():
    """Finding 18 — FOLD RUN assigns daemon-global `lastFold`, which every
    other FOLD verb reads. The four look-only verbs stay on."""
    assert ("FOLD", "RUN") not in bridge.READ_ONLY_TWIN
    assert ("FOLD", "INFO") in bridge.READ_ONLY_TWIN
    assert ("FOLD", "KEPT") in bridge.READ_ONLY_TWIN
    assert not bridge._command_allowed("FOLD RUN 6 3 78 78")
    assert bridge._command_allowed("FOLD INFO")


def test_tiled_queries_stay_reader_allowed():
    """Finding 19's ruling: tile residency is a cache, not graph state."""
    for sub in ("BFS", "SELECT", "STATUS", "LIST", "GET"):
        assert ("TILED", sub) in bridge.READ_ONLY_TWIN
    assert not bridge._command_allowed("TILED OPEN /tmp/g 2")
    assert not bridge._command_allowed("TILED TICK x00000001 1")


def test_allow_write_still_opens_everything(monkeypatch):
    monkeypatch.setattr(bridge, "ALLOW_WRITE", True)
    assert bridge._command_allowed("SET 3 TRUTH 1")
    assert bridge._command_allowed("READER r1 FOLD RUN 6 3 78 78")


# ---------------------------------------------------------------- D4

def test_bridge_refuses_a_command_longer_than_the_daemon_frame():
    """Finding 27 — the client sent `cmd + '\\n'` with no length check, and
    the daemon answered OK over the truncated prefix, so no client could
    tell a complete command from a truncated one."""
    assert bridge.MAX_COMMAND_BYTES == 4095
    too_long = "RINGS WRITE n00000001 " + " ".join(["1.0"] * 1300)
    assert len(too_long.encode()) > 5000
    assert bridge.query_daemon(too_long) == "ERROR too_long: command exceeds 4095 bytes"


def test_bridge_frame_check_counts_bytes_not_characters():
    at_cap = "STATUS" + " " * (bridge.MAX_COMMAND_BYTES - len("STATUS"))
    assert len(at_cap.encode()) == bridge.MAX_COMMAND_BYTES
    # One multi-byte character past the cap is still past the cap.
    over = at_cap + "é"
    assert bridge.query_daemon(over) == "ERROR too_long: command exceeds 4095 bytes"
