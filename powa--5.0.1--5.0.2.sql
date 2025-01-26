-- complain if script is sourced in psql, rather than via CREATE EXTENSION
\echo Use "ALTER EXTENSION powa" to load this file. \quit

CREATE OR REPLACE FUNCTION @extschema@.powa_take_snapshot(_srvid integer = 0) RETURNS integer
AS $PROC$
DECLARE
  purgets timestamp with time zone;
  purge_seq  bigint;
  r          record;
  v_state    text;
  v_msg      text;
  v_detail   text;
  v_hint     text;
  v_context  text;
  v_title    text = 'PoWA - ';
  v_rowcount bigint;
  v_nb_err int = 0;
  v_errs     text[] = '{}';
  v_pattern  text = '@extschema@.powa_take_snapshot(%s): function %s.%I failed:
              state  : %s
              message: %s
              detail : %s
              hint   : %s
              context: %s';
  v_pattern_simple text = '@extschema@.powa_take_snapshot(%s): function %s.%I failed: %s';

  v_pattern_cat  text = '@extschema@.powa_take_snapshot(%s): function @extschema@.powa_catalog_generic_snapshot for catalog %s failed:
              state  : %s
              message: %s
              detail : %s
              hint   : %s
              context: %s';
  v_pattern_cat_simple text = '@extschema@.powa_take_snapshot(%s): function @extschema@.powa_catalog_generic_snapshot for catalog %s failed: %s';
  v_coalesce bigint;
  v_catname text;
