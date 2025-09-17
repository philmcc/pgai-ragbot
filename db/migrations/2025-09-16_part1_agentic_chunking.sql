-- Migration: Part 1 — pg_vectorize + Agentic Chunking
-- Idempotent migration to upgrade an existing database to the new schema and functions.

BEGIN;
SET search_path = app, public;

-- 1) Provenance columns on app.doc_chunks
DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM information_schema.columns WHERE table_schema='app' AND table_name='doc_chunks' AND column_name='char_start'
  ) THEN
    ALTER TABLE app.doc_chunks ADD COLUMN char_start int;
  END IF;
  IF NOT EXISTS (
    SELECT 1 FROM information_schema.columns WHERE table_schema='app' AND table_name='doc_chunks' AND column_name='char_end'
  ) THEN
    ALTER TABLE app.doc_chunks ADD COLUMN char_end int;
  END IF;
  IF NOT EXISTS (
    SELECT 1 FROM information_schema.columns WHERE table_schema='app' AND table_name='doc_chunks' AND column_name='section_path'
  ) THEN
    ALTER TABLE app.doc_chunks ADD COLUMN section_path text;
  END IF;
END$$;

-- 2) Secrets table for server-side key storage
CREATE TABLE IF NOT EXISTS app.app_secrets (
  name  text PRIMARY KEY,
  value text,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now()
);

-- Trigger for updated_at
DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_proc WHERE proname = 'trg_app_secrets_updated_at'
  ) THEN
    CREATE OR REPLACE FUNCTION app.trg_app_secrets_updated_at()
    RETURNS trigger LANGUAGE plpgsql AS $f$
    BEGIN
      NEW.updated_at := now();
      RETURN NEW;
    END;
    $f$;
  END IF;
  IF NOT EXISTS (
    SELECT 1 FROM pg_trigger WHERE tgname = 'trg_app_secrets_updated_at'
  ) THEN
    CREATE TRIGGER trg_app_secrets_updated_at
      BEFORE UPDATE ON app.app_secrets
      FOR EACH ROW EXECUTE FUNCTION app.trg_app_secrets_updated_at();
  END IF;
END$$;

-- 3) app.set_request_context reads key from app_secrets
CREATE OR REPLACE FUNCTION app.set_request_context()
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
  v text;
  hdrs jsonb;
BEGIN
  BEGIN
    hdrs := current_setting('request.headers', true)::jsonb;
  EXCEPTION WHEN others THEN
    hdrs := NULL;
  END;

  -- OpenAI Key from DB secret
  SELECT s.value INTO v FROM app.app_secrets s WHERE s.name = 'openai_api_key' LIMIT 1;
  IF v IS NOT NULL AND v <> '' THEN
    PERFORM set_config('ai.openai_api_key', v, true);
  END IF;

  -- Embedding model override via headers (optional)
  v := COALESCE(
    NULLIF(current_setting('request.header.x-embedding-model', true), ''),
    NULLIF(hdrs->>'x-embedding-model', '')
  );
  IF v IS NOT NULL AND v <> '' THEN
    PERFORM set_config('ai.openai_embedding_model', v, true);
  END IF;

  -- Chat model override via headers (optional)
  v := COALESCE(
    NULLIF(current_setting('request.header.x-chat-model', true), ''),
    NULLIF(hdrs->>'x-chat-model', '')
  );
  IF v IS NOT NULL AND v <> '' THEN
    PERFORM set_config('ai.openai_chat_model', v, true);
  END IF;
END;
$$;

-- 4) Agentic chunker and ingestion refactor
CREATE OR REPLACE FUNCTION app.agentic_chunk_text(p_text text,
                                                 max_chunk_chars int DEFAULT 1400,
                                                 min_chunk_chars int DEFAULT 400)
RETURNS TABLE(seq int, chunk text, char_start int, char_end int, section_path text)
LANGUAGE plpgsql
AS $$
DECLARE
  lines text[];
  n int;
  i int := 1;
  buf text := '';
  buf_start int := 1;
  cur_section text := NULL;
  seqno int := 0;
  line text;
  line_len int;
  abs_pos int := 1;
  can_flush boolean;
