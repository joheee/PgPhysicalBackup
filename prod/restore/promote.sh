#!/bin/bash
# promote.sh — failover restore: restore AND promote to read-write.
# Run manually by operator. NOT called by cron.
set -euo pipefail

STANZA="${REMOTE_STANZA:-pg-reserve}"
PG_CONTAINER="${PG_CONTAINER:-pg}"
DATA_DIR="${DATA_DIR:-/var/lib/postgresql/data}"

echo "============================================================"
echo "[$(date -Iseconds)] FAILOVER PROMOTE"
echo "  Remote stanza : ${STANZA}"
echo "  PG container  : ${PG_CONTAINER}"
echo "  Data dir      : ${DATA_DIR}"
echo "============================================================"

echo "[$(date -Iseconds)] Stopping PG..."
docker stop "$PG_CONTAINER" 2>/dev/null || true
sleep 2

echo "[$(date -Iseconds)] Restoring from stanza=${STANZA} with --target-action=promote..."
pgbackrest --stanza="$STANZA" \
  --pg1-path="$DATA_DIR" \
  --type=immediate \
  --target-action=promote \
  --log-level-console=info \
  restore

echo "[$(date -Iseconds)] Starting PG (read-write)..."
docker start "$PG_CONTAINER"

echo "[$(date -Iseconds)] FAILOVER COMPLETE. PG is now read-write."
echo "Verify: docker exec -u postgres ${PG_CONTAINER} psql -c 'SELECT pg_is_in_recovery();'"
