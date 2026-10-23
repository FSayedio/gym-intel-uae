-- A deterministic, private comparison baseline. Never print actual row contents.
\set ON_ERROR_STOP on
BEGIN ISOLATION LEVEL REPEATABLE READ READ ONLY;
SET LOCAL search_path = pg_catalog;
SET LOCAL timezone = 'UTC';
SET LOCAL datestyle = 'ISO, YMD';
DO $$
BEGIN
  IF current_database() <> 'gym_intel_dev' THEN
    RAISE EXCEPTION 'Recovery capture requires gym_intel_dev';
  END IF;
  IF EXISTS (SELECT FROM public.oban_jobs
      WHERE state IN ('available', 'scheduled', 'executing', 'retryable')) THEN
    RAISE EXCEPTION 'Unfinished jobs prevent a quiescent recovery baseline';
  END IF;
  IF EXISTS (
    SELECT FROM pg_namespace
    WHERE nspname <> 'public' AND nspname <> 'information_schema'
      AND nspname NOT LIKE 'pg_%'
  ) THEN
    RAISE EXCEPTION 'Additional user schemas need an explicitly extended recovery check';
  END IF;
  -- Cluster-global memberships/settings are not exported by pg_dump. Refuse
  -- unsupported variants rather than silently claiming they were recovered.
  IF EXISTS (SELECT FROM pg_auth_members m
      JOIN pg_roles r ON r.oid IN (m.roleid, m.member)
      WHERE r.rolname IN ('gym_intel', 'gym_intel_migrator', 'gym_intel_app', 'gym_intel_grafana'))
    OR EXISTS (SELECT FROM pg_db_role_setting s JOIN pg_roles r ON r.oid = s.setrole
      WHERE r.rolname IN ('gym_intel', 'gym_intel_migrator', 'gym_intel_app', 'gym_intel_grafana')
        AND s.setdatabase IN (0, (SELECT oid FROM pg_database WHERE datname=current_database()))
        AND cardinality(s.setconfig) > 0) THEN
    RAISE EXCEPTION 'Custom role memberships/settings need a reviewed recovery extension';
  END IF;
END $$;

SELECT jsonb_build_object('database', jsonb_build_array(
  datname, pg_get_userbyid(datdba), pg_encoding_to_char(encoding),
  datlocprovider, datcollate, datctype, datconnlimit,
  (SELECT jsonb_agg(jsonb_build_array(
    pg_get_userbyid(a.grantor), CASE WHEN a.grantee = 0 THEN 'PUBLIC'
      ELSE pg_get_userbyid(a.grantee) END, a.privilege_type, a.is_grantable)
    ORDER BY a.grantor::regrole::text, a.grantee::regrole::text, a.privilege_type)
   FROM aclexplode(coalesce(datacl, acldefault('d', datdba))) a)
)) FROM pg_database WHERE datname = current_database();

SELECT jsonb_build_object('roles', jsonb_agg(jsonb_build_array(
  rolname, rolsuper, rolinherit, rolcreaterole, rolcreatedb, rolcanlogin,
  rolreplication, rolbypassrls, rolconnlimit) ORDER BY rolname))
FROM pg_roles WHERE rolname IN
  ('gym_intel', 'gym_intel_migrator', 'gym_intel_app', 'gym_intel_grafana');

