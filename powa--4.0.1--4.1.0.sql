-- complain if script is sourced in psql, rather than via CREATE EXTENSION
--\echo Use "ALTER EXTENSION powa" to load this file. \quit

ALTER TABLE public.powa_statements ADD last_present_ts timestamptz NULL DEFAULT now();
--- Create a performance index to speed up clean up process
CREATE INDEX powa_statements_mru_idx ON powa_statements (last_present_ts);

CREATE OR REPLACE FUNCTION powa_qualstats_snapshot(_srvid integer) RETURNS void as $PROC$
DECLARE
    result     bool;
    v_funcname text := 'powa_qualstats_snapshot';
    v_rowcount bigint;
BEGIN
  PERFORM powa_log(format('running %I', v_funcname));

  PERFORM powa_prevent_concurrent_snapshot(_srvid);

  WITH capture AS (
    SELECT *
    FROM powa_qualstats_src(_srvid) q
    WHERE EXISTS (SELECT 1
      FROM powa_statements s
      WHERE s.srvid = _srvid
      AND q.queryid = s.queryid
      AND q.dbid = s.dbid
      AND q.userid = s.dbid)
  ),
  missing_quals AS (
      INSERT INTO public.powa_qualstats_quals (srvid, qualid, queryid, dbid, userid, quals)
        SELECT DISTINCT _srvid AS srvid, qs.qualnodeid, qs.queryid, qs.dbid, qs.userid,
          array_agg(DISTINCT q::qual_type)
        FROM capture qs,
        LATERAL (SELECT (unnest(quals)).*) as q
        WHERE NOT EXISTS (
          SELECT 1
          FROM powa_qualstats_quals nh
          WHERE nh.srvid = _srvid
            AND nh.qualid = qs.qualnodeid
            AND nh.queryid = qs.queryid
            AND nh.dbid = qs.dbid
            AND nh.userid = qs.userid
        )
        GROUP BY srvid, qualnodeid, qs.queryid, qs.dbid, qs.userid
      RETURNING *
  ),
  by_qual AS (
      INSERT INTO public.powa_qualstats_quals_history_current (srvid, qualid, queryid,
        dbid, userid, ts, occurences, execution_count, nbfiltered,
        mean_err_estimate_ratio, mean_err_estimate_num)
      SELECT _srvid AS srvid, qs.qualnodeid, qs.queryid, qs.dbid, qs.userid,
          ts, sum(occurences), sum(execution_count), sum(nbfiltered),
          avg(mean_err_estimate_ratio), avg(mean_err_estimate_num)
        FROM capture as qs
        GROUP BY srvid, ts, qualnodeid, qs.queryid, qs.dbid, qs.userid
      RETURNING *
  ),
  by_qual_with_const AS (
      INSERT INTO public.powa_qualstats_constvalues_history_current(srvid, qualid,
        queryid, dbid, userid, ts, occurences, execution_count, nbfiltered,
        mean_err_estimate_ratio, mean_err_estimate_num, constvalues)
      SELECT _srvid, qualnodeid, qs.queryid, qs.dbid, qs.userid, ts,
        occurences, execution_count, nbfiltered, mean_err_estimate_ratio,
        mean_err_estimate_num, constvalues
      FROM capture as qs
  )
  SELECT COUNT(*) into v_rowcount
  FROM capture;

  perform powa_log(format('%I - rowcount: %s',
        v_funcname, v_rowcount));

    IF (_srvid != 0) THEN
        DELETE FROM powa_qualstats_src_tmp WHERE srvid = _srvid;
    END IF;

  result := true;

  -- pg_qualstats metrics are not accumulated, so we force a reset after every
  -- snapshot.  For local snapshot this is done here, remote snapshots will
  -- rely on the collector doing it through query_cleanup.
  IF (_srvid = 0) THEN
    PERFORM pg_qualstats_reset();
  END IF;
END
$PROC$ language plpgsql; /* end of powa_qualstats_snapshot */

DO $anon$
BEGIN
    IF current_setting('server_version_num')::int < 90600 THEN
        CREATE FUNCTION public.powa_get_guc (guc text, def text DEFAULT NULL) RETURNS text
        LANGUAGE plpgsql
        AS $_$
        DECLARE
            v_val text;
        BEGIN
            BEGIN
                SELECT current_setting(guc) INTO v_val;
            EXCEPTION WHEN OTHERS THEN
                v_val = def;
            END;

            RETURN v_val;
        END;
        $_$;
    ELSE
        CREATE FUNCTION public.powa_get_guc (guc text, def text DEFAULT NULL) RETURNS text
        LANGUAGE plpgsql
        AS $_$
        BEGIN
            RETURN COALESCE(current_setting(guc, true), def);
        END;
        $_$;
    END IF;
END;
$anon$;

CREATE OR REPLACE FUNCTION public.powa_log (msg text) RETURNS void
LANGUAGE plpgsql
AS $_$
BEGIN
    IF powa_get_guc('powa.debug', 'false')::bool THEN
        RAISE WARNING '%', msg;
    ELSE
        RAISE DEBUG '%', msg;
    END IF;
END;
$_$;

ALTER TYPE powa_statements_history_record RENAME ATTRIBUTE total_time TO total_exec_time CASCADE;
ALTER TYPE powa_statements_history_record ADD ATTRIBUTE plans bigint;
ALTER TYPE powa_statements_history_record ADD ATTRIBUTE total_plan_time double precision;
ALTER TYPE powa_statements_history_record ADD ATTRIBUTE wal_records bigint;
ALTER TYPE powa_statements_history_record ADD ATTRIBUTE wal_fpi bigint;
ALTER TYPE powa_statements_history_record ADD ATTRIBUTE wal_bytes numeric;

ALTER TYPE powa_statements_history_diff RENAME ATTRIBUTE total_time TO total_exec_time CASCADE;
ALTER TYPE powa_statements_history_diff ADD ATTRIBUTE plans bigint;
ALTER TYPE powa_statements_history_diff ADD ATTRIBUTE total_plan_time double precision;
ALTER TYPE powa_statements_history_diff ADD ATTRIBUTE wal_records bigint;
ALTER TYPE powa_statements_history_diff ADD ATTRIBUTE wal_fpi bigint;
ALTER TYPE powa_statements_history_diff ADD ATTRIBUTE wal_bytes numeric;

