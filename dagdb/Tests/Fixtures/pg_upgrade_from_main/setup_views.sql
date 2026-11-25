-- DagDB Views — Make graph data visible in DBeaver/pgAdmin
-- Run this after CREATE EXTENSION pg_dagdb;
-- Daemon must be running: .build/debug/dagdb-daemon --grid 256

-- View: all nodes with their properties
CREATE OR REPLACE VIEW dagdb_nodes AS
SELECT node_id, rank, truth, node_type
FROM dagdb_exec('NODES AT RANK 0')
WHERE node_id IS NOT NULL;

-- View: graph status as a row
CREATE OR REPLACE VIEW dagdb_status_view AS
SELECT message AS status
FROM dagdb_exec('STATUS')
WHERE message IS NOT NULL;

-- View: graph statistics
CREATE OR REPLACE VIEW dagdb_info AS
SELECT message AS info
FROM dagdb_exec('GRAPH INFO')
WHERE message IS NOT NULL;

-- Convenience function: tick and return results
CREATE OR REPLACE FUNCTION dagdb_run(n integer DEFAULT 1)
RETURNS TABLE(node_id integer, rank smallint, truth smallint, node_type smallint, message text) AS $$
    SELECT * FROM dagdb_exec('TICK ' || n);
$$ LANGUAGE sql;

-- Convenience function: get nodes at specific rank
CREATE OR REPLACE FUNCTION dagdb_rank(r integer)
RETURNS TABLE(node_id integer, rank smallint, truth smallint, node_type smallint, message text) AS $$
    SELECT * FROM dagdb_exec('NODES AT RANK ' || r);
$$ LANGUAGE sql;

-- Convenience function: traverse from a node
CREATE OR REPLACE FUNCTION dagdb_traverse(from_node integer, depth integer DEFAULT 2)
RETURNS TABLE(node_id integer, rank smallint, truth smallint, node_type smallint, message text) AS $$
    SELECT * FROM dagdb_exec('TRAVERSE FROM ' || from_node || ' DEPTH ' || depth);
$$ LANGUAGE sql;

-- ASCII art visualization of the ranked DAG
CREATE OR REPLACE FUNCTION dagdb_ascii()
RETURNS TABLE(graph text) AS $$
DECLARE
    r RECORD;
    sensors text[];
    zone_n text; zone_s text; zone_e text;
    grid_v text; decision_v text;
BEGIN
    sensors := ARRAY[]::text[];
    FOR r IN SELECT node_id, truth FROM dagdb_exec('NODES AT RANK 3') WHERE node_id BETWEEN 100 AND 117 ORDER BY node_id LOOP
        sensors := array_append(sensors, CASE WHEN r.truth = 1 THEN '●' ELSE '○' END);
    END LOOP;
    WHILE array_length(sensors, 1) IS NULL OR array_length(sensors, 1) < 18 LOOP
        sensors := array_append(sensors, '·');
    END LOOP;
    SELECT CASE WHEN truth=1 THEN '●' ELSE '○' END INTO zone_n FROM dagdb_exec('TRAVERSE FROM 118 DEPTH 1') WHERE node_id=118 LIMIT 1;
    SELECT CASE WHEN truth=1 THEN '●' ELSE '○' END INTO zone_s FROM dagdb_exec('TRAVERSE FROM 119 DEPTH 1') WHERE node_id=119 LIMIT 1;
    SELECT CASE WHEN truth=1 THEN '●' ELSE '○' END INTO zone_e FROM dagdb_exec('TRAVERSE FROM 120 DEPTH 1') WHERE node_id=120 LIMIT 1;
    SELECT CASE WHEN truth=1 THEN '●' ELSE '○' END INTO grid_v FROM dagdb_exec('TRAVERSE FROM 121 DEPTH 1') WHERE node_id=121 LIMIT 1;
    SELECT CASE WHEN truth=1 THEN '●' ELSE '○' END INTO decision_v FROM dagdb_exec('TRAVERSE FROM 122 DEPTH 1') WHERE node_id=122 LIMIT 1;
    zone_n := COALESCE(zone_n, '·'); zone_s := COALESCE(zone_s, '·');
    zone_e := COALESCE(zone_e, '·'); grid_v := COALESCE(grid_v, '·');
    decision_v := COALESCE(decision_v, '·');

    graph := ''; RETURN NEXT;
    graph := '  ╔══════════════════════════════════════════════════╗'; RETURN NEXT;
    graph := '  ║           DagDB — Power Grid HexDAG             ║'; RETURN NEXT;
    graph := '  ╠══════════════════════════════════════════════════╣'; RETURN NEXT;
    graph := '  ║                                                  ║'; RETURN NEXT;
    graph := '  ║  Rank 0            [' || decision_v || '] DECISION                ║'; RETURN NEXT;
    graph := '  ║                     │                            ║'; RETURN NEXT;
    graph := '  ║  Rank 1            [' || grid_v || '] GRID (AND)              ║'; RETURN NEXT;
    graph := '  ║                   ╱ │ ╲                          ║'; RETURN NEXT;
    graph := '  ║  Rank 2      [' || zone_n || ']   [' || zone_s || ']   [' || zone_e || ']                   ║'; RETURN NEXT;
    graph := '  ║             NORTH SOUTH EAST                    ║'; RETURN NEXT;
    graph := '  ║             (AND) (MAJ) (OR)                    ║'; RETURN NEXT;
    graph := '  ║            ╱│╲   ╱│╲   ╱│╲                      ║'; RETURN NEXT;
    graph := '  ║  Rank 3  ' || sensors[1] || sensors[2] || sensors[3] || sensors[4] || sensors[5] || sensors[6] || ' ' || sensors[7] || sensors[8] || sensors[9] || sensors[10] || sensors[11] || sensors[12] || ' ' || sensors[13] || sensors[14] || sensors[15] || sensors[16] || sensors[17] || sensors[18] || '            ║'; RETURN NEXT;
    graph := '  ║          SENSORS  SENSORS  SENSORS              ║'; RETURN NEXT;
    graph := '  ║                                                  ║'; RETURN NEXT;
    graph := '  ║  ● = TRUE (healthy)   ○ = FALSE (fault)         ║'; RETURN NEXT;
    graph := '  ╚══════════════════════════════════════════════════╝'; RETURN NEXT;
    RETURN;
