-- Bootstrap OpenAI API key from the DB container environment into app.app_secrets
-- This runs at init time only. For existing deployments, use the migration RPC
-- or the UI to set the key.
SET search_path = app, public;

-- PL/Python function to read the environment and store key
CREATE OR REPLACE FUNCTION app.bootstrap_openai_key_from_env()
RETURNS text
LANGUAGE plpython3u
SECURITY DEFINER
AS $$
import os
key = os.environ.get('OPENAI_API_KEY')
if key is None:
    return 'no-op: OPENAI_API_KEY not set in db container'
# Upsert into app_secrets
plan = plpy.prepare("""
  INSERT INTO app.app_secrets(name, value)
  VALUES ('openai_api_key', $1)
  ON CONFLICT (name) DO UPDATE SET value = EXCLUDED.value, updated_at = now()
""", ["text"])
plpy.execute(plan, [key])
return 'ok'
$$;

-- Attempt bootstrap (non-fatal)
DO $$
BEGIN
  PERFORM app.bootstrap_openai_key_from_env();
EXCEPTION WHEN others THEN
  RAISE NOTICE 'OpenAI key bootstrap skipped: %', SQLERRM;
END$$;