CREATE OR REPLACE FUNCTION powa_statements_history_mi(
    a powa_statements_history_record,
    b powa_statements_history_record)
RETURNS powa_statements_history_diff AS
$_$
DECLARE
    res powa_statements_history_diff;
BEGIN
    res.intvl = a.ts - b.ts;
    res.calls = a.calls - b.calls;
    res.total_exec_time = a.total_exec_time - b.total_exec_time;
    res.rows = a.rows - b.rows;
    res.shared_blks_hit = a.shared_blks_hit - b.shared_blks_hit;
    res.shared_blks_read = a.shared_blks_read - b.shared_blks_read;
    res.shared_blks_dirtied = a.shared_blks_dirtied - b.shared_blks_dirtied;
    res.shared_blks_written = a.shared_blks_written - b.shared_blks_written;
    res.local_blks_hit = a.local_blks_hit - b.local_blks_hit;
    res.local_blks_read = a.local_blks_read - b.local_blks_read;
    res.local_blks_dirtied = a.local_blks_dirtied - b.local_blks_dirtied;
    res.local_blks_written = a.local_blks_written - b.local_blks_written;
    res.temp_blks_read = a.temp_blks_read - b.temp_blks_read;
    res.temp_blks_written = a.temp_blks_written - b.temp_blks_written;
    res.blk_read_time = a.blk_read_time - b.blk_read_time;
    res.blk_write_time = a.blk_write_time - b.blk_write_time;
    res.plans = a.plans - b.plans;
    res.total_plan_time = a.total_plan_time - b.total_plan_time;
    res.wal_records = a.wal_records - b.wal_records;
    res.wal_fpi = a.wal_fpi - b.wal_fpi;
    res.wal_bytes = a.wal_bytes - b.wal_bytes;

    return res;
END;
$_$
LANGUAGE plpgsql IMMUTABLE STRICT;

ALTER TYPE powa_statements_history_rate ADD ATTRIBUTE plans_per_sec double precision;
ALTER TYPE powa_statements_history_rate ADD ATTRIBUTE plantime_per_sec double precision;
ALTER TYPE powa_statements_history_rate ADD ATTRIBUTE wal_records_per_sec double precision;
ALTER TYPE powa_statements_history_rate ADD ATTRIBUTE wal_fpi_per_sec double precision;
ALTER TYPE powa_statements_history_rate ADD ATTRIBUTE wal_bytes_per_sec numeric;

CREATE OR REPLACE FUNCTION powa_statements_history_div(
    a powa_statements_history_record,
    b powa_statements_history_record)
RETURNS powa_statements_history_rate AS
$_$
DECLARE
    res powa_statements_history_rate;
    sec integer;
BEGIN
    res.sec = extract(EPOCH FROM (a.ts - b.ts));
    IF res.sec = 0 THEN
        sec = 1;
    ELSE
        sec = res.sec;
    END IF;
    res.calls_per_sec = (a.calls - b.calls)::double precision / sec;
    res.runtime_per_sec = (a.total_exec_time - b.total_exec_time)::double precision / sec;
    res.rows_per_sec = (a.rows - b.rows)::double precision / sec;
    res.shared_blks_hit_per_sec = (a.shared_blks_hit - b.shared_blks_hit)::double precision / sec;
    res.shared_blks_read_per_sec = (a.shared_blks_read - b.shared_blks_read)::double precision / sec;
    res.shared_blks_dirtied_per_sec = (a.shared_blks_dirtied - b.shared_blks_dirtied)::double precision / sec;
    res.shared_blks_written_per_sec = (a.shared_blks_written - b.shared_blks_written)::double precision / sec;
    res.local_blks_hit_per_sec = (a.local_blks_hit - b.local_blks_hit)::double precision / sec;
    res.local_blks_read_per_sec = (a.local_blks_read - b.local_blks_read)::double precision / sec;
    res.local_blks_dirtied_per_sec = (a.local_blks_dirtied - b.local_blks_dirtied)::double precision / sec;
    res.local_blks_written_per_sec = (a.local_blks_written - b.local_blks_written)::double precision / sec;
    res.temp_blks_read_per_sec = (a.temp_blks_read - b.temp_blks_read)::double precision / sec;
    res.temp_blks_written_per_sec = (a.temp_blks_written - b.temp_blks_written)::double precision / sec;
    res.blk_read_time_per_sec = (a.blk_read_time - b.blk_read_time)::double precision / sec;
    res.blk_write_time_per_sec = (a.blk_write_time - b.blk_write_time)::double precision / sec;
    res.plans_per_sec = (a.plans - b.plans)::double precision / sec;
    res.plantime_per_sec = (a.total_plan_time - b.total_plan_time)::double precision / sec;
    res.wal_records_per_sec = (a.wal_records - b.wal_records)::double precision / sec;
    res.wal_fpi_per_sec = (a.wal_fpi - b.wal_fpi)::double precision / sec;
    res.wal_bytes_per_sec = (a.wal_bytes - b.wal_bytes)::double precision / sec;

    return res;
END;
$_$
LANGUAGE plpgsql IMMUTABLE STRICT;

TRUNCATE TABLE public.powa_statements_src_tmp;
ALTER TABLE public.powa_statements_src_tmp RENAME total_time TO total_exec_time;
ALTER TABLE public.powa_statements_src_tmp ADD plans bigint NOT NULL;
ALTER TABLE public.powa_statements_src_tmp ADD total_plan_time double precision NOT NULL;
ALTER TABLE public.powa_statements_src_tmp ADD wal_records bigint NOT NULL;
ALTER TABLE public.powa_statements_src_tmp ADD wal_fpi bigint NOT NULL;
ALTER TABLE public.powa_statements_src_tmp ADD wal_bytes numeric NOT NULL;

DROP FUNCTION powa_statements_src(integer);

CREATE OR REPLACE FUNCTION powa_statements_src(IN _srvid integer,
    OUT ts timestamp with time zone,
    OUT userid oid,
    OUT dbid oid,
    OUT queryid bigint,
    OUT query text,
    OUT calls bigint,
    OUT total_exec_time double precision,
    OUT rows bigint,
    OUT shared_blks_hit bigint,
    OUT shared_blks_read bigint,
    OUT shared_blks_dirtied bigint,
    OUT shared_blks_written bigint,
    OUT local_blks_hit bigint,
    OUT local_blks_read bigint,
    OUT local_blks_dirtied bigint,
    OUT local_blks_written bigint,
    OUT temp_blks_read bigint,
    OUT temp_blks_written bigint,
    OUT blk_read_time double precision,
    OUT blk_write_time double precision,
    OUT plans bigint,
    OUT total_plan_time float8,
    OUT wal_records bigint,
    OUT wal_fpi bigint,
    OUT wal_bytes numeric
)
RETURNS SETOF record
STABLE
AS $PROC$
DECLARE
    v_pgss integer[];
