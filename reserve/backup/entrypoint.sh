#!/bin/bash
# backup container entrypoint — generates crontab from env vars, then starts cron
set -e

# Required config (defined in .env, see .env.example) — fail fast if missing.
: "${MY_STANZA:?required env var MY_STANZA not set (see .env.example)}"
: "${BACKUP_FULL_CRON:?required env var BACKUP_FULL_CRON not set (see .env.example)}"
: "${BACKUP_DIFF_CRON:?required env var BACKUP_DIFF_CRON not set (see .env.example)}"
: "${BACKUP_CHECK_CRON:?required env var BACKUP_CHECK_CRON not set (see .env.example)}"

cat > /etc/cron.d/pgbackrest <<CRON
# Full backup
${BACKUP_FULL_CRON}  postgres  pgbackrest --stanza=${MY_STANZA} --type=full backup --log-level-console=info

# Differential backup
${BACKUP_DIFF_CRON}  postgres  pgbackrest --stanza=${MY_STANZA} --type=diff backup --log-level-console=info

# Health check
${BACKUP_CHECK_CRON}  postgres  pgbackrest --stanza=${MY_STANZA} check --log-level-console=info
CRON

chmod 644 /etc/cron.d/pgbackrest
crontab -u postgres /etc/cron.d/pgbackrest

echo "Backup container started — stanza=${MY_STANZA}"
echo "Cron schedule:"
crontab -u postgres -l

exec "$@"