SELECT jsonb_build_object('schema', coalesce(jsonb_agg(item ORDER BY item::text), '[]'))
FROM (
  SELECT jsonb_build_array('column', c.relname,
    row_number() OVER (PARTITION BY c.oid ORDER BY a.attnum), a.attname,
    format_type(a.atttypid, a.atttypmod), a.attnotnull, a.attidentity, a.attgenerated,
    pg_get_expr(d.adbin, d.adrelid), co.collname) AS item
  FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
  JOIN pg_attribute a ON a.attrelid = c.oid
  LEFT JOIN pg_attrdef d ON d.adrelid = c.oid AND d.adnum = a.attnum
  LEFT JOIN pg_collation co ON co.oid = a.attcollation
  WHERE n.nspname = 'public' AND a.attnum > 0 AND NOT a.attisdropped
    AND c.relkind IN ('r', 'p', 'v', 'm', 'S')
  UNION ALL
  SELECT jsonb_build_array('relation', c.relname, c.relkind,
    pg_get_userbyid(c.relowner), c.relrowsecurity, c.relforcerowsecurity)
  FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
  WHERE n.nspname = 'public' AND c.relkind IN ('r', 'p', 'v', 'm', 'S')
  UNION ALL
  SELECT jsonb_build_array('constraint', c.relname, x.conname,
    CASE WHEN x.conname IN (
      'memberships_access_scope_allowed', 'memberships_offer_type_allowed',
      'memberships_payment_structure_allowed', 'memberships_price_vat_status_allowed',
      'memberships_renewal_policy_allowed'
    ) THEN
      -- pg_dump/restore reparses varchar-literal arrays as individually text-cast
      -- elements. Normalize ONLY these ASCII allowlist literal casts and their
      -- redundant text[] wrapper; retain the whole surrounding CHECK expression,
      -- names, literals and validation state. Never strip arbitrary SQL casts.
      regexp_replace(regexp_replace(regexp_replace(pg_get_constraintdef(x.oid, false),
        $pattern$\('([A-Za-z_]+)'::character varying\)::text$pattern$,
        $replacement$'\1'::text$replacement$, 'g'),
        $pattern$'([A-Za-z_]+)'::character varying$pattern$,
        $replacement$'\1'::text$replacement$, 'g'),
        $pattern$\(ARRAY\[('[A-Za-z_]+'::text(, '[A-Za-z_]+'::text)*)\]\)::text\[\]$pattern$,
        $replacement$ARRAY[\1]$replacement$, 'g')
    ELSE pg_get_constraintdef(x.oid, false) END, x.convalidated)
  FROM pg_constraint x JOIN pg_class c ON c.oid = x.conrelid
  JOIN pg_namespace n ON n.oid = c.relnamespace WHERE n.nspname = 'public'
  UNION ALL
  SELECT jsonb_build_array('index', c.relname, pg_get_indexdef(i.indexrelid),
    i.indisunique, i.indisvalid)
  FROM pg_index i JOIN pg_class c ON c.oid = i.indrelid
  JOIN pg_namespace n ON n.oid = c.relnamespace WHERE n.nspname = 'public'
  UNION ALL
  SELECT jsonb_build_array('trigger', c.relname, t.tgname,
    pg_get_triggerdef(t.oid, false), t.tgenabled)
  FROM pg_trigger t JOIN pg_class c ON c.oid = t.tgrelid
  JOIN pg_namespace n ON n.oid = c.relnamespace
  WHERE n.nspname = 'public' AND NOT t.tgisinternal
  UNION ALL
  SELECT jsonb_build_array('function', p.proname,
    pg_get_function_identity_arguments(p.oid), pg_get_functiondef(p.oid),
    pg_get_userbyid(p.proowner))
  FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
  WHERE n.nspname = 'public' AND p.prokind IN ('f', 'p', 'w')
  UNION ALL
  SELECT jsonb_build_array('view', c.relname, pg_get_viewdef(c.oid, false))
  FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
  WHERE n.nspname = 'public' AND c.relkind IN ('v', 'm')
  UNION ALL
  SELECT jsonb_build_array('enum', t.typname, e.enumlabel,
    row_number() OVER (PARTITION BY t.oid ORDER BY e.enumsortorder))
  FROM pg_type t JOIN pg_namespace n ON n.oid = t.typnamespace
  JOIN pg_enum e ON e.enumtypid = t.oid WHERE n.nspname = 'public'
  UNION ALL
  SELECT jsonb_build_array('sequence', c.relname, s.seqstart, s.seqincrement,
    s.seqmax, s.seqmin, s.seqcache, s.seqcycle)
  FROM pg_sequence s JOIN pg_class c ON c.oid = s.seqrelid
  JOIN pg_namespace n ON n.oid = c.relnamespace WHERE n.nspname = 'public'
  UNION ALL
  SELECT jsonb_build_array('extension', extname, extversion) FROM pg_extension
) inventory;

