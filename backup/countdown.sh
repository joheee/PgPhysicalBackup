#!/bin/bash
# countdown.sh --live        one self-redrawing line in your terminal (Ctrl-C to quit).
#                            Nothing is logged or stored. Use it with:
#                              docker exec -it pg-cron-backup countdown.sh --live
# countdown.sh <seconds>     append a [countdown] line to docker logs every <seconds>
#                            seconds (stored in the container log; filter with
#                            grep -v '\[countdown\]').
# The schedule is read once (and again after a job time passes), so each tick
# is plain arithmetic.
set -uo pipefail

arg="${1:?usage: countdown.sh --live | <seconds>}"
live=0
interval="$arg"
if [ "$arg" = "--live" ]; then
    live=1
    interval=1
fi
sched=()
loaded=0
now=0

load() {
    mapfile -t sched < <(/usr/local/bin/status.sh --epochs)
    loaded="$now"
}

fmt() { # fmt <seconds> -> HH:MM:SS (hours keep counting past 24)
    local s="$1"
    printf '%02d:%02d:%02d' $((s / 3600)) $(((s % 3600) / 60)) $((s % 60))
}

short() {
    case "$1" in
        "Differential backup") echo "Diff" ;;
        "Health check") echo "Check" ;;
        "Full backup") echo "Full" ;;
        *) echo "$1" ;;
    esac
}

if [ "$live" -eq 1 ]; then
    trap 'printf "\n"; exit 0' INT TERM
    cols="$(tput cols 2>/dev/null || echo 80)"
fi

printf -v now '%(%s)T' -1
load
while sleep "$interval"; do
    printf -v now '%(%s)T' -1
    # Reload once a job time has passed, and hourly in case the schedule changed.
    if [ "${#sched[@]}" -eq 0 ] || [ "$now" -ge "${sched[0]%%|*}" ] || [ $((now - loaded)) -ge 3600 ]; then
        load
    fi
    line=""
    for entry in "${sched[@]}"; do
        left=$((${entry%%|*} - now))
        [ "$left" -lt 0 ] && left=0
        if [ "$live" -eq 1 ]; then
            line+="${line:+ | }$(short "${entry#*|}") [$(fmt "$left")]"
        else
            line+="${line:+ | }${entry#*|} [$(fmt "$left")]"
        fi
    done
    if [ "$live" -eq 1 ]; then
        # Redraw in place: back to column 0, print, erase the rest of the line.
        # Cut to the terminal width so it can never wrap onto a second line.
        printf '\r%s\033[K' "${line:0:cols-1}"
        continue
    fi
    # The container runs in UTC, so a literal Z is correct.
    printf '%(%FT%TZ)T %s\n' -1 "$line"
done
