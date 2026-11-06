# shellcheck shell=bash
# Globals (timings, backup details, scenario) are set by entrypoint.sh, which sources this file.
# shellcheck disable=SC2154
# Sourced by entrypoint.sh. write_report prints a Markdown summary and, when
# $REPORT_DIR is writable, saves <run-id>-<scenario>.json and .md there.
# It reads the globals set by entrypoint.sh (timings, backup details, checks).

num() { if [ -n "${1:-}" ]; then echo "$1"; else echo null; fi; }

write_report() {
    local overall=PASS cpus mem_mb pg_ver br_ver bucket repo_path finished json md base
    grep -q $'\tFAIL\t' "$CHECKS_FILE" && overall=FAIL
    finished="$(date -u +%FT%TZ)"
    cpus="$(nproc)"
    mem_mb="$(awk '/MemTotal/ { print int($2 / 1024) }' /proc/meminfo)"
    pg_ver="$(postgres --version | awk '{ print $3 }')"
    br_ver="$(pgbackrest version | awk '{ print $2 }')"
    bucket="$(sed -n 's/^repo1-s3-bucket=//p' /etc/pgbackrest/pgbackrest.conf 2>/dev/null | head -n 1)"
    repo_path="${PGBACKREST_REPO1_PATH:-$(sed -n 's/^repo1-path=//p' /etc/pgbackrest/pgbackrest.conf 2>/dev/null | head -n 1)}"

    json="$(jq -n \
        --arg run_id "$RUN_ID" --arg scenario "$SCENARIO" --arg result "$overall" \
        --arg started_at "$started_at" --arg finished_at "$finished" \
        --arg stanza "$STANZA" --arg bucket "$bucket" --arg repo_path "$repo_path" \
        --arg blabel "$backup_label" --arg btype "$backup_type" \
        --arg type "$TYPE" --arg target "$TARGET" --arg set "$SET" --arg db "$DB_INCLUDE" \
        --argjson delta "$DELTA" --argjson procs "${PGBACKREST_PROCESS_MAX:-1}" \
        --argjson bsize "$(num "$backup_size")" --argjson brepo "$(num "$backup_repo_size")" \
        --argjson restore_s "$(num "$restore_s")" --argjson replay_s "$(num "$replay_s")" \
        --argjson total_s "$(num "$total_s")" --argjson rpo_s "$(num "${RPO_SECONDS:-}")" \
        --arg pg "$pg_ver" --arg br "$br_ver" --argjson cpus "$cpus" --argjson mem "$mem_mb" \
        --slurpfile checks <(jq -R -s 'split("\n") | map(select(length > 0) | split("\t") | {name: .[0], status: .[1], detail: .[2]})' "$CHECKS_FILE") \
        '{run_id: $run_id, scenario: $scenario, result: $result,
          started_at: $started_at, finished_at: $finished_at,
          repository: {stanza: $stanza, bucket: $bucket, path: $repo_path},
          request: {type: $type, target: $target, set: $set, db_include: $db, delta: ($delta == 1), process_max: $procs},
          backup: {"label": $blabel, type: $btype, size_bytes: $bsize, repo_size_bytes: $brepo},
          timings_seconds: {restore: $restore_s, wal_replay: $replay_s, total: $total_s},
          rpo_seconds: $rpo_s,
          versions: {postgres: $pg, pgbackrest: $br},
          machine: {cpus: $cpus, memory_mb: $mem},
          checks: $checks[0]}')"

    if [ -z "$json" ]; then
        echo "ERROR: could not build the JSON report" >&2
        return 1
    fi

    md="$(jq -r '
        def secs: if . == null then "n/a" else "\(.)s" end;
        def mb: if . == null then "n/a" else "\((. / 1048576 * 10 | round) / 10) MB" end;
        "# Restore report: \(.scenario)\n\n"
        + "**Result: \(.result)**  (run `\(.run_id)`)\n\n"
        + "| | |\n|---|---|\n"
        + "| Backup restored | `\(.backup.label)` (\(.backup.type)), \(.backup.size_bytes | mb) database, \(.backup.repo_size_bytes | mb) in the repository |\n"
        + "| Restore time | \(.timings_seconds.restore | secs) (\(.request.process_max) parallel workers) |\n"
        + "| WAL replay time | \(.timings_seconds.wal_replay | secs) (Postgres start until recovery finished) |\n"
        + "| Total | \(.timings_seconds.total | secs) |\n"
        + "| RPO | \(.rpo_seconds | secs) |\n"
        + "| Repository | `\(.repository.bucket)` `\(.repository.path)` stanza `\(.repository.stanza)` |\n"
        + "| Versions | PostgreSQL \(.versions.postgres), pgBackRest \(.versions.pgbackrest) |\n"
        + "| Machine | \(.machine.cpus) CPUs, \(.machine.memory_mb) MB RAM |\n"
        + "| Started / finished | \(.started_at) / \(.finished_at) |\n\n"
        + "| Check | Result | Detail |\n|---|---|---|\n"
        + ([.checks[] | "| \(.name) | \(.status) | \(.detail | gsub("\\|"; "/")) |"] | join("\n"))
        + "\n"' <<<"$json")"

    if [ -z "$md" ]; then
        echo "ERROR: could not build the Markdown report" >&2
        return 1
    fi

    echo
    echo "$md"
    base="$REPORT_DIR/${RUN_ID}-${SCENARIO}"
    if [ -d "$REPORT_DIR" ] && [ -w "$REPORT_DIR" ]; then
        echo "$json" >"$base.json"
        echo "$md" >"$base.md"
        echo "Report saved: ${base}.json and .md"
    else
        echo "NOTE: $REPORT_DIR is not writable, so no report files were saved (the report above is complete)."
    fi
}