BEGIN
    IF (_srvid = 0) THEN
        SELECT regexp_split_to_array(extversion, '\.') INTO STRICT v_pgss
        FROM pg_extension
        WHERE extname = 'pg_stat_statements';

        IF (v_pgss[1] = 1 AND v_pgss[2] < 8) THEN
            RETURN QUERY SELECT now(),
                pgss.userid, pgss.dbid, pgss.queryid, pgss.query,
                pgss.calls, pgss.total_time,
                pgss.rows, pgss.shared_blks_hit,
                pgss.shared_blks_read, pgss.shared_blks_dirtied,
                pgss.shared_blks_written, pgss.local_blks_hit,
                pgss.local_blks_read, pgss.local_blks_dirtied,
                pgss.local_blks_written, pgss.temp_blks_read,
                pgss.temp_blks_written, pgss.blk_read_time,pgss.blk_write_time,
                0::bigint, 0::double precision,
                0::bigint, 0::bigint, 0::numeric

            FROM pg_stat_statements pgss
            JOIN pg_database d ON d.oid = pgss.dbid
            JOIN pg_roles r ON pgss.userid = r.oid
            WHERE pgss.query !~* '^[[:space:]]*(DEALLOCATE|BEGIN|PREPARE TRANSACTION|COMMIT PREPARED|ROLLBACK PREPARED)'
            AND NOT (r.rolname = ANY (string_to_array(
                        powa_get_guc('powa.ignored_users', ''),
                        ',')));
        ELSE
            RETURN QUERY SELECT now(),
                pgss.userid, pgss.dbid, pgss.queryid, pgss.query,
                pgss.calls, pgss.total_exec_time,
                pgss.rows, pgss.shared_blks_hit,
                pgss.shared_blks_read, pgss.shared_blks_dirtied,
                pgss.shared_blks_written, pgss.local_blks_hit,
                pgss.local_blks_read, pgss.local_blks_dirtied,
                pgss.local_blks_written, pgss.temp_blks_read,
                pgss.temp_blks_written, pgss.blk_read_time, pgss.blk_write_time,
                pgss.plans, pgss.total_plan_time,
                pgss.wal_records, pgss.wal_fpi, pgss.wal_bytes
            FROM pg_stat_statements pgss
            JOIN pg_database d ON d.oid = pgss.dbid
            JOIN pg_roles r ON pgss.userid = r.oid
            WHERE pgss.query !~* '^[[:space:]]*(DEALLOCATE|BEGIN|PREPARE TRANSACTION|COMMIT PREPARED|ROLLBACK PREPARED)'
            AND NOT (r.rolname = ANY (string_to_array(
                        powa_get_guc('powa.ignored_users', ''),
                        ',')));
        END IF;
    ELSE
        RETURN QUERY SELECT pgss.ts,
            pgss.userid, pgss.dbid, pgss.queryid, pgss.query,
            pgss.calls, pgss.total_exec_time,
            pgss.rows, pgss.shared_blks_hit,
            pgss.shared_blks_read, pgss.shared_blks_dirtied,
            pgss.shared_blks_written, pgss.local_blks_hit,
            pgss.local_blks_read, pgss.local_blks_dirtied,
            pgss.local_blks_written, pgss.temp_blks_read,
            pgss.temp_blks_written, pgss.blk_read_time, pgss.blk_write_time,
            pgss.plans, pgss.total_plan_time,
            pgss.wal_records, pgss.wal_fpi, pgss.wal_bytes
        FROM powa_statements_src_tmp pgss WHERE srvid = _srvid;
    END IF;
END;
$PROC$ LANGUAGE plpgsql; /* end of powa_statements_src */

CREATE OR REPLACE FUNCTION powa_statements_snapshot(_srvid integer) RETURNS void AS $PROC$
DECLARE
    result boolean;
    v_funcname    text := 'powa_statements_snapshot';
    v_rowcount    bigint;
BEGIN
    -- In this function, we capture statements, and also aggregate counters by database
    -- so that the first screens of powa stay reactive even though there may be thousands
    -- of different statements
    -- We only capture databases that are still there
    PERFORM powa_log(format('running %I', v_funcname));

    PERFORM powa_prevent_concurrent_snapshot(_srvid);

    WITH capture AS(
        SELECT *
        FROM powa_statements_src(_srvid)
    ),
    mru as (UPDATE powa_statements set last_present_ts = now()
            FROM capture
            WHERE powa_statements.queryid = capture.queryid
              AND powa_statements.dbid = capture.dbid
              AND powa_statements.userid = capture.userid
              AND powa_statements.srvid = _srvid
    ),
    missing_statements AS(
        INSERT INTO public.powa_statements (srvid, queryid, dbid, userid, query)
            SELECT _srvid, queryid, dbid, userid, query
            FROM capture c
            WHERE NOT EXISTS (SELECT 1
                              FROM powa_statements ps
                              WHERE ps.queryid = c.queryid
                              AND ps.dbid = c.dbid
                              AND ps.userid = c.userid
                              AND ps.srvid = _srvid
            )
    ),

    by_query AS (
        INSERT INTO public.powa_statements_history_current
            SELECT _srvid, queryid, dbid, userid,
            ROW(
                ts, calls, total_exec_time, rows,
                shared_blks_hit, shared_blks_read, shared_blks_dirtied,
                shared_blks_written, local_blks_hit, local_blks_read,
                local_blks_dirtied, local_blks_written, temp_blks_read,
                temp_blks_written, blk_read_time, blk_write_time,
                plans, total_plan_time,
                wal_records, wal_fpi, wal_bytes
            )::powa_statements_history_record AS record
            FROM capture
    ),

    by_database AS (
        INSERT INTO public.powa_statements_history_current_db
            SELECT _srvid, dbid,
            ROW(
                ts, sum(calls),
                sum(total_exec_time), sum(rows), sum(shared_blks_hit),
                sum(shared_blks_read), sum(shared_blks_dirtied),
                sum(shared_blks_written), sum(local_blks_hit),
                sum(local_blks_read), sum(local_blks_dirtied),
                sum(local_blks_written), sum(temp_blks_read),
                sum(temp_blks_written), sum(blk_read_time), sum(blk_write_time),
                sum(plans), sum(total_plan_time),
                sum(wal_records), sum(wal_fpi), sum(wal_bytes)
            )::powa_statements_history_record AS record
            FROM capture
            GROUP BY dbid, ts
    )

    SELECT count(*) INTO v_rowcount
    FROM capture;

    perform powa_log(format('%I - rowcount: %s',
            v_funcname, v_rowcount));

    IF (_srvid != 0) THEN
        DELETE FROM powa_statements_src_tmp WHERE srvid = _srvid;
    END IF;

    result := true; -- For now we don't care. What could we do on error except crash anyway?
