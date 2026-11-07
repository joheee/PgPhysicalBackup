# shellcheck shell=bash
# Globals (timings, backup details, scenario) are set by entrypoint.sh, which sources this file.
# shellcheck disable=SC2154
# Sourced by entrypoint.sh. Each check is recorded as PASS or FAIL in $CHECKS_FILE.

record() { # record <name> <PASS|FAIL> <detail>
    local detail="${3//$'\t'/ }"
    detail="${detail//$'\n'/ }"
    printf '%s\t%s\t%s\n' "$1" "$2" "$detail" >>"$CHECKS_FILE"
    printf '  [%s] %s: %s\n' "$2" "$1" "$detail"
}

q() { psql -Atqc "$1" 2>&1; }

ident_re='^[A-Za-z_][A-Za-z0-9_]*$'
table_re='^[A-Za-z_][A-Za-z0-9_]*(\.[A-Za-z_][A-Za-z0-9_]*)?$'

run_checks() {
    local v
    check_recovery_target
    v="$(q 'select pg_is_in_recovery()')"
    if [ "$v" = f ]; then record recovery_finished PASS "pg_is_in_recovery() = false"; else record recovery_finished FAIL "pg_is_in_recovery() = $v"; fi

    v="$(q 'show archive_mode')"
    if [ "$v" = off ]; then record archive_mode_off PASS "archive_mode = off, the copy cannot write to the stanza"; else record archive_mode_off FAIL "archive_mode = $v"; fi

    v="$(q 'show data_checksums')"
    if [ "$v" = on ]; then record data_checksums_on PASS "data_checksums = on"; else record data_checksums_on FAIL "data_checksums = $v"; fi

    v="$(q 'select count(*) from pg_database where datallowconn')"
    if [[ "$v" =~ ^[0-9]+$ ]]; then record queryable PASS "$v connectable databases, $(q 'select split_part(version(), $$ on $$, 1)')"; else record queryable FAIL "$v"; fi

    local amcheck_args=(--all)
    [ -n "$DB_INCLUDE" ] && amcheck_args=(--database="$DB_INCLUDE")
    if v="$(pg_amcheck --install-missing "${amcheck_args[@]}" 2>&1)"; then
        record amcheck PASS "pg_amcheck ${amcheck_args[*]}: no corruption reported"
    else
        record amcheck FAIL "$(head -c 400 <<<"$v")"
    fi

    if [ "$VERIFY" = 1 ]; then
        if v="$(pgbackrest --stanza="$STANZA" verify 2>&1)"; then
            record repo_verify PASS "pgbackrest verify: repository checks passed"
        else
            record repo_verify FAIL "$(tail -n 3 <<<"$v" | head -c 400)"
        fi
    fi

    [ -n "$EXPECT_FILE" ] && run_expectations
}

# For a targeted restore, Postgres logs where it stopped. Show it, and fail if it
# never stopped at the target (which would mean the whole archive was replayed).
check_recovery_target() {
    [ -n "$TYPE" ] || return 0
    local line
    line="$(grep -m1 'recovery stopping' /tmp/postgres.log 2>/dev/null | sed 's/^.*LOG:  //')"
    if [ -n "$line" ]; then
        record recovery_target_reached PASS "$line"
    else
        record recovery_target_reached FAIL "no 'recovery stopping' line in the Postgres log for target $TYPE${TARGET:+=$TARGET}"
    fi
}

# EXPECT_FILE is JSON, written by whatever knows the source state (the drill):
#   { "database": "postgres",
#     "counts":     { "public.orders": 1000 },        exact row counts
#     "min_counts": { "public.canary": 50 },          at least this many rows
#     "canary": { "table": "public.canary", "column": "ts" },
#     "kill_epoch": 1793000000,                       when the source died (unix time)
#     "rpo_max_seconds": 120 }
# RPO = kill_epoch - the newest canary timestamp found in the restored copy.
run_expectations() {
    if [ ! -r "$EXPECT_FILE" ] || ! jq -e . "$EXPECT_FILE" >/dev/null 2>&1; then
        record expectations FAIL "cannot read EXPECT_FILE=$EXPECT_FILE as JSON"
        return
    fi
    local db table want got key kind
    db="$(jq -r '.database // "postgres"' "$EXPECT_FILE")"
    [[ "$db" =~ $ident_re ]] || { record expectations FAIL "bad database name '$db'"; return; }

    for kind in counts min_counts; do
        while IFS=$'\t' read -r table want; do
            [ -n "$table" ] || continue
            key="${kind}:${table}"
            if ! [[ "$table" =~ $table_re ]] || ! [[ "$want" =~ ^[0-9]+$ ]]; then
                record "$key" FAIL "invalid table name or number in EXPECT_FILE"
                continue
            fi
            got="$(psql -d "$db" -Atqc "select count(*) from $table" 2>&1)"
            if ! [[ "$got" =~ ^[0-9]+$ ]]; then
                record "$key" FAIL "$got"
            elif [ "$kind" = counts ] && [ "$got" -eq "$want" ]; then
                record "$key" PASS "$got rows, as recorded on the source"
            elif [ "$kind" = min_counts ] && [ "$got" -ge "$want" ]; then
                record "$key" PASS "$got rows (at least $want)"
            else
                record "$key" FAIL "$got rows, expected $([ "$kind" = counts ] && echo "$want" || echo "at least $want")"
            fi
        done < <(jq -r --arg k "$kind" '.[$k] // {} | to_entries[] | [.key, (.value | tostring)] | @tsv' "$EXPECT_FILE")
    done

    local kill ctable ccol newest max
    kill="$(jq -r '.kill_epoch // empty' "$EXPECT_FILE")"
    if [ -n "$kill" ]; then
        ctable="$(jq -r '.canary.table // "public.canary"' "$EXPECT_FILE")"
        ccol="$(jq -r '.canary.column // "ts"' "$EXPECT_FILE")"
        if ! [[ "$ctable" =~ $table_re && "$ccol" =~ $ident_re && "$kill" =~ ^[0-9]+$ ]]; then
            record rpo FAIL "invalid canary settings in EXPECT_FILE"
            return
        fi
        newest="$(psql -d "$db" -Atqc "select extract(epoch from max($ccol))::bigint from $ctable" 2>&1)"
        if ! [[ "$newest" =~ ^[0-9]+$ ]]; then
            record rpo FAIL "no canary rows found: $newest"
            return
        fi
        RPO_SECONDS=$((kill - newest))
        export RPO_SECONDS
        max="$(jq -r '.rpo_max_seconds // empty' "$EXPECT_FILE")"
        if [ -n "$max" ] && [ "$RPO_SECONDS" -gt "$max" ]; then
            record rpo FAIL "RPO ${RPO_SECONDS}s is over the limit of ${max}s"
        else
            record rpo PASS "RPO ${RPO_SECONDS}s (newest restored canary row to source failure)"
        fi
    fi
}
