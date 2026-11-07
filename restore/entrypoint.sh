#!/bin/bash
# Throwaway restore: restore from S3 into an EMPTY data directory, start Postgres
# with archive_mode=off, wait for recovery to finish, run the checks, write a
# report and clean up. It never runs initdb and never touches pg-data (the
# Compose service does not mount it).
#
# Scenario, all optional (see README "Restore container"):
#   RESTORE_TYPE=time|name  RESTORE_TARGET=<timestamp|restore point name>
#   RESTORE_TYPE=immediate  (stop as soon as the backup is consistent, no target)
#   RESTORE_SET=<backup label>   RESTORE_DB_INCLUDE=<database>
#   RESTORE_DELTA=1   (restore onto an existing directory, fetching changed files only)
#   RESTORE_KEEP=1    (keep the restored data after the run)
#   RESTORE_VERIFY=1  (also run `pgbackrest verify` on the whole repo)
#   EXPECT_FILE=<json> (row counts / RPO to check, see checks.sh)
# Globals here are read by the sourced checks.sh and report.sh, which shellcheck
# does not follow without -x.
# shellcheck disable=SC1091,SC2034
set -uo pipefail

PGDATA="${PGDATA:-/var/lib/postgresql/data}"
STANZA="${PGBACKREST_STANZA:-pg}"
RUN_ID="${RUN_ID:-$(date -u +%Y%m%dT%H%M%SZ)}"
REPORT_DIR="${REPORT_DIR:-/reports}"
TYPE="${RESTORE_TYPE:-}"
TARGET="${RESTORE_TARGET:-}"
SET="${RESTORE_SET:-}"
DB_INCLUDE="${RESTORE_DB_INCLUDE:-}"
DELTA="${RESTORE_DELTA:-0}"
KEEP="${RESTORE_KEEP:-0}"
VERIFY="${RESTORE_VERIFY:-0}"
EXPECT_FILE="${EXPECT_FILE:-}"
export PGUSER="${POSTGRES_USER:-postgres}" PGHOST=/var/run/postgresql PGDATABASE=postgres
export CHECKS_FILE=/tmp/checks.tsv
: >"$CHECKS_FILE"

source /usr/local/bin/checks.sh
source /usr/local/bin/report.sh

die() { echo "ERROR: $*" >&2; exit 2; }
now() { date +%s.%N; }
elapsed() { awk -v a="$1" -v b="$2" 'BEGIN { printf "%.1f", b - a }'; }

# ── validate the request ────────────────────────────────
case "$TYPE" in "" | time | name | immediate) ;; *) die "RESTORE_TYPE must be empty, time, name or immediate (got '$TYPE')" ;; esac
case "$TYPE" in
    time | name) [ -n "$TARGET" ] || die "RESTORE_TYPE=$TYPE needs RESTORE_TARGET" ;;
    immediate) [ -z "$TARGET" ] || die "RESTORE_TYPE=immediate takes no RESTORE_TARGET" ;;
    "") [ -z "$TARGET" ] || die "RESTORE_TARGET needs RESTORE_TYPE=time or name" ;;
esac
[[ "$SET" =~ ^[0-9A-Za-z_-]*$ ]] || die "RESTORE_SET must be a backup label such as 20261106-183638F"
[[ "$DB_INCLUDE" =~ ^[0-9A-Za-z_]*$ ]] || die "RESTORE_DB_INCLUDE must be a database name"
case "$DB_INCLUDE" in
    postgres | template0 | template1)
        die "RESTORE_DB_INCLUDE=$DB_INCLUDE is a system database. pgBackRest always restores those; name a user database (for example appdb)." ;;
esac
for v in DELTA KEEP VERIFY; do
    [[ "${!v}" =~ ^[01]$ ]] || die "RESTORE_${v} must be 0 or 1"
done
[ -n "${PGBACKREST_REPO1_CIPHER_PASS:-}" ] || die "PGBACKREST_REPO1_CIPHER_PASS is not set"

parts=()
case "$TYPE" in time) parts+=(pitr) ;; name) parts+=(named-point) ;; immediate) parts+=(immediate) ;; esac
[ -n "$SET" ] && parts+=(older-set)
[ -n "$DB_INCLUDE" ] && parts+=(single-db)
[ "$DELTA" = 1 ] && parts+=(delta)
[ "${#parts[@]}" -eq 0 ] && parts+=(latest)
SCENARIO="${RESTORE_SCENARIO:-$(IFS=+; echo "${parts[*]}")}"
export SCENARIO RUN_ID STANZA

# ── the target must be empty (unless this is a delta restore) ──
started_empty=0
if [ -n "$(ls -A "$PGDATA" 2>/dev/null)" ]; then
    [ "$DELTA" = 1 ] || die "$PGDATA is not empty. A restore needs an empty directory (clear the restore-data volume, or use RESTORE_DELTA=1)."
    [ -f "$PGDATA/postmaster.pid" ] && die "$PGDATA has a postmaster.pid; stop that server first"
