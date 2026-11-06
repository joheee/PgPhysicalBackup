#!/bin/bash
# status.sh [--short|--epochs]: when does each scheduled job run next?
# Reads the schedule from /etc/cron.d/pgbackrest (UTC). Run it any time:
#   docker exec pg-cron-backup status.sh
set -euo pipefail

CRON_FILE="${CRON_FILE:-/etc/cron.d/pgbackrest}"
MODE="${1:-table}"

# One awk pass: for every job line, scan forward minute by minute to the next
# match, then print "<epoch>|<job>|<countdown>|<time>". Supports *, lists,
# ranges and /step in all five fields.
rows="$(gawk -v now="$(date +%s)" '
function match_field(f, v, lo, hi,    n, parts, i, rng, st, a, b, from, to) {
    n = split(f, parts, ",")
    for (i = 1; i <= n; i++) {
        st = 1; rng = parts[i]
        if (index(rng, "/")) { split(rng, a, "/"); rng = a[1]; st = a[2] + 0 }
        if (rng == "*") { from = lo; to = hi }
        else if (index(rng, "-")) { split(rng, b, "-"); from = b[1] + 0; to = b[2] + 0 }
        else { from = rng + 0; to = (st > 1 ? hi : from) }
        if (v >= from && v <= to && (v - from) % st == 0) return 1
    }
    return 0
}
function countdown(s) {
    return sprintf("%02d:%02d:%02d", int(s / 3600), int((s % 3600) / 60), s % 60)
}
/^[[:space:]]*(#|$)/ { next }
{
    t = now - (now % 60) + 60
    for (i = 0; i < 60 * 24 * 366; i++) {
        split(strftime("%M %H %d %m %w", t, 1), p, " ")
        w = p[5] + 0
        dom_ok = match_field($3, p[3] + 0, 1, 31)
        dow_ok = match_field($5, w, 0, 7) || (w == 0 && match_field($5, 7, 0, 7))
        if ($3 != "*" && $5 != "*") day_ok = dom_ok || dow_ok
        else day_ok = dom_ok && dow_ok
        if (match_field($1, p[1] + 0, 0, 59) && match_field($2, p[2] + 0, 0, 23) && \
            match_field($4, p[4] + 0, 1, 12) && day_ok) {
            printf "%d|%s|%s|%s\n", t, $8, countdown(t - now), strftime("%a %Y-%m-%d %H:%M UTC", t, 1)
            break
        }
        t += 60
    }
}' "$CRON_FILE" | sort -n)"

label() {
    case "$1" in
        full) echo "Full backup" ;;
        diff) echo "Differential backup" ;;
        check) echo "Health check" ;;
        *) echo "$1" ;;
    esac
}

if [ "$MODE" = "--epochs" ]; then
    # "<unix time>|<label>", soonest first (used by countdown.sh)
    while IFS='|' read -r epoch job _ _; do
        echo "${epoch}|$(label "$job")"
    done <<<"$rows"
    exit 0
fi

if [ "$MODE" = "--short" ]; then
    out=""
    while IFS='|' read -r _ job in_ _; do
        out+="${out:+ | }$(label "$job") [${in_}]"
    done <<<"$rows"
    echo "next: ${out}"
    exit 0
fi

echo "Next scheduled jobs (now: $(date -u '+%a %Y-%m-%d %H:%M UTC')):"
while IFS='|' read -r _ job in_ at; do
    printf '  %-20s [%s]  %s\n' "$(label "$job")" "$in_" "$at"
done <<<"$rows"
