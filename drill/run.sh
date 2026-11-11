#!/bin/bash
# drill/run.sh: restore drill on a throwaway stanza. It never touches pg, pg-data
# or the real stanza.
#
#   drill/run.sh                         must-haves: latest (+ verify), pitr, failure
#   drill/run.sh --scenario all          every scenario
#   drill/run.sh --scenario pitr,delta   only these (the seed and backups always run)
#   drill/run.sh --keep                  keep the drill containers and volumes afterwards
#
# Flow: start a throwaway drill-source Postgres that archives to drill/<run-id>/
# in the same bucket, with a random cipher passphrase. Seed it (pgbench, orders,
# a canary row every second), take a full backup, keep writing, take a
# differential backup, test that failures alert, then make the mistakes (restore
# point + bad migration, DELETE FROM orders, docker kill). For each scenario, write
# an EXPECT_FILE with what the source knew and run the restore container once.
# Reports land in reports/drill-<run-id>/, plus summary.md and summary.json.
#
# Needs: ./start.sh run once (or `./start.sh gen-configs`), Docker with Compose, jq.
# Objects under drill/ are left in S3 and expire through the bucket's lifecycle rule.
# jq programs and SQL use $names inside single quotes on purpose.
# shellcheck disable=SC2016
set -euo pipefail
cd "$(dirname "$0")/.."

MUST_HAVE=(latest pitr failure)
ALL=(latest pitr failure named-point older-set single-db delta)
PROJECT=pgdemo # docker-compose.yml: name
SCALE="${DRILL_PGBENCH_SCALE:-1}"
PGBENCH_SECONDS="${DRILL_PGBENCH_SECONDS:-15}"
export DRILL_ARCHIVE_TIMEOUT="${DRILL_ARCHIVE_TIMEOUT:-10}"
RPO_MAX="${DRILL_RPO_MAX_SECONDS:-$((DRILL_ARCHIVE_TIMEOUT * 2 + 10))}"
DRILL_ARCHIVE_DRAIN_TIMEOUT="${DRILL_ARCHIVE_DRAIN_TIMEOUT:-3600}"
FAKE_KEY_ID=AKIAIOSFODNN7EXAMPLE # AWS's documented example key: always rejected

usage() { sed -n '2,20p' "$0" | sed 's/^# \{0,1\}//'; }
die() { echo "ERROR: $*" >&2; exit 2; }
log() { printf '%s [drill] %s\n' "$(date -u +%T)" "$*"; }
now() { date +%s.%N; }
elapsed() { awk -v a="$1" -v b="$2" 'BEGIN { printf "%.1f", b - a }'; }

# ── arguments ───────────────────────────────────────────
selected=("${MUST_HAVE[@]}") keep=0 build=1
while [ $# -gt 0 ]; do
    case "$1" in
        --scenario)
            [ $# -ge 2 ] || die "--scenario needs a name, a comma list or 'all'"
            if [ "$2" = all ]; then selected=("${ALL[@]}"); else IFS=, read -ra selected <<<"$2"; fi
            shift 2 ;;
        --keep) keep=1; shift ;;
        --no-build) build=0; shift ;; # use the images you already have
        -h | --help) usage; exit 0 ;;
        *) die "unknown argument '$1' (see --help)" ;;
    esac
done
for s in "${selected[@]}"; do
    [ "$s" = verify ] && s=latest # verify runs as part of latest
    [[ " ${ALL[*]} " == *" $s "* ]] || die "unknown scenario '$s' (choose from: ${ALL[*]} all)"
done
want() { # want <scenario>: was it selected? (delta needs latest, verify is latest)
    local s
    for s in "${selected[@]}"; do
        [ "$s" = "$1" ] && return 0
        [ "$1" = latest ] && [[ "$s" = verify || "$s" = delta ]] && return 0
    done
    return 1
}