BEGIN
    PERFORM set_config('application_name',
        v_title || ' snapshot database list',
        false);
    PERFORM @extschema@.powa_log('start of powa_take_snapshot(' || _srvid || ')');

    PERFORM @extschema@.powa_prevent_concurrent_snapshot(_srvid);

    UPDATE @extschema@.powa_snapshot_metas
    SET coalesce_seq = coalesce_seq + 1,
        errors = NULL,
        snapts = now()
    WHERE srvid = _srvid
    RETURNING coalesce_seq INTO purge_seq;

    PERFORM @extschema@.powa_log(format('coalesce_seq(%s): %s', _srvid, purge_seq));

    IF (_srvid = 0) THEN
        SELECT current_setting('powa.coalesce') INTO v_coalesce;
    ELSE
        SELECT powa_coalesce
        FROM @extschema@.powa_servers
        WHERE id = _srvid
        INTO v_coalesce;
    END IF;

    -- For all enabled snapshot functions in the powa_functions table, execute
    FOR r IN SELECT CASE external
                WHEN true THEN quote_ident(nsp.nspname)
                ELSE '@extschema@'
             END AS schema, function_name AS funcname
             FROM @extschema@.powa_all_functions AS pf
             LEFT JOIN pg_extension AS ext ON pf.kind = 'extension'
                AND ext.extname = pf.name
             LEFT JOIN pg_namespace AS nsp ON nsp.oid = ext.extnamespace
             WHERE operation='snapshot'
             AND enabled
             AND srvid = _srvid
             ORDER BY priority, name
    LOOP
      -- Call all of them, for the current srvid
      BEGIN
        PERFORM @extschema@.powa_log(format('calling snapshot function: %s.%I',
                                     r.schema, r.funcname));
        PERFORM set_config('application_name',
            v_title || quote_ident(r.funcname) || '(' || _srvid || ')', false);

        EXECUTE format('SELECT %s.%I(%s)', r.schema, r.funcname, _srvid);
      EXCEPTION
        WHEN OTHERS THEN
          GET STACKED DIAGNOSTICS
              v_state   = RETURNED_SQLSTATE,
              v_msg     = MESSAGE_TEXT,
              v_detail  = PG_EXCEPTION_DETAIL,
              v_hint    = PG_EXCEPTION_HINT,
              v_context = PG_EXCEPTION_CONTEXT;

          RAISE warning '%', format(v_pattern, _srvid, r.schema, r.funcname,
            v_state, v_msg, v_detail, v_hint, v_context);

          v_errs := array_append(v_errs, format(v_pattern_simple, _srvid,
                r.schema, r.funcname, v_msg));

          v_nb_err = v_nb_err + 1;
      END;
    END LOOP;

    -- Coalesce datas if needed. The _srvid % 20 is there to avoid having all coalesces run at once
    IF ( ((purge_seq + (_srvid % 20) ) % v_coalesce ) = 0 )
    THEN
      PERFORM @extschema@.powa_log(
        format('coalesce needed, srvid: %s - seq: %s - coalesce seq: %s',
        _srvid, purge_seq, v_coalesce ));

      FOR r IN SELECT CASE external
                  WHEN true THEN quote_ident(nsp.nspname)
                  ELSE '@extschema@'
               END AS schema, function_name AS funcname
               FROM @extschema@.powa_all_functions AS pf
               LEFT JOIN pg_extension AS ext ON pf.kind = 'extension'
                  AND ext.extname = pf.name
               LEFT JOIN pg_namespace AS nsp ON nsp.oid = ext.extnamespace
               WHERE operation='aggregate'
               AND enabled
               AND srvid = _srvid
               ORDER BY priority, name
      LOOP
        -- Call all of them, for the current srvid
        BEGIN
          PERFORM @extschema@.powa_log(format('calling aggregate function: %s.%I(%s)',
                r.schema, r.funcname, _srvid));

          PERFORM set_config('application_name',
              v_title || quote_ident(r.funcname) || '(' || _srvid || ')',
              false);

          EXECUTE format('SELECT %s.%I(%s)', r.schema, r.funcname, _srvid);
        EXCEPTION
          WHEN OTHERS THEN
            GET STACKED DIAGNOSTICS
                v_state   = RETURNED_SQLSTATE,
                v_msg     = MESSAGE_TEXT,
                v_detail  = PG_EXCEPTION_DETAIL,
                v_hint    = PG_EXCEPTION_HINT,
                v_context = PG_EXCEPTION_CONTEXT;

            RAISE warning '%', format(v_pattern, _srvid, r.schema, r.funcname,
                v_state, v_msg, v_detail, v_hint, v_context);

            v_errs := array_append(v_errs, format(v_pattern_simple, _srvid,
                    r.schema, r.funcname, v_msg));

            v_nb_err = v_nb_err + 1;
        END;
      END LOOP;

      PERFORM set_config('application_name',
          v_title || 'UPDATE powa_snapshot_metas.aggets',
          false);
      UPDATE @extschema@.powa_snapshot_metas
      SET aggts = now()
      WHERE srvid = _srvid;
    END IF;

    -- We also purge, at the pass after the coalesce
    -- The _srvid % 20 is there to avoid having all purges run at once
    IF ( ((purge_seq + (_srvid % 20)) % v_coalesce) = 1 )
    THEN
      PERFORM @extschema@.powa_log(
        format('purge needed, srvid: %s - seq: %s coalesce seq: %s',
        _srvid, purge_seq, v_coalesce));

      FOR r IN SELECT CASE external
                    WHEN true THEN quote_ident(nsp.nspname)
                    ELSE '@extschema@'
               END AS schema, function_name AS funcname
               FROM @extschema@.powa_all_functions AS pf
               LEFT JOIN pg_extension AS ext ON pf.kind = 'extension'
                  AND ext.extname = pf.name
               LEFT JOIN pg_namespace AS nsp ON nsp.oid = ext.extnamespace
               WHERE operation='purge'
               AND enabled
               AND srvid = _srvid
               ORDER BY priority, name
      LOOP
        -- Call all of them, for the current srvid
        BEGIN
          PERFORM @extschema@.powa_log(format('calling purge function: %s.%I(%s)',
                r.schema, r.funcname, _srvid));
          PERFORM set_config('application_name',
              v_title || quote_ident(r.funcname) || '(' || _srvid || ')',
              false);

          EXECUTE format('SELECT %s.%I(%s)', r.schema, r.funcname, _srvid);
        EXCEPTION
          WHEN OTHERS THEN
            GET STACKED DIAGNOSTICS
                v_state   = RETURNED_SQLSTATE,
                v_msg     = MESSAGE_TEXT,
                v_detail  = PG_EXCEPTION_DETAIL,
                v_hint    = PG_EXCEPTION_HINT,
                v_context = PG_EXCEPTION_CONTEXT;

            RAISE warning '%', format(v_pattern, _srvid, r.schema, r.funcname,
                v_state, v_msg, v_detail, v_hint, v_context);

            v_errs := array_append(v_errs, format(v_pattern_simple, _srvid,
                  r.schema, r.funcname, v_msg));

            v_nb_err = v_nb_err + 1;
        END;
      END LOOP;

      PERFORM set_config('application_name',
          v_title || 'UPDATE powa_snapshot_metas.purgets',
          false);
      UPDATE @extschema@.powa_snapshot_metas
      SET purgets = now()
      WHERE srvid = _srvid;
    END IF;

    -- and finally we call the snapshot function for the per-db catalog import,
    -- if this is a remote server
    IF (_srvid != 0) THEN
      FOR v_catname IN SELECT catname FROM @extschema@.powa_catalogs ORDER BY priority
      LOOP
        PERFORM @extschema@.powa_log(format('calling catalog function: %s.%I(%s, %s)',
              '@extschema@', 'powa_catalog_generic_snapshot', _srvid, v_catname));
        PERFORM set_config('application_name',
            v_title || quote_ident('powa_catalog_generic_snapshot')
                    || '(' || _srvid || ', ' || v_catname || ')', false);

        BEGIN
          PERFORM @extschema@.powa_catalog_generic_snapshot(_srvid, v_catname);
        EXCEPTION
          WHEN OTHERS THEN
            GET STACKED DIAGNOSTICS
                v_state   = RETURNED_SQLSTATE,
                v_msg     = MESSAGE_TEXT,
                v_detail  = PG_EXCEPTION_DETAIL,
                v_hint    = PG_EXCEPTION_HINT,
                v_context = PG_EXCEPTION_CONTEXT;

            RAISE warning '%', format(v_pattern_cat, _srvid, v_catname,
                v_state, v_msg, v_detail, v_hint, v_context);

            v_errs := array_append(v_errs, format(v_pattern_cat_simple, _srvid,
                  v_catname, v_msg));

            v_nb_err = v_nb_err + 1;
        END;
      END LOOP;
    END IF;

    IF (v_nb_err > 0) THEN
      UPDATE @extschema@.powa_snapshot_metas
      SET errors = v_errs
      WHERE srvid = _srvid;
    END IF;

    PERFORM @extschema@.powa_log('end of powa_take_snapshot(' || _srvid || ')');
    PERFORM set_config('application_name',
        v_title || 'snapshot finished',
        false);

    return v_nb_err;
END;
$PROC$ LANGUAGE plpgsql
SET search_path = pg_catalog; /* end of powa_take_snapshot(int) */