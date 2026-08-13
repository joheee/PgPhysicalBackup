#!/bin/bash
# backup container entrypoint — generates crontab from env vars, then starts cron
set -e

# Required config (defined in .env, see .env.example) — fail fast if missing.
: "${MY_STANZA:?required env var MY_STANZA not set (see .env.example)}"
: "${PGBACKREST_CIPHER_PASS:?required env var PGBACKREST_CIPHER_PASS not set (see .env.example)}"
: "${BACKUP_FULL_CRON:?required env var BACKUP_FULL_CRON not set (see .env.example)}"
: "${BACKUP_DIFF_CRON:?required env var BACKUP_DIFF_CRON not set (see .env.example)}"
: "${BACKUP_CHECK_CRON:?required env var BACKUP_CHECK_CRON not set (see .env.example)}"

# cron jobs do NOT inherit the container environment, so PGBACKREST_CIPHER_PASS
# (referenced by the config's repo1-cipher-pass) is baked into the command line.
cat > /etc/cron.d/pgbackrest <<CRON
# Full backup
${BACKUP_FULL_CRON}  postgres  PGBACKREST_CIPHER_PASS='${PGBACKREST_CIPHER_PASS}' pgbackrest --stanza=${MY_STANZA} --type=full backup --log-level-console=info

# Differential backup
${BACKUP_DIFF_CRON}  postgres  PGBACKREST_CIPHER_PASS='${PGBACKREST_CIPHER_PASS}' pgbackrest --stanza=${MY_STANZA} --type=diff backup --log-level-console=info

# Health check
${BACKUP_CHECK_CRON}  postgres  PGBACKREST_CIPHER_PASS='${PGBACKREST_CIPHER_PASS}' pgbackrest --stanza=${MY_STANZA} check --log-level-console=info
CRON

chmod 644 /etc/cron.d/pgbackrest

echo "Backup container started — stanza=${MY_STANZA}"
echo "Cron schedule:"
cat /etc/cron.d/pgbackrest

exec "$@"