# ── preflight ───────────────────────────────────────────
command -v docker >/dev/null || die "docker is not installed"
command -v jq >/dev/null || die "jq is not installed on this host"
docker compose version >/dev/null 2>&1 || die "docker compose (v2) is not available"
[ -f configs/pg-pgbackrest.conf ] || die "configs/pg-pgbackrest.conf is missing; run ./start.sh (or ./start.sh gen-configs) first"
[[ "$SCALE" =~ ^[1-9][0-9]*$ ]] || die "DRILL_PGBENCH_SCALE must be a whole number"
[[ "$PGBENCH_SECONDS" =~ ^[1-9][0-9]*$ ]] || die "DRILL_PGBENCH_SECONDS must be a whole number"
[[ "$DRILL_ARCHIVE_TIMEOUT" =~ ^[1-9][0-9]*$ ]] || die "DRILL_ARCHIVE_TIMEOUT must be a whole number of seconds"
[[ "$RPO_MAX" =~ ^[0-9]+$ ]] || die "DRILL_RPO_MAX_SECONDS must be a whole number of seconds"
[[ "$DRILL_ARCHIVE_DRAIN_TIMEOUT" =~ ^[1-9][0-9]*$ ]] || die "DRILL_ARCHIVE_DRAIN_TIMEOUT must be a whole number of seconds"

# Leftovers from a crashed or --keep run would be restored into or reused, so
# refuse instead of wiping them.
for v in drill-source-data drill-socket drill-restore-data; do
    if docker volume inspect "${PROJECT}_$v" >/dev/null 2>&1; then
        die "volume ${PROJECT}_$v is left over from an earlier drill (--keep or a crash). Check it, then remove it:
  docker compose --profile drill rm -sf drill-source drill-listener
  docker volume rm ${PROJECT}_drill-source-data ${PROJECT}_drill-socket ${PROJECT}_drill-restore-data"
    fi
done

RUN_ID="$(date -u +%Y%m%dT%H%M%SZ)"
OUT="reports/drill-$RUN_ID"
# Values for docker compose: its interpolation reads the shell environment before
# .env, so the drill's stanza, path and passphrase win over the real ones. The
# passphrase is random for each run and only passed through the environment.
export DRILL_REPO_PATH="/drill/$RUN_ID"
DRILL_CIPHER_PASS="$(head -c 48 /dev/urandom | base64 | tr -d '\n')"
export DRILL_CIPHER_PASS
export PGBACKREST_CIPHER_PASS="$DRILL_CIPHER_PASS" # restore service
export PGBACKREST_STANZA=drill PGBACKREST_REPO1_PATH="$DRILL_REPO_PATH"
export RESTORE_DATA_VOLUME=drill-restore-data

mkdir -p reports "$OUT"
# The restore container runs as uid 999 and writes its reports here (as start.sh does).
chmod 1777 reports 2>/dev/null || true
chmod 1777 "$OUT"
RESULTS="$OUT/results.tsv"
: >"$RESULTS"

dc() { docker compose --profile drill "$@"; }
sql() { dc exec -T -u postgres drill-source psql -X -v ON_ERROR_STOP=1 -Atq -d "${DB:-appdb}" "$@"; }
br() { dc exec -T -u postgres drill-source pgbackrest --stanza=drill "$@"; }

cleanup() {
    local rc=$?
    if [ "$keep" = 1 ]; then
        log "--keep: left the drill containers and volumes. Remove them with:"
        echo "  docker compose --profile drill rm -sf drill-source drill-listener"
        echo "  docker volume rm ${PROJECT}_drill-source-data ${PROJECT}_drill-socket ${PROJECT}_drill-restore-data"
    else
        # Only what this run created: the drill's own containers and volumes.
        dc rm -sf drill-source drill-listener >/dev/null 2>&1 || true
        docker volume rm -f "${PROJECT}_drill-source-data" "${PROJECT}_drill-socket" "${PROJECT}_drill-restore-data" >/dev/null 2>&1 || true
    fi
    exit "$rc"
}
trap cleanup EXIT

log "run $RUN_ID: scenarios ${selected[*]}; stanza drill at $DRILL_REPO_PATH; reports in $OUT/"

# ── 1. throwaway source ─────────────────────────────────
if [ "$build" = 1 ]; then
    log "building images (cached after the first time)"
    dc --profile restore build drill-source restore backup >"$OUT/build.log" 2>&1 ||
        die "image build failed, see $OUT/build.log"
fi
dc up -d drill-source drill-listener >"$OUT/up.log" 2>&1 || die "could not start the drill containers, see $OUT/up.log"
SRC_CID="$(dc ps -q drill-source)"
for _ in $(seq 1 90); do
    if dc logs drill-source 2>/dev/null | grep -q 'PostgreSQL init process complete' &&
        dc exec -T drill-source pg_isready -q >/dev/null 2>&1; then
        ready=1
        break
    fi
    sleep 1
