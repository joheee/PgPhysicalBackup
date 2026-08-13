#!/bin/bash
# promote.sh — failover restore: restore AND promote to read-write.
# Run manually by operator. NOT called by cron.
set -euo pipefail

# Required config (provided by compose environment; see docker-compose.yml / .env.example).
: "${REMOTE_STANZA:?required env var REMOTE_STANZA not set}"
: "${PG_CONTAINER:?required env var PG_CONTAINER not set}"
: "${DATA_DIR:?required env var DATA_DIR not set}"

echo "============================================================"
echo "[$(date -Iseconds)] FAILOVER PROMOTE"
echo "  Remote stanza : ${REMOTE_STANZA}"
echo "  PG container  : ${PG_CONTAINER}"
echo "  Data dir      : ${DATA_DIR}"
echo "============================================================"

echo "[$(date -Iseconds)] Stopping PG..."
docker stop "$PG_CONTAINER" 2>/dev/null || true
sleep 2

echo "[$(date -Iseconds)] Restoring from stanza=${REMOTE_STANZA} with --target-action=promote..."
pgbackrest --stanza="$REMOTE_STANZA" \
  --pg1-path="$DATA_DIR" \
  --type=immediate \
  --target-action=promote \
  --log-level-console=info \
  restore

echo "[$(date -Iseconds)] Starting PG (read-write)..."
docker start "$PG_CONTAINER"

echo "[$(date -Iseconds)] FAILOVER COMPLETE. PG is now read-write."
echo "Verify: docker exec -u postgres ${PG_CONTAINER} psql -c 'SELECT pg_is_in_recovery();'"