END;
$$ LANGUAGE plpgsql;

-- Example queries to try in DBeaver:
--
--   SELECT * FROM dagdb_nodes;
--   SELECT * FROM dagdb_status_view;
--   SELECT * FROM dagdb_info;
--   SELECT * FROM dagdb_run(10);
--   SELECT * FROM dagdb_rank(2);
--   SELECT * FROM dagdb_traverse(42, 3);
--
--   -- Count nodes by rank:
--   SELECT rank, COUNT(*) FROM dagdb_nodes GROUP BY rank ORDER BY rank;
--
--   -- Find all true nodes:
--   SELECT * FROM dagdb_nodes WHERE truth = 1;
--   SELECT graph FROM dagdb_map;                              -- ASCII DAG with live values

-- Live hex DAG map — SELECT graph FROM dagdb_map;
CREATE OR REPLACE VIEW dagdb_map AS
SELECT row_number() OVER () AS line, graph FROM (
SELECT 1 AS ord, '' AS graph
UNION ALL SELECT 2, '  RANK 0 (ROOT)        RANK 1 (COMBINER)      RANK 2 (AGGREGATORS)         RANK 3 (LEAVES)'
UNION ALL SELECT 3, '  ═══════════════       ═══════════════════     ══════════════════════       ══════════════════════════════'
UNION ALL
SELECT 4,
  '  ┌───┐                 ┌───┐                  ┌───┐  ┌───┐  ┌───┐        ' ||
  (SELECT string_agg(CASE WHEN truth=1 THEN '●' ELSE '○' END, ' ' ORDER BY node_id)
   FROM dagdb_exec('NODES AT RANK 3') WHERE node_id BETWEEN 100 AND 105)
UNION ALL
SELECT 5,
  '  │' ||
  COALESCE((SELECT CASE WHEN truth=1 THEN ' ● ' ELSE ' ○ ' END FROM dagdb_exec('TRAVERSE FROM 122 DEPTH 1') WHERE node_id=122 LIMIT 1), ' · ') ||
  '│ ────────────── │' ||
  COALESCE((SELECT CASE WHEN truth=1 THEN ' ● ' ELSE ' ○ ' END FROM dagdb_exec('TRAVERSE FROM 121 DEPTH 1') WHERE node_id=121 LIMIT 1), ' · ') ||
  '│ ─────────┬──── │' ||
  COALESCE((SELECT CASE WHEN truth=1 THEN ' ● ' ELSE ' ○ ' END FROM dagdb_exec('TRAVERSE FROM 118 DEPTH 1') WHERE node_id=118 LIMIT 1), ' · ') ||
  '│  │' ||
  COALESCE((SELECT CASE WHEN truth=1 THEN ' ● ' ELSE ' ○ ' END FROM dagdb_exec('TRAVERSE FROM 119 DEPTH 1') WHERE node_id=119 LIMIT 1), ' · ') ||
  '│  │' ||
  COALESCE((SELECT CASE WHEN truth=1 THEN ' ● ' ELSE ' ○ ' END FROM dagdb_exec('TRAVERSE FROM 120 DEPTH 1') WHERE node_id=120 LIMIT 1), ' · ') ||
  '│ ──── ' ||
  (SELECT string_agg(CASE WHEN truth=1 THEN '●' ELSE '○' END, ' ' ORDER BY node_id)
   FROM dagdb_exec('NODES AT RANK 3') WHERE node_id BETWEEN 106 AND 111)
UNION ALL
SELECT 6,
  '  │122│                 │121│                  │AND│  │MAJ│  │OR │        ' ||
  (SELECT string_agg(CASE WHEN truth=1 THEN '●' ELSE '○' END, ' ' ORDER BY node_id)
   FROM dagdb_exec('NODES AT RANK 3') WHERE node_id BETWEEN 112 AND 117)
UNION ALL SELECT 7, '  │ID │                 │AND│                  │118│  │119│  │120│'
UNION ALL SELECT 8, '  └───┘                 └───┘                  └─┬─┘  └─┬─┘  └─┬─┘'
UNION ALL SELECT 9, '    │                     │                      │       │       │'
UNION ALL SELECT 10,'    └─────────────────────┘                      └───┬───┘───┬───┘'
UNION ALL SELECT 11,'              reads: 121                             │       │'
UNION ALL SELECT 12,'                                              ┌──────┘       └──────┐'
UNION ALL SELECT 13,'                                        100-105 ──→ 118    112-117 ──→ 120'
UNION ALL SELECT 14,'                                        106-111 ──→ 119'
UNION ALL SELECT 15, ''
UNION ALL SELECT 16, '  ● = TRUE    ○ = FALSE    ID = identity    AND = all    MAJ = majority(4+)    OR = any'
) sub ORDER BY ord;