done
[ "${ready:-0}" = 1 ] || die "drill-source did not become ready: $(dc logs --tail 5 drill-source 2>&1 | tr '\n' ' ')"
br stanza-create >"$OUT/stanza-create.log" 2>&1 || die "stanza-create failed: $(grep -m1 ERROR "$OUT/stanza-create.log")"
log "drill-source is up, stanza created"

# ── 2. seed ─────────────────────────────────────────────
DB=postgres sql -c 'CREATE DATABASE appdb' -c 'CREATE DATABASE reportsdb'
DB=reportsdb sql -c 'CREATE TABLE monthly_totals AS SELECT g AS month, g * 1000 AS total FROM generate_series(1, 12) AS g'
sql <drill/seed.sql
dc exec -T -u postgres drill-source pgbench -i -q -s "$SCALE" appdb >"$OUT/pgbench-init.log" 2>&1
# A large pgbench -i writes gigabytes of WAL in under a minute (about 8 GB at scale 680), but
# archive_command pushes one segment at a time. Without this wait, `check` (60 s archive
# timeout) queues behind the backlog and fails with [082]. Wait for the archive to catch up.
segment_no() { echo $(((16#${1:8:8}) * 256 + 16#${1:16:8})); } # 16 MB segments: 256 per log file
wait_archive_drained() {
    local target archived failed failed0 start=$SECONDS next_report=0
    DB=postgres sql -c 'SELECT pg_switch_wal()' >/dev/null
    target="$(DB=postgres sql -c 'SELECT pg_walfile_name(pg_current_wal_lsn() - 1)')"
    failed0="$(DB=postgres sql -c 'SELECT failed_count FROM pg_stat_archiver')"
    while :; do
        IFS='|' read -r archived failed < <(DB=postgres sql -c "SELECT coalesce(last_archived_wal, '-'), failed_count FROM pg_stat_archiver")
        if [[ "$archived" == "$target" || "$archived" > "$target" ]]; then
            log "WAL archive caught up to $target after $((SECONDS - start))s"
            return 0
        fi
        [ $((failed - failed0)) -lt 5 ] || die "archiving is failing ($((failed - failed0)) failures since the seed), see the drill-source log"
        [ $((SECONDS - start)) -lt "$DRILL_ARCHIVE_DRAIN_TIMEOUT" ] ||
            die "WAL archive did not catch up within ${DRILL_ARCHIVE_DRAIN_TIMEOUT}s (last archived: $archived, target: $target)"
        if [ "$SECONDS" -ge "$next_report" ]; then
            if [ "$archived" = - ]; then
                log "waiting for the WAL archive: nothing archived yet, target $target"
            else
                log "waiting for the WAL archive: $(($(segment_no "$target") - $(segment_no "$archived"))) segments behind (at $archived)"
            fi
            next_report=$((SECONDS + 30))
        fi
        sleep 5
    done
}
wait_archive_drained
# The canary: one committed row a second until the source dies.
dc exec -d -u postgres drill-source psql -X -d appdb -c \
    'DO $$ BEGIN LOOP INSERT INTO canary DEFAULT VALUES; COMMIT; PERFORM pg_sleep(1); END LOOP; END $$'
br check >"$OUT/check.log" 2>&1 || die "pgbackrest check failed: $(grep -m1 ERROR "$OUT/check.log")"
log "seeded appdb (pgbench scale $SCALE, 1000 orders, canary every second) and reportsdb; WAL reaches the repository"

# ── 3. backups ──────────────────────────────────────────
backup() { # backup <full|diff>: run it, print the seconds it took
    local t0 t1
    t0="$(now)"
    br --type="$1" backup >"$OUT/backup-$1.log" 2>&1 || die "$1 backup failed: $(grep -m1 ERROR "$OUT/backup-$1.log")"
    t1="$(now)"
    elapsed "$t0" "$t1"
}
full_s="$(backup full)"
log "full backup took ${full_s}s"
dc exec -T -u postgres drill-source pgbench -n -c 2 -T "$PGBENCH_SECONDS" appdb >"$OUT/pgbench-run.log" 2>&1
sql -c "INSERT INTO orders (customer, amount) SELECT 'customer-' || g, 9.99 FROM generate_series(1001, 1500) AS g"
wait_archive_drained # the pgbench run above writes WAL faster than it is archived; a backup waits only 60 s for its last segment
diff_s="$(backup diff)"
log "pgbench ran ${PGBENCH_SECONDS}s, 500 more orders; differential backup took ${diff_s}s"
br --output=json info >"$OUT/info.json"
full_label="$(jq -r '.[0].backup | map(select(.type == "full")) | .[-1].label' "$OUT/info.json")"
diff_label="$(jq -r '.[0].backup | map(select(.type == "diff")) | .[-1].label' "$OUT/info.json")"
[[ "$full_label" =~ F$ && "$diff_label" =~ D$ ]] || die "could not read the backup labels from pgbackrest info"

# ── 4. failure scenario: a broken job must fail loudly ──
record_failure() { # record_failure <check> <PASS|FAIL> <detail>
    printf '%s\t%s\t%s\n' "$1" "$2" "$3" >>"$OUT/failure.tsv"
    printf '  [%s] %s: %s\n' "$2" "$1" "$3"
}
job() { # job <tag> [docker run options]: run-job.sh check against the drill stanza, print its exit code
    local tag="$1" rc=0
    shift
    PGBACKREST_REPO1_CIPHER_PASS="$DRILL_CIPHER_PASS" docker run --rm --network "${PROJECT}_default" \
        --volumes-from "$SRC_CID" \
        -e PGBACKREST_STANZA=drill -e PGBACKREST_REPO1_PATH -e PGBACKREST_REPO1_CIPHER_PASS \
        -e PGBACKREST_PG1_PATH=/var/lib/postgresql/data -e CRON_FILE=/dev/null \
        -e ALERT_WEBHOOK_URL="http://drill-listener:8080/alert/$tag" \
        -e HEALTHCHECK_URL_CHECK="http://drill-listener:8080/ping/$tag" \
        "$@" --entrypoint /usr/local/bin/run-job.sh "${PROJECT}-backup" check check \
        >"$OUT/failure-$tag.log" 2>&1 || rc=$?
    echo "$rc"
}
heard() { dc logs --no-log-prefix drill-listener 2>/dev/null | grep -c -- "$1" || true; }
keys=()
[ -f configs/s3-keys.env ] && keys=(--env-file configs/s3-keys.env)

failure_scenario() {
    local rc
    : >"$OUT/failure.tsv"
    log "failure: run the check job with broken S3 credentials"
    rc="$(job creds -e PGBACKREST_REPO1_S3_KEY_TYPE=shared -e PGBACKREST_REPO1_S3_KEY="$FAKE_KEY_ID" \
        -e PGBACKREST_REPO1_S3_KEY_SECRET=drill-wrong-secret)"
    if [ "$rc" -ne 0 ]; then record_failure creds_job_failed PASS "run-job.sh exited $rc"; else record_failure creds_job_failed FAIL "run-job.sh exited 0 with fake keys"; fi
    if [ "$(heard 'POST /alert/creds .*FAILED')" -ge 1 ]; then record_failure creds_alert_sent PASS "webhook got the FAILED message"; else record_failure creds_alert_sent FAIL "no webhook call arrived"; fi
    if [ "$(heard 'GET /ping/creds/fail')" -ge 1 ]; then record_failure creds_fail_ping PASS "dead-man's switch got /fail"; else record_failure creds_fail_ping FAIL "no /fail ping arrived"; fi

    log "failure: stop archiving (pgbackrest stop on the source), then run the check job"
    br stop >>"$OUT/failure-archive.log" 2>&1
    rc="$(job archive "${keys[@]}" -e PGBACKREST_ARCHIVE_TIMEOUT=15)"
    br start >>"$OUT/failure-archive.log" 2>&1
    if [ "$rc" -ne 0 ]; then record_failure archive_job_failed PASS "run-job.sh exited $rc: $(grep -m1 -o 'ERROR: \[[0-9]*\][^.]*' "$OUT/failure-archive.log" | head -c 160)"; else record_failure archive_job_failed FAIL "run-job.sh exited 0 while archiving was stopped"; fi
    if [ "$(heard 'POST /alert/archive .*FAILED')" -ge 1 ]; then record_failure archive_alert_sent PASS "webhook got the FAILED message"; else record_failure archive_alert_sent FAIL "no webhook call arrived"; fi
    if [ "$(heard 'GET /ping/archive/fail')" -ge 1 ]; then record_failure archive_fail_ping PASS "dead-man's switch got /fail"; else record_failure archive_fail_ping FAIL "no /fail ping arrived"; fi

    log "failure: archiving back on, the same job must pass and ping"
    rc="$(job recovered "${keys[@]}")"
    if [ "$rc" -eq 0 ]; then record_failure recovered_job_ok PASS "run-job.sh exited 0"; else record_failure recovered_job_ok FAIL "run-job.sh exited $rc after archiving was restarted"; fi
    if [ "$(heard 'GET /ping/recovered$')" -ge 1 ]; then
        record_failure recovered_ping PASS "dead-man's switch got the success ping"
    else
        record_failure recovered_ping FAIL "no success ping arrived"
    fi
    if [ "$(heard 'alert/recovered')" -eq 0 ]; then record_failure recovered_no_alert PASS "no alert for a passing job"; else record_failure recovered_no_alert FAIL "an alert was sent for a passing job"; fi

    local result=PASS
    grep -q $'\tFAIL\t' "$OUT/failure.tsv" && result=FAIL
    jq -R -s --arg run_id "$RUN_ID" --arg result "$result" \
        '{run_id: $run_id, scenario: "failure", result: $result,
          checks: (split("\n") | map(select(length > 0) | split("\t") | {name: .[0], status: .[1], detail: .[2]}))}' \
        "$OUT/failure.tsv" >"$OUT/${RUN_ID}-failure.json"
    jq -r '"# Drill scenario: failure\n\n**Result: \(.result)**  (run `\(.run_id)`)\n\n"
        + "A check job (backup/run-job.sh) with broken S3 credentials, then with archiving stopped, then healthy again.\n\n"
        + "| Check | Result | Detail |\n|---|---|---|\n"
        + ([.checks[] | "| \(.name) | \(.status) | \(.detail | gsub("\\|"; "/")) |"] | join("\n")) + "\n"' \
        "$OUT/${RUN_ID}-failure.json" >"$OUT/${RUN_ID}-failure.md"
    printf '%s\t%s\n' failure "$result" >>"$RESULTS"
}
want failure && failure_scenario

# ── 5. the mistakes ─────────────────────────────────────
n_named="$(sql -c 'SELECT count(*) FROM orders')"
sql -c "SELECT pg_create_restore_point('drill_pre_migration')" >/dev/null
sql -c 'BEGIN' -c 'UPDATE orders SET amount = 0' -c 'DELETE FROM orders WHERE id % 3 = 0' \
    -c "INSERT INTO schema_migrations (version) VALUES ('2026_11_bad_migration')" -c 'COMMIT'
log "restore point drill_pre_migration at $n_named orders, then a bad migration"
sql -c "INSERT INTO orders (customer, amount) SELECT 'customer-' || g, 19.99 FROM generate_series(1501, 1700) AS g"
n_pitr="$(sql -c 'SELECT count(*) FROM orders')"
pitr_target="$(sql -c "SELECT to_char(clock_timestamp() AT TIME ZONE 'UTC', 'YYYY-MM-DD HH24:MI:SS.US') || '+00'")"
sleep 2
sql -c 'DELETE FROM orders'
log "target time $pitr_target at $n_pitr orders, then DELETE FROM orders"
sleep 1
sql -c "INSERT INTO orders (customer, amount) SELECT 'customer-' || g, 29.99 FROM generate_series(1701, 1750) AS g"
orders_path="$(sql -c "SELECT pg_relation_filepath('orders')")"

# Wait until the WAL with everything above is in the repository, so the latest
# restore can only lose canary rows written after this point.
mark_wal="$(sql -c 'SELECT pg_walfile_name(pg_current_wal_lsn())')"
mark_canary="$(sql -c 'SELECT count(*) FROM canary')"
for _ in $(seq 1 $((DRILL_ARCHIVE_TIMEOUT * 6 + 30))); do
    archived="$(sql -c 'SELECT coalesce(last_archived_wal, $$$$) FROM pg_stat_archiver')"
    [[ "$archived" > "$mark_wal" || "$archived" == "$mark_wal" ]] && break
    sleep 1
done
[[ "$archived" > "$mark_wal" || "$archived" == "$mark_wal" ]] || die "WAL $mark_wal was not archived in time (last archived: $archived)"
counts="$(sql -F $'\t' -c 'SELECT (SELECT count(*) FROM orders), (SELECT count(*) FROM schema_migrations),
    (SELECT count(*) FROM pgbench_history), (SELECT count(*) FROM pgbench_accounts)')"
IFS=$'\t' read -r n_final n_migrations n_history n_accounts <<<"$counts"
sleep 5 # the crash comes a few seconds after the last archived segment, as it would
kill_epoch="$(date +%s)"
docker kill "$SRC_CID" >/dev/null
log "docker kill drill-source at $(date -u -d "@$kill_epoch" +%T) ($n_final orders, $mark_canary+ canary rows)"

# ── 6. expectations ─────────────────────────────────────
expect() { # expect <scenario> <jq program>
    jq -n --argjson final "$n_final" --argjson migrations "$n_migrations" --argjson history "$n_history" \
        --argjson accounts "$n_accounts" --argjson canary "$mark_canary" --argjson kill "$kill_epoch" \
        --argjson rpo_max "$RPO_MAX" --argjson named "$n_named" --argjson pitr "$n_pitr" "$2" >"$OUT/expect-$1.json"
}
latest_expect='{database: "appdb",
    counts: {"public.orders": $final, "public.schema_migrations": $migrations,
             "public.pgbench_history": $history, "public.pgbench_accounts": $accounts},
    min_counts: {"public.canary": $canary},
    canary: {table: "public.canary", column: "ts"}, kill_epoch: $kill, rpo_max_seconds: $rpo_max}'
expect latest "$latest_expect"
expect single-db "$latest_expect"
expect delta "$latest_expect"
expect pitr '{database: "appdb", counts: {"public.orders": $pitr, "public.schema_migrations": 1}}'
expect named-point '{database: "appdb", counts: {"public.orders": $named, "public.schema_migrations": 0}}'
expect older-set '{database: "appdb", counts: {"public.orders": 1000, "public.schema_migrations": 0,
    "public.pgbench_history": 0, "public.pgbench_accounts": $accounts}}'

