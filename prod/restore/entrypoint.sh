#!/bin/bash
# restore container entrypoint — DR toolbox for standby init and failover.
# Idles until the operator execs in and runs init-standby.sh or promote.sh.
set -e

# Required config (defined in .env, see .env.example) — fail fast if missing.
: "${REMOTE_STANZA:?required env var REMOTE_STANZA not set (see .env.example)}"
: "${PG_CONTAINER:?required env var PG_CONTAINER not set}"
: "${DATA_DIR:?required env var DATA_DIR not set}"
: "${PGBACKREST_CIPHER_PASS:?required env var PGBACKREST_CIPHER_PASS not set (see .env.example)}"

# Grant the postgres user (which the scripts run as) access to the Docker socket,
# so it can `docker stop/start/exec` the pg container. The socket's group GID on
# the host varies, so detect it at runtime and add postgres to a group with that GID.
DOCKER_SOCKET_GID="$(stat -c '%g' /var/run/docker.sock 2>/dev/null || true)"
if [ -n "$DOCKER_SOCKET_GID" ] && [ "$DOCKER_SOCKET_GID" != "0" ]; then
  DOCKER_GROUP="$(getent group "$DOCKER_SOCKET_GID" 2>/dev/null | cut -d: -f1)"
  if [ -z "$DOCKER_GROUP" ]; then
    DOCKER_GROUP="docker-host"
    groupadd -g "$DOCKER_SOCKET_GID" "$DOCKER_GROUP" 2>/dev/null || true
  fi
  usermod -aG "$DOCKER_GROUP" postgres 2>/dev/null || true
fi

echo "Restore container ready — remote stanza=${REMOTE_STANZA}"
echo ""
echo "  Build standby (once):  docker exec -u postgres \$(hostname) /usr/local/bin/init-standby.sh"
echo "  Failover (promote):    docker exec -u postgres \$(hostname) /usr/local/bin/promote.sh"

exec "$@"