BEGIN
  IF p_text IS NULL OR length(p_text) = 0 THEN
    RETURN;
  END IF;
  p_text := replace(replace(p_text, '\r\n', '\n'), '\r', '\n');
  lines := regexp_split_to_array(p_text, E'\n');
  n := array_length(lines, 1);
  IF n IS NULL THEN
    lines := ARRAY[p_text]; n := 1;
  END IF;
  WHILE i <= n LOOP
    line := COALESCE(lines[i], '');
    line_len := length(line);
    IF line ~ E'^\s*#{1,6}\s+' THEN
      can_flush := length(buf) >= min_chunk_chars;
      IF can_flush THEN
        seqno := seqno + 1; seq := seqno; chunk := buf; char_start := buf_start; char_end := abs_pos - 1; section_path := cur_section; RETURN NEXT; buf := '';
      END IF;
      cur_section := regexp_replace(line, E'^\s*#{1,6}\s+', '');
      buf_start := abs_pos + line_len + 1;
    ELSIF line ~ E'^\s*$' THEN
      IF length(buf) >= min_chunk_chars THEN
        seqno := seqno + 1; seq := seqno; chunk := buf; char_start := buf_start; char_end := abs_pos - 1; section_path := cur_section; RETURN NEXT; buf := ''; buf_start := abs_pos;
      ELSIF length(buf) >= max_chunk_chars THEN
        seqno := seqno + 1; seq := seqno; chunk := buf; char_start := buf_start; char_end := abs_pos - 1; section_path := cur_section; RETURN NEXT; buf := ''; buf_start := abs_pos;
      ELSE
        buf := buf || '\n';
      END IF;
    ELSE
      IF length(buf) > 0 THEN buf := buf || '\n' || line; ELSE buf := line; END IF;
      IF length(buf) >= max_chunk_chars THEN
        seqno := seqno + 1; seq := seqno; chunk := buf; char_start := buf_start; char_end := abs_pos + line_len; section_path := cur_section; RETURN NEXT; buf := ''; buf_start := char_end + 1;
      END IF;
    END IF;
    abs_pos := abs_pos + line_len + 1;
    i := i + 1;
  END LOOP;
  IF length(buf) > 0 THEN
    seqno := seqno + 1; seq := seqno; chunk := buf; char_start := buf_start; char_end := GREATEST(buf_start + length(buf) - 1, buf_start); section_path := cur_section; RETURN NEXT;
  END IF;
END;
$$;

CREATE OR REPLACE FUNCTION app.process_pending_documents()
RETURNS int
LANGUAGE plpgsql
AS $$
DECLARE
  v_count int := 0;
BEGIN
  WITH new_docs AS (
    SELECT d.id, d.content_text
    FROM app.documents d
    LEFT JOIN app.doc_chunks c ON c.doc_id = d.id
    WHERE c.doc_id IS NULL
  ), ins AS (
    INSERT INTO app.doc_chunks (doc_id, seq, chunk, char_start, char_end, section_path)
    SELECT nd.id, c.seq, c.chunk, c.char_start, c.char_end, c.section_path
    FROM new_docs nd
    CROSS JOIN LATERAL app.agentic_chunk_text(nd.content_text, 1400, 400) c
    RETURNING 1
  )
  SELECT COALESCE(count(*),0) INTO v_count FROM ins;
  RETURN v_count;
END;
$$;

-- 5) Secrets RPCs
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

CREATE OR REPLACE FUNCTION app.get_openai_key()
RETURNS text
LANGUAGE sql
SECURITY DEFINER
AS $$
  SELECT value FROM app.app_secrets WHERE name = 'openai_api_key' LIMIT 1;
$$;

-- 6) Grants for PostgREST anon role
GRANT EXECUTE ON FUNCTION app.openai_key_status() TO anon;
GRANT EXECUTE ON FUNCTION app.set_openai_key(text) TO anon;

-- 7) Vectorizer configuration (requires pgai install run already)
DO $$
BEGIN
  PERFORM 1 FROM ai.vectorizers v WHERE v.source_table::regclass = 'app.doc_chunks'::regclass;
  IF NOT FOUND THEN
    PERFORM ai.create_vectorizer(
      'app.doc_chunks'::regclass,
      if_not_exists => true,
      loading      => ai.loading_column('chunk'),
      chunking     => ai.chunking_none(),
      embedding    => ai.embedding_openai('text-embedding-3-small', 1536, api_key_name => 'OPENAI_API_KEY'),
      destination  => ai.destination_column('embedding'),
      scheduling   => ai.scheduling_timescaledb('1 minute')
    );
  END IF;
EXCEPTION WHEN undefined_table THEN
  RAISE NOTICE 'Vectorizer objects not installed yet; run pgai install and re-run this migration';
END$$;

-- 8) Bootstrap OpenAI key into DB from DB container env (non-fatal)
CREATE OR REPLACE FUNCTION app.bootstrap_openai_key_from_env()
RETURNS text
LANGUAGE plpython3u
SECURITY DEFINER
AS $$
import os
key = os.environ.get('OPENAI_API_KEY')
if not key:
    return 'no-op'
plan = plpy.prepare("""
  INSERT INTO app.app_secrets(name, value)
  VALUES ('openai_api_key', $1)
  ON CONFLICT (name) DO UPDATE SET value = EXCLUDED.value, updated_at = now()
""", ["text"]) 
plpy.execute(plan, [key])
return 'ok'
$$;

DO $$
BEGIN
  PERFORM app.bootstrap_openai_key_from_env();
EXCEPTION WHEN others THEN
  RAISE NOTICE 'Bootstrap skipped: %', SQLERRM;
END$$;

COMMIT;
