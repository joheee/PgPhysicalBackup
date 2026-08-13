#!/bin/bash
# sync.sh — periodic delta restore to keep standby in sync.
# Does NOT promote. PG stays in recovery mode after restart.
set -euo pipefail

STANZA="${REMOTE_STANZA:-pg-reserve}"
PG_CONTAINER="${PG_CONTAINER:-pg}"
DATA_DIR="${DATA_DIR:-/var/lib/postgresql/data}"

echo "[$(date -Iseconds)] sync: stopping PG (container=${PG_CONTAINER})..."
docker stop "$PG_CONTAINER" 2>/dev/null || true
sleep 2

echo "[$(date -Iseconds)] sync: delta restore from stanza=${STANZA}..."
pgbackrest --stanza="$STANZA" \
  --pg1-path="$DATA_DIR" \
  --type=immediate \
  --delta \
  --log-level-console=info \
  restore

echo "[$(date -Iseconds)] sync: starting PG (container=${PG_CONTAINER}, recovery mode)..."
docker start "$PG_CONTAINER"

echo "[$(date -Iseconds)] sync: done."
