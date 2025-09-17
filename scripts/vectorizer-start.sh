#!/bin/sh
set -e

# Fetch OpenAI key from DB if not set in env.
if [ -z "$OPENAI_API_KEY" ]; then
  # Use python available in the worker image to query the DB for app.get_openai_key()
  KEY=$(python - <<'PY'
import os
from urllib.parse import urlparse
import psycopg

db_url = os.environ.get('PGAI_VECTORIZER_WORKER_DB_URL')
if not db_url:
    print("")
    raise SystemExit(0)

# psycopg3 connect directly with the URL
try:
    with psycopg.connect(db_url) as conn:
        with conn.cursor() as cur:
            cur.execute("select app.get_openai_key();")
            row = cur.fetchone()
            print(row[0] or "")
except Exception as e:
    print("")
PY
)
  if [ -n "$KEY" ]; then
    export OPENAI_API_KEY="$KEY"
  fi
fi

# Start the vectorizer worker
exec python -m pgai vectorizer worker --poll-interval 5s