END;
$PROC$ language plpgsql; /* end of powa_statements_snapshot */

CREATE OR REPLACE FUNCTION powa_statements_aggregate(_srvid integer)
RETURNS void AS $PROC$
DECLARE
    v_funcname    text := 'powa_statements_aggregate(' || _srvid || ')';
    v_rowcount    bigint;
BEGIN
    PERFORM powa_log(format('running %I', v_funcname));

    PERFORM powa_prevent_concurrent_snapshot(_srvid);

    -- aggregate statements table
    INSERT INTO public.powa_statements_history
        SELECT srvid, queryid, dbid, userid,
            tstzrange(min((record).ts), max((record).ts),'[]'),
            array_agg(record),
            ROW(min((record).ts),
                min((record).calls),min((record).total_exec_time),
                min((record).rows),
                min((record).shared_blks_hit),min((record).shared_blks_read),
                min((record).shared_blks_dirtied),min((record).shared_blks_written),
                min((record).local_blks_hit),min((record).local_blks_read),
                min((record).local_blks_dirtied),min((record).local_blks_written),
                min((record).temp_blks_read),min((record).temp_blks_written),
                min((record).blk_read_time),min((record).blk_write_time),
                min((record).plans),min((record).total_plan_time),
                min((record).wal_records),min((record).wal_fpi),
                min((record).wal_bytes)
            )::powa_statements_history_record,
            ROW(max((record).ts),
                max((record).calls),max((record).total_exec_time),
                max((record).rows),
                max((record).shared_blks_hit),max((record).shared_blks_read),
                max((record).shared_blks_dirtied),max((record).shared_blks_written),
                max((record).local_blks_hit),max((record).local_blks_read),
                max((record).local_blks_dirtied),max((record).local_blks_written),
                max((record).temp_blks_read),max((record).temp_blks_written),
                max((record).blk_read_time),max((record).blk_write_time),
                max((record).plans),max((record).total_plan_time),
                max((record).wal_records),max((record).wal_fpi),
                max((record).wal_bytes)
            )::powa_statements_history_record
        FROM powa_statements_history_current
        WHERE srvid = _srvid
        GROUP BY srvid, queryid, dbid, userid;

    GET DIAGNOSTICS v_rowcount = ROW_COUNT;
    perform powa_log(format('%I (powa_statements_history) - rowcount: %s',
            v_funcname, v_rowcount));

    DELETE FROM powa_statements_history_current WHERE srvid = _srvid;

    -- aggregate db table
    INSERT INTO public.powa_statements_history_db
        SELECT srvid, dbid,
            tstzrange(min((record).ts), max((record).ts),'[]'),
            array_agg(record),
            ROW(min((record).ts),
                min((record).calls),min((record).total_exec_time),
                min((record).rows),
                min((record).shared_blks_hit),min((record).shared_blks_read),
                min((record).shared_blks_dirtied),min((record).shared_blks_written),
                min((record).local_blks_hit),min((record).local_blks_read),
                min((record).local_blks_dirtied),min((record).local_blks_written),
                min((record).temp_blks_read),min((record).temp_blks_written),
                min((record).blk_read_time),min((record).blk_write_time),
                min((record).plans),min((record).total_plan_time),
                min((record).wal_records),min((record).wal_fpi),
                min((record).wal_bytes)
            )::powa_statements_history_record,
            ROW(max((record).ts),
                max((record).calls),max((record).total_exec_time),
                max((record).rows),
                max((record).shared_blks_hit),max((record).shared_blks_read),
                max((record).shared_blks_dirtied),max((record).shared_blks_written),
                max((record).local_blks_hit),max((record).local_blks_read),
                max((record).local_blks_dirtied),max((record).local_blks_written),
                max((record).temp_blks_read),max((record).temp_blks_written),
                max((record).blk_read_time),max((record).blk_write_time),
                max((record).plans),max((record).total_plan_time),
                max((record).wal_records),max((record).wal_fpi),
                max((record).wal_bytes)
            )::powa_statements_history_record
        FROM powa_statements_history_current_db
        WHERE srvid = _srvid
        GROUP BY srvid, dbid;

    GET DIAGNOSTICS v_rowcount = ROW_COUNT;
    perform powa_log(format('%I (powa_statements_history_db) - rowcount: %s',
            v_funcname, v_rowcount));

    DELETE FROM powa_statements_history_current_db WHERE srvid = _srvid;
END;
$PROC$ LANGUAGE plpgsql; /* end of powa_statements_aggregate */

CREATE OR REPLACE FUNCTION powa_statements_purge(_srvid integer)
RETURNS void AS $PROC$
DECLARE
    v_funcname    text := 'powa_statements_purge(' || _srvid || ')';
    v_rowcount    bigint;
    v_retention   interval;
BEGIN
    PERFORM powa_log(format('running %I', v_funcname));

    PERFORM powa_prevent_concurrent_snapshot(_srvid);

    SELECT powa_get_server_retention(_srvid) INTO v_retention;

    -- Delete obsolete data. We only bother with already coalesced data
    DELETE FROM powa_statements_history
    WHERE upper(coalesce_range)< (now() - v_retention)
    AND srvid = _srvid;

    GET DIAGNOSTICS v_rowcount = ROW_COUNT;
    perform powa_log(format('%I (powa_statements_hitory) - rowcount: %s',
            v_funcname, v_rowcount));

    DELETE FROM powa_statements_history_db
    WHERE upper(coalesce_range)< (now() - v_retention)
    AND srvid = _srvid;

    GET DIAGNOSTICS v_rowcount = ROW_COUNT;
    perform powa_log(format('%I (powa_statements_history_db) - rowcount: %s',
            v_funcname, v_rowcount));

    DELETE FROM powa_statements
    WHERE last_present_ts < (now() - v_retention)
    AND srvid = _srvid;

    GET DIAGNOSTICS v_rowcount = ROW_COUNT;
    perform powa_log(format('%I (powa_statements) - rowcount: %s',
            v_funcname, v_rowcount));
