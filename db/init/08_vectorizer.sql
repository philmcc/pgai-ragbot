-- pgai Vectorizer configuration for app.doc_chunks
SET search_path = app, public;

-- Create a vectorizer that embeds pre-chunked rows in app.doc_chunks
-- It writes embeddings into the existing embedding column using destination_column
-- and disables chunking (chunking_none) because chunking is done upstream in SQL.
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
  RAISE NOTICE 'ai.vectorizers not installed yet; run pgai install then re-run this script';
END$$;