# ── 7. restores ─────────────────────────────────────────
restore_run() { # restore_run <scenario> [RESTORE_*=value ...]
    local name="$1" rc
    shift
    log "restore: $name"
    set +e
    env RESTORE_TYPE= RESTORE_TARGET= RESTORE_SET= RESTORE_DB_INCLUDE= RESTORE_DELTA=0 RESTORE_KEEP=0 RESTORE_VERIFY=0 "$@" \
        docker compose run --rm -T -e RUN_ID="$RUN_ID" -e RESTORE_SCENARIO="$name" \
        -e EXPECT_FILE="/$OUT/expect-$name.json" -e REPORT_DIR="/$OUT" -e PGBACKREST_REPO1_PATH \
        restore 2>&1 | tee "$OUT/restore-$name.log" | grep --line-buffered -E '^  \[(PASS|FAIL)\]|^ERROR'
    rc="${PIPESTATUS[0]}"
    set -e
    if [ "$rc" -eq 0 ]; then printf '%s\tPASS\n' "$name" >>"$RESULTS"; else printf '%s\tFAIL\n' "$name" >>"$RESULTS"; fi
}

want pitr && restore_run pitr RESTORE_TYPE=time RESTORE_TARGET="$pitr_target"
want named-point && restore_run named-point RESTORE_TYPE=name RESTORE_TARGET=drill_pre_migration
want older-set && restore_run older-set RESTORE_SET="$full_label" RESTORE_TYPE=immediate
want single-db && restore_run single-db RESTORE_DB_INCLUDE=appdb
if want latest; then
    if want delta; then
        restore_run latest RESTORE_VERIFY=1 RESTORE_KEEP=1
        # Damage the kept copy: remove the orders table's file, then repair it with a delta restore.
        [[ "$orders_path" =~ ^base/[0-9]+/[0-9]+$ ]] || die "unexpected orders file path '$orders_path'"
        docker run --rm -v "${PROJECT}_drill-restore-data:/d" --entrypoint rm "${PROJECT}-restore" -f "/d/$orders_path"
        log "removed $orders_path (the orders table) from the restored copy"
        restore_run delta RESTORE_DELTA=1
    else
        restore_run latest RESTORE_VERIFY=1
    fi
