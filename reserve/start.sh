#!/bin/bash
# start.sh — Generates configs from templates and starts containers based on ROLE.
# Run this on every VM boot or after changing .env values.
set -euo pipefail
cd "$(dirname "$0")"

# ─── Load env vars (with defaults) ──────────────────────
if [ -f .env ]; then
    set -a; source .env; set +a
fi

MY_STANZA="${MY_STANZA:-changeme}"
REMOTE_STANZA="${REMOTE_STANZA:-changeme}"
ROLE="${ROLE:-primary}"
S3_BUCKET="${S3_BUCKET:-changeme}"
AWS_DEFAULT_REGION="${AWS_DEFAULT_REGION:-us-east-1}"
S3_ENDPOINT="${S3_ENDPOINT:-s3.us-east-1.amazonaws.com}"
COMPRESS_LEVEL="${COMPRESS_LEVEL:-6}"
COMPRESS_LEVEL_NETWORK="${COMPRESS_LEVEL_NETWORK:-3}"
PROCESS_MAX="${PROCESS_MAX:-4}"
RETENTION_FULL="${RETENTION_FULL:-2}"
RETENTION_DIFF="${RETENTION_DIFF:-4}"

# ─── Generate pgbackrest configs from templates ─────────
for tmpl in configs/*.conf.tmpl; do
    target="${tmpl%.tmpl}"
    sed -e "s/__MY_STANZA__/${MY_STANZA}/g" \
        -e "s/__REMOTE_STANZA__/${REMOTE_STANZA}/g" \
        -e "s|__S3_BUCKET__|${S3_BUCKET}|g" \
        -e "s|__AWS_DEFAULT_REGION__|${AWS_DEFAULT_REGION}|g" \
        -e "s|__S3_ENDPOINT__|${S3_ENDPOINT}|g" \
        -e "s/__COMPRESS_LEVEL__/${COMPRESS_LEVEL}/g" \
        -e "s/__COMPRESS_LEVEL_NETWORK__/${COMPRESS_LEVEL_NETWORK}/g" \
        -e "s/__PROCESS_MAX__/${PROCESS_MAX}/g" \
        -e "s/__RETENTION_FULL__/${RETENTION_FULL}/g" \
        -e "s/__RETENTION_DIFF__/${RETENTION_DIFF}/g" \
        "$tmpl" > "$target"
    echo "Generated: $target"
done

# ─── Create host directories ────────────────────────────
mkdir -p pg-data pg-socket pgbackrest-spool
chown -R 999:999 pg-data pg-socket pgbackrest-spool 2>/dev/null || true

# ─── Build images ───────────────────────────────────────
docker compose build

# ─── Start PG (always running on both VMs) ──────────────
docker compose up -d pg

# ─── Role-specific container ────────────────────────────
# primary : backup container schedules full/diff/check backups of MY_STANZA.
# standby : restore container idles as a DR toolbox (init-standby / promote).
if [ "${ROLE}" = "standby" ]; then
    echo "============================================================"
    echo " Role: STANDBY — starting restore container (read-only warm standby toolbox)"
    echo "============================================================"
    docker compose up -d restore
    docker compose stop backup 2>/dev/null || true
    docker compose rm -f backup 2>/dev/null || true
else
    echo "============================================================"
    echo " Role: PRIMARY — starting backup container"
    echo "============================================================"
    docker compose up -d backup
    docker compose stop restore 2>/dev/null || true
    docker compose rm -f restore 2>/dev/null || true
fi

echo ""
echo "Done. Container status:"
docker compose ps