-- Hex DAG as a 6-column table — rows=ranks, columns=nodes, pipes=edges
-- Usage: SELECT * FROM dagdb_hex(122, 4);  -- from node 122, depth 4
CREATE OR REPLACE FUNCTION dagdb_hex(root_node integer DEFAULT 122, max_depth integer DEFAULT 4)
RETURNS TABLE(rank text, c1 text, c2 text, c3 text, c4 text, c5 text, c6 text) AS $$
DECLARE
    current_nodes int[];
    next_nodes int[];
    nid int;
    tv int;
    rank_level int;
    vals text[];
    r RECORD;
    i int;
BEGIN
    current_nodes := ARRAY[root_node];
    FOR rank_level IN 0..max_depth LOOP
        vals := ARRAY['','','','','',''];
        next_nodes := ARRAY[]::int[];
        FOR i IN 1..COALESCE(array_length(current_nodes, 1), 0) LOOP
            IF i > 6 THEN EXIT; END IF;
            nid := current_nodes[i];
            SELECT t.truth INTO tv
            FROM dagdb_exec('TRAVERSE FROM ' || nid || ' DEPTH 1') t
            WHERE t.node_id = nid LIMIT 1;
            tv := COALESCE(tv, -1);
            vals[i] := CASE WHEN tv=1 THEN '● ' WHEN tv=0 THEN '○ ' ELSE '· ' END || nid::text;
            FOR r IN SELECT t.node_id AS rid FROM dagdb_exec('TRAVERSE FROM ' || nid || ' DEPTH 2') t
                     WHERE t.node_id != nid LIMIT 6 LOOP
                IF NOT (r.rid = ANY(next_nodes)) THEN
                    next_nodes := array_append(next_nodes, r.rid);
                END IF;
            END LOOP;
        END LOOP;
        rank := 'R' || rank_level;
        c1 := vals[1]; c2 := vals[2]; c3 := vals[3];
        c4 := vals[4]; c5 := vals[5]; c6 := vals[6];
        RETURN NEXT;
        IF rank_level < max_depth AND COALESCE(array_length(next_nodes, 1), 0) > 0 THEN
            rank := '   ';
            c1 := CASE WHEN vals[1]!='' THEN '  │' ELSE '' END;
            c2 := CASE WHEN vals[2]!='' THEN '  │' ELSE '' END;
            c3 := CASE WHEN vals[3]!='' THEN '  │' ELSE '' END;
            c4 := CASE WHEN vals[4]!='' THEN '  │' ELSE '' END;
            c5 := CASE WHEN vals[5]!='' THEN '  │' ELSE '' END;
            c6 := CASE WHEN vals[6]!='' THEN '  │' ELSE '' END;
            RETURN NEXT;
        END IF;
        IF COALESCE(array_length(next_nodes, 1), 0) = 0 THEN EXIT; END IF;
        current_nodes := next_nodes;
    END LOOP;
    RETURN;
END;
$$ LANGUAGE plpgsql;