fi

# ── 8. summary ──────────────────────────────────────────
shopt -s nullglob
reports=("$OUT/${RUN_ID}"-*.json)
jq -s --arg run_id "$RUN_ID" --argjson order "$(printf '%s\n' "${ALL[@]}" | jq -R . | jq -s .)" --arg stanza_path "$DRILL_REPO_PATH" --slurpfile info "$OUT/info.json" \
    --argjson full_s "$full_s" --argjson diff_s "$diff_s" --argjson scale "$SCALE" \
    --argjson archive_timeout "$DRILL_ARCHIVE_TIMEOUT" --arg pitr_target "$pitr_target" \
    '{run_id: $run_id, repository_path: $stanza_path, pgbench_scale: $scale, archive_timeout_seconds: $archive_timeout,
      pitr_target: $pitr_target,
      result: (if all(.[]; .result == "PASS") then "PASS" else "FAIL" end),
      backups: [$info[0][0].backup[] | {label, type, size_bytes: .info.size, repo_size_bytes: .info.repository.size,
                seconds: (.timestamp.stop - .timestamp.start)}],
      backup_wall_seconds: {full: $full_s, diff: $diff_s},
      scenarios: (sort_by(.scenario as $s | $order | index($s)) | map({scenario, result, restore_seconds: .timings_seconds.restore, wal_replay_seconds: .timings_seconds.wal_replay,
                      total_seconds: .timings_seconds.total, rpo_seconds, backup: .backup.label,
                      failed_checks: [.checks[] | select(.status == "FAIL") | .name]}))}' \
    "${reports[@]}" </dev/null >"$OUT/summary.json"
