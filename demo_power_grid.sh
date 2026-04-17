#!/bin/bash
# DagDB Demo — Power Grid Decision Graph
#
# Builds a ranked DAG:
#   Rank 3: 18 sensors (voltage, current, temperature × 6 substations)
#   Rank 2: 3 zone aggregators (North=AND, South=MAJORITY, East=OR)
#   Rank 1: 1 grid controller (AND — all zones must be healthy)
#   Rank 0: 1 final decision (IDENTITY — pass-through)
#
# Daemon must be running: .build/debug/dagdb-daemon --grid 256

SOCK="/tmp/dagdb.sock"
cmd() { echo "$1" | nc -U "$SOCK" 2>/dev/null; }

echo "══════════════════════════════════════════════════════════"
echo "  DagDB Demo — Power Grid Decision Graph"
echo "══════════════════════════════════════════════════════════"

STATUS=$(cmd "STATUS")
if ! echo "$STATUS" | grep -q "OK"; then
    echo "  ERROR: Daemon not running."
    exit 1
fi
echo "  $STATUS"
echo ""

# ── Clear neighbors for our nodes (daemon starts with hex grid neighbors) ──
# We'll use nodes 100-122 to avoid default hex wiring

# ── Rank 3: 18 sensor nodes (leaves) ──
echo "  ── Rank 3: Sensors ──"

# North zone: 6 sensors, all healthy
for i in $(seq 100 105); do
    cmd "SET $i RANK 3" >/dev/null
    cmd "SET $i LUT CONST1" >/dev/null
    cmd "SET $i TRUTH 1" >/dev/null
done
echo "    Nodes 100-105: North sensors = ALL HEALTHY"

# South zone: 6 sensors, one fault at node 109
for i in $(seq 106 111); do
    cmd "SET $i RANK 3" >/dev/null
    if [ "$i" -eq 109 ]; then
        cmd "SET $i LUT CONST0" >/dev/null
        cmd "SET $i TRUTH 0" >/dev/null
    else
        cmd "SET $i LUT CONST1" >/dev/null
        cmd "SET $i TRUTH 1" >/dev/null
    fi
done
echo "    Nodes 106-111: South sensors = 5 HEALTHY, 1 FAULT (109)"

# East zone: 6 sensors, two faults at 114, 116
for i in $(seq 112 117); do
    cmd "SET $i RANK 3" >/dev/null
    if [ "$i" -eq 114 ] || [ "$i" -eq 116 ]; then
        cmd "SET $i LUT CONST0" >/dev/null
        cmd "SET $i TRUTH 0" >/dev/null
    else
        cmd "SET $i LUT CONST1" >/dev/null
        cmd "SET $i TRUTH 1" >/dev/null
    fi
done
echo "    Nodes 112-117: East sensors = 4 HEALTHY, 2 FAULTS (114, 116)"

# ── Rank 2: Zone aggregators ──
echo ""
echo "  ── Rank 2: Zone Aggregators ──"

# Node 118: North zone = AND (all 6 must be healthy)
cmd "SET 118 RANK 2" >/dev/null
cmd "SET 118 LUT AND" >/dev/null
for i in $(seq 100 105); do cmd "CONNECT FROM $i TO 118" >/dev/null; done
echo "    Node 118: North zone AND gate (all must be true)"

# Node 119: South zone = MAJORITY (4+ of 6 healthy = OK)
cmd "SET 119 RANK 2" >/dev/null
cmd "SET 119 LUT MAJ" >/dev/null
for i in $(seq 106 111); do cmd "CONNECT FROM $i TO 119" >/dev/null; done
echo "    Node 119: South zone MAJORITY gate (4+ of 6)"

# Node 120: East zone = OR (any sensor healthy = partially operational)
cmd "SET 120 RANK 2" >/dev/null
cmd "SET 120 LUT OR" >/dev/null
for i in $(seq 112 117); do cmd "CONNECT FROM $i TO 120" >/dev/null; done
echo "    Node 120: East zone OR gate (any healthy = OK)"

# ── Rank 1: Grid controller ──
echo ""
echo "  ── Rank 1: Grid Controller ──"

# Node 121: Grid = AND of all 3 zones
cmd "SET 121 RANK 1" >/dev/null
cmd "SET 121 LUT AND" >/dev/null
cmd "CONNECT FROM 118 TO 121" >/dev/null
cmd "CONNECT FROM 119 TO 121" >/dev/null
cmd "CONNECT FROM 120 TO 121" >/dev/null
echo "    Node 121: Grid controller AND gate (all zones must pass)"