END;
$PROC$ LANGUAGE plpgsql; /* end of powa_statements_purge */

-- automatically configure powa for local snapshot if supported extension are
-- created locally
CREATE OR REPLACE FUNCTION public.powa_check_created_extensions()
RETURNS event_trigger
LANGUAGE plpgsql
AS $_$
DECLARE
BEGIN
    /* We have for now no way for a proper handling of this event,
     * as we don't have a table with the list of supported extensions.
     * So just call every powa_*_register() function we know each time an
     * extension is created. Powa should be in a dedicated database and the
     * register function handle to be called several time, so it's not critical
     */
    PERFORM public.powa_activate_extension(0, 'pg_stat_kcache');
    PERFORM public.powa_activate_extension(0, 'pg_qualstats');
    PERFORM public.powa_activate_extension(0, 'pg_track_settings');
    PERFORM public.powa_activate_extension(0, 'pg_wait_sampling');
END;
$_$; /* end of powa_check_created_extensions */

-- automatically remove extensions from local snapshot if supported extension
-- is removed locally
CREATE OR REPLACE FUNCTION public.powa_check_dropped_extensions()
RETURNS event_trigger
LANGUAGE plpgsql
AS $_$
DECLARE
    funcname text;
    v_state   text;
    v_msg     text;
    v_detail  text;
    v_hint    text;
    v_context text;
BEGIN
    -- We unregister extensions regardless the "enabled" field
    WITH ext AS (
        SELECT object_name
        FROM pg_event_trigger_dropped_objects() d
        WHERE d.object_type = 'extension'
    )
    SELECT function_name INTO funcname
    FROM powa_functions f
    JOIN ext ON f.module = ext.object_name
    WHERE operation = 'unregister'
    ORDER BY module;

    IF ( funcname IS NOT NULL ) THEN
        BEGIN
            PERFORM powa_log(format('running %I', funcname));
            EXECUTE 'SELECT ' || quote_ident(funcname) || '(0)';
        EXCEPTION
          WHEN OTHERS THEN
            GET STACKED DIAGNOSTICS
                v_state   = RETURNED_SQLSTATE,
                v_msg     = MESSAGE_TEXT,
                v_detail  = PG_EXCEPTION_DETAIL,
                v_hint    = PG_EXCEPTION_HINT,
                v_context = PG_EXCEPTION_CONTEXT;
            RAISE WARNING 'powa_check_dropped_extensions(): function "%" failed:
                state  : %
                message: %
                detail : %
                hint   : %
                context: %', funcname, v_state, v_msg, v_detail, v_hint, v_context;
        END;
    END IF;
END;
$_$; /* end of powa_check_dropped_extensions */

ALTER TABLE public.powa_servers ADD version text;

ALTER TABLE public.powa_functions ADD extname text;
UPDATE public.powa_functions SET extname = module WHERE module != 'pg_stat_bgwriter';
UPDATE public.powa_functions SET extname = 'powa' WHERE extname LIKE 'powa%';

CREATE TABLE public.powa_extensions (
    srvid integer,
    extname text,
    version text,
    PRIMARY KEY (srvid, extname),
    FOREIGN KEY (srvid) REFERENCES public.powa_servers (id)
);
INSERT INTO public.powa_extensions (srvid, extname)
    SELECT DISTINCT srvid,
        CASE WHEN module LIKE 'powa%' THEN 'powa' ELSE module END
    FROM public.powa_functions
    WHERE module != 'pg_stat_bgwriter';

ALTER TABLE public.powa_functions
    ADD FOREIGN KEY (srvid, extname)
    REFERENCES public.powa_extensions (srvid, extname)
    ON UPDATE CASCADE ON DELETE CASCADE;

DROP FUNCTION public.powa_activate_extension(integer, text);
-- Register the module if needed, and set the enabled flag to on.  This
-- function should only be callsed by powa_register_server.
CREATE OR REPLACE FUNCTION public.powa_activate_extension(_srvid integer, _module text) RETURNS boolean
AS $_$
DECLARE
    v_ext_registered boolean;
    v_manually boolean;
    v_found boolean;
    v_extname text;