jq -r '
    def secs: if . == null then "" else "\(.)s" end;
    def mb: if . == null then "n/a" else "\((. / 1048576 * 10 | round) / 10) MB" end;
    "# Restore drill \(.run_id): \(.result)\n\n"
    + "Throwaway stanza `drill` at `\(.repository_path)`, pgbench scale \(.pgbench_scale), archive_timeout \(.archive_timeout_seconds)s.\n\n"
    + "| Backup | Type | Database | In repository | Took |\n|---|---|---|---|---|\n"
    + ([.backups[] | "| `\(.label)` | \(.type) | \(.size_bytes | mb) | \(.repo_size_bytes | mb) | \(.seconds)s |"] | join("\n"))
    + "\n\n| Scenario | Result | Restore | WAL replay | Total | RPO | Failed checks |\n|---|---|---|---|---|---|---|\n"
    + ([.scenarios[] | "| \(.scenario) | \(.result) | \(.restore_seconds | secs) | \(.wal_replay_seconds | secs) | \(.total_seconds | secs) | \(.rpo_seconds | secs) | \(.failed_checks | join(", ")) |"] | join("\n"))
    + "\n"' "$OUT/summary.json" >"$OUT/summary.md"
if [ -f "$OUT/${RUN_ID}-failure.md" ]; then
    { sed -n '/^| Check/,$p' "$OUT/${RUN_ID}-failure.md" | sed '1s/^| Check/| Failure check/'; } >>"$OUT/summary.md"
fi
for s in "${selected[@]}"; do
    [ "$s" = verify ] && s=latest
    grep -q "^$s"$'\t' "$RESULTS" || printf '%s\tFAIL\n' "$s" >>"$RESULTS" # selected but never reported
done

echo
cat "$OUT/summary.md"
echo "Reports: $OUT/ (summary.md, one JSON + Markdown report per scenario, logs)"
echo "Drill objects stay under s3://<bucket>$DRILL_REPO_PATH and expire through the drill/ lifecycle rule."
if grep -q $'\tFAIL' "$RESULTS"; then
    log "FAILED: $(grep $'\tFAIL' "$RESULTS" | cut -f1 | sort -u | tr '\n' ' ')"
    exit 1
fi
log "all selected scenarios passed"
