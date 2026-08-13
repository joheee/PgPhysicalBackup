#!/bin/bash
# backup container entrypoint — generates crontab from env vars, then starts cron
set -e

STANZA="${MY_STANZA:-changeme}"

cat > /etc/cron.d/pgbackrest <<CRON
# Full backup: Sunday 2:07am
07 2 * * 0  postgres  pgbackrest --stanza=${STANZA} --type=full backup --log-level-console=info

# Differential backup: Mon-Sat 2:07am
07 2 * * 1-6  postgres  pgbackrest --stanza=${STANZA} --type=diff backup --log-level-console=info

# Health check: daily 7:17am
17 7 * * *  postgres  pgbackrest --stanza=${STANZA} check --log-level-console=info
CRON

chmod 644 /etc/cron.d/pgbackrest
crontab -u postgres /etc/cron.d/pgbackrest

echo "Backup container started — stanza=${STANZA}"
echo "Cron schedule:"
crontab -u postgres -l

exec "$@"