BEGIN
    SELECT COUNT(*) > 0 INTO v_ext_registered
    FROM powa_functions
    WHERE module = _module
    AND srvid = _srvid;

    IF (_module LIKE 'powa%') THEN
        v_extname = 'powa';
    ELSIF (_module = 'pg_stat_bgwriter') THEN
        v_extname = NULL;
    ELSE
        v_extname = _module;
    END IF;

    -- the rows may already be present, but the enabled flag could be off,
    -- so enabled it everywhere it's disabled.  We don't check for other cases,
    -- for instance if part of the needed rows were deleted.
    IF (v_ext_registered) THEN
        UPDATE powa_functions
        SET enabled = true
        WHERE enabled = false
        AND srvid = _srvid
        AND module = _module;

        RETURN true;
    END IF;

    -- Add the row in powa_extensions if needed.  Note that since we add the
    -- row before knowing if it's a supported extension, we may have to remove
    -- it later.
    IF (v_extname IS NOT NULL) THEN
        SELECT COUNT(*) = 1 INTO v_found
        FROM public.powa_extensions
        WHERE srvid = _srvid
        AND extname = v_extname;

        IF NOT v_found THEN
            INSERT INTO public.powa_extensions (srvid, extname)
            VALUES (_srvid, v_extname);
        END IF;
    END IF;

    -- default extensions for non-local server have to be dumped
    SELECT _srvid != 0 INTO v_manually;

    IF (_module = 'pg_stat_statements') THEN
        INSERT INTO public.powa_functions(srvid, extname, module, operation, function_name,
            query_source, added_manually, enabled, priority)
        VALUES
        (_srvid, 'pg_stat_statements', 'pg_stat_statements', 'snapshot',  'powa_databases_snapshot',   'powa_databases_src',  v_manually, true, -1),
        (_srvid, 'pg_stat_statements', 'pg_stat_statements', 'snapshot',  'powa_statements_snapshot',  'powa_statements_src', v_manually, true, default),
        (_srvid, 'pg_stat_statements', 'pg_stat_statements', 'aggregate', 'powa_statements_aggregate', NULL,                  v_manually, true, default),
        (_srvid, 'pg_stat_statements', 'pg_stat_statements', 'purge',     'powa_statements_purge',     NULL,                  v_manually, true, default),
        (_srvid, 'pg_stat_statements', 'pg_stat_statements', 'purge',     'powa_databases_purge',      NULL,                  v_manually, true, default),
        (_srvid, 'pg_stat_statements', 'pg_stat_statements', 'reset',     'powa_statements_reset',     NULL,                  v_manually, true, default);
    ELSIF (_module = 'powa_stat_user_functions') THEN
        INSERT INTO public.powa_functions(srvid, extname, module, operation, function_name,
            query_source, added_manually, enabled, priority)
        VALUES
         (_srvid, 'powa', 'powa_stat_user_functions', 'snapshot',  'powa_user_functions_snapshot',  'powa_user_functions_src', v_manually, true, default),
         (_srvid, 'powa', 'powa_stat_user_functions', 'aggregate', 'powa_user_functions_aggregate', NULL,                      v_manually, true, default),
         (_srvid, 'powa', 'powa_stat_user_functions', 'purge',     'powa_user_functions_purge',     NULL,                      v_manually, true, default),
         (_srvid, 'powa', 'powa_stat_user_functions', 'reset',     'powa_user_functions_reset',     NULL,                      v_manually, true, default);
    ELSIF (_module = 'powa_stat_all_relations') THEN
        INSERT INTO public.powa_functions(srvid, extname, module, operation, function_name,
            query_source, added_manually, enabled, priority)
        VALUES
        (_srvid, 'powa', 'powa_stat_all_relations',  'snapshot',  'powa_all_relations_snapshot',   'powa_all_relations_src',  v_manually, true, default),
        (_srvid, 'powa', 'powa_stat_all_relations',  'aggregate', 'powa_all_relations_aggregate',  NULL,                      v_manually, true, default),
        (_srvid, 'powa', 'powa_stat_all_relations',  'purge',     'powa_all_relations_purge',      NULL,                      v_manually, true, default),
        (_srvid, 'powa', 'powa_stat_all_relations',  'reset',     'powa_all_relations_reset',      NULL,                      v_manually, true, default);
    ELSIF (_module = 'pg_stat_bgwriter') THEN
        INSERT INTO public.powa_functions(srvid, extname, module, operation, function_name,
            query_source, added_manually, enabled, priority)
        VALUES
        (_srvid, NULL, 'pg_stat_bgwriter',  'snapshot',  'powa_stat_bgwriter_snapshot',   'powa_stat_bgwriter_src',  v_manually, true, default),
        (_srvid, NULL, 'pg_stat_bgwriter',  'aggregate', 'powa_stat_bgwriter_aggregate',  NULL,                      v_manually, true, default),
        (_srvid, NULL, 'pg_stat_bgwriter',  'purge',     'powa_stat_bgwriter_purge',      NULL,                      v_manually, true, default),
        (_srvid, NULL, 'pg_stat_bgwriter',  'reset',     'powa_stat_bgwriter_reset',      NULL,                      v_manually, true, default);
    ELSIF (_module = 'pg_stat_kcache') THEN
        RETURN powa_kcache_register(_srvid);
    ELSIF (_module = 'pg_qualstats') THEN
        RETURN powa_qualstats_register(_srvid);
    ELSIF (_module = 'pg_wait_sampling') THEN
        RETURN powa_wait_sampling_register(_srvid);
    ELSIF (_module = 'pg_track_settings') THEN
        RETURN powa_track_settings_register(_srvid);
    ELSE
        -- remove the previously added row in powa_extensions
        IF (v_extname IS NOT NULL) THEN
            DELETE FROM public.powa_extensions
                WHERE srvid = _srvid AND extname = v_extname;
        END IF;

        RETURN false;
    END IF;

    return true;
END;
$_$ LANGUAGE plpgsql; /* end of powa_activate_extension */

/*
 * register pg_stat_kcache extension
 */
CREATE OR REPLACE function public.powa_kcache_register(_srvid integer = 0) RETURNS bool AS
$_$
DECLARE
    v_func_present bool;
    v_ext_present bool;
BEGIN
    -- Only check for extension availability for local server
    IF (_srvid = 0) THEN
        SELECT COUNT(*) = 1 INTO v_ext_present
        FROM pg_extension
        WHERE extname = 'pg_stat_kcache';
    ELSE
        v_ext_present = true;
    END IF;

    IF ( v_ext_present ) THEN
        SELECT COUNT(*) > 0 INTO v_func_present
        FROM public.powa_functions
        WHERE module = 'pg_stat_kcache'
        AND srvid = _srvid;

        IF ( NOT v_func_present) THEN
            PERFORM powa_log('registering pg_stat_kcache');

            INSERT INTO public.powa_functions (srvid, extname, module, operation, function_name, query_source, added_manually, enabled, priority)
            VALUES (_srvid, 'pg_stat_kcache', 'pg_stat_kcache', 'snapshot',   'powa_kcache_snapshot',   'powa_kcache_src', true, true, -1),
                   (_srvid, 'pg_stat_kcache', 'pg_stat_kcache', 'aggregate',  'powa_kcache_aggregate',  NULL,              true, true, default),
                   (_srvid, 'pg_stat_kcache', 'pg_stat_kcache', 'unregister', 'powa_kcache_unregister', NULL,              true, true, default),
                   (_srvid, 'pg_stat_kcache', 'pg_stat_kcache', 'purge',      'powa_kcache_purge',      NULL,              true, true, default),
                   (_srvid, 'pg_stat_kcache', 'pg_stat_kcache', 'reset',      'powa_kcache_reset',      NULL,              true, true, default);
        END IF;
    END IF;

    RETURN true;
END;
$_$
language plpgsql; /* end of powa_kcache_register */

/*
 * powa_qualstats_register
 */
CREATE OR REPLACE function public.powa_qualstats_register(_srvid integer = 0) RETURNS bool AS
$_$
DECLARE
    v_func_present bool;
    v_ext_present bool;
