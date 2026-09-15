#!/bin/bash
# start.sh — generate configs, build images, start pg + backup.
# Run on every boot or after changing .env values.
set -euo pipefail
cd "$(dirname "$0")"

# ─── Load env vars (with defaults) ──────────────────────
if [ -f .env ]; then
    set -a; source .env; set +a
fi

PGBACKREST_STANZA="${PGBACKREST_STANZA:-pg}"
PGBACKREST_S3_BUCKET="${PGBACKREST_S3_BUCKET:-changeme}"
PGBACKREST_AWS_DEFAULT_REGION="${PGBACKREST_AWS_DEFAULT_REGION:-us-east-1}"
PGBACKREST_S3_ENDPOINT="${PGBACKREST_S3_ENDPOINT:-s3.us-east-1.amazonaws.com}"
PGBACKREST_COMPRESS_LEVEL="${PGBACKREST_COMPRESS_LEVEL:-6}"
PGBACKREST_COMPRESS_LEVEL_NETWORK="${PGBACKREST_COMPRESS_LEVEL_NETWORK:-3}"
PGBACKREST_PROCESS_MAX="${PGBACKREST_PROCESS_MAX:-4}"
PGBACKREST_RETENTION_FULL="${PGBACKREST_RETENTION_FULL:-2}"
PGBACKREST_RETENTION_DIFF="${PGBACKREST_RETENTION_DIFF:-4}"

gen_configs() {
    for tmpl in configs/*.conf.tmpl; do
        target="${tmpl%.tmpl}"
        sed -e "s/__STANZA__/${PGBACKREST_STANZA}/g" \
            -e "s|__S3_BUCKET__|${PGBACKREST_S3_BUCKET}|g" \
            -e "s|__AWS_DEFAULT_REGION__|${PGBACKREST_AWS_DEFAULT_REGION}|g" \
            -e "s|__S3_ENDPOINT__|${PGBACKREST_S3_ENDPOINT}|g" \
            -e "s/__COMPRESS_LEVEL__/${PGBACKREST_COMPRESS_LEVEL}/g" \
            -e "s/__COMPRESS_LEVEL_NETWORK__/${PGBACKREST_COMPRESS_LEVEL_NETWORK}/g" \
            -e "s/__PROCESS_MAX__/${PGBACKREST_PROCESS_MAX}/g" \
            -e "s/__RETENTION_FULL__/${PGBACKREST_RETENTION_FULL}/g" \
            -e "s/__RETENTION_DIFF__/${PGBACKREST_RETENTION_DIFF}/g" \
            "$tmpl" > "$target"
        echo "Generated: $target"
    done
}

# `./start.sh gen-configs` — only regenerate configs (used by restore.sh)
if [ "${1:-}" = "gen-configs" ]; then
    gen_configs
    exit 0
fi

gen_configs

# ─── Create host directories ────────────────────────────
mkdir -p pg-data pg-socket pgbackrest-spool
chown -R 999:999 pg-data pg-socket pgbackrest-spool 2>/dev/null || true

# ─── Build images + start PG ─────────────────────────────
docker compose build
docker compose up -d pg

# Wait for PG to accept connections, then ensure the stanza exists (idempotent).
for _ in $(seq 1 30); do
    docker compose exec -T pg pg_isready -U "${POSTGRES_USER:-postgres}" >/dev/null 2>&1 && break
    sleep 2
done

if docker compose exec -T -u postgres pg pgbackrest --stanza="$PGBACKREST_STANZA" info >/dev/null 2>&1; then
    echo "Stanza '${PGBACKREST_STANZA}' already exists."
else
    echo "Creating stanza '${PGBACKREST_STANZA}'..."
    docker compose exec -T -u postgres pg pgbackrest --stanza="$PGBACKREST_STANZA" stanza-create
fi

# ─── Start backup scheduler ──────────────────────────────
docker compose up -d backup

echo ""
echo "Done. Container status:"
docker compose ps
