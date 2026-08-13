#!/bin/bash
# restore container entrypoint — generates crontab from env vars, then starts cron
set -e

SYNC_CRON="${RESTORE_SYNC_CRON:-*/30 * * * *}"

cat > /etc/cron.d/pgbackrest <<CRON
# Sync from remote stanza (default: every 30 minutes)
${SYNC_CRON}  postgres  /usr/local/bin/sync.sh >> /var/log/pgbackrest/sync.log 2>&1
CRON

chmod 644 /etc/cron.d/pgbackrest
crontab -u postgres /etc/cron.d/pgbackrest

echo "Restore container started — remote stanza=${REMOTE_STANZA:-changeme}"
echo "Cron schedule:"
crontab -u postgres -l

exec "$@"