BEGIN
    IF (_srvid = 0) THEN
        SELECT COUNT(*) = 1 INTO v_ext_present
        FROM pg_extension
        WHERE extname = 'pg_qualstats';
    ELSE
        v_ext_present = true;
    END IF;

    IF ( v_ext_present) THEN
        SELECT COUNT(*) > 0 INTO v_func_present
        FROM public.powa_functions
        WHERE module = 'pg_qualstats'
        AND srvid = _srvid;

        IF ( NOT v_func_present) THEN
            PERFORM powa_log('registering pg_qualstats');

            INSERT INTO public.powa_functions (srvid, extname, module, operation, function_name, query_source, query_cleanup, added_manually, enabled)
            VALUES (_srvid, 'pg_qualstats', 'pg_qualstats', 'snapshot',   'powa_qualstats_snapshot',   'powa_qualstats_src', 'SELECT pg_qualstats_reset()', true, true),
                   (_srvid, 'pg_qualstats', 'pg_qualstats', 'aggregate',  'powa_qualstats_aggregate',  NULL,                 NULL,                          true, true),
                   (_srvid, 'pg_qualstats', 'pg_qualstats', 'unregister', 'powa_qualstats_unregister', NULL,                 NULL,                          true, true),
                   (_srvid, 'pg_qualstats', 'pg_qualstats', 'purge',      'powa_qualstats_purge',      NULL,                 NULL,                          true, true),
                   (_srvid, 'pg_qualstats', 'pg_qualstats', 'reset',      'powa_qualstats_reset',      NULL,                 NULL,                          true, true);
        END IF;
    END IF;

    RETURN true;
END;
$_$
language plpgsql; /* end of powa_qualstats_register */

/*
 * register pg_wait_sampling extension
 */
CREATE OR REPLACE function public.powa_wait_sampling_register(_srvid integer = 0) RETURNS bool AS
$_$
DECLARE
    v_func_present bool;
    v_ext_present bool;
BEGIN
    -- Only check for extension availability for local server
    IF (_srvid = 0) THEN
        SELECT COUNT(*) = 1 INTO v_ext_present
        FROM pg_extension
        WHERE extname = 'pg_wait_sampling';
    ELSE
        v_ext_present = true;
    END IF;

    IF ( v_ext_present ) THEN
        SELECT COUNT(*) > 0 INTO v_func_present
        FROM public.powa_functions
        WHERE module = 'pg_wait_sampling'
        AND srvid = _srvid;

        IF ( NOT v_func_present) THEN
            PERFORM powa_log('registering pg_wait_sampling');

            INSERT INTO public.powa_functions (srvid, extname, module, operation, function_name, query_source, added_manually, enabled)
            VALUES (_srvid, 'pg_wait_sampling', 'pg_wait_sampling', 'snapshot',   'powa_wait_sampling_snapshot',   'powa_wait_sampling_src', true, true),
                   (_srvid, 'pg_wait_sampling', 'pg_wait_sampling', 'aggregate',  'powa_wait_sampling_aggregate',  NULL,                     true, true),
                   (_srvid, 'pg_wait_sampling', 'pg_wait_sampling', 'unregister', 'powa_wait_sampling_unregister', NULL,                     true, true),
                   (_srvid, 'pg_wait_sampling', 'pg_wait_sampling', 'purge',      'powa_wait_sampling_purge',      NULL,                     true, true),
                   (_srvid, 'pg_wait_sampling', 'pg_wait_sampling', 'reset',      'powa_wait_sampling_reset',      NULL,                     true, true);
        END IF;
    END IF;

    RETURN true;
END;
$_$
language plpgsql; /* end of powa_wait_sampling_register */

CREATE OR REPLACE FUNCTION powa_track_settings_register(_srvid integer = 0) RETURNS bool AS $_$
DECLARE
    v_func_present bool;
    v_ext_present bool;
BEGIN
    IF (_srvid = 0) THEN
        SELECT COUNT(*) = 1 INTO v_ext_present
        FROM pg_extension
        WHERE extname = 'pg_track_settings';
    ELSE
        v_ext_present = true;
    END IF;

    IF ( v_ext_present ) THEN
        SELECT COUNT(*) > 0 INTO v_func_present
        FROM public.powa_functions
        WHERE module = 'pg_track_settings'
        AND srvid = _srvid;

        IF ( NOT v_func_present) THEN
            PERFORM powa_log('registering pg_track_settings');

            -- This extension handles its own storage, just add its snapshot,
            -- reset and an unregister function.
            INSERT INTO public.powa_functions (srvid, extname, module, operation, function_name, query_source, added_manually, enabled)
            VALUES (_srvid, 'pg_track_settings', 'pg_track_settings', 'snapshot',   'pg_track_settings_snapshot_settings', 'pg_track_settings_settings_src', true, true),
                   (_srvid, 'pg_track_settings', 'pg_track_settings', 'snapshot',   'pg_track_settings_snapshot_rds',      'pg_track_settings_rds_src',      true, true),
                   (_srvid, 'pg_track_settings', 'pg_track_settings', 'snapshot',   'pg_track_settings_snapshot_reboot',   'pg_track_settings_reboot_src',   true, true),
                   (_srvid, 'pg_track_settings', 'pg_track_settings', 'reset',      'pg_track_settings_reset',             NULL,                             true, true),
                   (_srvid, 'pg_track_settings', 'pg_track_settings', 'unregister', 'powa_track_settings_unregister',      NULL,                             true, true);
        END IF;
    END IF;

    RETURN true;
END;
$_$ language plpgsql; /* end of pg_track_settings_register */

