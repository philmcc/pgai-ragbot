-- Health RPC for smoke tests
SET search_path = app, public;

CREATE OR REPLACE FUNCTION app.health()
RETURNS jsonb
LANGUAGE sql
STABLE
SECURITY DEFINER
AS $$
WITH exts AS (
  SELECT array_agg(extname ORDER BY extname) AS names
  FROM pg_extension
), counts AS (
  SELECT
    (SELECT count(*) FROM app.documents) AS documents,
    (SELECT count(*) FROM app.doc_chunks) AS chunks,
    (SELECT count(*) FROM app.doc_chunks WHERE embedding IS NULL) AS chunks_pending
), job AS (
  SELECT EXISTS(
    SELECT 1 FROM timescaledb_information.jobs WHERE proc_name = 'app.job_sync_and_process'
  ) AS job_exists
)
SELECT jsonb_build_object(
  'extensions', (SELECT names FROM exts),
  'documents', (SELECT documents FROM counts),
  'chunks', (SELECT chunks FROM counts),
  'chunks_pending', (SELECT chunks_pending FROM counts),
  'job_exists', (SELECT job_exists FROM job),
  'models', jsonb_build_object(
    'embedding', COALESCE(NULLIF(current_setting('ai.openai_embedding_model', true), ''), 'text-embedding-3-small'),
    'chat', COALESCE(NULLIF(current_setting('ai.openai_chat_model', true), ''), 'gpt-4o-mini')
  )
);
$$;

GRANT EXECUTE ON FUNCTION app.health() TO anon;