SELECT jsonb_build_object('privileges', coalesce(jsonb_agg(item ORDER BY item::text), '[]'))
FROM (
  SELECT jsonb_build_array('relation', c.relname, pg_get_userbyid(a.grantor),
    CASE WHEN a.grantee = 0 THEN 'PUBLIC' ELSE pg_get_userbyid(a.grantee) END,
    a.privilege_type, a.is_grantable) AS item
  FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
  CROSS JOIN LATERAL aclexplode(coalesce(c.relacl,
    acldefault(CASE WHEN c.relkind = 'S' THEN 'S'::"char" ELSE 'r'::"char" END, c.relowner))) a
  WHERE n.nspname = 'public' AND c.relkind IN ('r', 'p', 'v', 'm', 'S')
  UNION ALL
  SELECT jsonb_build_array('function', p.proname,
    pg_get_function_identity_arguments(p.oid), pg_get_userbyid(a.grantor),
    CASE WHEN a.grantee = 0 THEN 'PUBLIC' ELSE pg_get_userbyid(a.grantee) END,
    a.privilege_type, a.is_grantable)
  FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
  CROSS JOIN LATERAL aclexplode(coalesce(p.proacl, acldefault('f', p.proowner))) a
  WHERE n.nspname = 'public'
  UNION ALL
  SELECT jsonb_build_array('schema', n.nspname, pg_get_userbyid(n.nspowner),
    pg_get_userbyid(a.grantor), CASE WHEN a.grantee = 0 THEN 'PUBLIC'
      ELSE pg_get_userbyid(a.grantee) END, a.privilege_type, a.is_grantable)
  FROM pg_namespace n
  CROSS JOIN LATERAL aclexplode(coalesce(n.nspacl, acldefault('n', n.nspowner))) a
  WHERE n.nspname = 'public'
  UNION ALL
  SELECT jsonb_build_array('default', pg_get_userbyid(d.defaclrole), n.nspname,
    d.defaclobjtype, pg_get_userbyid(a.grantor),
    CASE WHEN a.grantee = 0 THEN 'PUBLIC' ELSE pg_get_userbyid(a.grantee) END,
    a.privilege_type, a.is_grantable)
  FROM pg_default_acl d LEFT JOIN pg_namespace n ON n.oid = d.defaclnamespace
  CROSS JOIN LATERAL aclexplode(d.defaclacl) a
) privileges;

-- Hash every public table's complete rows, including Oban arguments/errors,
-- without copying those rows into the comparison report. Stable order retains
-- duplicates and is independent of heap order or database object OIDs.
SELECT format(
  'SELECT jsonb_build_object(''table'', %L, ''rows'', count(*), ''sha256'',
    encode(sha256(convert_to(coalesce(jsonb_agg(to_jsonb(t)
      ORDER BY to_jsonb(t)::text), ''[]''::jsonb)::text, ''UTF8'')), ''hex''))
   FROM %I.%I t;', c.relname, n.nspname, c.relname)
FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
WHERE n.nspname = 'public' AND c.relkind = 'r' ORDER BY c.relname
\gexec

SELECT format(
  'SELECT jsonb_build_object(''sequence_state'', %L,
    ''last_value'', last_value, ''is_called'', is_called) FROM %I.%I;',
  c.relname, n.nspname, c.relname)
FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
WHERE n.nspname = 'public' AND c.relkind = 'S' ORDER BY c.relname
\gexec
COMMIT;
