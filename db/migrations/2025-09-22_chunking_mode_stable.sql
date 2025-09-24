-- Make chunking_mode() STABLE and ensure PostgREST can expose it
SET search_path = app, public;

CREATE OR REPLACE FUNCTION app.chunking_mode()
RETURNS text
STABLE
LANGUAGE sql
AS $$
  SELECT COALESCE(NULLIF(current_setting('app.chunking_mode', true), ''), 'heuristic')
$$;

GRANT EXECUTE ON FUNCTION app.chunking_mode() TO anon;

-- Ask PostgREST to reload schema cache
NOTIFY pgrst, 'reload schema';
