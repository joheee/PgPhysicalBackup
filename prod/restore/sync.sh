#!/bin/bash
# sync.sh — periodic delta restore to keep standby in sync.
# Does NOT promote. PG stays in recovery mode after restart.
set -euo pipefail

# Required config (provided by compose environment; see docker-compose.yml / .env.example).
: "${REMOTE_STANZA:?required env var REMOTE_STANZA not set}"
: "${PG_CONTAINER:?required env var PG_CONTAINER not set}"
: "${DATA_DIR:?required env var DATA_DIR not set}"

echo "[$(date -Iseconds)] sync: stopping PG (container=${PG_CONTAINER})..."
docker stop "$PG_CONTAINER" 2>/dev/null || true
sleep 2

echo "[$(date -Iseconds)] sync: delta restore from stanza=${REMOTE_STANZA}..."
pgbackrest --stanza="$REMOTE_STANZA" \
  --pg1-path="$DATA_DIR" \
  --type=immediate \
  --delta \
  --log-level-console=info \
  restore

echo "[$(date -Iseconds)] sync: starting PG (container=${PG_CONTAINER}, recovery mode)..."
docker start "$PG_CONTAINER"

echo "[$(date -Iseconds)] sync: done."
