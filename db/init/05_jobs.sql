-- Timescale background jobs to poll MinIO and process documents
SET search_path = app, public;

-- Wrapper procedure for jobs
CREATE OR REPLACE PROCEDURE app.job_sync_and_process()
LANGUAGE plpgsql
AS $$
DECLARE
  v_new int := 0;
  v_chunked int := 0;
BEGIN
  PERFORM app.s3_sync_documents('documents');
  v_chunked := app.process_pending_documents();
  RAISE NOTICE 'Sync complete. New chunked: %', v_chunked;
END;
$$;

-- Register job to run every minute (idempotent)
DO $$
BEGIN
  PERFORM add_job('app.job_sync_and_process', '1 minute');
EXCEPTION WHEN others THEN
  RAISE NOTICE 'Job may already exist: %', SQLERRM;
END$$;
