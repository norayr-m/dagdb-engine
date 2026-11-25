# DSL reference

Every verb the daemon's DSL parser recognizes. Source of truth:
[`dagdb/Sources/DagDBDaemon/DSLParser.swift`](../../dagdb/Sources/DagDBDaemon/DSLParser.swift).

Commands are newline-delimited text on `/tmp/dagdb.sock`. Every
response is either `OK …` or `ERROR <category>: <detail>` (see
[`invariants.md`](invariants.md) for categories).

**The frame.** A command is at most **4,095 bytes** followed by a
newline. The daemon reads until that newline, completing a short read
by reading again — AF_UNIX may split a write even well under the cap.
A line that reaches 4,095 bytes without a newline is answered

```
ERROR too_long: command exceeds 4095 bytes
```

and is **not parsed**. This matters for the verbs whose argument list
has no length of its own: `RINGS WRITE <id> <f> <f> …` takes an
arbitrary float list and `SAVE <path>` an arbitrary path. Earlier
builds did one 4,095-byte read, trimmed, and executed the PREFIX — so
a long `RINGS WRITE` was answered `OK` over a truncated value list and
no client could tell a complete command from a truncated one. Both
Python clients (`mcp_server.py`, `web/bridge.py`) now refuse an
over-long line themselves, with the same wording, instead of sending
it.

**Bounds.** Every wire integer is checked on BOTH sides before any
pointer is touched. A node id, a depth or an offset outside its range
is refused as

```
ERROR out_of_range: <name> <value> not in 0..<<extent>
```

— the refusal names the offending value AND the true extent. Counts
that drive loops carry a stated cap in `TILED TICK`'s closed-range
vocabulary, `ERROR out_of_range: <name> <value> not in <lo>...<hi>`:
`TICK`, `TICK_SYNC` and `CLOCK ADVANCE` at 10,000 per command,
`BANK NOISE`'s seed at 1,000,000, `SIMILAR_DECISIONS`'s candidate pool
at 4,096. A cap is a refusal, never a silent clip.

`tickCount` is a 32-bit field in the snapshot header, so a tick that
would carry it past `4294967295` is refused rather than wrapped:

```
ERROR out_of_range: tick total <t>+<n> not in 0...4294967295 — tickCount is a 32-bit field in the snapshot header; SAVE and restart to reset it
```

**Shared memory.** Every writer checks capacity before writing a byte,
as the readers always did. A result that does not fit is refused as

```
ERROR out_of_range: result needs <bytes> bytes, shm holds <capacity>
```

and the previous result in shm is left intact. `STREAM NEXT`'s `n` and
`RECORD SLICE`'s `count` are bounded by that capacity, not by a
hardcoded restatement of it.

**Pipelining.** A connection carries ONE command,
answered and closed — unless its first line is `PIPELINE`:

```
PIPELINE
  → OK PIPELINE
<command>
  → <its reply>
<command>
  → <its reply>
…   (until the client half-closes or closes)
```

After the acknowledgement every line is a command, answered in order on
the same connection, each reply byte-identical to the one the command
gets on a connection of its own (gate: a 1,000-command mixed script).
Commands still run one at a time on the single-threaded loop; an empty
line is no command and gets no reply, as on its own connection. An
over-long line is refused with the `too_long` line above and the
connection closes (the frame cannot be resynchronised without reading
the tail, which the daemon never drains). A client should read replies
while it writes (or write in windows): a client that writes everything
before reading anything can fill both socket buffers and stall, as on
any pipelined protocol. Without `PIPELINE` nothing changed: a client
that never half-closes (`echo X | nc -U`) still gets its EOF after its
one reply; an older daemon answers `PIPELINE` with
`ERROR unknown_command: PIPELINE` and closes, so a client can tell.

**A pipeline holds the loop until it ends.** The daemon
serves one connection at a time on its single-threaded loop, and a
pipelined connection is one connection: while it lasts, every other
client waits in the listen queue — for as long as the pipeline's
commands take (measured: 400 × `TICK 200` on a 256-node graph held the
loop for 12–15 s (release daemon, two runs); a concurrent `STATUS`
with a 1 s timeout gave up).
This is documented, not redesigned. Long work belongs in the bulk verbs
(one command, one WAL record) or in short pipelines, not in one
connection that never lets go. A client that gives up and closes while
it waits is dropped when the loop reaches it — logged
`connection dropped: …`, never answered, never fatal (the daemon
ignores SIGPIPE, and a socket whose peer is already gone, where
`SO_NOSIGPIPE` cannot be set, is dropped before anything is read or
run). The command such a client sent is not run.

**Result-style input.** `CONNECT_BACK_BULK` and
`SET_TRUTH_BULK` read their entries from the result file as a client
frame (below): u32 row count at offset 0, u32 `0x314D4808`
(`CONNECT_BACK_BULK`) or `0x314D4809` (`SET_TRUTH_BULK`) at offset 4,
the 8-byte rows from offset 8 (little-endian). The mark is checked
first, then the rows against the mapping's capacity, before an entry
is read. (Before client_protocol 2, word 1 was the row size 8.)

**Input frames (client_protocol 2).** Every verb that
reads its input from the result file reads only a frame its client
wrote for it: `[u32 count][u32 0x314D4800 | v]` at bytes 0..7,
little-endian, `v` the verb's code below, then the payload at offset 8
as each verb describes it. `count` is the number of elements the verb
reads, in its unit. STATUS ends with ` client_protocol=2` on a daemon
that requires this; a daemon whose STATUS has no such token reads the
payload at 8 and ignores bytes 0..7 (except the row count and row size
8 of the two framed verbs).

**What the mark certifies.** The mark is the client's statement that it
wrote this frame's payload for this verb; the daemon cannot check the
payload's authorship. A client that rewrites only the header over a
daemon result gets that result installed as input. So write the
payload first and the header last, and write the whole payload the
count covers.

| code | verb | word 1 | count |
|---|---|---|---|
| 1 | `SET_RANKS_BULK` | `0x314D4801` | nodeCount (u64 each) |
| 2 | `SET_LUTS_BULK` | `0x314D4802` | nodeCount (u64 each) |
| 3 | `SET_NEIGHBORS_BULK` | `0x314D4803` | nodeCount (nodes, 6 × i32 each) |
| 4 | `SET_MODES_BULK` | `0x314D4804` | nodeCount (u8) |
| 5 | `SET_TTABLE_IDS_BULK` | `0x314D4805` | nodeCount (u16) |
| 6 | `SET_THRESH_BULK` | `0x314D4806` | nodeCount (f32 lo, hi pairs) |
| 7 | `TTABLE_BULK <first> <c>` | `0x314D4807` | c (729-byte tables) |
| 8 | `CONNECT_BACK_BULK` | `0x314D4808` | the rows (8 bytes each) |
| 9 | `SET_TRUTH_BULK` | `0x314D4809` | the rows (8 bytes each) |
| 10 | `XCONV CHECK <nA> <nB> <kA> <kB> <w>` | `0x314D480A` | nA + nB + kA + kB (f32) |
| 11 | `XCONV SEALED <id> <n> [<w>]` | `0x314D480B` | 2n (f64: a, then b) |
| 12 | `BUDGET OPEN <p> <t> <c>` | `0x314D480C` | p·t + c (f64 costs, then u32 minTiers) |
| 13 | `BANK GENERATE <id> <M>` | `0x314D480D` | K·M (f32) |
| 14 | `BANK FIT <id>` | `0x314D480E` | T (f32) |

No daemon write can produce a mark: every result header the daemon
writes has a word 1 below 256, and daemon start leaves (0, 0). So a
result left in place, a never-written file, or a frame another verb
has read is refused by name, nothing written and no WAL record:

```
→ ERROR stale_frame: <VERB> reads a client frame; the shm header is (<w0>, <w1>),
    not (<count>, 0x314D48<VV>): write [u32 count][u32 0x314D48<VV>] at bytes
    0..7, then the payload at 8; nothing written
→ ERROR stale_frame: <VERB> reads a client frame, and this one is marked for
    <OTHER>; write [u32 count][u32 0x314D48<VV>] at bytes 0..7, then the
    payload at 8; nothing written
→ ERROR bad_value: <VERB> frame count <w0>, the verb reads <count>; nothing written
→ ERROR out_of_range: <VERB> frame count <a>*<b>[+<c>] overflows Int; nothing written
```

`<VV>` is the verb's code in two uppercase hex digits. The check runs
immediately before the verb's read, after every check that runs before
it (arguments, the reader-session gate, overflow, capacity), so those
refusals answer as before; for `CONNECT_BACK_BULK` and
`SET_TRUTH_BULK`, whose count is word 0 itself, the mark is checked
first. The mark survives commands that write no shm, so a client may
resend a frame it edited in place to the same verb (rewrite word 0 if
the count changes); any command that writes the result file clears it,
`BANK GENERATE` and `BANK FIT` included (their output overwrites the
header).

---

## Lifecycle

```
STATUS
  → OK STATUS nodes=<N> ticks=<k> gpu=<model> grid=<W>x<H> maxRank=<M>
    ranks=<levels> rank_max=<highest rank present> twin_open=<n> tiled_open=<n>
    tiled_refused=<n> client_protocol=2
  # client_protocol = the input-frame protocol (Input frames,
  #            above); READER <id> STATUS ends with it too. Absent on a
  #            daemon before it.
  # tiled_refused = the TILED OPENs the router refused since
  #            the daemon started; a refused open leaves no router whose
  #            TILED STATUS could count it.
  # maxRank  = the CONFIGURED bound the daemon was started with.
  # ranks    = the rank levels the rank-mode tick actually dispatches,
  #            max(maxRank, rank_max + 1).
  # rank_max = the highest rank actually present in the graph.
  # ranks > maxRank means the running bound is smaller than the graph —
  # a health check compares rank_max against maxRank directly, without
  # having to tick. VALIDATE names the nodes involved.

TICK <n>
  → OK TICK <n> elapsed=<ms>ms total=<tickCount> nodes_computed=<k>
    [ranks=<levels> bound=<maxRank>]
  → ERROR invalid_graph: rank-mode TICK refused, validation: <violation>
    (VALIDATE names it; TICK_SYNC is defined on this graph)
  # Rank mode orders evaluation by rank, so a graph
  # with a self-loop or an edge whose source is not strictly above its
  # destination in rank (a cyclic lattice) is refused by name, nothing
  # computed, tick count unchanged — it used to run silently. <violation>
  # is VALIDATE's sentence for the edge (`node <d> slot <k>: self-loop`,
  # `node <d> slot <k>: src rank <a> must be > dst rank <b>`). A source
  # index out of range or a duplicate source (S1) is left to the kernel (it
  # bounds-checks every slot and evaluates a duplicate input twice).
  # TICK_SYNC is unaffected. The verdict is cached until a command that can
  # move a rank or an edge, so a run of TICKs scans the graph once; every
  # loader drops it (the loaders install S2/S3 under the slot
  # model, so a cached "valid" never survives a load).
  # <n> is an integer or absent (`TICK` = `TICK 1`).
  # Anything else (`TICK foo`, `TICK 1.5`, `TICK UNTIL`) is
  # `ERROR unknown_command: <line>` and ticks nothing; older builds ran
  # one tick.
  # Having found no such edge, TICK (and TICK UNTIL_STABLE)
  # dispatches each rank once, from a per-rank contiguous list (every node
  # of the rank, ascending id; 4 bytes per node, allocated at the first
  # such TICK), instead of once per (rank, colour) segment. On a graph that
  # passes the check no node reads its own rank, so the bytes are the
  # colour path's exactly; the dispatch count falls (up to 7 per rank → 1;
  # a 128³ voxel layout has 12 ranks) and the threads walk each rank in id
  # order. EVAL asks the same check (below) and, on a graph
  # that passes it, keeps the colour path.
  # The lists hold node ids by rank only, so they are rebuilt
  # (one O(N) pass) after a write that moves a rank (SET RANK,
  # SET_RANKS_BULK, LOAD, IMPORT, LOAD JSON/CSV, BACKUP RESTORE, WAL
  # replay) — not after a truth write (SET TRUTH, SET_TRUTH_BULK), which
  # used to force that rebuild before every TICK that followed it.
  → ERROR resource: rank-mode TICK refused: rank lists: buffer allocation
    failed (<bytes> bytes for <n> nodes); nothing ticked
  # If the lists' first allocation fails, TICK (and TICK
  # UNTIL_STABLE) is refused by name, tick count unchanged — it used to
  # stop the daemon (fatalError). TICK_SYNC and EVAL do not use the lists.
  # On a graph with >= 65,536 back edges the latch runs on the
  # GPU, in the tick's own command buffer after the rank dispatches, instead
  # of two CPU loops over the back-edge list. Same bytes as the CPU latch:
  # each register is written once, from its LAST back edge in
  # list order (the CPU latch's last write wins), and when a source is also a
  # register every source is read before any write (two phases, as before).
  # The plan behind it (8 bytes per register, plus 1 in the two-phase case)
  # is built the first time a GPU latch needs it after the back-edge list
  # changed (CONNECT BACK, CONNECT_BACK_BULK, CLEAR … BACK_EDGES, LOAD,
  # IMPORT, restores) and kept until the list changes again. Smaller graphs,
  # TICK_SYNC and EVAL keep the CPU latch.
  # The first TICK after such a change takes the CPU latch (the
  # same bytes, at the CPU latch's cost) and builds nothing; the plan is built at the
  # second consecutive TICK with no back-edge change between, so a client
  # that alternates an edit with a TICK never pays for a plan it would use
  # once. Other writes (truth, LUTs, modes, SAVE) and other tick verbs (EVAL,
  # TICK_SYNC) between the two TICKs do not count as a change. A daemon's
  # first TICK builds at once (there is no TICK before it to have been
  # edited after), and TICK UNTIL_STABLE builds on entry. The build is one
  # pass over the back-edge list (about 3 ms at 2,000,000 random back
  # edges on 1,048,576 nodes; an earlier three-pass build took about 8.5).
  → ERROR gpu: TICK: command buffer status <status> (<error | no error
    object>) at tick <i> of <n>; nothing claimed, the truth bytes may hold
    part of that command buffer's writes; total=<tickCount>
  # A tick whose command buffer ended with any
  # status but completed stops the verb; nothing of it is latched or
  # counted, and the tick total counts the ticks before it. EVAL replies
  # `ERROR gpu: EVAL: …` the same way, with no rows written.

TICK UNTIL_STABLE [MAX <k>]
  → OK TICK UNTIL_STABLE stable ticks=<c> run=<r> changed=<x> latched=<y>
      elapsed=<ms>ms total=<tickCount> nodes_computed=<n> [ranks=<l> bound=<M>]
  → OK TICK UNTIL_STABLE not stable after MAX <k> ticks=<c> run=<r>
      changed=<x> latched=<y> elapsed=<ms>ms total=<tickCount> nodes_computed=<n>
  → ERROR out_of_range: MAX <k> not in 1...10000
  → ERROR invalid_graph: … (as TICK)
  # Rank-mode ticks, one at a time, until a tick
  # changes no truth byte and no register latch — at most <k> ticks
  # (default and ceiling: TICK's cap, 10,000). Equal to TICK 1 repeated
  # until a tick changes nothing (gate: a converging flood, an
  # oscillator, a graph already stable).
  #   ticks=   the ticks that changed something — 0 on a graph already
  #            stable;
  #   run=     the ticks run, the last included (the one that found the
  #            fixed point, or the MAX-th); the tick total moves by run;
  #   changed= the truth bytes the LAST tick run changed, registers
  #            included (0 when stable);
  #   latched= the registers the last tick's latch changed, counted by
  #            the latch from its own writes (each register once), not
  #            by a rescan.
  # A fixed point does not depend on the colour order the tick number
  # picks: a tick that changes no node read only unchanged inputs.
  # The headroom check is taken against <k>, as for TICK <k>.
  # The counts come from the tick itself, with no copy or scan
  # of the truth buffer: the rank kernels' counting twins (run only here)
  # count the nodes whose new byte differs from their old one, and the
  # latch counts its own writes; a back-edge destination the kernel also
  # evaluates (register flag cleared) is corrected from its bytes before
  # the tick and before the latch. The numbers equal a byte compare's, as
  # tests and a differential fuzz against the earlier byte-compare daemon showed. Per tick it now
  # costs about what TICK 1 costs (a voxel cavity flood at 128³: 3.7–3.9×
  # before, ~1.1× after).
  # Inside this verb the latch always runs on the GPU (any number
  # of back edges); latched= is its own count, one atomic add per SIMD group,
  # each register once — equal to the earlier counting latch on every tick.
  # A plan with kernel-evaluated destinations (register flag cleared
  # under a back edge) latches in a second command buffer, after their bytes
  # before the latch are read.
  # A tick that runs nothing (the GPU gives no command buffer)
  # counts changed=0 latched=0, so the verb stops "stable" there, as a byte
  # compare would (an earlier build reported the previous tick's count).
  → ERROR resource: TICK UNTIL_STABLE refused: change counter: buffer
    allocation failed (4 bytes); nothing ticked
  → ERROR resource: TICK UNTIL_STABLE refused: change marks: buffer
    allocation failed (<nodes> bytes); nothing ticked
  # The session's marks (one byte per node, held only while
  # the verb runs) are allocated so that a failure is this refusal, tick
  # count unchanged — earlier builds stopped the daemon (a trap).
  # The library session under this verb (`DagDBEngine.countingLatchChanges`)
  # takes its plan of the back-edge layout once, when it opens. Its
  # precondition is enforced, by name (`CountingSessionRefusal`): the body
  # may tick, and must not add, clear or move back edges or write register
  # flags; sessions do not nest.
  #   - a nested session: refused before it runs ("counting session
  #     refused: a counting session is already open (sessions do not
  #     nest); nothing ran"); the open session carries on;
  #   - an edit of the back-edge lists: each tick checks, in O(1), that the
  #     list is the one the plan holds (an edit through the engine copies
  #     it); a new list is compared by count and a checksum of every
  #     destination and its register flag, and adopted if equal. A change
  #     refuses that tick and every later one, nothing ticked, and the
  #     session throws when it closes;
  #   - a raw write to the register flags (isRegisterBuf): seen by the same
  #     checksum, taken again when the session closes (checking it every
  #     tick would bring back the O(back edges) per-tick scan that
  #     UNTIL_STABLE no longer runs); the session throws
  #     instead of returning, its later counts refused.
  # Neither refusal is reachable over the wire: this verb opens one session
  # and its body only ticks.
  # The frontier session: the engine has a second session,
  # `frontierSession`, with the same
  # counts, refusals and precondition, whose ticks evaluate only the nodes
  # that can change (readers of a node that changed, readers of a register
  # the latch changed, NOSKIP nodes that changed in the previous tick) and
  # latch only the back edges whose source changed; its first tick is a
  # whole tick. Inside it a topology change through the engine (a slot, a
  # rank, a back edge) is refused by name too: "frontier session refused:
  # the graph's topology changed inside the session …". The session's
  # reverse index is kept between calls and dropped by every topology writer
  # only: CONNECT, CLEAR … EDGES, SET_NEIGHBORS_BULK, SET … RANK,
  # SET_RANKS_BULK, CONNECT BACK, CLEAR … BACK_EDGES, CONNECT_BACK_BULK,
  # LOAD, IMPORT MORTON, LOAD JSON, LOAD CSV, BACKUP RESTORE (and any verb
  # not known to keep it); never by a LUT, table, mode, threshold, weight,
  # value or truth write.
  # This verb runs on
  # the frontier session, 16 ticks per command buffer (each batch
  # min(16, MAX − ticks run)): the CPU waits on the GPU once per batch, reads
  # each tick's two counts from the batch's per-tick counters, and stops at
  # the first tick with both 0, or at MAX. ticks=, run=, changed=, latched=,
  # stable / not stable, total= and the bytes equal those of the one-tick-per-buffer
  # path. Ticks a batch ran after the fixed point ran from a
  # fixed point and changed no byte; they are not in run= or the
  # tick total. nodes_computed= is now the honest count: the node slots the
  # session's rank dispatches covered (a whole tick: every node; later
  # ticks: the frontier's lists), not run × the graph. Kernel-evaluated
  # destinations (a register flag cleared by a raw write) take one tick per
  # command buffer pair, as before. The first call after a topology change
  # builds the reverse index on the CPU (30–32 ms on a 128³ voxel graph), and the
  # daemon's first call makes the frontier kernels.
  # The batches of one call ramp up — 1, 2, 4, 8, then 16, 16, … — each also
  # min(·, MAX − ticks run), so a graph already stable encodes one tick (it
  # used to run a whole batch of 16 to find that out) and a call never
  # encodes more than 2 × run ticks; the CPU's waits stay ≤ ⌈run/4⌉ + 2. A
  # command buffer holds at most 131,072 dispatches (a frontier tick is two
  # per non-empty rank plus the latch's two or three), at least one tick.
  # The depth guard: on a graph with more than 24 non-empty rank levels
  # (R*, measured: past it the frontier's two dispatches per rank cost more
  # than they save) the verb runs the counting path, one tick per command
  # buffer, the same replies and bytes; no reverse index is built for it.
  → ERROR gpu: TICK UNTIL_STABLE: command buffer status <status>
    (<error | no error object>) at tick <i>; nothing claimed, the truth bytes
    may hold part of that command buffer's writes; total=<tickCount>
  # Every tick path reads its command buffer's
  # status after the wait. Any status but completed ends the verb with this
  # line, the status by name (notEnqueued, enqueued, committed, scheduled,
  # error) — earlier builds read counts of 0 from an aborted buffer and the verb
  # replied "stable". <i> is the first tick of the buffer that failed; the
  # tick total counts only the ticks of buffers that completed. TICK,
  # TICK_SYNC and EVAL reply the same way (below).
  # Test seams, never set in production: DAGDB_FRONTIER_FOR_TESTING=1 logs
  # one line per call (batches, the CPU's waits on the GPU, evaluated node
  # slots, index and kernel builds, the session's buffers, and also
  # ticks encoded, the largest buffer, the non-empty rank levels, the
  # guard);
  # DAGDB_FRONTIER_BATCH_FOR_TESTING=<k> sets the ramp's ceiling (k = 1:
  # one tick per command buffer);
  # DAGDB_FRONTIER_TAU_FOR_TESTING=<x>|inf sets the whole-rank threshold;
  # DAGDB_FRONTIER_MAX_LEVELS_FOR_TESTING=<n>|inf sets the depth guard's R*
  # (inf: the frontier at any depth).

TICK_SYNC <n>
  → OK TICK_SYNC <n> elapsed=<ms>ms total=<tickCount> nodes_computed=<k>
    [rank_max=<highest rank present> bound=<maxRank>]
  → ERROR gpu: TICK_SYNC: command buffer status <status> (…) at tick <i> of
    <n>; nothing claimed, …; total=<tickCount>
  # As TICK UNTIL_STABLE; the failed tick's
  # buffers are not swapped and nothing is latched.
  # nodes_computed is the WHOLE command's node-evaluations: the node
  # slots one tick dispatches times <n>. Printed always.
  # The bound pair appears only when the graph reaches past the
  # configured bound — the state a graph saved under a large maxRank
  # and restored under a small one lands in. It is computed, not
  # refused.
  # The two verbs word it differently ON PURPOSE: rank mode reports
  # the levels it dispatched (ranks=), sync mode does not dispatch by
  # rank at all, so it states the same news about the GRAPH (rank_max=)
  # rather than implying a bounded dispatch it never performed.

EVAL [WHERE <field><op><value>]
  → writes matching roots to shm
  → OK EVAL rows=<k> tick=<t> scope=roots nodes_computed=<n>
      [ranks=<r> bound=<M>]
  # EVAL ticks the WHOLE graph and then reports only rank-0 roots —
  # `scope=roots` says so on the wire. It dispatched by rank exactly
  # as TICK did, so it carries TICK's `nodes_computed` and the same
  # `ranks=`/`bound=` pair when the graph reaches past the bound.
  → ERROR invalid_graph: EVAL refused, validation: <violation>
    (VALIDATE names it; TICK_SYNC is defined on this graph)
  # EVAL ticks through the
  # colour path. On a graph holding S2 or S3 (which every loader accepts
  # under the slot model), a same-rank edge between two nodes of the same hex colour is
  # read while it is written, and two identical daemons could end apart.
  # EVAL now asks the cached verdict rank-mode TICK asks and refuses such a
  # graph in TICK's words, only the verb changed. <violation> is the same
  # sentence. Nothing runs: no tick, no rows written, the tick count and
  # the truth bytes unchanged. The tick headroom check (ERROR out_of_range)
  # still comes first, as in TICK. On a graph that passes, EVAL is
  # unchanged: the same colour-segment dispatch, the same rows, the same
  # bytes. Use TICK_SYNC on such graphs.
  → ERROR dsl_parse: EVAL takes no RANK clause: EVAL reports the rank-0
    roots (scope=roots), and NODES AT RANK <n> [WHERE <field><op><value>]
    reads other ranks; nothing ran
  # The old
  # `[RANK <lo> TO <hi>]` clause was parsed and then ignored (`EVAL RANK
  # 9 TO 0` returned plain EVAL's rows). EVAL's rows are the rank-0 roots,
  # so a rank range on them is trivial, and the scope change a caller
  # means is new semantics: the parser now refuses every RANK form (with
  # or without TO, numeric or not, before or after WHERE) with the words
  # above, before anything else, the graph's verdict included. Nothing
  # runs: no tick, no rows, no truth or tick-count change, no WAL byte.
  # A WHERE predicate on the rank field (`WHERE rank=0`, `WHERE rank = 0`)
  # is not the clause and is unchanged. Inside READER the same refusal
  # comes before the session's own.

