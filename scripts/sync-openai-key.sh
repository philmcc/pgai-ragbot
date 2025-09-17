#!/usr/bin/env bash
set -euo pipefail

# This script reads the OpenAI key from the database (app.get_openai_key)
# and writes it to the project .env as OPENAI_API_KEY=...
# This allows the vectorizer worker and db to read the key via environment variables.

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT_DIR"

# Read key via psql inside the db container
KEY=$(docker compose exec -T db psql -t -A -U postgres -d pgai -c "select app.get_openai_key();" | tr -d '\r')

if [ -z "$KEY" ]; then
  echo "No key found in DB (app.app_secrets). Use the UI or PostgREST to set it first." >&2
  exit 1
fi

# Ensure .env exists
ENV_FILE="$ROOT_DIR/.env"
if [ ! -f "$ENV_FILE" ]; then
  touch "$ENV_FILE"
fi

# Update or append OPENAI_API_KEY
if grep -q '^OPENAI_API_KEY=' "$ENV_FILE"; then
  sed -i.bak "s/^OPENAI_API_KEY=.*/OPENAI_API_KEY=$KEY/" "$ENV_FILE"
else
  echo "OPENAI_API_KEY=$KEY" >> "$ENV_FILE"
fi

echo "OPENAI_API_KEY synchronized to .env"
