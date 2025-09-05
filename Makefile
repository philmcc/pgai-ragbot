# Common tasks for pgai-ragbot

# Environment overrides
MINIO_TAG ?= RELEASE.2024-08-17T01-24-00Z
PGRST ?= http://localhost:3000
KEY ?=
EMBED_MODEL ?= text-embedding-3-small
CHAT_MODEL ?= gpt-4o-mini

.PHONY: up down logs rebuild status ingest health reset-chunks postgrest-headers

up:
	docker compose up -d --build

rebuild:
	docker compose build --no-cache
	docker compose up -d

logs:
	docker compose logs -f db postgrest frontend minio

status:
	curl -sS $(PGRST)/v_ingest_status | jq .

# Trigger ingestion once (sync, chunk, and embed pending) using your OpenAI key
# Usage: make ingest KEY=sk-xxxxx [EMBED_MODEL=text-embedding-3-small]
ingest:
	@if [ -z "$(KEY)" ]; then echo "Set KEY=sk-..."; exit 1; fi
	curl -sS -X POST $(PGRST)/rpc/run_ingest_once \
	  -H "Content-Type: application/json" \
	  -H "X-OpenAI-Key: $(KEY)" \
	  -H "X-Embedding-Model: $(EMBED_MODEL)" \
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
	@echo "  X-OpenAI-Key: sk-..."
	@echo "  X-Embedding-Model: $(EMBED_MODEL)"
	@echo "  X-Chat-Model: $(CHAT_MODEL)"

# Tear down stack and volumes
 down:
	docker compose down -v
