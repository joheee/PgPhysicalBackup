#!/bin/bash
# start.sh — generate configs, build images, start pg + backup.
# Run on every boot or after changing .env values.
set -euo pipefail
cd "$(dirname "$0")"

# ─── Load env vars (with defaults) ──────────────────────
# shellcheck disable=SC1091
if [ -f .env ]; then
    set -a; source .env; set +a
fi

PGBACKREST_STANZA="${PGBACKREST_STANZA:-pg}"
PGBACKREST_S3_BUCKET="${PGBACKREST_S3_BUCKET:-changeme}"
PGBACKREST_AWS_DEFAULT_REGION="${PGBACKREST_AWS_DEFAULT_REGION:-ap-southeast-2}"
PGBACKREST_S3_ENDPOINT="${PGBACKREST_S3_ENDPOINT:-s3.ap-southeast-2.amazonaws.com}"
PGBACKREST_ARCHIVE_TIMEOUT="${PGBACKREST_ARCHIVE_TIMEOUT:-60}"

# Static IAM user keys (laptop, VPS) -> "shared"; EC2 instance profile -> "auto".
if [ -n "${PGBACKREST_AWS_ACCESS_KEY_ID:-}" ] && [ -n "${PGBACKREST_AWS_SECRET_ACCESS_KEY:-}" ]; then
    PGBACKREST_S3_KEY_TYPE=shared
else
    PGBACKREST_S3_KEY_TYPE=auto
fi

# Refuse the placeholder passphrase: the repo would be encrypted with a known value.
if [ "${PGBACKREST_CIPHER_PASS:-changeme}" = "changeme" ]; then
    echo "ERROR: set PGBACKREST_CIPHER_PASS in .env (openssl rand -base64 48)" >&2
    exit 1
fi
# .env holds the cipher passphrase and the S3 keys.
if [ -f .env ] && [ "$(stat -c %a .env)" != "600" ]; then
    echo "WARNING: .env is mode $(stat -c %a .env); run: chmod 600 .env" >&2
fi
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
            -e "s|__S3_KEY_TYPE__|${PGBACKREST_S3_KEY_TYPE}|g" \
            -e "s/__ARCHIVE_TIMEOUT__/${PGBACKREST_ARCHIVE_TIMEOUT}/g" \
            -e "s/__PROCESS_MAX__/${PGBACKREST_PROCESS_MAX}/g" \
            -e "s/__RETENTION_FULL__/${PGBACKREST_RETENTION_FULL}/g" \
            -e "s/__RETENTION_DIFF__/${PGBACKREST_RETENTION_DIFF}/g" \
            "$tmpl" > "$target"
        echo "Generated: $target"
    done
}

# Static S3 keys go to a mode-600, git-ignored env file that Compose loads
# (env_file, required: false). pgBackRest rejects empty key variables, so with
# an instance profile the file must not exist at all.
gen_s3_keys_env() {
    rm -f configs/s3-keys.env
    if [ "$PGBACKREST_S3_KEY_TYPE" = "shared" ]; then
        (
            umask 077
            printf 'PGBACKREST_REPO1_S3_KEY=%s\nPGBACKREST_REPO1_S3_KEY_SECRET=%s\n' \
                "$PGBACKREST_AWS_ACCESS_KEY_ID" "$PGBACKREST_AWS_SECRET_ACCESS_KEY" \
                > configs/s3-keys.env
        )
        echo "Generated: configs/s3-keys.env (mode 600)"
    fi
}

# `./start.sh gen-configs` — only regenerate configs (used by restore.sh)
if [ "${1:-}" = "gen-configs" ]; then
    gen_configs
    gen_s3_keys_env
    exit 0
fi

gen_configs
gen_s3_keys_env

# ─── Create host directories ────────────────────────────
mkdir -p pg-data pg-socket pgbackrest-spool reports
# The restore container runs as uid 999 and writes its reports here; a sticky
# world-writable directory lets it do that while you stay able to delete them.
chmod 1777 reports
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
