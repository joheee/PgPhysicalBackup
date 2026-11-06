#!/bin/bash
# restore.sh — DR: rebuild THIS host from the latest S3 backup (single-PG model).
#
# Use on a fresh/replacement EC2 VM:
#   1. Clone repo, cp .env.example .env, set PGBACKREST_S3_BUCKET /
#      PGBACKREST_CIPHER_PASS / PGBACKREST_STANZA to the SAME values as the source
#      instance.
#   2. ./restore.sh          (asks before wiping pg-data; --yes skips the prompt)
#
# Restores the latest backup (preserving the database system-id, so archiving to
# the same stanza keeps working) and brings PG up as the primary.
set -euo pipefail
cd "$(dirname "$0")"

ASSUME_YES=0
case "${1:-}" in
    --yes|-y) ASSUME_YES=1 ;;
    "") ;;
    *) echo "usage: $0 [--yes]" >&2; exit 2 ;;
esac

# shellcheck disable=SC1091
if [ -f .env ]; then
    set -a; source .env; set +a
fi

PGBACKREST_STANZA="${PGBACKREST_STANZA:-pg}"
: "${PGBACKREST_S3_BUCKET:?PGBACKREST_S3_BUCKET must be set in .env}"
: "${PGBACKREST_CIPHER_PASS:?PGBACKREST_CIPHER_PASS must be set in .env}"

echo "=== Restoring stanza=${PGBACKREST_STANZA} from bucket=${PGBACKREST_S3_BUCKET} ==="

# 1. Generate configs + dirs (same substitution as start.sh)
./start.sh gen-configs
mkdir -p pg-data pg-socket pgbackrest-spool
chown -R 999:999 pg-data pg-socket pgbackrest-spool 2>/dev/null || true

# pg-data is owned by uid 999 (mode 700), so inspect and wipe it from a throwaway
# root container that only mounts the data directory.
pgdata_sh() {
    docker compose run --rm --no-deps -T --user root --entrypoint sh pg -c "$1" </dev/null
}

# 2. Confirm before touching anything (prompt first, so "no" leaves pg running)
NEEDS_WIPE=0
# shellcheck disable=SC2016  # $(...) must expand inside the container, not here
if pgdata_sh 'test -n "$(ls -A /var/lib/postgresql/data)"'; then
    NEEDS_WIPE=1
    echo "This will DELETE everything in $(pwd)/pg-data and replace it with the latest backup."
    if [ "$ASSUME_YES" -ne 1 ]; then
        if [ ! -t 0 ]; then
            echo "Refusing to wipe pg-data without a terminal; pass --yes to confirm." >&2
            exit 1
        fi
        read -r -p "Type the stanza name (${PGBACKREST_STANZA}) to continue: " answer
        if [ "$answer" != "$PGBACKREST_STANZA" ]; then
            echo "Aborted; pg-data untouched." >&2
            exit 1
        fi
    fi
fi

# 3. Stop pg and backup (never let initdb run before restore), then wipe:
#    pgBackRest restores only into an empty target.
docker compose stop pg backup 2>/dev/null || true
if [ "$NEEDS_WIPE" -eq 1 ]; then
    pgdata_sh 'find /var/lib/postgresql/data -mindepth 1 -delete'
fi

# 4. Restore latest backup (runs as postgres for correct file ownership).
#    The passphrase and S3 keys come from the pg service's environment, not the command line.
docker compose run --rm --no-deps --user postgres --entrypoint pgbackrest \
    -e HOME=/var/lib/postgresql \
    pg --stanza="$PGBACKREST_STANZA" --pg1-path=/var/lib/postgresql/data --log-level-console=info restore

# 5. Start pg (replays WAL to the latest, comes up writable) + backup
docker compose up -d pg
docker compose up -d backup

echo ""
echo "Restore complete. Verify:"
echo "  docker exec pg psql -U postgres -c 'SELECT pg_is_in_recovery();'   # expect f"
