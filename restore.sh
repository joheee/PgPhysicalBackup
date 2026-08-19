#!/bin/bash
# restore.sh — DR: rebuild THIS host from the latest S3 backup (single-PG model).
#
# Use on a fresh/replacement EC2 VM:
#   1. Clone repo, cp .env.example .env, set S3_BUCKET / PGBACKREST_CIPHER_PASS / STANZA
#      to the SAME values as the source instance.
#   2. ./restore.sh
#
# Restores the latest backup (preserving the database system-id, so archiving to
# the same stanza keeps working) and brings PG up as the primary.
set -euo pipefail
cd "$(dirname "$0")"

if [ -f .env ]; then
    set -a; source .env; set +a
fi

STANZA="${STANZA:-pg}"
: "${S3_BUCKET:?S3_BUCKET must be set in .env}"
: "${PGBACKREST_CIPHER_PASS:?PGBACKREST_CIPHER_PASS must be set in .env}"

echo "=== Restoring stanza=${STANZA} from bucket=${S3_BUCKET} ==="

# 1. Generate configs + dirs (same substitution as start.sh)
./start.sh gen-configs
mkdir -p pg-data pg-socket pgbackrest-spool
chown -R 999:999 pg-data pg-socket pgbackrest-spool 2>/dev/null || true

# 2. Stop pg if present (never let initdb run before restore)
docker compose stop pg 2>/dev/null || true

# 3. Wipe local data (restore requires an empty target)
find pg-data -mindepth 1 -delete

# 4. Restore latest backup (runs as postgres for correct file ownership)
docker compose run --rm --no-deps --user postgres --entrypoint pgbackrest \
    -e PGBACKREST_CIPHER_PASS="$PGBACKREST_CIPHER_PASS" \
    -e HOME=/var/lib/postgresql \
    pg --stanza="$STANZA" --pg1-path=/var/lib/postgresql/data --log-level-console=info restore

# 5. Start pg (replays WAL to the latest, comes up writable) + backup
docker compose up -d pg
docker compose up -d backup

echo ""
echo "Restore complete. Verify:"
echo "  docker exec pg psql -U postgres -c 'SELECT pg_is_in_recovery();'   # expect f"
