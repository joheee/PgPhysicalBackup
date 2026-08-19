#!/bin/bash
# promote.sh — failover: promote the warm standby to a writable primary.
# Run once you've decided to cut over to this VM:
#   docker exec -u postgres <restore-container> /usr/local/bin/promote.sh
set -euo pipefail

if [ "$(id -u)" = "0" ]; then
  echo "ERROR: must run as the postgres user (UID 999), not root." >&2
  echo "Use: docker exec -u postgres $(hostname) /usr/local/bin/promote.sh" >&2
  exit 1
fi
export HOME=/var/lib/postgresql

: "${PG_CONTAINER:?required env var PG_CONTAINER not set}"

echo "[$(date -Iseconds)] Promoting ${PG_CONTAINER} to read-write primary..."
docker exec "$PG_CONTAINER" psql -U postgres -c "SELECT pg_promote();"

echo "[$(date -Iseconds)] PROMOTE COMPLETE — ${PG_CONTAINER} is now read-write."
echo "Verify: docker exec ${PG_CONTAINER} psql -U postgres -c 'SELECT pg_is_in_recovery();'  # expect f"