CREATE OR REPLACE FUNCTION powa_kcache_src(IN _srvid integer,
    OUT ts timestamp with time zone,
    OUT queryid bigint, OUT userid oid, OUT dbid oid,
    OUT reads bigint, OUT writes bigint,
    OUT user_time double precision, OUT system_time double precision,
    OUT minflts bigint, OUT majflts bigint,
    OUT nswaps bigint,
    OUT msgsnds bigint, OUT msgrcvs bigint,
    OUT nsignals bigint,
    OUT nvcsws bigint, OUT nivcsws bigint
) RETURNS SETOF record STABLE AS $PROC$
BEGIN
    IF (_srvid = 0) THEN
        RETURN QUERY SELECT now(),
            k.queryid, k.userid, k.dbid, k.reads, k.writes, k.user_time,
            k.system_time, k.minflts, k.majflts, k.nswaps, k.msgsnds,
            k.msgrcvs, k.nsignals, k.nvcsws, k.nivcsws
        FROM pg_stat_kcache() k
        JOIN pg_roles r ON r.oid = k.userid
        WHERE NOT (r.rolname = ANY (string_to_array(
                    powa_get_guc('powa.ignored_users', ''),
                    ',')))
        AND k.dbid NOT IN (SELECT oid FROM powa_databases WHERE dropped IS NOT NULL);
    ELSE
        RETURN QUERY SELECT k.ts,
            k.queryid, k.userid, k.dbid, k.reads, k.writes, k.user_time,
            k.system_time, k.minflts, k.majflts, k.nswaps, k.msgsnds,
            k.msgrcvs, k.nsignals, k.nvcsws, k.nivcsws
        FROM powa_kcache_src_tmp k
        WHERE k.srvid = _srvid;
    END IF;
END;
$PROC$ LANGUAGE plpgsql; /* end of powa_kcache_src */

CREATE OR REPLACE FUNCTION powa_qualstats_src(IN _srvid integer,
    OUT ts timestamp with time zone,
    OUT uniquequalnodeid bigint,
    OUT dbid oid,
    OUT userid oid,
    OUT qualnodeid bigint,
    OUT occurences bigint,
    OUT execution_count bigint,
    OUT nbfiltered bigint,
    OUT mean_err_estimate_ratio double precision,
    OUT mean_err_estimate_num double precision,
    OUT queryid bigint,
    OUT constvalues varchar[],
    OUT quals qual_type[]
) RETURNS SETOF record STABLE AS $PROC$
DECLARE
  is_v2 bool;
  ratio_col text := 'qs.mean_err_estimate_ratio';
  num_col text := 'qs.mean_err_estimate_num';
  sql text;
BEGIN
    IF (_srvid = 0) THEN
        SELECT substr(extversion, 1, 1)::int >=2 INTO STRICT is_v2
          FROM pg_extension
          WHERE extname = 'pg_qualstats';


        IF NOT is_v2 THEN
            ratio_col := 'NULL::double precision';
            num_col := 'NULL::double precision';
        END IF;

        sql := format($sql$
            SELECT now(), pgqs.uniquequalnodeid, pgqs.dbid, pgqs.userid,
                pgqs.qualnodeid, pgqs.occurences, pgqs.execution_count,
                pgqs.nbfiltered, pgqs.mean_err_estimate_ratio,
                pgqs.mean_err_estimate_num, pgqs.queryid, pgqs.constvalues,
                pgqs.quals
            FROM (
                SELECT coalesce(i.uniquequalid, i.uniquequalnodeid) AS uniquequalnodeid,
                    i.dbid, i.userid,  coalesce(i.qualid, i.qualnodeid) AS qualnodeid,
                    i.occurences, i.execution_count, i.nbfiltered,
                    i.mean_err_estimate_ratio, i.mean_err_estimate_num,
                    i.queryid,
                    array_agg(i.constvalue order by i.constant_position) AS constvalues,
                    array_agg(ROW(i.relid, i.attnum, i.opno, i.eval_type)::qual_type) AS quals
                FROM
                (
                    SELECT qs.dbid,
                    CASE WHEN lrelid IS NOT NULL THEN lrelid
                        WHEN rrelid IS NOT NULL THEN rrelid
                    END as relid,
                    qs.userid as userid,
                    CASE WHEN lrelid IS NOT NULL THEN lattnum
                        WHEN rrelid IS NOT NULL THEN rattnum
                    END as attnum,
                    qs.opno as opno,
                    qs.qualid as qualid,
                    qs.uniquequalid as uniquequalid,
                    qs.qualnodeid as qualnodeid,
                    qs.uniquequalnodeid as uniquequalnodeid,
                    qs.occurences as occurences,
                    qs.execution_count as execution_count,
                    qs.queryid as queryid,
                    qs.constvalue as constvalue,
                    qs.nbfiltered as nbfiltered,
                    %s AS mean_err_estimate_ratio,
                    %s AS mean_err_estimate_num,
                    qs.eval_type,
                    qs.constant_position
                    FROM pg_qualstats() qs
                    WHERE (qs.lrelid IS NULL) != (qs.rrelid IS NULL)
                ) i
                GROUP BY coalesce(i.uniquequalid, i.uniquequalnodeid),
                    coalesce(i.qualid, i.qualnodeid), i.dbid, i.userid,
                    i.occurences, i.execution_count, i.nbfiltered,
                    i.mean_err_estimate_ratio, i.mean_err_estimate_num,
                    i.queryid
            ) pgqs
            JOIN (
                -- if we use remote capture, powa_statements won't be
                -- populated, so we have to to retrieve the content of both
                -- statements sources.  Since there can (and probably) be
                -- duplicates, we use a UNION on purpose
                SELECT s1.queryid, s1.dbid, s1.userid
                    FROM pg_stat_statements s1
                UNION
                SELECT s2.queryid, s2.dbid, s2.userid
                    FROM powa_statements s2 WHERE s2.srvid = 0
            ) s USING(queryid, dbid, userid)
        -- we don't gather quals for databases that have been dropped
        JOIN pg_database d ON d.oid = s.dbid
        JOIN pg_roles r ON s.userid = r.oid
          AND NOT (r.rolname = ANY (string_to_array(
                    powa_get_guc('powa.ignored_users', ''),
                    ',')))
        WHERE pgqs.dbid NOT IN (SELECT oid FROM powa_databases WHERE dropped IS NOT NULL)
        $sql$, ratio_col, num_col);
        RETURN QUERY EXECUTE sql;
    ELSE
        RETURN QUERY
            SELECT pgqs.ts, pgqs.uniquequalnodeid, pgqs.dbid, pgqs.userid,
                pgqs.qualnodeid, pgqs.occurences, pgqs.execution_count,
                pgqs.nbfiltered, pgqs.mean_err_estimate_ratio,
                pgqs.mean_err_estimate_num, pgqs.queryid, pgqs.constvalues,
                pgqs.quals
            FROM powa_qualstats_src_tmp pgqs
        WHERE pgqs.srvid = _srvid;
    END IF;
END;
$PROC$ LANGUAGE plpgsql; /* end of powa_qualstats_src */