# ── Rank 0: Final decision ──
echo ""
echo "  ── Rank 0: Decision ──"

cmd "SET 122 RANK 0" >/dev/null
cmd "SET 122 LUT ID" >/dev/null
cmd "CONNECT FROM 121 TO 122" >/dev/null
echo "    Node 122: Final decision IDENTITY (pass-through)"

# ── Evaluate ──
echo ""
echo "  ── Evaluating (leaves-up propagation) ──"
cmd "TICK 1"

# ── Read results ──
echo ""
echo "  ── Results ──"
echo ""

# Read key nodes
for n in 118 119 120 121 122; do
    cmd "TRAVERSE FROM $n DEPTH 1"
done

echo ""
echo "  Expected behavior:"
echo "    North (AND):  All 6 true    → TRUE"
echo "    South (MAJ):  5 of 6 true   → TRUE (majority = 4+)"
echo "    East  (OR):   4 of 6 true   → TRUE (any true = true)"
echo "    Grid  (AND):  All 3 zones   → TRUE"
echo "    Decision:     Pass-through   → TRUE"
echo ""
echo "  Now inject a cascade failure:"
echo "    Setting 4 North sensors to FALSE..."

for i in 100 101 102 103; do
    cmd "SET $i TRUTH 0" >/dev/null
done
cmd "TICK 1"

echo ""
echo "  After cascade:"
for n in 118 119 120 121 122; do
    cmd "TRAVERSE FROM $n DEPTH 1"
done

echo ""
echo "  Expected: North AND fails (2/6) → Grid AND fails → Decision = FALSE"

# ── SQL view ──
if command -v psql &>/dev/null && psql dagdb -c "SELECT 1" &>/dev/null 2>&1; then
    echo ""
    echo "  ── SQL View ──"
    psql dagdb -c "
    SELECT node_id,
           CASE rank WHEN 3 THEN 'Sensor' WHEN 2 THEN 'Zone' WHEN 1 THEN 'Grid' WHEN 0 THEN 'Decision' ELSE 'Other' END AS layer,
           CASE truth WHEN 1 THEN 'HEALTHY' WHEN 0 THEN 'FAULT' ELSE 'UNKNOWN' END AS status,
           node_type
    FROM dagdb_exec('NODES AT RANK 3')
    WHERE node_id BETWEEN 100 AND 122
    UNION ALL
    SELECT node_id,
           CASE rank WHEN 3 THEN 'Sensor' WHEN 2 THEN 'Zone' WHEN 1 THEN 'Grid' WHEN 0 THEN 'Decision' ELSE 'Other' END AS layer,
           CASE truth WHEN 1 THEN 'HEALTHY' WHEN 0 THEN 'FAULT' ELSE 'UNKNOWN' END AS status,
           node_type
    FROM dagdb_exec('NODES AT RANK 2')
    WHERE node_id BETWEEN 100 AND 122
    UNION ALL
    SELECT node_id,
           CASE rank WHEN 3 THEN 'Sensor' WHEN 2 THEN 'Zone' WHEN 1 THEN 'Grid' WHEN 0 THEN 'Decision' ELSE 'Other' END AS layer,
           CASE truth WHEN 1 THEN 'HEALTHY' WHEN 0 THEN 'FAULT' ELSE 'UNKNOWN' END AS status,
           node_type
    FROM dagdb_exec('NODES AT RANK 1')
    WHERE node_id BETWEEN 100 AND 122
    UNION ALL
    SELECT node_id,
           CASE rank WHEN 3 THEN 'Sensor' WHEN 2 THEN 'Zone' WHEN 1 THEN 'Grid' WHEN 0 THEN 'Decision' ELSE 'Other' END AS layer,
           CASE truth WHEN 1 THEN 'HEALTHY' WHEN 0 THEN 'FAULT' ELSE 'UNKNOWN' END AS status,
           node_type
    FROM dagdb_exec('NODES AT RANK 0')
    WHERE node_id BETWEEN 100 AND 122
    ORDER BY node_id;
    "
fi

echo ""
echo "══════════════════════════════════════════════════════════"
echo "  Demo complete."
echo "══════════════════════════════════════════════════════════"
