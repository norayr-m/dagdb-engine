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