else
    started_empty=1
fi

echo "== restore run $RUN_ID: scenario=$SCENARIO stanza=$STANZA =="

started_at="$(date -u +%FT%TZ)"
restore_s="" replay_s="" total_s=""
backup_label="" backup_type="" backup_size="" backup_repo_size=""
pg_up=0

finish() { # finish: stop Postgres, clean up, write the report, exit with pass/fail
    if [ "$pg_up" = 1 ]; then
        pg_ctl -D "$PGDATA" -m fast -w stop >/dev/null 2>&1
    fi
    # Only a directory this run created empty is cleared; delta runs never are.
    if [ "$started_empty" = 1 ] && [ "$KEEP" != 1 ] && [ "$DELTA" != 1 ]; then
        find "$PGDATA" -mindepth 1 -delete 2>/dev/null
    fi
    # A report that cannot be built is a failure, never a silent pass.
    write_report || exit 1
    grep -q $'\tFAIL\t' "$CHECKS_FILE" && exit 1
    exit 0
}

# ── what are we restoring? ──────────────────────────────
info_json="$(pgbackrest --stanza="$STANZA" --output=json info 2>/tmp/info.err)" || info_json=""
backup_json="$(jq -c --arg set "$SET" '.[0].backup // [] | if $set == "" then .[-1] else map(select(.label == $set))[0] end' <<<"$info_json" 2>/dev/null)"
if [ -z "$backup_json" ] || [ "$backup_json" = null ]; then
    record backup_found FAIL "no usable backup in stanza '$STANZA'${SET:+ (set $SET)}: $(head -c 300 /tmp/info.err | tr '\n' ' ')"
    finish
fi
backup_label="$(jq -r .label <<<"$backup_json")"
backup_type="$(jq -r .type <<<"$backup_json")"
backup_size="$(jq -r '.info.size' <<<"$backup_json")"
backup_repo_size="$(jq -r '.info.repository.size' <<<"$backup_json")"
record backup_found PASS "$backup_label ($backup_type)"

# ── restore ─────────────────────────────────────────────
args=(--stanza="$STANZA" --pg1-path="$PGDATA" --archive-mode=off --log-level-console=info)
case "$TYPE" in
    time | name) args+=(--type="$TYPE" --target="$TARGET" --target-action=promote) ;;
    immediate) args+=(--type=immediate --target-action=promote) ;;
esac
[ -n "$SET" ] && args+=(--set="$SET")
[ -n "$DB_INCLUDE" ] && args+=(--db-include="$DB_INCLUDE")
[ "$DELTA" = 1 ] && args+=(--delta)

t_start="$(now)"
pgbackrest "${args[@]}" restore 2>&1 | tee /tmp/restore.log
restore_rc="${PIPESTATUS[0]}"
t_restored="$(now)"
restore_s="$(elapsed "$t_start" "$t_restored")"
if [ "$restore_rc" -ne 0 ]; then
    record restore FAIL "pgbackrest restore exited $restore_rc: $(grep -m1 ERROR /tmp/restore.log | cut -c1-300)"
    finish
fi
record restore PASS "restored in ${restore_s}s"

# ── start Postgres (no network, archiving off) and wait for recovery ──
if ! pg_ctl -D "$PGDATA" -w -t "${RESTORE_START_TIMEOUT:-3600}" -l /tmp/postgres.log \
    -o "-c listen_addresses='' -c archive_mode=off -c unix_socket_directories=$PGHOST" start >/tmp/pg_ctl.out 2>&1; then
    record postgres_started FAIL "$(tail -n 5 /tmp/postgres.log | tr '\n' ' ' | cut -c1-400)"
    finish
fi
pg_up=1
t_started="$(now)"
deadline=$((SECONDS + ${RESTORE_REPLAY_TIMEOUT:-7200}))
while :; do
    state="$(psql -Atqc 'select pg_is_in_recovery()' 2>/dev/null || true)"
    [ "$state" = f ] && break
    if ! pg_ctl -D "$PGDATA" status >/dev/null 2>&1; then
        pg_up=0
        record recovery_finished FAIL "Postgres stopped during recovery: $(tail -n 5 /tmp/postgres.log | tr '\n' ' ' | cut -c1-400)"
        finish
    fi
    if [ "$SECONDS" -ge "$deadline" ]; then
        record recovery_finished FAIL "still in recovery after ${RESTORE_REPLAY_TIMEOUT:-7200}s"
        finish
    fi
    sleep 0.2
done
t_recovered="$(now)"
replay_s="$(elapsed "$t_started" "$t_recovered")"
total_s="$(elapsed "$t_start" "$t_recovered")"

echo "== checks =="
run_checks
finish
