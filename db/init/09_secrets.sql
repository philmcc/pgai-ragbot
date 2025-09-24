-- Secrets management helpers
SET search_path = app, public;

-- Return whether an OpenAI key is configured, plus metadata
CREATE OR REPLACE FUNCTION app.openai_key_status()
RETURNS jsonb
LANGUAGE sql
STABLE
SECURITY DEFINER
AS $$
  SELECT jsonb_build_object(
    'configured', EXISTS (SELECT 1 FROM app.app_secrets s WHERE s.name = 'openai_api_key' AND NULLIF(s.value,'') IS NOT NULL),
    'updated_at', (SELECT s.updated_at FROM app.app_secrets s WHERE s.name = 'openai_api_key')
  );
$$;

-- Set or update the OpenAI API key
CREATE OR REPLACE FUNCTION app.set_openai_key(p_key text)
RETURNS text
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
BEGIN
  INSERT INTO app.app_secrets(name, value)
  VALUES ('openai_api_key', p_key)
  ON CONFLICT (name) DO UPDATE SET value = EXCLUDED.value, updated_at = now();
  RETURN 'ok';
END;
$$;

-- Privileged getter (no grant to anon). Useful for ops/migrations running as postgres.
CREATE OR REPLACE FUNCTION app.get_openai_key()
RETURNS text
LANGUAGE sql
SECURITY DEFINER
AS $$
  SELECT value FROM app.app_secrets WHERE name = 'openai_api_key' LIMIT 1;
$$;
