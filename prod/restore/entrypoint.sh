#!/bin/bash
# restore container entrypoint — generates crontab from env vars, then starts cron
set -e

# Required config (defined in .env, see .env.example) — fail fast if missing.
: "${REMOTE_STANZA:?required env var REMOTE_STANZA not set (see .env.example)}"
: "${RESTORE_SYNC_CRON:?required env var RESTORE_SYNC_CRON not set (see .env.example)}"

cat > /etc/cron.d/pgbackrest <<CRON
# Sync from remote stanza
${RESTORE_SYNC_CRON}  postgres  /usr/local/bin/sync.sh >> /var/log/pgbackrest/sync.log 2>&1
CRON

chmod 644 /etc/cron.d/pgbackrest
crontab -u postgres /etc/cron.d/pgbackrest

echo "Restore container started — remote stanza=${REMOTE_STANZA}"
echo "Cron schedule:"
crontab -u postgres -l

exec "$@"