VALIDATE
  → OK VALIDATE  |  FAIL VALIDATE <first-violation>
  # VALIDATE reports the rank-mode DAG property, not the
  # store's invariant — unchanged. Since the slot model a graph that
  # FAILs it on S1 (a duplicate source), S2 (a slot self-loop) or S3 (a
  # rank inversion) is still a legal store: SAVE writes it, every loader
  # loads it, TICK_SYNC is defined on it. Rank-mode TICK refuses S2/S3
  # (not S1, which it evaluates twice). S4 and an out-of-range source are
  # refused everywhere.
  # Edge violations first (bounds, self-loop, rank monotonicity,
  # duplicates). Then the register invariant (a BACK_EDGE destination
  # with combinational fan-in), the range of every back-edge index, and
  # the agreement between the register flags and the back-edge list.
  # Then the rank bound:
  #   FAIL VALIDATE rank bound: <k> node(s) at or above maxRank <M>
  #     (first node <i> rank <r>, highest rank <h>); rank dispatch
  #     covers <c> of <N> node(s) over <L> rank level(s)
  #     [; <u> node(s) at rank >= <L> are outside every dispatch
  #        (first node <j> rank <s>)]
  # The old sentence is unchanged; the two clauses after it are new.
  # `maxRank` alone conflated two different states. A rank ABOVE the
  # configured bound but inside the dispatch IS computed — that is the
  # stale-bound warning, and the coverage clause says so by printing
  # <c> == <N>. A rank at or above the dispatch's own level count is
  # computed by NOBODY; the last clause names it and <c> falls short.
  # `nodes_computed` on the TICK reply is the same shortfall on the wire.
