# Common tasks for pgai-ragbot

# Environment overrides
MINIO_TAG ?= RELEASE.2024-08-17T01-24-00Z
PGRST ?= http://localhost:3000
EMBED_MODEL ?= text-embedding-3-small
CHAT_MODEL ?= gpt-4o-mini

.PHONY: up down logs rebuild status ingest health reset-chunks postgrest-headers set-key sync-key

up:
	docker compose up -d --build

rebuild:
	docker compose build --no-cache
	docker compose up -d

logs:
	docker compose logs -f db postgrest frontend minio

status:
	curl -sS $(PGRST)/v_ingest_status | jq .

# Trigger ingestion once (sync + agentic chunking). Embeddings are populated by vectorizer.
ingest:
	curl -sS -X POST $(PGRST)/rpc/run_ingest_once \
	  -H "Content-Type: application/json" \
	  -d '{}'
	@echo
	$(MAKE) status

# Health check RPC
health:
	curl -sS $(PGRST)/rpc/health | jq .

# Admin: clear chunks to re-run chunking/embedding
reset-chunks:
	curl -sS -X POST $(PGRST)/rpc/reset_chunks -H "Content-Type: application/json" -d '{}' | jq .

# Show which headers are required when calling PostgREST directly
postgrest-headers:
	@echo "Required headers:"
	@echo "  X-Embedding-Model: $(EMBED_MODEL)"
	@echo "  X-Chat-Model: $(CHAT_MODEL)"

# Set OpenAI key in DB via PostgREST (Usage: make set-key KEY=sk-...)
set-key:
	@if [ -z "$(KEY)" ]; then echo "Set KEY=sk-..."; exit 1; fi
	curl -sS -X POST $(PGRST)/rpc/set_openai_key -H "Content-Type: application/json" -d '{"p_key":"'"$(KEY)"'"}' | jq .

# Sync OpenAI key from DB to .env for containers (vectorizer/db)
sync-key:
	bash scripts/sync-openai-key.sh

# Tear down stack and volumes
 down:
	docker compose down -v
