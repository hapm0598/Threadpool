#!/bin/bash
set -euo pipefail

WORKDIR="/home/Threadpool"
COLLECTOR="$WORKDIR/collector_core.sh"
mkdir -p "$WORKDIR"

############################################
# ARGS
############################################
LOCATION="http://localhost:80"
THRESHOLD=1000
FREQ=10

while getopts ":l:t:f:" opt; do
    case $opt in
        l) LOCATION=$OPTARG ;;
        t) THRESHOLD=$OPTARG ;;
        f) FREQ=$OPTARG ;;
    esac
done

############################################
# ONE-TIME TRIGGER LOCK
############################################
if [[ -e "$WORKDIR/auto_trigger.lock" ]]; then
    echo "[auto] Already triggered once. Exiting."
    exit 0
fi

############################################
# MONITOR LOOP
############################################
echo "[auto] Monitoring $LOCATION every ${FREQ}s, threshold=${THRESHOLD}ms"

prev_hour=""
while true; do
    hour=$(date '+%Y-%m-%d_%H')
    if [[ "$hour" != "$prev_hour" ]]; then
        LOG="$WORKDIR/resptime_${hour}.log"
        prev_hour="$hour"
    fi

    read -r resp sec <<< $(curl -so /dev/null -w "%{time_total} %{http_code}" "$LOCATION" || echo "5 000")

    ms=$(echo "$resp*1000/1" | bc)
    echo "$(date '+%Y-%m-%d %H:%M:%S'): $ms ms ($sec)" >> "$LOG"

    if (( ms >= THRESHOLD )); then
        echo "[auto] Threshold exceeded → Trigger collector"
        touch "$WORKDIR/auto_trigger.lock"
        nohup bash "$COLLECTOR" --auto > "$WORKDIR/auto_trigger.log" 2>&1 &
        exit 0
    fi

    sleep "$FREQ"
done