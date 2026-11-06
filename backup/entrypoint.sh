#!/bin/bash
# backup container entrypoint: writes the job env file and the crontab, then starts cron.
set -euo pipefail

# Required config (defined in .env, see .env.example): fail fast if missing.
: "${PGBACKREST_STANZA:?required env var PGBACKREST_STANZA not set (see .env.example)}"
: "${PGBACKREST_REPO1_CIPHER_PASS:?required env var PGBACKREST_REPO1_CIPHER_PASS not set (see .env.example)}"
: "${PGBACKREST_BACKUP_FULL_CRON:?required env var PGBACKREST_BACKUP_FULL_CRON not set (see .env.example)}"
: "${PGBACKREST_BACKUP_DIFF_CRON:?required env var PGBACKREST_BACKUP_DIFF_CRON not set (see .env.example)}"
: "${PGBACKREST_BACKUP_CHECK_CRON:?required env var PGBACKREST_BACKUP_CHECK_CRON not set (see .env.example)}"

# cron jobs do NOT inherit the container environment. Secrets go into a
# root-only (mode 600) env file that run-job.sh sources, never into
# /etc/cron.d, a command line or a log. On EC2 with an instance profile the
# S3 keys stay unset and repo1-s3-key-type=auto uses the instance role.
JOB_ENV=/etc/pgbackrest-job.env
(
    umask 077
    for var in PGBACKREST_STANZA PGBACKREST_REPO1_CIPHER_PASS \
        PGBACKREST_REPO1_S3_KEY PGBACKREST_REPO1_S3_KEY_SECRET \
        ALERT_WEBHOOK_URL HEALTHCHECK_URL_FULL HEALTHCHECK_URL_DIFF HEALTHCHECK_URL_CHECK; do
        if [ -n "${!var:-}" ]; then
            printf 'export %s=%q\n' "$var" "${!var}"
        fi
    done
) > "$JOB_ENV"
chmod 600 "$JOB_ENV"

# The crontab holds schedules only, so it is safe to be world-readable.
cat > /etc/cron.d/pgbackrest <<CRON
# Full backup
${PGBACKREST_BACKUP_FULL_CRON}  root  /usr/local/bin/run-job.sh full --type=full backup
# Differential backup
${PGBACKREST_BACKUP_DIFF_CRON}  root  /usr/local/bin/run-job.sh diff --type=diff backup
# Health check
${PGBACKREST_BACKUP_CHECK_CRON}  root  /usr/local/bin/run-job.sh check check
CRON
chmod 644 /etc/cron.d/pgbackrest

echo "Backup container started: stanza=${PGBACKREST_STANZA} (all times UTC)"
/usr/local/bin/status.sh
echo "Extra commands (run on your host):"
echo "  docker exec -it pg-cron-backup countdown.sh --live   # live countdown, one line, nothing stored (Ctrl-C quits)"
echo "  docker exec pg-cron-backup status.sh                 # next run times"
echo "  docker exec -u postgres pg-cron-backup pgbackrest --stanza=${PGBACKREST_STANZA} info   # backups in S3"
if [ -z "${ALERT_WEBHOOK_URL:-}" ]; then
    echo "WARNING: ALERT_WEBHOOK_URL is not set; failures will only appear in docker logs."
fi

# Live countdown without storing anything:
#   docker exec -it pg-cron-backup countdown.sh --live
# COUNTDOWN_INTERVAL_SECONDS=N also appends a countdown line to docker logs every
# N seconds (default 1). Disk use is capped by the log rotation in
# docker-compose.yml. 0 leaves an hourly one-line reminder instead.
interval="${COUNTDOWN_INTERVAL_SECONDS:-1}"
if ! [[ "$interval" =~ ^[0-9]+$ ]]; then
    echo "ERROR: COUNTDOWN_INTERVAL_SECONDS must be a whole number of seconds (0 = off)" >&2
    exit 1
fi
if [ "$interval" -gt 0 ]; then
    /usr/local/bin/countdown.sh "$interval" &
else
    (
        while sleep 3600; do
            printf '%s [scheduler] %s\n' "$(date -u +%FT%TZ)" "$(/usr/local/bin/status.sh --short)"
        done
    ) &
fi

exec "$@"
