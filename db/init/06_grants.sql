-- Grants for PostgREST anon role
SET search_path = app, public;

GRANT USAGE ON SCHEMA app TO anon;
GRANT USAGE ON SCHEMA ai TO anon;
GRANT SELECT ON app.v_ingest_status TO anon;
GRANT SELECT ON app.v_vectorizer_status TO anon;
GRANT SELECT ON app.v_vectorizer_worker_progress TO anon;

-- RPC functions
GRANT EXECUTE ON FUNCTION app.chat_rag(text, int) TO anon;
GRANT EXECUTE ON FUNCTION app.search_chunks(text, int, float4) TO anon;
GRANT EXECUTE ON FUNCTION app.run_ingest_once() TO anon;
GRANT EXECUTE ON FUNCTION app.openai_key_status() TO anon;
GRANT EXECUTE ON FUNCTION app.set_openai_key(text) TO anon;
GRANT EXECUTE ON FUNCTION app.delete_document(bigint) TO anon;
GRANT EXECUTE ON FUNCTION app.delete_document_by_key(text) TO anon;
GRANT EXECUTE ON FUNCTION app.delete_all_documents() TO anon;
