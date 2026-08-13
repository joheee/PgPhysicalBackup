#!/bin/bash
# backup container entrypoint — generates crontab from env vars, then starts cron
set -e

STANZA="${MY_STANZA:-changeme}"
FULL_CRON="${BACKUP_FULL_CRON:-07 2 * * 0}"
DIFF_CRON="${BACKUP_DIFF_CRON:-07 2 * * 1-6}"
CHECK_CRON="${BACKUP_CHECK_CRON:-17 7 * * *}"

cat > /etc/cron.d/pgbackrest <<CRON
# Full backup (default: Sunday 02:07)
${FULL_CRON}  postgres  pgbackrest --stanza=${STANZA} --type=full backup --log-level-console=info

# Differential backup (default: Mon-Sat 02:07)
${DIFF_CRON}  postgres  pgbackrest --stanza=${STANZA} --type=diff backup --log-level-console=info

# Health check (default: daily 07:17)
${CHECK_CRON}  postgres  pgbackrest --stanza=${STANZA} check --log-level-console=info
CRON

chmod 644 /etc/cron.d/pgbackrest
crontab -u postgres /etc/cron.d/pgbackrest

echo "Backup container started — stanza=${STANZA}"
echo "Cron schedule:"
crontab -u postgres -l

exec "$@"
