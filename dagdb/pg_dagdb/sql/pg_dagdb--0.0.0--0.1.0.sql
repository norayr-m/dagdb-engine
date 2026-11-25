/*
pg_dagdb 0.0.0 -> 0.1.0. Run by:  ALTER EXTENSION pg_dagdb UPDATE;  (or UPDATE TO '0.1.0'),
after the 0.1.0 package is installed (cargo pgrx install). The whole update is one transaction.

0.0.0 is main's pg_dagdb before the ternary build. Its dagdb_exec(text) returns
  TABLE(node_id integer, rank smallint, truth smallint, node_type smallint, message text).
0.1.0's returns
  TABLE(node_id bigint, rank bigint, truth smallint, node_type smallint, mode smallint, trit smallint, message text).
A function's return type cannot change in place, so dagdb_exec is dropped and created again.

VIEWS. The drop is CASCADE: it drops every view that reads dagdb_exec, directly or through another
view. Those are setup_views.sql's dagdb_nodes, dagdb_status_view, dagdb_info and dagdb_map, and any
view of your own built on dagdb_exec or on those views (dagdb_exec's columns change, so such a view
could not keep working unchanged). Postgres runs an extension script with client_min_messages at
WARNING, so the CASCADE's own NOTICE never reaches you; this script names the views it is about to
drop in a WARNING first. setup_views.sql's functions (dagdb_run, dagdb_rank, dagdb_traverse,
dagdb_ascii, dagdb_hex) are not dropped, because Postgres does not track what a function body
calls; they keep 0.0.0's shapes until setup_views.sql replaces them.
AFTER THIS UPDATE, RE-RUN setup_views.sql (psql <db> -f setup_views.sql). It drops its old
objects and creates them all again over 0.1.0's columns.

dagdb_status() and dagdb_tick(integer) have the same signature, result and C symbol in both
versions. They are restated with CREATE OR REPLACE, which keeps their OIDs, so that this update
leaves the same catalog as a fresh CREATE EXTENSION pg_dagdb at 0.1.0
(gated by test_pg_dagdb_ext_update_live.py).

Between installing the 0.1.0 package and running this update, the 0.0.0 catalog points at the
0.1.0 library. dagdb_exec then refuses with ERROR 42804 by name and sends nothing to the daemon;
dagdb_status and dagdb_tick answer.
*/

\echo Use "ALTER EXTENSION pg_dagdb UPDATE TO '0.1.0'" to load this file. \quit

-- Name the views the CASCADE below drops: those whose rewrite rule depends on dagdb_exec(text),
-- then, recursively, those whose rule depends on one of them.
DO $$
DECLARE
    dropped text;
BEGIN
    WITH RECURSIVE dep(oid) AS (
        SELECT r.ev_class
        FROM pg_depend d
        JOIN pg_rewrite r ON d.classid = 'pg_rewrite'::regclass AND d.objid = r.oid
        WHERE d.refclassid = 'pg_proc'::regclass AND d.refobjid = 'dagdb_exec(text)'::regprocedure
        UNION
        SELECT r.ev_class
        FROM dep
        JOIN pg_depend d ON d.refclassid = 'pg_class'::regclass AND d.refobjid = dep.oid
        JOIN pg_rewrite r ON d.classid = 'pg_rewrite'::regclass AND d.objid = r.oid
        WHERE r.ev_class <> dep.oid
    )
    SELECT string_agg(oid::regclass::text, ', ' ORDER BY oid::regclass::text) INTO dropped FROM dep;
    IF dropped IS NOT NULL THEN
        RAISE WARNING 'pg_dagdb 0.0.0 -> 0.1.0 drops the views that read dagdb_exec: %', dropped
            USING HINT = 'After the update, re-run setup_views.sql; re-create views of your own over the new columns.';
    END IF;
END
$$;

DROP FUNCTION dagdb_exec(text) CASCADE;

CREATE FUNCTION "dagdb_exec"(
	"command" TEXT
) RETURNS TABLE (
	"node_id" bigint,
	"rank" bigint,
	"truth" smallint,
	"node_type" smallint,
	"mode" smallint,
	"trit" smallint,
	"message" TEXT
)
STRICT
LANGUAGE c
AS 'MODULE_PATHNAME', 'dagdb_exec_wrapper';

CREATE OR REPLACE FUNCTION "dagdb_status"() RETURNS TEXT
STRICT
LANGUAGE c
AS 'MODULE_PATHNAME', 'dagdb_status_wrapper';

CREATE OR REPLACE FUNCTION "dagdb_tick"(
	"n" INT DEFAULT 1
) RETURNS TEXT
STRICT
LANGUAGE c
AS 'MODULE_PATHNAME', 'dagdb_tick_wrapper';
