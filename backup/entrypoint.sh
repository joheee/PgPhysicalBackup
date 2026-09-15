#!/bin/bash
# backup container entrypoint — generates crontab from env vars, then starts cron
set -e

# Required config (defined in .env, see .env.example) — fail fast if missing.
: "${PGBACKREST_STANZA:?required env var PGBACKREST_STANZA not set (see .env.example)}"
: "${PGBACKREST_CIPHER_PASS:?required env var PGBACKREST_CIPHER_PASS not set (see .env.example)}"
: "${PGBACKREST_BACKUP_FULL_CRON:?required env var PGBACKREST_BACKUP_FULL_CRON not set (see .env.example)}"
: "${PGBACKREST_BACKUP_DIFF_CRON:?required env var PGBACKREST_BACKUP_DIFF_CRON not set (see .env.example)}"
: "${PGBACKREST_BACKUP_CHECK_CRON:?required env var PGBACKREST_BACKUP_CHECK_CRON not set (see .env.example)}"

# cron jobs do NOT inherit the container environment, so PGBACKREST_CIPHER_PASS
# (referenced by the config's repo1-cipher-pass) is baked into the command line.
# Static AWS keys (VPS, no EC2 metadata) are baked the same way. On EC2 with an
# instance profile, leave them unset: repo1-s3-key-type=auto falls through to the
# instance role.
AWS_ENV=""
if [ -n "${AWS_ACCESS_KEY_ID:-}" ] && [ -n "${AWS_SECRET_ACCESS_KEY:-}" ]; then
    AWS_ENV="AWS_ACCESS_KEY_ID='${AWS_ACCESS_KEY_ID}' AWS_SECRET_ACCESS_KEY='${AWS_SECRET_ACCESS_KEY}'"
fi

cat > /etc/cron.d/pgbackrest <<CRON
# Full backup
${PGBACKREST_BACKUP_FULL_CRON}  postgres  ${AWS_ENV} PGBACKREST_CIPHER_PASS='${PGBACKREST_CIPHER_PASS}' pgbackrest --stanza=${PGBACKREST_STANZA} --type=full backup --log-level-console=info

# Differential backup
${PGBACKREST_BACKUP_DIFF_CRON}  postgres  ${AWS_ENV} PGBACKREST_CIPHER_PASS='${PGBACKREST_CIPHER_PASS}' pgbackrest --stanza=${PGBACKREST_STANZA} --type=diff backup --log-level-console=info

# Health check
${PGBACKREST_BACKUP_CHECK_CRON}  postgres  ${AWS_ENV} PGBACKREST_CIPHER_PASS='${PGBACKREST_CIPHER_PASS}' pgbackrest --stanza=${PGBACKREST_STANZA} check --log-level-console=info
CRON

chmod 644 /etc/cron.d/pgbackrest

echo "Backup container started — stanza=${PGBACKREST_STANZA}"
echo "Cron schedule:"
cat /etc/cron.d/pgbackrest

exec "$@"
