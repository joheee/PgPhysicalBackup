#!/bin/bash
# restore container entrypoint — generates crontab from env vars, then starts cron
set -e

# Required config (defined in .env, see .env.example) — fail fast if missing.
: "${REMOTE_STANZA:?required env var REMOTE_STANZA not set (see .env.example)}"
: "${PG_CONTAINER:?required env var PG_CONTAINER not set}"
: "${DATA_DIR:?required env var DATA_DIR not set}"
: "${PGBACKREST_CIPHER_PASS:?required env var PGBACKREST_CIPHER_PASS not set (see .env.example)}"
: "${RESTORE_SYNC_CRON:?required env var RESTORE_SYNC_CRON not set (see .env.example)}"

# cron jobs do NOT inherit the container environment, so the vars sync.sh needs
# are baked into the command line as env-prefix assignments.
cat > /etc/cron.d/pgbackrest <<CRON
# Sync from remote stanza
${RESTORE_SYNC_CRON}  postgres  REMOTE_STANZA='${REMOTE_STANZA}' PG_CONTAINER='${PG_CONTAINER}' DATA_DIR='${DATA_DIR}' PGBACKREST_CIPHER_PASS='${PGBACKREST_CIPHER_PASS}' /usr/local/bin/sync.sh >> /var/log/pgbackrest/sync.log 2>&1
CRON

chmod 644 /etc/cron.d/pgbackrest

echo "Restore container started — remote stanza=${REMOTE_STANZA}"
echo "Cron schedule:"
cat /etc/cron.d/pgbackrest

exec "$@"
