#!/bin/bash
# run-job.sh <job-name> <pgbackrest args...>
# Runs one pgBackRest job as the postgres user and fails loudly:
#   - output goes to `docker logs` (PID 1's stdout)
#   - non-zero exit on failure
#   - webhook alert on failure (ALERT_WEBHOOK_URL, optional)
#   - dead-man's switch ping on success, /fail on failure (HEALTHCHECK_URL_<JOB>, optional)
set -uo pipefail

job="${1:?usage: run-job.sh <job-name> <pgbackrest args...>}"
shift

# shellcheck source=/dev/null
[ -r /etc/pgbackrest-job.env ] && source /etc/pgbackrest-job.env

: "${PGBACKREST_STANZA:?PGBACKREST_STANZA missing from /etc/pgbackrest-job.env}"

LOG_SINK=/proc/1/fd/1
log() { printf '%s [%s] %s\n' "$(date -u +%FT%TZ)" "$job" "$*" | tee -a "$LOG_SINK"; }

# Per-job dead-man's switch URL, e.g. HEALTHCHECK_URL_FULL.
hc_var="HEALTHCHECK_URL_${job^^}"
hc_url="${!hc_var:-}"

ping_hc() { # ping_hc [suffix]
    [ -n "$hc_url" ] || return 0
    curl -fsS -m 5 --retry 2 -o /dev/null "${hc_url}${1:-}" ||
        log "WARNING: dead-man's switch ping failed"
}

alert() { # alert <message>
    [ -n "${ALERT_WEBHOOK_URL:-}" ] || return 0
    jq -n --arg text "$1" '{text: $text}' |
        curl -fsS -m 5 --retry 2 -o /dev/null -H 'Content-Type: application/json' \
            --data @- "$ALERT_WEBHOOK_URL" ||
        log "WARNING: webhook alert failed"
}

out="$(mktemp)"
trap 'rm -f "$out"' EXIT

log "start: pgbackrest --stanza=${PGBACKREST_STANZA} $*"

# Run as postgres; the env (secrets) comes from the env file sourced above.
runuser -u postgres -- pgbackrest --stanza="$PGBACKREST_STANZA" --log-level-console=info "$@" 2>&1 |
    tee "$out" >>"$LOG_SINK"
rc="${PIPESTATUS[0]}"

if [ "$rc" -eq 0 ]; then
    log "ok"
    ping_hc
else
    log "FAILED with exit code $rc"
    ping_hc /fail
    alert "pgBackRest job '${job}' FAILED on $(hostname) (stanza ${PGBACKREST_STANZA}, exit ${rc}):
$(tail -n 15 "$out")"
fi
exit "$rc"
