-- Grants for PostgREST anon role
SET search_path = app, public;

GRANT USAGE ON SCHEMA app TO anon;
GRANT SELECT ON app.v_ingest_status TO anon;

-- RPC functions
GRANT EXECUTE ON FUNCTION app.chat_rag(text, int) TO anon;
GRANT EXECUTE ON FUNCTION app.search_chunks(text, int, float4) TO anon;
GRANT EXECUTE ON FUNCTION app.run_ingest_once() TO anon;
