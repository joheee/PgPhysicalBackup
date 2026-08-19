#!/bin/bash
# init-standby.sh — one-time setup: restore the remote backup and bring pg up as a
# warm standby (read-only). After this, pg keeps itself in sync by replaying the
# remote's WAL via restore_command — no cron needed.
# Run once, manually:
#   docker exec -u postgres <restore-container> /usr/local/bin/init-standby.sh
set -euo pipefail

if [ "$(id -u)" = "0" ]; then
  echo "ERROR: must run as the postgres user (UID 999), not root." >&2
  echo "Use: docker exec -u postgres $(hostname) /usr/local/bin/init-standby.sh" >&2
  exit 1
fi
export HOME=/var/lib/postgresql

# Provided by compose environment (see docker-compose.yml / .env.example).
: "${REMOTE_STANZA:?required env var REMOTE_STANZA not set}"
: "${PG_CONTAINER:?required env var PG_CONTAINER not set}"
: "${DATA_DIR:?required env var DATA_DIR not set}"

echo "============================================================"
echo "[$(date -Iseconds)] INIT STANDBY from stanza=${REMOTE_STANZA}"
echo "  PG container  : ${PG_CONTAINER}"
echo "  Data dir      : ${DATA_DIR}"
echo "============================================================"

echo "[$(date -Iseconds)] Stopping PG (container=${PG_CONTAINER})..."
docker stop "$PG_CONTAINER" 2>/dev/null || true
sleep 2

echo "[$(date -Iseconds)] Clearing data dir ${DATA_DIR} ..."
find "$DATA_DIR" -mindepth 1 -delete

echo "[$(date -Iseconds)] Restoring ${REMOTE_STANZA} as a standby (--type=standby → standby.signal)..."
pgbackrest --stanza="$REMOTE_STANZA" \
  --pg1-path="$DATA_DIR" \
  --type=standby \
  --log-level-console=info \
  restore

echo "[$(date -Iseconds)] Starting PG (read-only warm standby)..."
docker start "$PG_CONTAINER"

echo "[$(date -Iseconds)] STANDBY READY — PG is read-only and replaying ${REMOTE_STANZA}'s WAL."
echo "Verify: docker exec ${PG_CONTAINER} psql -U postgres -c 'SELECT pg_is_in_recovery();'  # expect t"
