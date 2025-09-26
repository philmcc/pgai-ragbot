-- Core RAG schema
SET search_path = app, public;

-- Documents sourced from S3 (MinIO)
CREATE TABLE IF NOT EXISTS documents (
  id           BIGSERIAL PRIMARY KEY,
  s3_bucket    text NOT NULL,
  s3_key       text NOT NULL UNIQUE,
  source_uri   text NOT NULL,
  content_type text,
  content_bytes bytea,
  content_text text,
  metadata     jsonb DEFAULT '{}'::jsonb,
  created_at   timestamptz NOT NULL DEFAULT now()
);

-- Chunked representation and embeddings
-- Using OpenAI embedding with 1536 dims by default
CREATE TABLE IF NOT EXISTS doc_chunks (
  doc_id    bigint NOT NULL REFERENCES documents(id) ON DELETE CASCADE,
  seq       int    NOT NULL,
  chunk_text text   NOT NULL,
  -- Optional provenance
  char_start int,
  char_end   int,
  section_path text,
  -- Embedding populated by vectorizer (destination_column) or by DB in earlier versions
  embedding vector(1536),
  PRIMARY KEY (doc_id, seq)
);

-- Vector index for similarity search (IVFFLAT)
-- Note: Requires analyze and some data to be effective
CREATE INDEX IF NOT EXISTS doc_chunks_embedding_ivfflat
  ON doc_chunks USING ivfflat (embedding vector_cosine_ops) WITH (lists=100);

-- Lexical search support (hybrid search): tsvector column + GIN index + trigger
-- These are idempotent and safe to run on existing databases.
ALTER TABLE app.doc_chunks
  ADD COLUMN IF NOT EXISTS lexeme tsvector;

-- Backfill existing rows (no-op on fresh DB)
UPDATE app.doc_chunks
SET lexeme = to_tsvector('english', COALESCE(chunk_text, ''))
WHERE lexeme IS NULL;

-- Maintain lexeme on insert/update
DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_proc p
    JOIN pg_namespace n ON n.oid = p.pronamespace
    WHERE n.nspname = 'app' AND p.proname = 'trg_update_doc_chunks_lexeme'
  ) THEN
    CREATE OR REPLACE FUNCTION app.trg_update_doc_chunks_lexeme()
    RETURNS trigger LANGUAGE plpgsql AS $$
    BEGIN
      NEW.lexeme := to_tsvector('english', COALESCE(NEW.chunk_text, ''));
      RETURN NEW;
    END;$$;
  END IF;
  -- Create trigger if missing
  IF NOT EXISTS (
    SELECT 1 FROM pg_trigger t
    JOIN pg_class c ON c.oid = t.tgrelid
    JOIN pg_namespace n ON n.oid = c.relnamespace
    WHERE t.tgname = 'trg_update_doc_chunks_lexeme'
      AND n.nspname = 'app'
      AND c.relname = 'doc_chunks'
  ) THEN
    CREATE TRIGGER trg_update_doc_chunks_lexeme
      BEFORE INSERT OR UPDATE OF chunk_text ON app.doc_chunks
      FOR EACH ROW EXECUTE FUNCTION app.trg_update_doc_chunks_lexeme();
  END IF;
EXCEPTION WHEN others THEN
  RAISE NOTICE 'lexeme trigger may already exist: %', SQLERRM;
END$$;

-- GIN index for fast lexical search
CREATE INDEX IF NOT EXISTS doc_chunks_lexeme_gin ON app.doc_chunks USING GIN (lexeme);

-- Helper view to show ingestion and embedding status
CREATE OR REPLACE VIEW v_ingest_status AS
SELECT d.id, d.s3_bucket, d.s3_key,
       count(c.*) FILTER (WHERE c.embedding IS NULL) AS chunks_pending,
       count(c.*)                                   AS chunks_total,
       d.created_at
FROM documents d
LEFT JOIN doc_chunks c ON c.doc_id = d.id
GROUP BY d.id;

-- Idempotent schema upgrades when running against an existing database
DO $$
BEGIN
  BEGIN
    ALTER TABLE app.doc_chunks ADD COLUMN IF NOT EXISTS char_start int;
  EXCEPTION WHEN others THEN
    RAISE NOTICE 'char_start may already exist: %', SQLERRM;
  END;
  BEGIN
    ALTER TABLE app.doc_chunks ADD COLUMN IF NOT EXISTS char_end int;
  EXCEPTION WHEN others THEN
    RAISE NOTICE 'char_end may already exist: %', SQLERRM;
  END;
  BEGIN
    ALTER TABLE app.doc_chunks ADD COLUMN IF NOT EXISTS section_path text;
  EXCEPTION WHEN others THEN
    RAISE NOTICE 'section_path may already exist: %', SQLERRM;
  END;
END$$;

-- Expose vectorizer status via app schema for PostgREST
CREATE OR REPLACE VIEW app.v_vectorizer_status AS
SELECT id,
       name,
       source_table,
       target_table,
       view,
       embedding_column,
       pending_items,
       disabled
FROM ai.vectorizer_status;

-- Worker progress view for UI/observability
CREATE OR REPLACE VIEW app.v_vectorizer_worker_progress AS
SELECT vectorizer_id,
       success_count,
       error_count,
       last_success_at,
       last_success_process_id,
       last_error_at,
       last_error_message,
       last_error_process_id
FROM ai.vectorizer_worker_progress;

-- Secrets/config (store API keys and other small config values)
-- Note: In production, prefer a managed secret store. This is for demo/local use.
CREATE TABLE IF NOT EXISTS app.app_secrets (
  name  text PRIMARY KEY,
  value text,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now()
);

-- Upsert helper to keep updated_at fresh (trigger)
DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_trigger WHERE tgname = 'trg_app_secrets_updated_at'
  ) THEN
    CREATE OR REPLACE FUNCTION app.trg_app_secrets_updated_at()
    RETURNS trigger LANGUAGE plpgsql AS $$
    BEGIN
      NEW.updated_at := now();
      RETURN NEW;
    END;$$;
    CREATE TRIGGER trg_app_secrets_updated_at
      BEFORE UPDATE ON app.app_secrets
      FOR EACH ROW EXECUTE FUNCTION app.trg_app_secrets_updated_at();
  END IF;
EXCEPTION WHEN others THEN
  RAISE NOTICE 'app_secrets trigger may already exist: %', SQLERRM;
END$$;
