-- Roles, schema for PostgREST
DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'anon') THEN
    CREATE ROLE anon NOLOGIN;
  END IF;
END$$;

CREATE SCHEMA IF NOT EXISTS app;
GRANT USAGE ON SCHEMA app TO anon;

-- Pre-request hook to capture headers (e.g., OpenAI key) into session GUCs
CREATE OR REPLACE FUNCTION app.set_request_context()
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
  v text;
  hdrs jsonb;
BEGIN
  -- Prefer consolidated JSON headers; fallback to legacy per-header GUCs
  BEGIN
    hdrs := current_setting('request.headers', true)::jsonb;
  EXCEPTION WHEN others THEN
    hdrs := NULL;
  END;

  -- OpenAI Key: source from DB secret, not headers
  SELECT s.value INTO v FROM app.app_secrets s WHERE s.name = 'openai_api_key' LIMIT 1;
  IF v IS NOT NULL AND v <> '' THEN
    PERFORM set_config('ai.openai_api_key', v, true);
  END IF;

  -- Embedding model
  v := COALESCE(
    NULLIF(current_setting('request.header.x-embedding-model', true), ''),
    NULLIF(hdrs->>'x-embedding-model', '')
  );
  IF v IS NOT NULL AND v <> '' THEN
    PERFORM set_config('ai.openai_embedding_model', v, true);
  END IF;

  -- Chat model
  v := COALESCE(
    NULLIF(current_setting('request.header.x-chat-model', true), ''),
    NULLIF(hdrs->>'x-chat-model', '')
  );
  IF v IS NOT NULL AND v <> '' THEN
    PERFORM set_config('ai.openai_chat_model', v, true);
  END IF;

  -- Rerank model
  v := COALESCE(
    NULLIF(current_setting('request.header.x-rerank-model', true), ''),
    NULLIF(hdrs->>'x-rerank-model', '')
  );
  IF v IS NOT NULL AND v <> '' THEN
    PERFORM set_config('ai.openai_rerank_model', v, true);
  END IF;
END;
$$;

GRANT EXECUTE ON FUNCTION app.set_request_context() TO anon;