```

`<field>` ∈ `truth`, `state` (alias for `truth`), `rank`, `type`.
`<op>` ∈ `=`, `!=`, `<`, `>`, `<=`, `>=`. One clause per WHERE.

**Ticks are not durable without SAVE.** TICK, TICK_SYNC, EVAL and TICK
UNTIL_STABLE are not written to the WAL: the log records inputs (every mutating verb), and the
truth a tick computes becomes durable only through a snapshot. `SAVE`
writes it into the file and binds the file to its WAL position (a
SNAPSHOT_BIND record before the rename, a CHECKPOINT after it), so a
restart that loads that file replays only the records after it. A daemon restarted
from its WAL alone rebuilds the inputs and the truth as it stood before
the unsaved ticks; its boot log says how many
(`WAL: at least <L> ticks were not recovered (highest logged total …`,
from the advisory, unsynced TICK_NOTE each tick command leaves; `WAL: tick
history unknown` for a log with none). One consequence is visible on replay: **a write that
was validated against post-tick truth may be refused on WAL replay, by
name.** The case in this build: `SET <id> MODE TTABLE|TTHRESH` (or
`SET_MODES_BULK`) on a node whose Loom byte (≥ 3) a tick had rewritten
to 0 or 1 is legal live, but on replay the byte is still ≥ 3, so the
record is refused — not applied, counted in the startup line's
`skipped=` (under `out_of_range`), and named in `ReplayResult.refusals`
as `offset <o> opcode 0x40: node <i>: truth byte <b> on a ternary node`
(0x47 for the bulk record). The replayed state is then the pre-tick
world the log describes. Logging TICK, TICK_SYNC and EVAL as replayable
records is left for later work.

**Replay applies every live rule that reads only the record and logged
state**. Refused on replay as they are live —
skipped, counted under `out_of_range`, named in `ReplayResult.refusals`:
a non-finite `SET WEIGHT` (opcode 0x04) or `SET VALUE` (0x06); `SET
TRUTH` of 3 or more on a ternary node (0x01); `CONNECT BACK` into a
ternary node (0x10). The node's mode is in the log, so these replay
exactly as they ran. Only the truth-byte check of `SET MODE` (above)
reads tick-computed truth. The daemon's startup log names every refused
record in one line beside the counts: `WAL: refused
<n> record(s) — offset <o> opcode 0x<op>: <reason>; …`.

**Every write verb refuses a non-finite lane.**
`SAVE` (plain, `COMPRESSED`, and the auto-snapshot), `SAVE JSON`, `SAVE
CSV`, `SAVE TILED`, `EXPORT MORTON`, `BACKUP INIT` and `BACKUP APPEND`
answer `ERROR
io: <verb>: … edge weight node=<i> slot=<d> is <v> (bits 0x…); a weight
must be finite` (or `node value node=<i> is <v> …; a value must be
finite`) and write nothing, so a write that succeeds can be loaded. `SET
WEIGHT` and `SET VALUE` refuse such values live, and replay refuses such
records (above).

**Every load and restore path refuses a non-finite lane**,
by name and before any buffer is written: `LOAD` (a `.dags`
v6–v8 file, plain or zlib), `LOAD JSON`, `LOAD CSV`, `IMPORT MORTON`
(`node_value.bin` / `edge_weights.bin` named), `BACKUP RESTORE` (the
base, and the state every diff leaves — the refusal names the diff:
`ERROR io: backup_restore: invalid diff: 00002.diff: node value
node=<i> is <v> (bits 0x…); a value must be finite`) and
`DAGDB_STARTUP_LOAD` (the daemon does not start: `FATAL: startup
snapshot unreadable: …`). The text is the write verbs' and the target's
state is unchanged, so a state that loads can also be saved. `BACKUP
COMPACT` refuses a chain whose folded state holds one with the same
sentence, writes nothing and deletes nothing, and the chain still
restores to the same refusal. An earlier version of this page said an
engine could hold a non-finite weight or value only through raw buffer
access; that was false until these checks were added — these load paths accepted a
non-finite node value from a crafted or corrupt file, and `BACKUP
RESTORE` a non-finite weight from a diff. The library writers
(`DagDBSnapshot.save`, `exportMorton`, `DagDBJSONIO.saveJSON` /
`saveCSV`, `DagDBBackup.initializeChain` / `appendDiff`) still do not
check: a program that links DagDB and writes the
buffers directly can write such a file, and the daemon refuses to load
it.

---

## Read

```
NODES [AT RANK <n>] [WHERE <field><op><value>]
  → writes rows (node, rank, truth, type, mode) to shm
  → OK NODES rows=<k> omitted=<n>

TRAVERSE FROM <node> DEPTH <n>
  → writes rows (node, rank, truth, type, mode) to shm
  → OK TRAVERSE rows=<k> from=<node> depth=<n>

GRAPH INFO
  → OK GRAPH nodes=<N> true=<k> r0=<n> r1=<n> … ternary_nodes=<t> trits=-:<a> 0:<b> +:<c>
  # The two ternary fields are appended on every reply, 0s on a binary
  # graph: <t> nodes have a non-zero mode, and <a> + <b> + <c> = <t>
  # count their truth bytes read as trits (0 → -, 2 and any
  # byte ≥ 3 → 0, 1 → +).
```

Every result row is 24 bytes: u64 node, u64 rank, u8 truth (byte 16),
u8 type (byte 17), u8 **mode** (byte 18; since the ternary build —
pad, always 0, before it), 5 bytes pad, written 0 on every row write. `NODES`, `TRAVERSE` and `EVAL`
write these rows; the tiled verbs write their own 16- and 8-byte rows,
which carry no mode byte.

`NODES` with no rank filter drops every node whose rank AND truth are
both zero — the "likely unused" default filter. `omitted=<n>` is how
many it dropped. The filter is disclosed, not changed.

```
TRUTH_SLICE NODES <lo>-<hi>
TRUTH_SLICE RANK <lo>-<hi>
  → OK TRUTH_SLICE nodes=<k> format=<bits|trits> bits_per_node=<1|2>
      shm_bytes=<b> first=<id|-> last=<id|->
  → ERROR bad_value: TRUTH_SLICE node <i> truth <v> does not fit 2 bits
      (0, 1, 2); read it with NODES or GET
  → ERROR out_of_range: node <hi> not in 0..<<N>
  → ERROR out_of_range: range <lo>-<hi> is empty (lo > hi)
  → ERROR out_of_range: result needs <bytes> bytes, shm holds <cap>
  # The truth bytes of nodes <lo>…<hi> by id, or of
  # every node whose rank is in <lo>…<hi> (in ascending id; first= and
  # last= name the end ids, the client knows the layout or reads the ids
  # once with NODES), packed into shm: header u32 node count, u32 bits
  # per node at offset 0, the packed bytes from offset 8, node j of the
  # slice at bit j·bits, least significant bits first (numpy:
  # unpackbits(bitorder="little")). One bit per node — ≤ 1 byte per 8
  # nodes — on a graph with no ternary node whose slice holds only 0
  # and 1; otherwise two bits per node — ≤ 1 byte per 4 — carrying the
  # byte itself (0, 1, 2: a ternary node's −1, +1, 0). Equal to NODES'
  # truth column for every node (gate). A binary node holding a Loom
  # code (3…255) fits neither and is refused by name. Reader sessions
  # take it too (`READER <id> TRUTH_SLICE …`, `session=` in the reply).
  #
  # The
  # same bytes, the same refusals, the same reply, read from the selection
  # only, 8 nodes per step. A NODES range reads its own ids (one u64 load
  # per 8 nodes); RANK r-r reads rank r's per-rank list (ascending ids,
  # rebuilt first if a rank write has made it stale since the last tick).
  # RANK lo-hi with lo < hi, a RANK r-r before the first rank-ordered TICK
  # (no lists yet) and a reader session's slice keep the per-node loop over the
  # rank lane. The first byte ≥ 3 in ascending id is still the one named,
  # and a refused slice still writes nothing. Test seam:
  # DAGDB_TRUTH_SLICE_OLD_LOOP_FOR_TESTING=1 at daemon start runs that per-node loop
  # for every slice.

TRUTH_SLICE NODES <lo>-<hi> BYTES
TRUTH_SLICE RANK <lo>-<hi> BYTES
  → OK TRUTH_SLICE nodes=<k> format=bytes bits_per_node=8 shm_bytes=<k>
      first=<id|-> last=<id|->
  → ERROR out_of_range: node <hi> not in 0..<<N>
  → ERROR out_of_range: range <lo>-<hi> is empty (lo > hi)
  → ERROR out_of_range: result needs <bytes> bytes, shm holds <cap>
  # The raw lane. The same selection as above, every
  # truth byte verbatim, one byte per node: header u32 node count, u32 8 at
  # offset 0, the bytes from offset 8 (numpy: a zero-copy uint8 or bool
  # view of the result file, no unpack). It chooses no width and REFUSES
  # NOTHING for its value: a Loom code (3…255) and a ternary node's 0/1/2
  # travel as they are, so the caller reads what it gets — a bool view is
  # the truth only where the caller knows every byte is 0 or 1. Only the
  # selection's refusals and the result file's capacity, as above. Equal to
  # NODES' truth column for every node, Loom codes included (gate). Reader
  # sessions take it too.
```

`TRAVERSE` keeps a global visited set, so a node reachable at several
depths is reported once and the row count is bounded by `nodeCount`.
`depth` is bounded by `nodeCount` too: no path in a DAG on N nodes is
longer than N−1 hops.

---

## Mutate

Every mutation that changes a node's `(truth, rank)` flips the
secondary-index dirty flag. WAL (if enabled) appends the record
before the buffer is touched.

```
SET <node> TRUTH <0|1|2>
  → OK SET node=<n> truth=<v>
  → ERROR bad_value: ternary: SET TRUTH on ternary node <n> accepts 0..2, not <v>
  # A binary node keeps 0..255 (Loom event codes); a ternary-mode node
  # accepts only 0..2. SET <n> TRIT is the trit form.
SET <node> RANK  <u64>
  → OK SET node=<n> rank=<v>
  → ERROR out_of_range: rank <v> not in 0..<<nodeCount>
  # A rank of nodeCount or more is refused and the rank buffer is left
  # alone: no valid DAG on N nodes holds a rank of N or more. A rank
  # between maxRank and nodeCount is ACCEPTED and computed — the bound
  # is a sizing hint, not a limit.
SET <node> LUT   <PRESET>

CONNECT FROM <src> TO <dst>
  → OK CONNECT from=<src> to=<dst>
  → ERROR schema: self-loop: src == dst (<src>)
  → ERROR schema: back_edge_violation: node <dst> is a BACK_EDGE
      destination (register); use CLEAR <dst> BACK_EDGES first if you
      want a combinational input here
  → ERROR schema: rank violation: src(<s>) rank=<a> must be > dst(<d>)
      rank=<b> — edges flow leaves→roots
  → ERROR schema: duplicate edge: <src> → <dst>
  # CONNECT is the incremental authoring verb of a
  # rank-mode DAG and stays strict on all four slot shapes (S2, S4, S3,
  # S1, in that order): what it builds is always rank-tickable, and it
  # names the mistake when it is made. The slot model is the STORE's
  # invariant — slot-model graphs (a duplicate source, a slot self-loop,
  # a rank inversion) enter through SET_NEIGHBORS_BULK, IMPORT MORTON and
  # the loaders. So no CONNECT record ever carries S1–S3.
CLEAR   <node> EDGES

SET_RANKS_BULK
  → OK SET_RANKS_BULK nodes=<N> validation=skipped
      skipped=rank_monotonicity recheck=VALIDATE
  → ERROR out_of_range: node <i> rank <v> not in 0..<<nodeCount>
  # Caller writes the header [u32 nodeCount][u32 0x314D4801] at bytes
  # 0..7 and a u64 rank vector of length nodeCount to shm at
  # offset 8 BEFORE calling this (Input frames, above; an unmarked or
  # foreign frame is stale_frame). Daemon memcpys into rankBuf in
  # one round-trip. No per-insert MONOTONICITY validation — run
  # VALIDATE after if paranoid. The RANGE is checked: the whole
  # vector is inspected before a single rank is written, so a bad
  # entry leaves every rank exactly as it was and the refusal names
  # the first offending node.

SET_LUTS_BULK
  # Caller writes the header [u32 nodeCount][u32 0x314D4802] at bytes
  # 0..7 and a u64 LUT vector of length nodeCount to shm at
  # offset 8 BEFORE calling this (Input frames, above). Daemon splits each u64 into low/
  # high u32 and commits to lut6Low/lut6High in one round-trip.
  # WAL-logged (opcode 0x15) when the daemon runs with a WAL.

SET_LUTS NODES|RANK <lo>-<hi> FILL <hex64>
SET_LUTS NODES|RANK <lo>-<hi> MAP [MASK <hex64>] <from>=<to> [<from>=<to> …]
  → OK SET_LUTS nodes=<k> written=<w>
  → ERROR out_of_range: range <lo>-<hi> is empty (lo > hi)
  → ERROR out_of_range: node <hi> not in 0..<<N>
  → ERROR out_of_range: SET_LUTS MAP pairs <p> not in 1...16; nothing written
  → ERROR bad_value: SET_LUTS MAP pair <j>: from <hex> has bits outside
      MASK <hex> (a LUT ANDed with the mask never equals it); nothing written
  → ERROR bad_value: SET_LUTS MAP pairs <i> and <j> have the same key <hex>
      under MASK <hex> (keys must be distinct after masking); nothing written
  → ERROR gpu: SET_LUTS: command buffer status <status> (<error|no error
      object>); nothing claimed, the LUT lane may hold part of that command
      buffer's writes[; the WAL record stands (replay applies the verb whole)]
  → ERROR wal: append: opcode 0x4f needs log version 3, this log is version <1|2>; nothing written; <remedy>
  # A LUT
  # write by selection, no vector through shm. The selection is TRUTH_SLICE's
  # (above): the ids <lo>…<hi> (NODES), or every node whose rank is in
  # <lo>…<hi> (RANK); a rank range that holds no node is OK, nodes=0. FILL
  # writes the value to every node of the selection (written = nodes). MAP
  # writes <to> to every node of the selection whose LUT ANDed with the mask
  # (default: all ones) equals <from> — a simultaneous substitution on the
  # node's value before the verb: a node is read once, before its own write,
  # so a <to> equal to another pair's <from> is not followed (no chaining).
  # 1…16 pairs; every <from> inside the mask (a key with a bit outside it could
  # never be equalled — refused, so "ANDed with the mask equals from" and
  # "keys distinct after masking" are one rule); the keys distinct. written =
  # the nodes whose key matched. Hex words with or without 0x, any case, 1…16
  # digits; a malformed line is an unknown command. The bytes land in
  # lut6Low/lut6High exactly as SET_LUTS_BULK splits a u64 (the
  # lane after every verb equals SET_LUTS_BULK's with the equivalent vector).
  # Registers and ternary nodes are written like any node (the tick never
  # reads a register's LUT; a TTABLE or TTHRESH node keeps its own rule).
  # One GPU kernel, one thread per node: over the id range (NODES); over rank
  # <lo>'s per-rank list when lo == hi and the lists exist — rebuilt
  # first if a rank write has made them stale since the last tick; else one
  # pass over the rank lane. The CPU twin writes the same bytes when no
  # command buffer can be had (the reply does not say which ran). A LUT write
  # moves no rank, slot, back edge or truth byte: the DAG verdict, the frontier
  # index, the GPU latch plan and the (truth, rank) index are kept.
  # WAL: one record of opcode 0x4F per verb (version-3 logs), 31 bytes for
  # FILL and 32 + 16p for a MAP of p pairs; replay checks the verb's rule
  # against the replayed node count (a refused record is skipped, counted
  # under out_of_range and named) and runs the same function. Forbidden in a
  # reader session. Test seam: DAGDB_SET_LUTS_CPU_FOR_TESTING=<n> at daemon
  # start runs every verb whose dispatch covers ≥ n nodes on the CPU twin.
  #
  # Example, a voxel client's phase in three lines, O's two classes tagged once in the
  # import LUTs (inside bit 62, outside bit 61, bits the O rule never reads):
  #   SET_LUTS RANK <L+1>-<L+1> FILL <A's LUT>
  #   SET_LUTS RANK <L>-<L> MAP MASK 0x6000000000000000
  #       0x4000000000000000=<0x4000000000000000|inside rule>
  #       0x2000000000000000=<0x2000000000000000|outside rule>
  #   SET_LUTS NODES <B0>-<B0+5> FILL <border>

SET_NEIGHBORS_BULK
  → OK SET_NEIGHBORS_BULK nodes=<N> edges_slot=<6N>
      rank_order=unchecked recheck=VALIDATE
  → ERROR out_of_range: slot <i> (node <n> dir <d>) neighbour <v>
      not in -1..<<nodeCount>
  → ERROR schema: SET_NEIGHBORS_BULK slot <i> (node <n> dir <d>):
      back_edge_violation: node <n> is a BACK_EDGE destination
      (register); use CLEAR <n> BACK_EDGES first if you want a
      combinational input here; nothing written
  → ERROR out_of_range: result needs <bytes> bytes, shm holds <cap>
  # Caller writes the header [u32 nodeCount][u32 0x314D4803] at bytes
  # 0..7 (the count is nodes, not slots) and an Int32 vector of length
  # (nodeCount * 6) to shm
  # at offset 8 BEFORE calling this (Input frames, above). Daemon memcpys to neighborsBuf.
  # -1 in any slot means "no neighbour"; every other element must be
  # a real node id. The WHOLE vector is range-checked before a single
  # word is written, so a bad slot leaves every neighbour exactly as
  # it was, and the refusal names the FIRST offender. The read is
  # size-checked against the mapping first.
  # Under the slot model, S4 — a slot into a register (a node
  # whose register flag is set, the flag CONNECT reads) — is refused by
  # its first slot in CONNECT's words, nothing written, no WAL record.
  # S1–S3 (a duplicate source, a slot self-loop, a rank inversion) are
  # store shapes and are installed; the rank order is not checked, and
  # the reply says so (`rank_order=unchecked recheck=VALIDATE`; before the
  # slot model it said `validation=skipped skipped=back_edge_register_fanin`).
```

```
CONNECT_BACK_BULK
  → OK CONNECT_BACK_BULK edges=<k> back_edges=<total>
  → ERROR <category>: CONNECT_BACK_BULK entry <i>: <CONNECT BACK's own
      refusal>; nothing written
  → ERROR stale_frame: CONNECT_BACK_BULK reads a client frame; the shm
      header is (<w0>, <w1>), not (<w0>, 0x314D4808): … (Input frames, above;
      before client_protocol 2: "row size <r>, expected 8")
  → ERROR out_of_range: result needs <bytes> bytes, shm holds <cap>;
      CONNECT_BACK_BULK count <count> (row 8) does not fit; nothing written
  → ERROR wal: append: opcode 0x4d needs log version 3, this log is
      version <1|2>; nothing written; <remedy>
  # WAL: the bulk is one record of opcode 0x4D, which
  # only a version-3 log carries. With the WAL on, a daemon running on a
  # version-1 or version-2 log refuses the bulk by name with the line
  # above — nothing written, no state, no WAL byte. Without a WAL there
  # is no log to refuse it.
  # Result-style input (see the top of this file):
  # [u32 count][u32 0x314D4808] at bytes 0..7, then
  # count × (u32 src, u32 dst) at offset 8. Equal to <count> `CONNECT BACK FROM
  # <src> TO <dst>` commands in file order — the final graph, the
  # snapshot bytes and the WAL replay (gate) — duplicates included (a
  # duplicate appends, as CONNECT BACK does). Every entry gets CONNECT
  # BACK's checks (range, self-loop, a ternary destination, a
  # destination with combinational fan-in) BEFORE anything is written;
  # the first refused entry refuses the whole bulk in CONNECT BACK's
  # words, its index named — nothing written, no WAL byte. Those checks
  # read only the destination's mode and slots, never the back-edge
  # list, so one pass over the file gives the verdicts N commands
  # would. Accepted: ONE WAL record (opcode 0x4D), then the edges.
  # count 0 is OK and writes nothing.

SET_TRUTH_BULK
  → OK SET_TRUTH_BULK nodes=<k>
  → ERROR <category>: SET_TRUTH_BULK entry <i>: <SET TRUTH's own
      refusal>; nothing written
  → ERROR bad_value: SET_TRUTH_BULK entry <i>: pad bytes 5..7 must be 0
      (row: u32 node, u8 value, 3 zero bytes); nothing written
  → ERROR stale_frame: SET_TRUTH_BULK reads a client frame; the shm
      header is (<w0>, <w1>), not (<w0>, 0x314D4809): … (Input frames, above;
      before client_protocol 2: "row size <r>, expected 8")
  → ERROR out_of_range: result needs <bytes> bytes, shm holds <cap>;
      SET_TRUTH_BULK count <count> (row 8) does not fit; nothing written
  → ERROR wal: append: opcode 0x4e needs log version 3, this log is
      version <1|2>; nothing written; <remedy>
  # WAL: one record of opcode 0x4E, version-3 logs
  # only; on a version-1 or version-2 log the bulk is refused by name
  # with the line above, nothing written.
  # Result-style input: [u32 count][u32 0x314D4809]
  # at bytes 0..7, then count × (u32 node, u8 value,
  # three zero bytes) at offset 8. Equal to <count> `SET <node> TRUTH <value>`
  # commands in file order (a repeated node: the last wins), all or
  # nothing, ONE WAL record (opcode 0x4E). SET TRUTH's checks per entry:
  # the node's range, and 0..2 on a ternary node (binary nodes keep
  # 0..255). Non-zero pad is refused rather than read as the low byte
  # of a wider value. Like SET TRUTH, it marks the (truth, rank) index
  # dirty. NOT built: a "NOSKIP refusal" on the bulk (a ternary node may
  # not jump −1 → +1)" — the single SET TRUTH has no such refusal (it
  # moves a NOSKIP node from −1 to +1 today; NOSKIP is a tick rule,
  # not a write rule), so the bulk, equal to the single, has none either.
  # Whether the bulk should refuse it is not decided.

SET_TRUTH NODES|RANK <lo>-<hi> FILL <v>
  → OK SET_TRUTH nodes=<k> truth=<v>
  → ERROR out_of_range: range <lo>-<hi> is empty (lo > hi)
  → ERROR out_of_range: node <hi> not in 0..<<N>
  → ERROR bad_value: ternary: SET_TRUTH FILL <v>: the graph has <t> ternary
      node(s), which hold 0..2; write a value of 3 or more per node with
      SET_TRUTH_BULK; nothing written
  → ERROR wal: append: opcode 0x50 needs log version 3, this log is version <1|2>; nothing written; <remedy>
  # The
  # truth byte of every node in the selection := <v> (decimal 0…255, as SET
  # TRUTH; a malformed line is an unknown command). The selection is
  # TRUTH_SLICE's and SET_LUTS's: the ids <lo>…<hi> (NODES), or every node
  # whose rank is in <lo>…<hi> (RANK); a rank range that holds no node is OK,
  # nodes=0. Registers are written like any node — a truth write outside any
  # session, as SET TRUTH is. A value of 3 or more is refused by name when the
  # graph holds any ternary node (one count, not a per-node check: a ternary
  # node holds 0..2; SET_TRUTH_BULK checks per node); 0, 1, 2 are legal on
  # every mode. On the CPU: a memset of the id range (NODES); a scatter through
  # rank <lo>'s per-rank list when lo == hi and the lists exist — rebuilt
  # first if a rank write has made them stale since the last tick; else one
  # pass over the rank lane. Like SET TRUTH it marks the (truth, rank) index
  # dirty (when a node was written); it moves no rank, slot, back edge or LUT,
  # so the DAG verdict, the frontier index, the latch plan and the rank lists
  # are kept. WAL: one record of opcode 0x50 per verb (version-3 logs), 23
  # bytes; replay checks the verb's rule against the replayed node count and
  # ternary nodes (a refused record is skipped, counted under out_of_range and
  # named) and runs the same function. Forbidden in a reader session.
  #
  # Example, a voxel client's zero phase: `SET_TRUTH NODES <V0>-<V0+N-1> FILL 0` and
  # no tick: the zero tick's only persisting effect is V := 0, and the flood's
  # first tick (whole) recomputes every other node from V and the LUTs. The
  # bytes right after the verb differ from the zero-tick path's (O, A and the
  # change tree are stale until that tick); after it they are the same, and
  # TICK UNTIL_STABLE's reply is the same but `total=`, one tick fewer.
```

The three bulk verbs together compile a million-node microcircuit
graph in three shm writes + three verbs. See
[`microcircuit-compilation.md`](microcircuit-compilation.md) for the
full recipe on approximating continuous functions at substrate
throughput.

LUT presets: `AND`, `OR`, `XOR`, `MAJ` (MAJORITY6), `IDENTITY`,
`CONST0`, `CONST1`, `VETO`, `NOR`, `NAND`, `AND3`, `OR3`, `MAJ3`.

### Bitwise LUT composition

Compose source LUTs into a destination LUT in a single bitwise
operation. Foundation for graph-simplification passes (collapse a
fused subtree into one node), policy composition ("fires when all
of {a, b, c} agree"), and any case where you'd otherwise evaluate
a tree of intermediate nodes per tick.

```
COMPOSE AND <src1> <src2> INTO <dst>     # dst.LUT = src1.LUT & src2.LUT
COMPOSE OR  <src1> <src2> INTO <dst>     # dst.LUT = src1.LUT | src2.LUT
COMPOSE XOR <src1> <src2> INTO <dst>     # dst.LUT = src1.LUT ^ src2.LUT
COMPOSE NOT <src>         INTO <dst>     # dst.LUT = ~src.LUT
```

Caller is responsible for the assumption that sources and
destination share a common input vector — the engine performs the
bitwise op directly on the 64-bit LUT integers, no input
remapping. WAL-logs the equivalent `SET_LUT` if enabled. Returns
`OK COMPOSE op=<OP> src1=<i> src2=<j|—> dst=<k> lut=0x<hex>`.
Rejected inside reader sessions (mutates the LUT buffer).

When the sources are TTABLE nodes the same words compose their TABLES
pointwise (see the ternary section below).

---

## Ternary (native ternary tick)

The replies below are fixed.

A node's **mode** (u8, default 0) picks its rule: bits 0–1 the kind —
0 BINARY (the LUT6 rule, unchanged bit for bit), 1 TTABLE, 2 TTHRESH —
bit 2 NOSKIP (ternary kinds only), bits 3–7 zero. The legal mode bytes
are 0, 1, 2, 5, 6.

- **The trit view.** A ternary node reads every input byte
  as a trit: 0 → −1, 1 → +1, 2 → 0, and any byte ≥ 3 (a Loom event
  code) → 0. An absent slot (−1, or ≥ nodeCount) reads 0. It stores its
  trit as the byte −1 → 0, 0 → 2, +1 → 1, so nothing collapses an
  UNDEFINED. A BINARY node reads and writes exactly as before
  (bit = `byte == 1`, writes 0/1).
- **TTABLE.** Looks up library table `ttableId` at index
  Σ_{d=0..5} 3^d·(t_d + 1); each table is 729 bytes in {0, 1, 2} (the
  stored-trit encoding of the output).
- **TTHRESH.** s = 0; for d = 0…5 over
  present slots, s = s + w_d·t_d in f32, with w from the edge-weight
  lane (`SET <n> WEIGHT`). Output +1 if s > hi, −1 if s < lo, 0
  otherwise — equality gives 0. The slot order is part of the
  definition. The arithmetic flushes to zero: each
  weight, lo, hi and every partial sum after each addition is replaced
  by the zero of its sign when it is subnormal, before the comparison
  (signed zeros compare equal) — the GPU does this in hardware, and the
  CPU reference does exactly the same.
- **NOSKIP.** No direct −1 → +1 or +1 → −1: when the
  previous trit and the computed one are opposite and non-zero, the
  node writes 0. "Previous" is the node's byte before this evaluation
  in rank mode, and `truth_in` in sync mode.
- **Registers.** A BACK_EDGE destination
  stays BINARY and latches its source's byte unchanged — a ternary
  source's 0/1/2 arrives exactly, and ternary readers read it as a
  trit.

```
SET <id> MODE BINARY|TTABLE|TTHRESH [NOSKIP]
  → OK SET node=<id> mode=<BINARY|TTABLE|TTHRESH> noskip=<0|1>
SET <id> TTABLE <tid>
  → OK SET node=<id> ttable=<tid>
SET <id> THRESH <lo> <hi>
  → OK SET node=<id> thresh=<lo>,<hi>
SET <id> TRIT -1|0|1
  → OK SET node=<id> trit=<t>          # any node; writes the stored byte 0/2/1
GET <id> TRIT
  → OK GET node=<id> trit=<t>          # the trit view of the byte, any node

TTABLE DEFINE <tid> <729 chars of - 0 +>
  → OK TTABLE DEFINE tid=<tid> tables=<size>
TTABLE PRESET <tid> <name> <k>
  → OK TTABLE PRESET tid=<tid> name=<NAME> k=<k> tables=<size>
TTABLE GET <tid>
  → OK TTABLE GET tid=<tid> table=<729 chars of - 0 +>
  → ERROR out_of_range: tid <tid> not in 0..<<size>

COMPOSE AND|OR <s1> <s2> INTO <d>      # TTABLE sources and destination
COMPOSE NOT <s> INTO <d>
  → OK COMPOSE op=<op> src1=<a> src2=<b|—> dst=<d> ttable=<new tid>

# Bulk, through the result file (written first: the header
# [u32 count][u32 0x314D48<VV>] at bytes 0..7, the vector at shm offset 8;
# Input frames, above):
SET_MODES_BULK                  # [N][0x314D4804], u8[N]
  → OK SET_MODES_BULK nodes=<N> ternary=<count of non-zero modes>
SET_TTABLE_IDS_BULK             # [N][0x314D4805], u16[N]
  → OK SET_TTABLE_IDS_BULK nodes=<N>
SET_THRESH_BULK                 # [N][0x314D4806], f32[2N], (lo, hi) per node
  → OK SET_THRESH_BULK nodes=<N>
TTABLE_BULK <first> <count>     # [count][0x314D4807], u8[729·count]
  → OK TTABLE_BULK first=<first> count=<count> tables=<size>
```

**Presets** (the wire names are fixed):
`TMIN` (Kleene AND), `TMAX` (Kleene OR), `TSUM` (sign of the sum),
`TCONS` (all k inputs equal and non-zero → that value, else 0),
`TCONST-1`, `TCONST0`, `TCONST+1` take k = 1…6; `TID` and `TNEG` take
k = 1 only. Arity k uses slots 0..k−1; slots ≥ k are don't-care. Each
preset's table is generated from its CPU formula.

**The library** is dense — ids
0 ..< size, at most 65,536 tables. `DEFINE` and `PRESET` overwrite an
id below the size or append at id = size; an id above the size is a
gap and is refused. `TTABLE_BULK` needs first ≤ size, count ≥ 1 and
first + count ≤ 65,536. It rides the result file, which the daemon
sizes 8 + 24·nodeCount bytes, so one call carries at most
⌊24·nodeCount / 729⌋ tables (2 at 64 nodes, none below 31 nodes);
a small graph's library goes in through
`DEFINE`/`PRESET` or several calls.

**COMPOSE on tables** is node-addressed
like the LUT form: when the sources are TTABLE nodes, the pointwise
table (AND → min, OR → max, NOT → negation) is appended to the library
as a new entry and `<d>`'s table id is set to it; `<d>` must be a
TTABLE node. Binary sources into a binary destination run the LUT
COMPOSE above, unchanged.

**Refusals.** A ternary rule refused is `ERROR bad_value: ternary:
<reason>`, and nothing is written — no buffer, no WAL record. Bulk
vectors are checked whole before a byte is written. The reasons, by
rule:

- mode bits 3–7 set, kind 3, NOSKIP on a BINARY node (`mode 0x<mm> …`
  naming which);
- a ternary kind given to a node holding a truth byte ≥ 3 (`node <i>
  holds truth byte <b>; a ternary node holds 0, 1 or 2 — SET <i> TRUTH
  first`), or to a register (`node <i> is a register (BACK_EDGE
  destination); registers stay BINARY`);
- `SET … MODE TTABLE` on a node whose table id is not below the
  library size, and any explicit table id ≥ the size (`ttableId <tid>
  is not below the library size <size>`);
- a threshold that is not finite (`threshold lo=<lo> hi=<hi> is not
  finite`) or inverted (`threshold lo=<lo> > hi=<hi>`);
- a trit outside −1, 0, 1 (`trit <t> — use -1, 0 or 1`);
- a table that is not 729 characters of `- 0 +`, a table byte ≥ 3, a
  library gap, more than 65,536 tables, a `TTABLE_BULK` count outside
  1…65,536;
- an unknown preset name, or a k outside the preset's arity (`preset
  <NAME> is defined for k in <lo>...<hi>, not <k>`);
- COMPOSE: XOR on tables; a TTABLE source beside a non-TTABLE one; a
  TTHRESH source; table sources into a non-TTABLE destination; binary
  sources aimed at a ternary destination;
- `SET <n> TRUTH <v>` with v ≥ 3 on a ternary node (Mutate, above);
  `CONNECT BACK` into a ternary node (`… a register (BACK_EDGE
  destination) stays BINARY — SET <dst> MODE BINARY first`).

A node index out of range keeps the daemon's `ERROR out_of_range: node
<i> not in 0..<<N>` wording; a bulk vector or table block larger than
the result file is `ERROR out_of_range: result needs <b> bytes, shm
holds <cap>`; a WAL that will not take the record is `ERROR wal:
append: …`, with the engine unchanged.

**Elsewhere.** Every mutating form is logged first (WAL v3, opcodes
0x40–0x4A: one per single and bulk verb, and one for a table COMPOSE)
and is refused in a reader session (`ERROR forbidden: command not
allowed in reader session (read-only)`); `GET … TRIT`, `TTABLE GET` and
`GRAPH INFO` are served from a session's snapshot. `GRAPH INFO` counts
trits (Read, above); result rows carry the mode in byte 18.
`tickWithResonance` (library only, no daemon verb) refuses a graph with
any non-binary node, by name. `.dagb` delta encoding refuses one too.
A graph with no non-binary node ticks on the binary kernels — no
mode-lane read, none of the ternary buffers bound); the first
non-binary node, written by any verb, LOAD,
import, restore or replay, switches TICK, TICK_SYNC and EVAL to the
general kernels, and they switch back when the count returns to 0. Both
kernels give the same bytes on a binary graph. Ticks are not durable
without SAVE, and a mode write validated against post-tick truth may be
refused on WAL replay (Lifecycle, above).

---

## Persistence — binary `.dags`

```
SAVE <path> [COMPRESSED]
  → OK SAVE bytes=<b> elapsed=<ms>ms ratio=<pct>% path=<p>
  → OK SAVE bytes=<b> … path=<p> WARN wal: checkpoint not written (<error>);
      recovery starts after this snapshot's bind record
  → ERROR wal: SAVE refused: the snapshot's WAL bind record could not be
      appended (<error>); nothing renamed, <p> unchanged
  → ERROR io: save: validation: <violation>
  # With the WAL on, SAVE writes <p>.tmp,
  # fsyncs it, appends and fsyncs a SNAPSHOT_BIND record (the file's
  # SHA-256), then renames, writes <p>.sha256 and appends the checkpoint.
  # Recovery starts after the last bind record carrying the loaded file's
  # digest, so a kill between the rename and the checkpoint, or a
  # checkpoint that could not be appended (named by the WARN above, never
  # swallowed), no longer replays the records before the snapshot onto it.
  # A bind record that cannot be appended refuses the SAVE before the
  # rename. The autosave and the loaders' rebase run the same steps.
  # SAVE refuses what LOAD refuses, in LOAD's words,
  # writing nothing (no file, no .sha256, no WAL checkpoint). The
  # auto-snapshot path is the same. Under the slot model that is a
  # source out of range (`ERROR io: save: validation: node <d> slot <k>:
  # src <s> out of range`) and S4 (below, with the way out); S1–S3 are
  # saved and load back.

LOAD <path>
  → OK LOAD bytes=<b> nodes=<N> ticks=<t> [wal_base=<startup path>]
  → ERROR wal: LOAD loaded the state, but its durable snapshot to <path>
      failed (<SAVE's reply>); a restart would recover the state from
      before LOAD; SAVE <path> once it can be written
  # LOAD, LOAD JSON, LOAD CSV and BACKUP
  # RESTORE replace the engine's state and write no WAL record. With the
  # WAL on and DAGDB_STARTUP_LOAD set, a successful load ends with SAVE's
  # own durable snapshot to the startup path plus a WAL checkpoint, so a
  # restart (startup snapshot + the records past its bind record)
  # rebuilds on the loaded state; the reply says wal_base=<that path>.
  # With the WAL off, or with no DAGDB_STARTUP_LOAD (a restart then replays
  # the whole log over an empty engine), the reply and the
  # files are as before.
  # A snapshot that fails after the load is named (above): the state is
  # loaded and recovery's base did not move. A snapshot that succeeds but
  # whose checkpoint could not be appended ends the reply
  # with SAVE's WARN after wal_base=: the base moved (the snapshot is
  # bound), and the failure is named.

EXPORT MORTON <dir>
  → writes sixteen raw-buffer files (eleven, plus mode.bin,
    ttable_id.bin, thr_lo.bin, thr_hi.bin and ttables.bin since the
    ternary build); OK EXPORT bytes=<b> dir=<d>
  # The reply line is unchanged; the VALUE of bytes= grew, because it
  # used to report nodeCount * 42 — the six body lanes — while the
  # engine holds ten persisted lanes plus the back-edge list. It now
  # reports what was actually written. See the wiki's data-and-
  # persistence page for the file list.

IMPORT MORTON <dir>
  → reads the six body files (required), the five lane/back-edge
    files and the five ternary files (each when present), validates,
    commits; lanes a directory does not carry come back at their
    defaults, not at the destination's previous values — a directory
    without the ternary files loads as an all-BINARY graph with an
    empty library
  # With the WAL on, the import is logged — the bytes
  # of every file it read, after every check and before the commit
  # (IMPORT_MORTON 0x4C, preceded by IMPORT_PART 0x4B records when the
  # files exceed 2 GiB) — so a crash after the reply replays it even if
  # the directory is gone. A log that will not take the record leaves
  # the graph unchanged: ERROR wal: append: <reason>.

# One rule set for back edges. Every
# loader that installs a back-edge list checks each entry, in order, by
# CONNECT BACK's rules — no self-loop, a BINARY destination, a destination
# with no live combinational slot — against the lanes it is about to make
# live (the file's own mode and neighbour lanes, before anything is
# committed), and refuses the whole load at the first offender, in
# CONNECT BACK's words after its category, nothing committed, no WAL byte:
  → ERROR schema: IMPORT MORTON back_edges.bin entry <i>: <words>; nothing imported
  → ERROR schema: LOAD back-edge section entry <i>: <words>; nothing loaded
  → ERROR schema: LOAD JSON backEdges entry <i>: <words>; nothing loaded
  → ERROR schema: LOAD CSV back_edges.csv entry <i>: <words>; nothing loaded
  → ERROR schema: BACKUP RESTORE back-edge section entry <i>: <words>; nothing restored
  → ERROR schema: SAVE back edge entry <i>: <words>; nothing written
  # e.g. <words> = self-loop: src == dst (11) | ternary: CONNECT BACK into
  # ternary node 11; a register (BACK_EDGE destination) stays BINARY — SET
  # 11 MODE BINARY first | BACK_EDGE dst node 20 has a combinational input
  # at slot 0 (source node 4); registers must have zero combinational fan-in.
  # SAVE refuses the live list by the same rules (SAVE refuses what LOAD
  # refuses). A WAL import record holding such a list (an older build
  # could log one) is refused on replay by name. LOAD's
  # back-edge section and BACKUP RESTORE's are read and range-checked
  # before the commit (a refused entry used to leave the new body live
  # with no back edges). Library loads with validate: false skip these
  # rules with the slot rule; the ternary rules always run.

# The slot model.
# Four slot shapes: S1 a duplicate source within one node's six slots, S2
# a slot self-loop (not a back-edge self-loop), S3 a rank inversion (the
# source's rank ≤ the destination's), S4 a slot into a register.
#
# Persistence accepts S1–S3 on every path: SAVE, SAVE COMPRESSED, the
# autosave and the rebase after a load (`wal_base`) write them; LOAD (and DAGDB_STARTUP_LOAD),
# IMPORT MORTON (and its WAL replay), LOAD JSON, LOAD CSV and BACKUP
# RESTORE load them; the writers that never checked slots (SAVE JSON, SAVE
# CSV, EXPORT MORTON, BACKUP INIT / APPEND / COMPACT) are unchanged. They
# all ask ONE persistence rule: a source at or past the node count
# is refused, `node <d> slot <k>: src <s> out of range` (LOAD CSV said
# `node <d>: src <s> out of range` before the slot model); any negative slot is empty.
# TICK_SYNC is defined on these graphs; rank-mode TICK and TICK
# UNTIL_STABLE still refuse S2/S3 by name after every loader (the loaders
# drop the cached verdict); VALIDATE still names S1–S3; EVAL, which once kept no
# such refusal, now refuses S2/S3 as TICK does,
# in TICK's words with its own verb. TILED stays rank-mode: it accepts exactly
# what rank-mode TICK runs. TILED OPEN holds each tile body to the rank-mode
# rule (a source out of range, S2 and S3 refused; S1 accepted — the kernel
# evaluates a duplicate input twice), and SAVE TILED refuses S2 and S3 by
# name, so it never writes what TILED OPEN refuses:
  → ERROR invalid_graph: SAVE TILED refused, validation: <rank-mode TICK's
      words> (a tiled graph is a rank-mode object: TILED OPEN refuses this
      edge); nothing written
#
# S4 is refused everywhere: CONNECT and SET_NEIGHBORS_BULK (above), the
# back-edge loaders (above), LOAD JSON v1 and LOAD CSV without lanes.csv against
# the live list they keep, and the daemon's writers of a state
# holding one (only a log from before the slot model can replay one, below):
  → ERROR schema: LOAD JSON kept back edge entry <i>: <words>; nothing loaded
  → ERROR schema: LOAD CSV kept back edge entry <i>: <words>; nothing loaded
  → ERROR schema: <SAVE|SAVE JSON|SAVE CSV|EXPORT MORTON|BACKUP INIT|
      BACKUP APPEND|SAVE TILED> back edge entry <i>: <words>; nothing
      written; the way out: CLEAR <dst> EDGES (drops the register's
      combinational inputs) or CLEAR <dst> BACK_EDGES (unmakes the register)
  → ERROR schema: BACKUP COMPACT back-edge section entry <i>: <words>;
      nothing written    (RESTORE's rules, below)
  # <words> = CONNECT BACK's: BACK_EDGE dst node <d> has a combinational
  # input at slot <k> (source node <s>); registers must have zero
  # combinational fan-in. The library writers stay permissive.
  # A log from before the slot model: SET_NEIGHBORS_BULK accepted S4 then, and such a
  # record replays as logged (recovery equals what that daemon held), named
  # on the boot's `WAL: applied <k> record(s) as logged that this build
  # refuses live — …` line; the boot then prints `WARN: the recovered
  # state holds <k> slot(s) into a register (S4) …: node <d> slot <k>
  # (source node <s>), …; the way out, per register (…): CLEAR <dst> EDGES
  # … or CLEAR <dst> BACK_EDGES …`. Either verb makes the state one SAVE
  # writes, so a refusal is never a dead end.
  # BACKUP RESTORE also checks the chain's tip against the persistence
  # rule (`ERROR io: backup_restore: invalid diff: validation: …; nothing
  # restored`) and its register flags against its list (a flag no list
  # entry carries — a register nobody latches — is refused by name).
  # BACKUP COMPACT asks the chain's tip RESTORE's rules, in
  # RESTORE's order and words, `nothing written` for `nothing restored`,
  # before it writes or deletes anything: it refuses exactly the chains
  # RESTORE refuses, so compacting never makes a refused chain restorable:
  → ERROR io: backup_compact: invalid diff: register flags: node <d> is
      flagged a register but no back edge in the chain's list ends at it
      (a register nobody latches); nothing written
  → ERROR io: backup_compact: invalid diff: validation: node <d> slot <k>:
      src <s> out of range; nothing written
  # The WAL goes to version 4 in place when an import carrying S1–S3 is
  # logged (data-and-persistence.md); no .dags version changes.
```

Atomic save discipline: tmp → `F_FULLFSYNC` → `replaceItemAt` → dir
fsync. A kill -9 at any point leaves either pre-save state or the
complete new file, never a truncation.

v1 (u8 rank), v2 (u32 rank), v3 (u64 rank), v4 (v3 + back-edge
trailer), v5 (v4 + env-origin trailer), v6 (WGTS lanes), v7 (TWIN
section) and **v8** (the ternary build: a 53-byte-per-node body — the
v3 body plus mode, table id and both thresholds — behind a u64 body
length, `bodyBytes`@28 = 0xFFFFFFFF, and a TERN library section after
WGTS) all load; a v1–v7 file loads as a binary graph (the four
ternary lanes at their defaults, the library empty). **SAVE writes v7**
— byte for byte as before — for a graph with no ternary content (every
node's mode, table id and both threshold bit patterns zero, and an
empty library), **and v8 otherwise**; a binary graph whose v7 body would
not fit v7's u32 length field is written as v8 too.
Every writer refuses, by name and leaving no file, a ternary
state its loader would refuse (mode bits, kind 3, NOSKIP on BINARY, a
table id ≥ the library size, an inverted or non-finite threshold, a
table byte ≥ 3, truth ≥ 3 on a ternary node, a ternary register), and
every loader refuses the same, leaving the engine unchanged.

---

## JSON / CSV

```
SAVE JSON <path>
LOAD JSON <path>      # → OK LOAD_JSON … [wal_base=<startup path>]: as LOAD
  # dagdb-json v2 — every lane: v1's six buffers plus edge weights,
  # activation, node value, back edges, mode, table id, thresholds and
  # the library; f32 lanes as u32 bit patterns (so -0.0 keeps its
  # sign), tables as strings of - 0 +. v1 files still load, as a
  # binary graph. v2 refuses an out-of-range truth by name; v1 still
  # truncates it, as it always did. A v1 file keeps the live back-edge
  # list; the slot model refuses it when its slots give a kept register a
  # combinational input (`kept back edge entry <i>`, above).

SAVE CSV <dir>
LOAD CSV <dir>        # → OK LOAD_CSV … [wal_base=<startup path>]: as LOAD
  # v1's two files, <dir>/nodes.csv + <dir>/edges.csv, unchanged, plus
  # lanes.csv (the v2 marker), weights.csv, back_edges.csv and
  # ttables.csv. A directory without lanes.csv loads as v1.
```

Same atomic-save discipline. Pre-commit validation (the
persistence rule — a source out of range — and the back-edge rules)
blocks tampered files from reaching live buffers.

---

## Backup chain

```
BACKUP INIT    <dir>       # wipe + write base.dags
BACKUP APPEND  <dir>       # write NNNNN.diff vs current tip
BACKUP RESTORE <dir>       # replay base + all diffs
BACKUP COMPACT <dir>       # fold the chain → new base → drop diffs
BACKUP INFO    <dir>       # base presence, diff count, sizes, format
```

XOR diffs per engine buffer, zlib-compressed per segment. Single-bit
mutations typically produce diffs under 5 % of raw snapshot size.

Replies carry the diff format and what a restore actually wrote:

```
OK BACKUP_APPEND bytes=<n> elapsed=<t>ms path=<file> format=<2|3>
OK BACKUP_RESTORE diffs_replayed=<n> elapsed=<t>ms rank_bytes=<8·N> twin=not_covered [wal_base=<startup path>]
OK BACKUP_INFO base=<bool> base_bytes=<n> diffs=<n> total_diff_bytes=<n> format=<v> twin=not_covered
```

`rank_bytes` is the width the restore wrote back — 8 bytes per node,
the engine's u64 rank buffer. `twin=not_covered` is literal: twin
state (streams, rings, clocks, banks, alarms, folds, views) is not in
a backup, and a restore leaves any open twin objects as they are.

**Format 2** (2026-09-12) covers rank (8·N), truth, nodeType, both LUT
halves, neighbours, isRegister, edgeWeights, activation, nodeValue and
the back-edge list. **Format 1** carried six buffers and only 4 of the
8 rank bytes per node, so RESTORE and APPEND refuse such a chain by
name — there is nothing to migrate, the bytes were never written:

```
ERROR io: backup format 1 carries 4 of 8 rank bytes per node and no registers, back edges, weights, activation or node values; cannot restore ranks for nodes N/2..<N; re-create the backup
```

`BACKUP INFO` is read-only: it reports `format=1` and repeats that
sentence as ` caveat=…` instead of refusing.

**Format 3** (the ternary build) is
format 2's segments, then the four ternary lanes as XOR segments —
mode (N), table id (2·N), thrLo (4·N), thrHi (4·N) — then the back-edge
section, then the table library carried whole (729 bytes per table).
`BACKUP APPEND` writes format 3 exactly when the diff has a ternary
part (a lane that changed since the chain's tip, or a library that
differs) and format 2 otherwise, and its reply prints the format it
wrote. Restore applies both, in any mix, in sequence order. INIT and
COMPACT write their base through SAVE's writer, so a base is v7 or v8
by SAVE's rule. `BACKUP INFO`'s `format=` is the FIRST diff's version,
as before the ternary build: a chain of diffs in formats 2, 3, 3
prints `format=2`.

Eight more refusals, each returned as its own sentence:

```
ERROR io: backup diff <seq> segment <name> is <a> bytes, expected <b>
ERROR io: backup diff <seq> segment <name> declares <a> bytes, more than the <max> it can hold (<why>)
ERROR io: backup chain is missing diff sequence <n>; the chain is incomplete
ERROR io: backup chain has two diffs with sequence <n>: <file> and <file>
ERROR io: backup diff <file> already exists; refusing to overwrite
ERROR io: backup diff <file> does not match its sha256 sidecar; the file is corrupt or truncated
ERROR io: backup diff <file> has no sha256 sidecar; re-create the backup
ERROR io: backup diff <seq> back-edge section is <a> bytes, expected <b> for <n> pairs
```

The `declares` refusal comes before a segment is
read or anything is allocated: a library above 65,536 × 729 =
47,775,744 bytes (`(65536 tables × 729 bytes)`), or a back-edge section
or library whose declared size is more than its compressed bytes can
decode to — deflate gives at most 1,032 bytes per compressed byte
(`(its <c> compressed bytes decode to at most 1032 bytes each)`). A
diff cut short inside a segment names it: `invalid diff: <file>:
truncated segment header (segment <name>)`, or `… body (segment
<name>)`.

Diffs apply in the order of the sequence number in their own header,
never in filename order, and each is verified against its `.sha256`
sidecar before it is decoded. `BACKUP COMPACT` writes its new base
from the chain's own replayed tip at the chain's own tick count — it
neither reads nor changes the live engine. A non-finite edge weight or
node value in the base, or in the state any diff leaves, is refused by
name (the diff named) by RESTORE, COMPACT and APPEND alike, before any
of them writes or deletes anything (see Lifecycle).

---

## Secondary index

```
SELECT truth <k> rank <lo>-<hi>
  → matching node IDs written to shm as Int32[],
    OK SELECT truth=<k> rank=<lo>-<hi> matches=<k> shm_bytes=<b>
```

Lazy rebuild on the first `SELECT` after any mutation that changes
`(truth, rank)`. O(log N + matches) lookup. `TICK`, `TICK_SYNC` and
`EVAL` count as such mutations (since the ternary build; before it,
a `SELECT` after a tick answered from the pre-tick truth).

---

## BFS

```
BFS_DEPTHS FROM <seed>                  # undirected (inputs ∪ fanout)
BFS_DEPTHS FROM <seed> BACKWARD         # inputs only
  → writes Int32[nodeCount] to shm; depth[i] = -1 if unreachable
  → OK BFS_DEPTHS seed=<s> dir=<undirected|backward> reached=<r>
    max_depth=<d> elapsed=<f>ms shm_bytes=<4n>
    back_edges=excluded back_edge_count=<b>
  # BOTH walks read the
  # COMBINATIONAL edge table. BACK_EDGEs are tick-boundary latches, not
  # edges the rank order constrains, and the engine evaluates them in a
  # separate phase — so they are EXCLUDED from the walk, and the reply
  # says so and says how many were left out rather than folding a latch
  # into a geodesic distance. `back_edge_count` is the graph's total
  # BACK_EDGE count, not the number on any particular path. A caller
  # that wants the latch edges walks them itself. The reader-session
  # form (`READER <id> BFS_DEPTHS ...`) carries the same two fields.
```

---

## Partition queries

```
ANCESTRY FROM <node> DEPTH <d>
  → reverse BFS bounded by depth; writes (Int32 node, Int32 depth)
    pairs to shm

SIMILAR_DECISIONS TO <node> DEPTH <d> K <k> [AMONG TRUTH <t>]
  → WL-1 histogram L1 distance on each candidate's local ancestral
    subgraph; returns top-K as (Int32 node, Float32 distance)
```

---

## Subgraph distances

```
DISTANCE <metric> <loA>-<hiA> <loB>-<hiB>
  → OK DISTANCE <metric> value=<v> |A|=<nA> |B|=<nB>
```

`<metric>` ∈ `jaccardNodes`, `jaccardEdges`, `rankL1`, `rankL2`,
`typeL1`, `boundedGED`, `wlL1`, `spectralL2`.

Subgraphs are defined by rank range `<lo>-<hi>` (inclusive).

---

### TILED

Tiling, step one (roadmap item 8, 2026-09-10) plus step two, ticking
across tiles. **The TILED family is
NOT a twin registry** — despite the superficially similar
OPEN/…/STATUS/LIST/CLOSE shape, a `TiledGraphRouter` is never
persisted, never WAL-logged, and never part of a snapshot: the tile
directory on disk written by `SAVE TILED` IS the durable state, and
`TILED OPEN` only rebuilds an in-memory view of it (recovering any
dangling flush and completing a partial round first — see "Roles at
open" below). It parses at the DSL top level (not through the twin
verb dispatcher), routers live on the daemon handler (not in
`TwinState`), and its ids are `x%08x` from a handler-local counter — a
different shape from the twin registries' single-letter prefixes, and
unreachable through `dagdb_twin_list`/`dagdb_twin_close`.

```
SAVE TILED <dir> <b1,b2,...>
  # Splits the daemon's OWN current engine (not a saved snapshot) into
  # tile files under <dir> by rank range. Boundaries are ascending
  # rank values, comma-separated, no spaces; at least one required.
  → OK SAVE TILED dir=<dir> tiles=<n> nodes=<N> crossings=<c>
  (empty/unsorted/duplicate boundaries → ERROR bad_value; a BACK_EDGE
  whose src and dst would fall in different tiles under these
  boundaries → ERROR bad_value: back edge crosses a tile boundary
  (<src>→<dst>), checked and refused BEFORE any directory is written;
  guardPath failure or a write error → ERROR io; under the slot model, a slot into
  a register → ERROR schema: SAVE TILED back edge entry <i>: …, and a
  self-loop slot or a rank inversion → ERROR invalid_graph: SAVE TILED
  refused, validation: … — a tiled graph is a rank-mode object)

TILED OPEN <dir> [<K>]
  # Opens a router over <dir>'s manifest.json (written by a prior SAVE
  # TILED). K = max resident tiles, default 2, checked 1...64. Writer
  # role (the only role the daemon opens with): recovers any tile
  # whose last flush crashed mid-way, then completes a partial round
  # left by a between-tiles interruption, BEFORE returning — a torn
  # world is never handed out. Loads no tile bodies until the first
  # query touches them.
  → OK TILED OPEN id=x%08x tiles=<n> nodes=<N> resident_max=<K>
    recovered=<n> completed=<m>
  # Since 2026-09-12 OPEN also refuses, by
  # name: a manifest whose `format`/`version` are not this reader's; a
  # tile whose manifest / meta.json / body.dags node counts disagree
  # (checked before any engine is allocated); a manifest entry whose
  # engineIndexOf is the wrong length or names an index outside the
  # graph; and a tile whose flush.wal ends in a TORN record (a
  # half-written line, an unknown verb, a three-field BEGIN, or a BEGIN
  # at epoch 0) — that last used to read as "clean" and the tile loaded.
  (K out of range → ERROR out_of_range; missing/corrupt manifest, or
  an unresolvable tear → ERROR io)
  → ERROR gpu: TILED OPEN: command buffer status <status> (…) at tile <t>
    epoch <k>; nothing claimed: … (the same tail as TILED TICK's below)
  # A recovery or round-completion tick whose
  # command buffer did not complete. That tile is not flushed, no router
  # is opened, and the next TILED OPEN tries again.
  # Before recovery or completion writes
  # anything, every tile they will load is loaded once and discarded; a
  # refused load (an older build's tile body holding S2/S3, refused by the
  # rank-mode rule) replies ERROR io by name with every file unchanged.
  # In earlier builds a completion reaching the refused tile second had
  # already flushed the first.
  # Recovery and completion are then planned whole against
  # the files before the first write, so every refusal they could raise
  # after an earlier write is raised first, by name, every file unchanged,
  # and counted in STATUS tiled_refused: a pending tile's body at neither
  # its BEGIN's epoch nor the one before; a strip the re-tick or a
  # register's pre-latch byte reads that is stale, missing or unreadable; a
  # re-flush epoch past body.dags's 32-bit field; a crossingsIn local past a
  # tile's node count; completion's mode at the max epoch (mismatch, or
  # none); and completion's ghost refusals (as TILED TICK's below).
  → ERROR io: TILED OPEN: [recovery of|completion of] tile <t> epoch <k>:
    the write step '<step>' failed (<error>); nothing after it written;
    <what tile t's files hold and what a writer TILED OPEN does>; tiles at
    epoch <k>: <m> of <tiles>; epoch=<min>/<max>[ (torn: …)]
  # A recovery or completion write step that failed (an I/O
  # error). No router is opened; the next TILED OPEN recovers again. A
  # recovered tile's flush.wal now ends BEGIN k, COMMIT k (case (i) re-flushes
  # under the dangling BEGIN; it used to append a second), and case (ii)
  # writes the body's sidecar a crash between the rename and the sidecar left
  # out, so a recovered tile's files equal a never-failed tile's.
  # A tile's flush.wal record is one write(2); a last record
  # with no newline (a kill inside that write) never started its step, so a
  # writer TILED OPEN reads the wal without it and, once its plan has passed,
  # cuts it (the file removed when nothing is left) before recovering
  # (a failed cut: … the write step 'flush.wal cut' failed …, nothing
  # written). Every other malformed wal is still refused by name, and so is
  # a torn last record at a tile load outside a writer open.
  → ERROR io: TiledGraphRouter: tile <t> flush.wal cannot be read
    (<call> flush.wal: errno <e> (<text>)); refused, nothing written
  # A flush.wal present but unreadable (a permission, an I/O
  # error) is refused by name, counted in STATUS tiled_refused; it used to
  # read as clean, so a dangling BEGIN went unseen and its tile was re-ticked
  # under a second BEGIN.

TILED BFS <id> <globalId> <depth> [BACK]
  # Cross-tile BFS (undirected, default) or ancestry (BACK,
  # inputs-only), level-synchronous across tile boundaries — depth
  # 0...12. <globalId> is the packed GlobalNodeID (raw u64: 24-bit
  # tile id high, 40-bit local node id low), NOT a plain engine index.
  # shm: [u32 count][u32 rowSize=16] header, then 16-byte rows (u64
  # global id, u32 depth, 4 pad).
  → OK TILED BFS id=<id> seed=<globalId> depth=<d> back=<0|1>
    count=<n> loads=<n> evicts=<n>
  (unknown id → ERROR not_found; depth < 0 → ERROR bad_value; depth >
  12, or a torn tile body's sha256 mismatch → ERROR io, and the
  refusal is also recorded in TILED STATUS)

TILED SELECT <id> <truth> <lo> <hi>
  # Cross-tile truth/rank-range select — every tile whose span could
  # overlap [lo, hi] is loaded and queried against its own secondary
  # index. shm: [u32 count][u32 rowSize=8] header, then sorted u64 ids.
  → OK TILED SELECT id=<id> truth=<t> lo=<lo> hi=<hi> count=<n>

TILED STATUS <id>
  → OK TILED STATUS id=<id> resident=<n>/<K> loads=<n> evicts=<n>
    refused=<n> last=<error|none> epoch=<min>/<max>
  # loads=/evicts= are ROUTER-WIDE counters, not per-session: any
  # session's query moves them, a READER session's and the web
  # bridge's included. They report the router's residency cache, not
  # the caller's work.
  # epoch is the (min, max) world tick over every tile's own
  # last-flushed epoch (the router holds no global counter) — equal
  # except mid-recovery; a router the daemon opened is never torn.
  # Since 2026-09-12 `resident`
  # and the router's high-water mark count the TICKING path's resident
  # set as well as the query path's, and the ticking path's refusals
  # are recorded in `refused`/`last`. A router mid-tick used to report
  # zero residency and no refusals at all.
  # Every refused tile load is counted, whatever
  # refused it (the load's own validation too: a body the rank-mode slot
  # rule refuses used to leave refused=0 last=none), on the tick, query
  # and pre-flight paths. A tile id the manifest does not hold is not
  # counted (TILED GET answers it as out of range).

TILED LIST        → OK TILED LIST count=<n> [id@dir=... tiles=... nodes=... resident_max=... ...]
TILED CLOSE <id>  → OK TILED CLOSE id=<id> open=<n>
  # Nothing to flush — the tile directory on disk is already the
  # durable state.

TILED TICK <id> [<n>] [SYNC]
  # Advances the world <n> ticks (default 1, checked 1...10000), rank
  # mode unless SYNC trails. Durable: every tile is ticked and flushed
  # to disk every round (BEGIN <tile> <epoch> <rank|sync>, body, halo
  # strip, meta, manifest entry, COMMIT, in that order), so a crash
  # mid-flush is detected and recovered the next time the directory is
  # opened.
  → OK TILED TICK id=<id> ticks=<epoch after> tiles_ticked=<n>
    loads=<n> evicts=<n> flushes=<n> halo_bytes=<n>
  (n out of range → ERROR out_of_range; unknown id → ERROR not_found;
  a router error — a stale halo strip that couldn't regenerate, a
  manifest/sidecar sha256 disagreement on a clean tile, a tile epoch
  that would not fit body.dags's 32-bit tick field (refused at flush
  since 2026-09-12, rather than truncated — widening that header field
  is a separate change to the core format), a partial-round
  mode disagreement — → ERROR io)
  → ERROR gpu: TILED TICK: command buffer status <status> (<error | no
    error object>) at tick <i> of <n>, tile <t> epoch <k>; nothing
    claimed: tile <t> not flushed (its files unchanged), its engine
    dropped; tiles at epoch <k>: <m> of <tiles>; epoch=<min>/<max>
    [(torn: a writer TILED OPEN completes the round)]; total=<min>
  # After every tile's tick the router reads the
  # tile engine's command-buffer status. Any status but
  # completed stops the verb: that tile is not flushed and its epoch does
  # not move; its in-memory engine is dropped, so its next tick reloads
  # it from its unchanged files. total= is the epoch every tile has
  # committed. When the failed tile is not the round's first, the tiles
  # before it have already flushed at <k>: the world is torn, exactly as
  # a crash between tiles leaves it. TILED TICK then refuses it (ERROR io:
  # world torn), and a writer TILED OPEN completes the round.
  # Before the first round advances any
  # tile, every tile not already resident is loaded once and discarded,
  # exactly as its round would load it (not counted in loads=). Tile
  # bodies are held to the rank-mode rule in BOTH modes (a tiled graph is
  # a rank-mode object), so SYNC refuses an older build's S2/S3
  # tiles too; the refusal (ERROR io: validation: …) now comes before any
  # tile advances, every file and epoch unchanged, and is counted in
  # TILED STATUS. In earlier builds the tiles ahead of the bad one in the
  # round had flushed first: a torn directory.
  # Then the call is planned against the files before the
  # first write, so what a later tile's turn would refuse is refused first,
  # by name, every file and epoch unchanged, counted in TILED STATUS: a
  # ghost whose source tile is not in the manifest or whose source local the
  # source's strip does not carry (ERROR io: … crossing names tile <s> local
  # <l>: …; refused before any tile is written — an in-range local used to be
  # served from the resident buffer in rank mode at K >= 2 and refused at
  # K = 1), or past the source's node count (… tile <s> outside tile-id
  # space); in rank mode a source tile not above
  # its reader (the strip regeneration's haloStale); a source strip the
  # call's first SYNC round reads that is missing or malformed (ERROR io: …
  # tile <s>'s halo_lower.<p>.bin cannot be read (…)) or stale and not
  # regenerable; a crossingsIn local past a tile's node count; a later world
  # tick of the call whose epoch passes body.dags's 32-bit field.
  → ERROR io: TILED TICK: tile <t> epoch <k> at tick <i> of <n>: the write
    step '<step>' failed (<error>); nothing after it written; <what tile
    t's files hold and what a writer TILED OPEN does>; tiles at epoch <k>:
    <m> of <tiles>; epoch=<min>/<max>[ (torn: a writer TILED OPEN recovers
    and completes the round)]
  # A flush step that failed (an I/O error). <step> is the
  # file it writes: flush.wal BEGIN, body.dags.tmp, body.dags rename,
  # body.dags.sha256, halo_lower.<p>.bin, meta.json, manifest.json,
  # flush.wal COMMIT (or a source strip's regeneration). Every step is
  # whole or not at all: the wal record appended whole or cut back, the
  # body a renamed tmp, strip/meta/manifest a renamed temp file; the body's
  # sidecar is checked after the save (its write failure used to be
  # swallowed and the tile committed without it). The router then refuses
  # TILED TICK (ERROR io: … flush incomplete …) until a writer TILED OPEN
  # recovers the tile, after which every tile's files equal its pre- or
  # post-round files.
  # Those refusals (… flush incomplete at epoch <k> …,
  # … world torn …, and a wal this router could not cut back) are counted in
  # TILED STATUS like every other (refused=, last=tile <t>: the pending or
  # torn tile; for a torn world the lowest tile below the max epoch).

TILED GET <id> <globalId> TRUTH
  # One node's current truth byte, decimal — a cheap readback that
  # doesn't need a BFS/SELECT.
  → OK TILED GET id=<id> node=<globalId> truth=<0|1|2>
  (no such node → ERROR out_of_range; unknown id → ERROR not_found)
```

**Roles at open.** A mixed-epoch ("torn") tiled world must never
answer a query — BFS/SELECT over tiles at different epochs would be a
tear with no name on it. `TiledGraphRouter.init(role:)` is `.writer`
(the daemon's `TILED OPEN`, and the library default) or `.reader`. A
writer recovers any dangling flush and completes any partial round
before returning, so its world is never torn when it starts answering
or ticking; a reader refuses to open at all over a torn world
(`RouterError.worldTorn`) rather than fixing anything. The daemon only
ever opens writer routers — `TILED OPEN`'s reply always carries what
that open did (`recovered=`/`completed=`).

**STATUS.** The daemon's own `STATUS` line carries `tiled_open=<n>`
alongside `twin_open=<n>` — open routers are counted separately and do
NOT add to `twin_open` (they aren't a twin registry entry).

**Reader allowlist.** `TILED BFS`, `TILED SELECT`, `TILED STATUS`,
`TILED LIST`, and `TILED GET` are read-only and permitted inside
`READER <id> …` (routers are daemon-global, like twin state, so a
reader session may query the same routers the primary path opened).
They DO move the router's tile residency and its `loads=`/`evicts=`
counters — tile residency is a cache, not graph state, which is why
they stay allowed, and why `TILED STATUS`'s counters are documented
above as router-wide;
`TILED OPEN`, `TILED CLOSE`, `SAVE TILED`, and `TILED TICK` mutate the
router registry, the filesystem, or (TICK) flush every tile to disk,
and are forbidden there.

**Not done**: the pre-fetch thread (optional; it would change no
result), the cold tier, thermal pauses, the
10¹¹-node run, `TILED BACKUP`.

---

## Twin primitives

The seven twin-spec primitives (`NamedStream`, `StreamHeader`,
`StreamRecord`, `BudgetLayout`, `CrossConvolutionCheck`, `GearedRings`,
`MasterClock`/`PhaseGear`) plus the alarm-stream court types
(`AlarmRecord`, `SealedCourt`, `AlarmFixture`, `CorruptionModel`,
`SuccessorCourt`, `AllocatorCourt`) landed over the
daemon socket in the interface phase (2026-09-06). Five more families
followed on 2026-09-10: a tenth, `BANK` (the waveform mouth, § below);
an eleventh, `VIEW` (alarm-set derived views, § below); a twelfth,
`FOLD` (the tier ladder, § below); a thirteenth, `KERNEL` (per-path
kernel storage, § below), plus a second entry point on the pre-existing
`XCONV` family (`XCONV SEALED`, beside `XCONV CHECK`); and a
fourteenth, `HOOK` (the sealed allocator court as a ticked
process, roadmap item 7, § below).
Fourteen verb families dispatch through one `TwinCommand` grammar
(`dagdb/Sources/DagDBDaemonKit/TwinCommand.swift`,
`DSLParser+Twin.swift`, `DagDBCommandHandler+Twin*.swift`) — `FOLD` is
the one family that mints no registry entry and writes no WAL: every
verb is a pure read of the engine's current lanes.

Every mutating verb follows the WAL-first pattern used elsewhere in
this daemon: validate → mint an id → append to the WAL (abort on
failure, registry untouched) → apply → reply. State lives in one
**daemon-global** `TwinState` (§ below) — there is no per-connection
twin state, unlike `OPEN_READER`'s snapshot-on-read sessions.

### Id prefixes

Every twin id is `"<letter>%08x"` of a per-registry counter that never
reuses a value:

| Prefix | Registry |
|---|---|
| `s` | stream (`NamedStream`) |
| `t` | record (`StreamRecord`) |
| `n` | rings (`GearedRings`) |
| `c` | clock (`MasterClock`) |
| `g` | gear (`PhaseGear`) |
| `b` | budget layout (`BudgetLayout`) |
| `a` | alarm set (`AlarmFixture`) |
| `w` | wave bank (`WaveBank`) |
| `v` | view set (`DerivedViews` over a loaded `CortexFixture`) |
| `k` | kernel pair (`KernelPair`) |
| `h` | attention hook (`AttentionHook`) |

### STREAM / HEADER / RECORD

```
STREAM OPEN <name> <stateHi> <stateLo> <incHi> <incLo>
  → OK STREAM OPEN id=<id> name=<name> draws=0

STREAM NEXT <id> <n>   (1 <= n <= nodeCount*3)
  → shm [u32 count][u32 8][u64 x count]; then
    OK STREAM NEXT id=<id> n=<n> draws=<d> state=0x<hi>:0x<lo> shm_bytes=<8n>
  # WAL logs the POST-draw state (.streamState), not the draw count —
  # replay restores the boundary in O(1), it never redraws.

STREAM STATE <id>
  → OK STREAM STATE id=<id> name=<name> draws=<d> state=0x<hi>:0x<lo>

STREAM CLOSE <id>  →  OK STREAM CLOSE id=<id>
STREAM LIST        →  OK STREAM LIST count=<n> [id id ...]

HEADER CHECK <band> <tau> <comb> <echo> <record> <step> <floor>
  → OK HEADER CHECK admissible=1
    | FAIL HEADER CHECK violations=<k> <tag>;<tag>...
  # a non-finite field returns ERROR bad_value instead of FAIL
  # The count and the tags cover the
  # CLOCK-SYNC half of the judgement too, so this verb and RECORD OPEN
  # answer the same header the same way. In earlier builds a floor coarser
  # than the step, or one reaching the record window, was answered
  # `admissible=1` here and refused by RECORD OPEN. The two extra tags:
  #   floorAboveStep(<floor>,<step>)
  #   floorOutlivesRecord(<floor>,<window>)
  # A single-clock stream declares floor 0 and is unaffected.

RECORD OPEN <name> <7 header numbers> <stateHi> <stateLo> <incHi> <incLo>
  → OK RECORD OPEN id=<id> name=<name> slices=0
    (inadmissible header → ERROR schema: inadmissible header: <tags>)
    (quantity 7, the clock sync floor, is now COMPARED as well as
     declared: a floor above the integrator step, or one reaching the
     record window, → ERROR schema: inadmissible clock sync floor: ...
     A single-clock stream declares 0 and is unaffected.)

RECORD SLICE <id> <count>   (1 <= count <= nodeCount*3, and <= 10000)
  → OK RECORD SLICE id=<id> index=<i> count=<count> slices=<total>
    (a count above the replay cap of 10000 → ERROR bad_value: count <n>
     not in 0...10000 — the same ceiling the WAL replay of this verb
     applies, so a record that replays is a record that could have been
     written)

RECORD REPLAY <id> <index>
  → shm [u32 count][u32 8][u64 x count]; then
    OK RECORD REPLAY id=<id> index=<i> count=<c> match=<0|1> shm_bytes=<8c>

RECORD VERIFY <id>
  → OK RECORD VERIFY id=<id> failing=<k>[ failing_indices=<i,j,...>]

RECORD INFO <id>   → OK RECORD INFO id=<id> name=<name> slices=<n> draws=<d>
RECORD CLOSE <id>  → OK RECORD CLOSE id=<id>
RECORD LIST        → OK RECORD LIST count=<n> [id id ...]
```

### RINGS / CLOCK / GEAR

```
RINGS OPEN <gear> <rings> <cells>
  → OK RINGS OPEN id=<id> gear=<g> rings=<r> cells=<c> capacity=<r*c>
    (shape violation — gear<2, rings outside 1..16, cells outside
    2..4096, or a gear whose gear^(rings-1) overflows UInt64 (the
    coarsest span would wrap to zero and the next write would divide by
    it) — → ERROR bad_value: <reason>)

RINGS WRITE <id> <v1> [<v2> ...]
  → OK RINGS WRITE id=<id> n=<count> now=<tick>

RINGS RECALL <id> <lag>
  → OK RINGS RECALL id=<id> lag=<lag> value=<f> tick=<t> ring=<r> span=<s>
    | OK RINGS RECALL id=<id> lag=<lag> value=none   (lag beyond every horizon)

RINGS INFO <id>   → OK RINGS INFO id=<id> gear=<g> rings=<r> cells=<c> capacity=<cap> now=<tick>
RINGS CLOSE <id>  → OK RINGS CLOSE id=<id> open=<remaining>
RINGS LIST        → OK RINGS LIST count=<n> [id id ...]

CLOCK OPEN  → OK CLOCK OPEN id=<id> tick=0

CLOCK ADVANCE <id> [<n>] [VALUE <f>]
  → OK CLOCK ADVANCE id=<id> n=<n> tick=<t> gears=<count>
    (n above the replay cap of 10000 → ERROR bad_value: n <n> not in
     0...10000)
  # n ticks + value logged as ONE WAL record (§ below) — replay re-runs
  # the same count-tick loop, it does not replay tick by tick, so live
  # and replayed gear fires/latchedTick/latchedValue agree exactly. The
  # cap matters because the record is 20 bytes and the work it commands
  # is n: replay applies the same 10000 ceiling.

CLOCK STATE <id>  → OK CLOCK STATE id=<id> tick=<t> gears=[<id,id,...>]
CLOCK CLOSE <id>  → OK CLOCK CLOSE id=<id> gears_closed=<n>   (cascades)
CLOCK LIST        → OK CLOCK LIST count=<n> [id id ...]

GEAR OPEN <clockId> <name> <num>/<den>
  → OK GEAR OPEN id=<id> clock=<clockId> name=<name> ratio=<p>/<q>
    (reduced via GearRatio.reduced; both terms must be > 0)

GEAR STATE <id>
  → OK GEAR STATE id=<id> name=<name> ratio=<p>/<q> fires=<n>
    phase=<a>/<q> latched_tick=<t|none> latched_value=<f|none>

GEAR CLOSE <id>  → OK GEAR CLOSE id=<id>
  # closing a gear prunes it from its owning clock's gearIds first, so a
  # later CLOCK ADVANCE never trips on a stale gear id.
```

### XCONV / BUDGET

`XCONV CHECK` is DEPRECATED (2026-09-10): not a court check; flags every
true recording at the court's tolerance (50/50). It stays wired
for compatibility. `XCONV SEALED` (§ KERNEL, below) is the
standing cheap check.

```
XCONV CHECK <nA> <nB> <kA> <kB> <warmup>
  # shm in: [u32 nA+nB+kA+kB][u32 0x314D480A] at bytes 0..7 (Input
  # frames, above), then f32 vectors back to back at offset 8: recordA(nA), recordB(nB),
  # kernelA taps(kA), kernelB taps(kB)
  → OK XCONV CHECK residual=<d> compared=<n>
    (input past shm capacity → ERROR out_of_range)
  # Two corrections, 2026-09-12. `compared` is now bounded by the RECORDS — min(nA, nB)
  # minus the warmup — where it used to run taps−1 samples past the end
  # of the shorter recording, over the convolution tail. And a warmup at
  # or past that window is REFUSED rather than clamped: `compared` is 0
  # and `residual` is inf, where the clamp used to report residual 0 and
  # a check that had compared nothing passed every tolerance.

BUDGET OPEN <nPockets> <nTiers> <nClasses>
  # shm in: [u32 nPockets*nTiers+nClasses][u32 0x314D480C] at bytes
  # 0..7 (Input frames, above), then at offset 8: f64 cost[nPockets][nTiers] row-major, then
  # u32 minTier[nClasses]
  → OK BUDGET OPEN id=<id> pockets=<p> tiers=<t> classes=<c>
    (ragged/NaN/oversized → ERROR bad_value | ERROR out_of_range)

BUDGET SEALED
  → OK BUDGET SEALED id=<id> pockets=4 tiers=8 classes=2
    (opens SealedCourt.makeLayout() — the frozen 4x8 tariff table,
    minTier [4, 1])

BUDGET ALLOCATE <id> <budget> <pocket>:<class> [<pocket>:<class> ...]
  → OK BUDGET ALLOCATE id=<id> value=<v> cost=<c> served=<p,p,...>
    purchases=<pocket:tier:cost:readValue,...>
    (bad pocket/class index or too many claimed pockets → ERROR out_of_range)

BUDGET INFO <id>   → OK BUDGET INFO id=<id> pockets=<p> tiers=<t> classes=<c>
BUDGET CLOSE <id>  → OK BUDGET CLOSE id=<id> open=<remaining>
BUDGET LIST        → OK BUDGET LIST count=<n> [id id ...]
```

### ALARM

```
ALARM LOAD <path> [SHA <hex64>]
  # guardPath() rejects traversal / outside-DATA_ROOT paths before any
  # file I/O. The loaded fixture's OWN computed sha256 (not the caller's
  # optional SHA argument) is what gets WAL-logged and later verified on
  # restore.
  → OK ALARM LOAD id=<id> records=<n> control=<0|1> sha256=<hex>
    quiet=<n> liar=<n> deep=<n> drift=<n> ears=A<n>/B<n>/C<n>
    (missing file, sha mismatch, malformed/unknown-class entry — every
    case → ERROR io: ...; a sha mismatch line always contains the
    literal phrase "sha256 mismatch")

ALARM INFO <id>   → OK ALARM INFO id=<id> path=<p> records=<n> sha256=<hex>
ALARM LIST        → OK ALARM LIST count=<n> [id id ...]
ALARM CLOSE <id>  → OK ALARM CLOSE id=<id>

ALARM FRAME <id> <idx>   (1 <= idx <= records.count)
  → OK ALARM FRAME id=<id> idx=<i> key=<k> class=<raw> ear=<A|B|C|-)
    label=<label|-> pocket=<p|-> burst=<0|1>

ALARM COURT <id> <budget>
  → OK ALARM COURT id=<id> B=<budget> misses=<m> served=<s> cost=<c>
    dummy=<d> dominated=<dm> burst=<served>/<missed>/<total>
  # runs AllocatorCourt.run and reports the allocator arm

ALARM SUCCESSOR <id> <budget> <epsM> <epsS> <epsN>
  → OK ALARM SUCCESSOR id=<id> B=<budget> misses_alloc=<ma>
    misses_greedy=<mg> cost_alloc=<ca> cost_greedy=<cg> weight_dev=<d>
    missing_class_counts=<n>
    (a knob outside [0,1] or non-finite → ERROR bad_value)
    (a fixture whose counts omit a label declared in classSpecs →
     ERROR out_of_range: missing class count <label>)
  # The per-class
  # expectations are scaled by the loaded fixture's own class counts;
  # a label declared in `classSpecs` but absent from that table used to
  # contribute zero silently, making the totals short by a whole class.
  # The counts are validated first and the FIRST missing label, in
  # declaration order (liar_A, liar_B, liar_C, deep, drift, then
  # quiet), is named. `missing_class_counts` is therefore 0 on every OK
  # line; it is printed so a caller reads the fact rather than assumes
  # it.

ALARM CORRUPT <id> <idx> <epsM> <epsS> <epsN>
  # shm out: [u32 count][u32 rowSize=40] header at offset 0, then
  # `count` 40-byte rows at offset 8, each:
  #   f64 weight | u32 nClaims | u32 reserved0 |
  #   5 x (u8 pocket, u8 row(0=L,1=D), u8 phantom, u8 pad) | 4 pad
  → OK ALARM CORRUPT id=<id> idx=<i> outcomes=<n> weight_sum=<w>
    shm_bytes=<40n> claims_truncated=<t>
  # w sums to exactly 1.0 over the full enumeration
  # The row holds 5 claim slots while `nClaims` carries the TRUE
  # count, so a wider outcome would be lossy. `claims_truncated=<t>`
  # is how many rows lost a claim. Under the sealed model it is
  # always 0 — the widest outcome is 4 phantom pockets plus the
  # branch claim, exactly 5 — but the reply states it rather than
  # leave the reader to assume it.
  # The rows are size-checked against the mapping before any is
  # written; too many for this daemon's shm is an out_of_range
  # refusal, not an overrun.
```

### BANK

The waveform mouth (2026-09-10): one frozen `WaveBank` — a T×K matrix Φ of
unit-norm atoms (harmonic cos/sin columns, then Gabor atoms on a
center/frequency grid) — per open id. `GENERATE` is one matrix product
W = Φ·C; `FIT` is a least-squares solve for the coefficients that best
reproduce a target waveform in the bank's span; every bank declares
its own rank and condition number at OPEN and on INFO.

```
BANK OPEN <name> [<T> <fs> <f0> <H> <centers> <freqs> <sigmaFrac> [ALIASED]]
  → OK BANK OPEN id=<id> name=<name> T=<T> K=<K> atoms_bytes=<T*K*4>
    rank=<int> cond=<d> rank_deficient=<0|1>
  # No numbers ⇒ WaveBank.Spec.referenceNyquistSafe, the repaired bank
  # (T=4096, fs=3000, f0=60, H=24, centers=8, freqs=6, sigma_frac=0.02,
  # K=144, rank=144). All seven numbers or none; K = 2*H + 2*centers*freqs
  # is derived, not passed. A spec whose top harmonic reaches or exceeds
  # Nyquist (H*f0 >= fs/2) is refused — ERROR bad_value naming the first
  # aliasing harmonic and its frequency — unless the line ends ALIASED
  # (the library itself builds either spec unconditionally; only the
  # daemon gates). The sealed 160-atom CONTROL bank (H=32 at the
  # reference rates) needs its seven numbers plus ALIASED and prints
  # K=160 rank=146 — 14 of its atoms alias above Nyquist.
  # (spec doesn't admit a bank → ERROR bad_value: <reason>)
  # Since 2026-09-12 the
  # Nyquist refusal covers EVERY atom family, not the harmonics alone:
  # the highest Gabor centre (fs/4 by construction) plus that atom's
  # bandwidth 1/(2*pi*sigma_t) is tested against fs/2 under the same
  # ALIASED opt-out. Both sealed specs stay clear of it — at the
  # reference rates the bandwidth is about 5.8 Hz against a 750 Hz grid
  # top — so no reply above changes. The harmonic the message names is
  # also clamped into 1...H: for H*f0 exactly at fs/2 it used to name
  # harmonic H+1, an atom the bank does not contain.

BANK GENERATE <id> <M>
  # M is bounded by the library's declared ceiling of 100 000 columns
  # (the clamp `BANK BENCH` always applied); above it the product is
  # refused by name rather than sized — past 2^31 the BLAS argument
  # conversion trapped, and below it the T*M allocation was unbounded.
  # A coefficient count other than K*M is likewise named, not silently
  # answered with an empty vector.
  # shm in: [u32 K*M][u32 0x314D480D] at bytes 0..7 (Input frames,
  # above), then f32 C[K*M] at offset 8, row-major K×M (C[k*M+m])
  # shm out: [u32 T*M][u32 4] header, then f32 W, T*M values row-major
  # (W[t*M+m])
  → OK BANK GENERATE id=<id> T=<T> M=<M> samples=<T*M> elapsed_ms=<f>
    (input 8+K*M*4 or output 8+T*M*4 past shm capacity → ERROR out_of_range)
    (a column count above the ceiling, or a coefficient count other
     than K*M → ERROR bad_value: BANK GENERATE refused: <reason>)
  # The handler goes through the library's
  # THROWING door (`generateChecked`). Before that, the non-throwing
  # `generate` wrote its named reason to the daemon's stderr and handed
  # back an empty vector, which this verb printed under an `OK` line —
  # a refusal a socket client could not see.

BANK FIT <id>
  # shm in: [u32 T][u32 0x314D480E] at bytes 0..7 (Input frames,
  # above), then f32 x[T] at offset 8
  # shm out: [u32 K][u32 4] header, then f32 coefficients, K values
  → OK BANK FIT id=<id> residual=<d> norm=<d> coefficients=<K>
  # residual = ‖x − Φc*‖₂ / ‖x‖₂, both norms Double; norm = ‖x‖₂
    (input 8+T*4 past shm capacity → ERROR out_of_range)

BANK NOISE <id> <seed> <n>   (seed >= 0; 1 <= n <= 200)
  → OK BANK NOISE id=<id> n=<n> expected=<d> mean=<d> min=<d> max=<d>
  # n probes of the engine's own Gaussian noise (PCG stream advanced by
  # `seed` draws, then 2*T*i per probe i), each fit against the bank;
  # expected = sqrt(1 - K/T), the out-of-bank law

BANK BENCH <id> <M> <reps>   (M clamped [1,100000]; reps clamped [1,20])
  → OK BANK BENCH id=<id> M=<M> reps=<reps> best_ms=<f> samples_per_s=<f>
  # best of `reps` timed GENERATE calls, one untimed warm-up first

BANK INFO <id>
  → OK BANK INFO id=<id> name=<name> T=<T> fs=<fs> f0=<f0> H=<H>
    centers=<c> freqs=<f> sigma_frac=<frac> K=<K> rank=<int> cond=<d>
    rank_deficient=<0|1>
  # rank/cond recomputed fresh on every call (~10 ms at 4096x160)
  # `rank_deficient` is
  # the library's stricter reading of its own declaration: 1 when the
  # smallest singular value sits at or below the rank threshold
  # (sigmaMax * 1e-9), so `cond` is a finite number that states nothing
  # useful about the bank. It is DISCLOSED, not refused: the sealed
  # 160-atom control bank is deliberately rank deficient (146 of 160)
  # and its `rank=146` is pinned by a test. The repaired default bank
  # prints `rank_deficient=0`. What IS refused, through the throwing
  # door, is a declaration whose LAPACK solve failed or whose smallest
  # singular value is zero or non-finite — the numbers then mean
  # nothing at all:
  #   ERROR bad_value: BANK OPEN refused: <reason>
  #   ERROR bad_value: BANK INFO refused: <reason>

BANK LIST        → OK BANK LIST count=<n> [id id ...]
BANK CLOSE <id>  → OK BANK CLOSE id=<id>
```

The `8 + K*M*4` (GENERATE input) and `8 + T*M*4` (GENERATE output)
capacity rule is the same shm-fits check every twin verb with a shm
payload uses; both are checked before the product runs, so an
oversized request never partially writes.

### VIEW

Added 2026-09-10: three
alarm-set derived views over the sealed cortex v4 world — reflex,
geometry-then-energy rung, and arrival-geometry ceiling — one loaded
fixture per open id. Grammar mirrors `ALARM`'s LOAD/INFO/LIST/CLOSE
shape; `REFLEX`/`RUNG`/`CEILING`/`FEATURES` are new, pure reads over
the loaded `DerivedViews` (no WAL, no mutation).

```
VIEW LOAD <path> [SHA <hex64>]
  # guardPath() rejects traversal / outside-DATA_ROOT paths before any
  # file I/O. The loaded fixture's OWN computed sha256 (not the
  # caller's optional SHA argument) is what gets WAL-logged and later
  # verified on restore — mirrors ALARM LOAD.
  → OK VIEW LOAD id=<id> train=6966 test=300 stations=8 samples=64
    candidates=129 sha256=<hex>
    (missing file, sha mismatch, malformed npz layout — every case →
    ERROR io: ...; a sha mismatch line always contains the literal
    phrase "sha256 mismatch")
  # Since 2026-09-12 the
  # library's `CortexFixture.load` DEFAULTS its sha pin to the sealed
  # constant, so a caller that names no sha gets the pin the type
  # promises; passing nil is an explicit opt-out that prints
  # `WARN unpinned fixture` once. The npz reader also refuses, by name:
  # an .npy major version other than 1, 2 or 3 (every other value used
  # to be parsed as if it were v2) and any minor other than 0; a
  # negative or overflowing shape component (the product is a
  # non-wrapping multiply and used to trap); and zip64 placeholders in
  # the end-of-central-directory or a central record. The daemon's own
  # reply lines are unchanged — it always passes its SHA argument.

VIEW REFLEX <id> <S>   (1 <= S <= 8)
  # The daemon's guard is the LIBRARY's
  # (`DerivedViews.checkStations`), so the two cannot drift apart about
  # what S a fixture admits. The refusal keeps its wording and gains the
  # library's own named reason after an em dash:
  #   ERROR out_of_range: S <s> not in [1, <stations>] — stations <s>
  #   exceeds the fixture's own station count <stations>
  # It applies to REFLEX, RUNG, CEILING and FEATURES alike. Underneath it the
  # library gained the same bound: every `DerivedViews` entry point refuses a station count
  # outside 1...fixture.stations by name — above it, `tau[c*stride + s]`
  # read silently into the NEXT candidate's row for every candidate but
  # the last, and the frame index then trapped. Three more: a candidate
  # whose least-squares fit FAILS is now skipped and counted (`skipped=`
  # on the decision, `skippedTotal` on the summary) instead of being
  # scored from a fabricated (alpha, beta) = (0, 0) that could win the
  # tie-break; a non-finite k = 1/(speed*dt*os) refuses instead of
  # making every class size 1 and the ceiling 1.0; and the 16-sample
  # front window's zero-filled convention at the end of a record is now
  # gated as a control against the short-window convention. On the
  # sealed fixture nothing is skipped and no sealed number moves.
  # Per station s in 0..<S: arrival = first index |x_s| > 0.25*max|x_s|
  # on the S-station slice, re-zeroed. Per candidate: 2-parameter
  # least-squares fit (alpha, beta) over normalized tau (global
  # tau_max), alpha clipped at 0 after the fit; tie rule
  # r <= r_min + 1e-9*max(1, r_min); winner = lowest tied index.
  → OK VIEW REFLEX id=<id> S=<S> reflex=<n> oracle=<n> tie_min=<n>
    tie_median=<d> tie_max=<n> frames_with_tie=<n> near_edge=<n>
  # the tests pin reflex/oracle/tie_*/frames_with_tie to the sealed
  # reference values; near_edge, the number of candidate residuals within
  # 10x the tie tolerance of the tie edge summed over the frames, is
  # printed only

VIEW RUNG <id> <S>
  # Reflex tied set resolved by nearest standardized-feature class
  # centroid (Euclidean; exact-distance ties keep the lowest index),
  # over 3*S front-aligned energy features standardized with the 6966
  # train frames' (mean, std) pairs (one per station/channel, std
  # floored at 1e-12, never pooled). Centroids recomputed on every
  # call.
  → OK VIEW RUNG id=<id> S=<S> hits=<n> min_margin=<d>
  # the tests pin hits to the sealed reference value; min_margin is
  # printed only

VIEW CEILING <id> <S>
  # k = 1/(SPEED*dt*OS); A = k*tau_raw[:, :S], row-shifted by its min.
  # Exact-twin pairs: max-norm < 1e-9. Identifiable classes: unique +
  # groups under the max-norm < 1.0 transitive-closure relation.
  → OK VIEW CEILING id=<id> S=<S> identifiable=<n> of=129
    ceiling=<%.6f> exact_twin_pairs=<n> unique=<n> groups=<n>
  # the tests pin these to the sealed reference values; ceiling printed
  # at six decimals

VIEW FEATURES <id> <frame> <S>   (0 <= frame < 300)
  # shm out: [u32 count=3*S][u32 4] header at offset 0, then `count`
  # little-endian f32 standardized values at offset 8 — station-major:
  # for each station in the S-subset, (ii) log front-window energy
  # ratio, (iii) magnitude-weighted spectral centroid (Hz), (iv) log
  # second/first-window energy ratio.
  → OK VIEW FEATURES id=<id> frame=<frame> S=<S> count=<3*S>
  # (S or frame out of range → ERROR out_of_range)

VIEW INFO <id>
  → OK VIEW INFO id=<id> path=<p> sha256=<hex> train=<n> test=<n>
    stations=<n> samples=<n> candidates=<n>
VIEW LIST        → OK VIEW LIST count=<n> [id id ...]
VIEW CLOSE <id>  → OK VIEW CLOSE id=<id>
```

Persistence follows `ALARM`'s pattern exactly: view sets persist BY
REFERENCE (path + sha256, WAL opcode `0x2D`, snapshot v7's `views`
field), never their bytes; a missing or hash-changed file on restore
drops that one entry with a stderr `WARN`, it does not refuse the
whole snapshot load. Reader-session allowlist: `REFLEX`, `RUNG`,
`CEILING`, `FEATURES`, `INFO`, `LIST` are read-only; `LOAD` and
`CLOSE` are forbidden inside `READER <id> ...`, same shape as every
other twin family.

### FOLD

The tier ladder (2026-09-10): Kron/Schur fold of a rank ring
into the kept set at a time, operator stored to Float32 between folds,
solved in Float64 via LAPACK `dgesv` — `LadderFold.run` promoted from
the sealed `E3Ladder` runner, arithmetic unchanged. Unlike every other
twin family, `FOLD` mints no id and touches no WAL: it is a pure,
read-only computation over the engine's current lanes (neighbors,
edge weights, `nodeValue` as leak, rank) — the same lanes
`CONNECT`/`SET` write, so a fresh daemon (neighbor table wiped) folds
whatever graph is there, hex adjacency only if it was written there.
The handler holds only the last `FOLD RUN` result; every other FOLD
verb reads back from it.

```
FOLD RUN <maxRank> <keepRank> <f1> <f2> [<f3>] [CHECK <l1,l2,...>]
  # shm out: [u32 k*k][u32 4] header, then f32 final_operator, k*k
  # values row-major (k = kept count)
  → OK FOLD RUN kept=<k> folds=<n> bytes=<k*k*4> wall_ms=<f>
    (a node whose rank sits above <maxRank>, a rank lane value above
     Int.max, or a singular fold → ERROR bad_value: FOLD RUN refused:
     <reason>. The source-index and rank/keepRank arguments are still
     caught earlier by this handler's own out_of_range guards.)
  # The handler goes through the library's
  # throwing door (`runChecked`). Before that, `run` reported a refusal
  # as an empty result plus a stderr line, which this verb printed as
  # `OK FOLD RUN kept=0 folds=0 bytes=0` — and that empty result was
  # stored as the last fold, so FOLD KEPT/SOURCE/TIER read it back. A
  # refused fold now leaves the previous result untouched.
  # kept-set size k is predicted before any O(k^3) work; a result that
  # would exceed shm capacity is ERROR out_of_range before computing.
  # (bad rank/node/checkpoint args → ERROR out_of_range; any FOLD verb
  # before the first FOLD RUN → ERROR not_found)
  # The daemon's own guards above are unchanged. Underneath them the
  # library's fold gained four refusals (subsystems bounds, findings
  # 36-39), each carried on the result and printed as a named
  # `ERROR ladder_fold:` line: a schedule whose maxRank is BELOW the
  # object's own highest rank (those nodes were silently dropped at the
  # first fold, with their rows and columns of the operator); a source
  # index outside the node range; a singular fold or tier operator
  # (which used to abort the process on a LAPACK precondition); and a
  # rank the engine's u64 lane holds but Int cannot represent.

FOLD KEPT
  # shm out: [u32 k][u32 8] header, then u64 keptIds, k values
  → OK FOLD KEPT kept=<k>

FOLD SOURCE <1|2|3>
  # shm out: [u32 k][u32 4] header, then f32 foldedSource, k values
  # (3 with no f3 given to RUN → a vector of zeros)
  → OK FOLD SOURCE which=<i> kept=<k>

FOLD TIER <level|final> <1|2|3>
  # shm out: [u32 k][u32 8] header, then f64 tier answer, k values
  # (level not a checkpoint passed to RUN, or which=3 with no f3
  # given to RUN → ERROR not_found)
  → OK FOLD TIER level=<level> which=<i> count=<k>

FOLD INFO        → OK FOLD INFO kept=<k> folds=<n> tiers=<l1,l2,...,final>
                    bytes=<k*k*4> wall_ms=<f>
  # no shm output
```

Every FOLD verb is read-only, `RUN` included — reader sessions may
run all five (§ MVCC reader sessions, below).

### KERNEL / XCONV SEALED

Added 2026-09-10: per-path kernels (impulse responses
root→ear, 2048 taps) stored by reference and by id, a per-pair
warmup declared or derived, and the sealed court's own frozen
cross-convolution residual R reached over the socket — a **second**
entry point for the cross-convolution check, distinct from the pre-existing `XCONV
CHECK` (now deprecated, § XCONV/BUDGET above). Grammar mirrors
`ALARM`/`VIEW`'s LOAD/INFO/LIST/CLOSE shape; `KERNEL LOAD`'s optional
groups are in a FIXED order — `[SHA <hex64>] [TAU <τA> <τB> SIGMA
<σ>] [WARMUP <n>]` — any other order, or a group twice, is
`.unknown`, never reordered/matched.

```
KERNEL LOAD <path> [SHA <hex64>] [TAU <τA> <τB> SIGMA <σ>] [WARMUP <n>]
  # guardPath() rejects traversal / outside-DATA_ROOT paths before any
  # file I/O. The loaded kernels file's OWN computed sha256 (not the
  # caller's optional SHA argument) is what gets WAL-logged and later
  # verified on restore — mirrors ALARM LOAD / VIEW LOAD. TAU/SIGMA
  # (τ_A, τ_B, σ_source, seconds) are the pair's path delays and the
  # source bank's Gaussian envelope sigma — DECLARED here, never
  # read from the kernels file — and derive the warmup; an explicit
  # WARMUP is used only when TAU/SIGMA are absent (TAU/SIGMA's derived
  # warmup always wins when both are present).
  → OK KERNEL LOAD id=<id> taps=<n> fs=<hz> window=<n> ears=<A>/<B>
    warmup=<v|none> derived=<0|1> sha256=<hex>
    (a resolved warmup at or above the file's own window_samples →
     ERROR io: bad layout: warmup <v> leaves no comparison window
     against window_samples <w> (taps <n>))
  # That refusal comes from the LIBRARY loader, which has checked it
  # since 2026-09-12. A later follow-up changed the ORDER, not the
  # refusal: the daemon now
  # resolves the warmup through the same throwing door BEFORE the id is
  # minted and before the op reaches the WAL, so no path through this
  # handler can install a kernel whose warmup leaves no comparison
  # window. The handler's own wording for that case
  # (ERROR bad_value: KERNEL LOAD refused: ...) is defence in depth and
  # unreachable while the loader keeps the check.
    (missing file, sha mismatch, malformed/empty kernel array — every
    case → ERROR io: ...; a sha mismatch line always contains the
    literal phrase "sha256 mismatch")
  # Since 2026-09-12
  # the library's `KernelPair.load` defaults its sha pin to the sealed
  # constant (nil is an explicit opt-out that warns once), refuses a
  # non-integral or out-of-Int `window_samples` instead of truncating
  # it, refuses a non-finite fs/tau or a non-finite/negative sigma
  # (which used to trap inside the derived-warmup conversion or yield a
  # negative warmup), and refuses a resolved warmup that leaves no
  # comparison window against `window_samples`. The daemon's replies are
  # unchanged for the sealed fixture — its derived warmup is still 185
  # against a 2048-sample window.

XCONV SEALED <id> <n> [<warmup>]
  # shm in: [u32 2n][u32 0x314D480B] at bytes 0..7 (Input frames,
  # above), then f64 a[n] then f64 b[n] at offset 8 (rowSize 8, no gap) —
  # the sealed records to check against the loaded pair `id`.
  # `warmup`, if given, OVERRIDES the pair's own resolution and is
  # reported "declared, not derived" (derived=0); omitted, the pair's
  # own warmup is used (derived from TAU/SIGMA if present, else the
  # pair's declared WARMUP, else ERROR bad_value — no default).
  # Residual: yAB = (kB ⋆ a)[:n], yBA = (kA ⋆ b)[:n], window
  # [warmup, n) on BOTH numerator and denominator, denominator
  # one-sided max|yAB| + 1e-300, float64 end to end — the sealed court's
  # frozen formula, NOT XCONV CHECK's.
  → OK XCONV SEALED id=<id> n=<n> warmup=<v> derived=<0|1>
    residual=<R Double> compared=<n − warmup>
    (a warmup at or above the pair's window_samples →
     ERROR bad_value: XCONV SEALED refused: <reason>)
  # This refusal is ordered BEFORE the
  # `warmup < n` bound, so an override that violates both is reported
  # as the window violation.
    (n < 2 → ERROR bad_value; no warmup available and none given →
    ERROR bad_value; warmup >= n, or input past shm capacity →
    ERROR out_of_range; unknown id → ERROR not_found)

KERNEL INFO <id>
  → OK KERNEL INFO id=<id> path=<p> sha256=<hex> taps=<n> fs=<hz>
    window=<n> ears=<A>/<B> tau_a=<v|none> tau_b=<v|none>
    sigma=<v|none> warmup=<v|none> derived=<0|1>
    (as above → ERROR bad_value: KERNEL INFO refused: <reason>)
KERNEL LIST        → OK KERNEL LIST count=<n> [id id ...]
KERNEL CLOSE <id>  → OK KERNEL CLOSE id=<id>
```

For the sealed pair (`Tests/Fixtures/w1_kernels.json`, τ_A
0.18227148035108542, τ_B 0.18382585465904366, σ_source 0.02), the
derived warmup is 185, printed on both `KERNEL LOAD`
and `KERNEL INFO`.

Persistence follows `ALARM`'s / `VIEW`'s pattern exactly: kernel pairs
persist BY REFERENCE (path + sha256, plus the declared τ_A/τ_B/
σ_source/warmup, WAL opcode `0x2E`, snapshot v7's `kernels` field),
never the taps; a missing or hash-changed file on restore drops that
one entry with a stderr `WARN`, it does not refuse the whole snapshot
load. Reader-session allowlist: `XCONV SEALED`, `KERNEL INFO`,
`KERNEL LIST` are read-only; `KERNEL LOAD` and `KERNEL CLOSE` are
forbidden inside `READER <id> ...`, same shape as every other twin
family. `XCONV CHECK` was already reader-allowed (§ XCONV/BUDGET,
above; unchanged).

### HOOK

Roadmap item 7 (2026-09-10): the sealed allocator court (`AllocatorCourt.run`) as a
daemon-global ticked process — instead of one batch call, an
`AttentionHook` advances one frame per `HOOK STEP`, appending one
derived ledger row each time. Grammar mirrors `ALARM`/`VIEW`/`KERNEL`'s
LOAD→OPEN/INFO/LIST/CLOSE shape; `HOOK OPEN`'s optional groups are in
a FIXED order — `[DELTA <d>] [POLICY allocator|greedy|uniform] [CLOCK
<c>]` — any other order, or a group twice, is `.unknown`, never
reordered/matched.

```
HOOK OPEN <alarmId> <layoutId|SEALED> <budget> [DELTA <d>] [POLICY allocator|greedy|uniform] [CLOCK <c>]
  # layoutId "SEALED" resolves to nil at the parser (SealedCourt.makeLayout());
  # delta/policy absent here resolve to the sealed defaults (3, allocator)
  # in the HANDLER, not the parser, so the reply always prints the
  # resolved value. budget must be finite and > 0; the budget is
  # CONSTANT per hook — a different B is a different hook, never a
  # mid-run re-declaration (no HOOK BUDGET).
  → OK HOOK OPEN id=<id> alarm=<id> layout=<id|SEALED> B=<f> delta=<n>
    policy=<allocator|greedy|uniform> clock=<id|none> frames=<n>
    (frames = the alarm set's record count + delta)
    (unknown alarm/layout/clock → ERROR not_found; budget not finite
    or <= 0 → ERROR bad_value; delta < 0 → ERROR out_of_range)

HOOK STEP <id> <n>
  # Advances up to n frames, or until done, whichever comes first — a
  # step past the last frame is a no-op (stepped=0, done=1). Refused
  # on a clock-bound hook: its one driver is CLOCK ADVANCE.
  → OK HOOK STEP id=<id> t=<t> stepped=<n> done=<0|1> served=<n>
    misses=<n> cost=<f>
    (n < 1 → ERROR out_of_range; unknown id → ERROR not_found; bound
    to a clock → ERROR forbidden: bound to clock <c>)

HOOK STATE <id>
  → OK HOOK STATE id=<id> t=<t> done=<0|1> served=<n> misses=<n>
    cost=<f> dummy=<n> dominated=<n> max_spend_ratio=<f>
    warmup_cost=<f> burst=<served>/<missed>/<total>

HOOK LEDGER <id> [<from> <count>]
  # Omitting from/count returns every row. shm: [u32 count][u32
  # rowSize=40] header at offset 0, then `count` 40-byte rows at
  # offset 8, each 8-byte aligned:
  #   u32 t | i32 src | u8 judged | u8 outcome (0 none, 1 hit, 2 miss)
  #   | i8 tier (-1 none) | i8 pocket (-1 none) | 4 pad | f64 spend |
  #   f64 cumulativeCost | u8 countsTowardCost | 7 pad = 40 bytes/row.
  # The ledger is DERIVED, never stored — rebuilt by re-stepping.
  → OK HOOK LEDGER id=<id> from=<n> count=<n> of=<n>
    (range outside [0, ledger.count], or the requested bytes exceed
    shm capacity → ERROR out_of_range; unknown id → ERROR not_found)

HOOK INFO <id>
  → OK HOOK INFO id=<id> alarm=<id> layout=<id|SEALED> B=<f> delta=<n>
    policy=<p> clock=<id|none> frames=<n> t=<n> done=<0|1>
HOOK LIST        → OK HOOK LIST count=<n> [id id ...]
HOOK CLOSE <id>  → OK HOOK CLOSE id=<id>
  # Refused if the alarm set or budget layout it was opened against is
  # closed while this hook is still open — see ALARM/BUDGET CLOSE below.
```

**One step, one frame.** At frame `t` the hook reads the alarm of
source frame `src = t − Δ`; the frame is judged iff `1 ≤ src ≤ N`
(the alarm set's record count). Warm-up rows (`t = 1..Δ`) are `judged
= false` — for `uniform` they still pay the flat frame cost, booked
into `warmupCostExcluded` (never into `cost`) while `maxSpendRatio`
still sees them; `allocator`/`greedy` warm-up rows spend 0. A judged
frame whose source is quiet is outcome `none`: `uniform` still pays
its flat cost and books `cost` with no hit/miss; `allocator`/`greedy`
book nothing. `allocator` buys the cheapest tier with read value 1 in
the claimed pocket; `greedy` buys the deepest affordable tier in the
source alarm's own pocket (no "loudest" from residuals — one alarm per
frame); the oracle has no lag and is not a hook policy, it stays a
court arm only.

**Refusals.** A hook bound to a clock (`HOOK OPEN … CLOCK <c>`)
refuses `HOOK STEP` directly — `ERROR forbidden: bound to clock <c>`
— so its frame counter has exactly one driver; step it via `CLOCK
ADVANCE` instead. `CLOCK ADVANCE` steps every hook bound to that clock
once per tick, AFTER that tick's gears (`TwinState.apply` order:
clock tick, gears, hooks) — attention is spent on the engine's clock,
not by a batch call. `CLOCK CLOSE` cascades to bound hooks the same
way it cascades to gears, and its reply gains `hooks_closed=<n>`
beside `gears_closed=<n>` (the live hooks it closed).
`HOOK CLOSE` of a bound hook removes its id from the clock, as `GEAR
CLOSE` does a gear's (in earlier builds the id stayed, and every
later `CLOCK ADVANCE` of that clock moved one tick and answered
`ERROR not_found`).

**A log too old for a record.** A refusal the
log's version causes (`ERROR wal: append: opcode 0x<op> needs log version
<v>, this log is version <w>`) writes nothing and names `<remedy>`, the way
to a log that takes the record: `SAVE <the startup snapshot path>, stop the
daemon, move <the log> aside and start it again` (with no
`DAGDB_STARTUP_LOAD`: SAVE to a file and start again with
`DAGDB_STARTUP_LOAD` naming it). The daemon then loads the snapshot and
opens a fresh version-3 log, which upgrades itself on demand. SAVE and LOAD
through the wire do not replace the log (a rebase writes into the same log,
whose header keeps its version). Closing the alarm set or budget layout a
live hook depends on refuses the same way: `ALARM CLOSE`/`BUDGET
CLOSE` on an id a hook still references returns `ERROR forbidden: hook
<h> depends on <id>`, naming the hook — close the hook first.

**Reader allowlist.** `HOOK STATE`, `HOOK LEDGER`, `HOOK INFO`, and
`HOOK LIST` are read-only and permitted inside `READER <id> …`; `HOOK
OPEN`, `HOOK STEP`, and `HOOK CLOSE` mutate daemon-global twin state
and are forbidden there, same shape as every other twin family.

Over the sealed alarm records (`DAGDB_W2_FIXTURE`), `HOOK STEP` to
completion (203 steps) at the richest sealed budget point (B =
16164.352484758914) prints `served=150 misses=0 cost=819218.0` for
the allocator policy — the interface-phase gate-1 line, bit for bit — and
`served=50 misses=100 cost=94400.0` for uniform.

### Persistence

WAL opcodes `0x20`–`0x2B` (`TwinWALCodec`, little-endian, u16-length-
prefixed strings, f32/f64 as bit patterns): `twinStreamOpen`,
`twinStreamState`, `twinRecordOpen`, `twinRecordSlice`, `twinRingsOpen`,
`twinRingsWrite`, `twinClockOpen`, `twinClockAdvance`, `twinGearOpen`,
`twinLayoutOpen`, `twinAlarmLoad`, `twinClose`. Opcode `0x2C`,
`twinBankOpen`,
logs a `BANK OPEN` the same way — `GENERATE`/`FIT`/`NOISE`/`BENCH`
never touch the WAL, only shm. Opcode `0x2D`, `twinViewLoad`,
logs a `VIEW LOAD` the same way — `REFLEX`/`RUNG`/`CEILING`/
`FEATURES`/`INFO`/`LIST` never touch the WAL, `REFLEX`/`RUNG`/
`CEILING` reply directly and `FEATURES` writes shm only. Opcode
`0x2E`, `twinKernelLoad`, logs a `KERNEL LOAD` the same way —
`XCONV SEALED`/`INFO`/`LIST` never touch the WAL, `XCONV SEALED`
reads shm input (a client frame, `[u32 2n][u32 0x314D480B]`: § Input
frames) and replies directly. Opcodes `0x2F`/`0x30`,
`twinHookOpen`/`twinHookStep`, log `HOOK OPEN`/`HOOK STEP` the same way —
`HOOK CLOSE` logs the same plain `twinClose` (`0x2B`) every other
CLOSE verb logs, and for a hook bound to a clock also `twinHookSweep`
(`0x31`, log version 6) in the same append;
`HOOK STATE`/`LEDGER`/`INFO`/`LIST` never touch the WAL. A malformed
twin payload decodes to `nil` and is skipped on replay, never fatal —
a following non-twin record still applies.

Snapshot **v7** adds a `TWIN` section (magic `"TWIN"` + `u32`
byteLength + sorted-keys JSON of `TwinState.Snapshot`) between the
WGTS lane section and the ENVS trailer; `save`/`load` default to no
twin state (length 0 / section ignored) unless a `TwinState` is
threaded through. `TwinState.Snapshot`'s `banks`, `views`,
`kernels` and `hooks` fields decode tolerantly — an older
v7 file with no `banks`/`views`/`kernels`/`hooks` key still loads, with an
empty registry. Alarm sets, view sets, and kernel pairs all persist
**by reference** (path + sha256, kernel pairs also carrying the
declared τ_A/τ_B/σ_source/warmup),
never their bytes; on restore a missing or hash-mismatched file
drops that one entry with a stderr `WARN`, it does not refuse the
whole snapshot load — the live load path's stricter "wrong hash FAILS" rule
(`docs/contracts/INTERFACE_PHASE_GATES_FROZEN.md` amendment 1, and the same rule
for `VIEW` and for `KERNEL`) applies only
to `ALARM LOAD`'s / `VIEW LOAD`'s / `KERNEL LOAD`'s live load path,
not to restore. Hooks persist differently: a `HookRef` is trusted
parameters + the frame counter `t` (no path/hash of its own — nothing
external to check), rebuilt on restore by re-opening against its
already-restored alarm/layout/clock and re-stepping `t` times, which
also rebuilds the ledger (DERIVED, never stored); a hook whose
referenced alarm or layout failed to restore throws rather than
warn-and-drop, since that is real corruption, not a missing external
file.

---

## MVCC reader sessions

```
OPEN_READER
  → OK OPEN_READER id=<17-char-hex> tick=<t> open_sessions=<k>

CLOSE_READER <id>
  → OK CLOSE_READER id=<id>

LIST_READERS
  → OK LIST_READERS open_sessions=<k> <id1>@tick=<t> <id2>@tick=<t>

READER <id> <inner read-only command>
  → dispatches <inner> against the session's snapshot engine
```

Allowed inner commands: `STATUS`, `GRAPH INFO`, `NODES`, `TRAVERSE`,
`BFS_DEPTHS`, `DISTANCE`, `SELECT`, `ANCESTRY`, `VALIDATE`, `GET … TRUTH`,
`GET … TRIT` and `TTABLE GET` (the ternary build: a session copies the
four ternary lanes and the library with the other ten lanes),
`TRUTH_SLICE` (and its `BYTES` form;
`session=` in the reply), and the
read-only twin verbs (§ Twin primitives, above) — `STREAM STATE`/
`LIST`, `HEADER CHECK`, `RECORD REPLAY`/`VERIFY`/`INFO`/`LIST`,
`RINGS RECALL`/`INFO`/`LIST`, `CLOCK STATE`/`LIST`, `GEAR STATE`,
`XCONV CHECK`, `BUDGET ALLOCATE`/`INFO`/`LIST`, `ALARM INFO`/`LIST`/
`FRAME`/`COURT`/`SUCCESSOR`/`CORRUPT`, and `BANK GENERATE`/`FIT`/`NOISE`/`BENCH`/`INFO`/`LIST` —
`GENERATE`/`FIT` write shm only, never the daemon-global twin state,
so they count as read-only the same way `RECORD REPLAY` does; and
`VIEW REFLEX`/`RUNG`/`CEILING`/`FEATURES`/`INFO`/`LIST` — `FEATURES`
writes shm only, the rest reply directly, none touch the daemon-global
twin state. Four of the five FOLD verbs —
`FOLD KEPT`/`SOURCE`/`TIER`/`INFO` — are allowed too. **`FOLD RUN` is
NOT**: it mints no id and touches no WAL,
but it ASSIGNS the daemon-global last-fold result those four read, so
a reader session — or a browser through `web/bridge.py` — silently
overwrote what the primary saw. A reader issuing it gets
`ERROR forbidden: FOLD RUN assigns the daemon-global last-fold result
that FOLD KEPT/SOURCE/TIER/INFO read; not allowed in reader session`,
and the primary's `FOLD INFO` is unchanged. And `XCONV SEALED`, `KERNEL INFO`, `KERNEL LIST` — `XCONV
SEALED` reads shm input (a client frame, `[u32 2n][u32 0x314D480B]`,
also in a reader session) and replies directly, neither touches the
daemon-global twin state; `KERNEL LOAD`/`CLOSE` are mutating and
forbidden, same as `ALARM`/`VIEW`. Writes,
`EVAL`, nested
`READER`, `SIMILAR_DECISIONS`, the eleven mutating ternary forms
(`SET … MODE`/`TTABLE`/`THRESH`/`TRIT`, `TTABLE DEFINE`/`PRESET`,
the four ternary bulk verbs, and `COMPOSE` like every COMPOSE), and every mutating twin verb (twin
registries are daemon-global — convention 13 of the interface-phase gate contract, there is
no reader-scoped twin state to serve) are rejected with
`ERROR forbidden:`.

---

## Error taxonomy

Every error response starts with `ERROR <category>: <detail>`. See
[`invariants.md`](invariants.md) for the full table.

Categories: `out_of_range`, `dsl_parse`, `unknown_command`,
`schema`, `io`, `wal`, `bfs`, `not_found`, `forbidden`, `bad_value`,
`too_long`, `reader`, `invalid_graph`, `gpu`, `shutdown`.

`shutdown`: `ERROR shutdown: the daemon is shutting down;
the command was not run` — a command that had not started when SIGTERM or
SIGINT arrived. The command in flight completes; the autosave then runs
between commands and the daemon exits.

`gpu`: a tick verb (TICK, TICK_SYNC, EVAL, TICK
UNTIL_STABLE, a tile's tick inside TILED TICK or TILED OPEN), or SET_LUTS,
whose command buffer ended with a status other than completed — named in
the line — claims nothing of that buffer. See TICK under Lifecycle, TILED
TICK, and SET_LUTS under Mutate.

`invalid_graph`: rank-mode TICK on a graph rank mode
cannot order — see TICK under Lifecycle; also SAVE TILED
of such a graph (a tiled graph is a rank-mode object).

`too_long`: the one framing refusal —
`ERROR too_long: command exceeds 4095 bytes`. See "The frame" at the
top of this file.

`bad_value` (added with the twin verbs): a non-finite
number, an out-of-[0,1] corruption knob, or a shape violation
(`RINGS OPEN`'s gear/rings/cells bounds, `BUDGET OPEN`'s ragged/NaN
cost table) — a validating front door catching what would otherwise
be a `precondition` trap. A later follow-up added five more of
exactly that kind, all in the form `ERROR bad_value: <VERB> refused:
<reason>`: `FOLD RUN`, `BANK GENERATE`, `BANK OPEN`/`BANK INFO`,
`KERNEL LOAD`/`KERNEL INFO` and `XCONV SEALED`. Each is a subsystem
refusal that previously travelled only as a line on the daemon's
stderr plus an empty or default-valued result under an `OK` line — a
refusal no socket client could see.

Outside the DSL, a follow-up made `HexGrid`'s ordinary
initialiser throwing, so a grid whose axes fall outside the 16-bit
Morton encoding, or whose node count exceeds the Int32 index space, is
refused by name at construction instead of aborting the process with a
`precondition`. This is the daemon's `--grid` argument at startup, not
a wire command; the refusal names the axis, the value and the bound. `reader` predates the twin verbs (a
reader-session-bound node-range check in `TRAVERSE`/`ANCESTRY`) but
was missing from this list. Those two reader-side checks now print
`out_of_range` like every other bounds refusal, so nothing in the
current daemon emits `reader:`; the category stays listed because
older logs carry it.
