#!/bin/bash
set -euo pipefail

# ============================================================
# Auto TCP Outbound Connection Monitor
# ============================================================

script_name=${0##*/}
instancehome=$(hostname)
WORKDIR="/home/Troubleshooting/${instancehome}"
COLLECTOR="$WORKDIR/collector_core.sh"
TRIGGER_LOCK="$WORKDIR/auto_trigger_tcp.lock"
mkdir -p "$WORKDIR"

tcp_threshold=""
frequency=""

OPTIND=1
while getopts ":t:f:h" opt; do
  case $opt in
    t) tcp_threshold=$OPTARG ;;
    f) frequency=$OPTARG ;;
    h) echo "Usage: $script_name -t <threshold> -f <frequency>"; exit 0 ;;
    *) echo "Invalid option: -$OPTARG"; exit 1 ;;
  esac
done
shift $((OPTIND - 1))

enable_dump=false
for arg in "$@"; do
  case "$arg" in
    --enable-dump) enable_dump=true ;;
    *) echo "Invalid option: $arg"; exit 1 ;;
  esac
done

tcp_threshold=${tcp_threshold:-200}
frequency=${frequency:-10}

[[ "$tcp_threshold" =~ ^[0-9]+$ ]] || { echo "Invalid threshold: $tcp_threshold"; exit 1; }
[[ "$frequency" =~ ^[0-9]+$ ]] || { echo "Invalid frequency: $frequency"; exit 1; }

output_dir="$WORKDIR/tcpstats"
mkdir -p "$output_dir"
find "$output_dir" -type f -name "tcp_stats_*.log" -mtime +2 -delete 2>/dev/null || true

echo "###Info: Starting TCP monitor: threshold=${tcp_threshold}, frequency=${frequency}s"

previous_hour=""
while true; do
  current_hour=$(date +"%Y-%m-%d_%H")
  if [[ "$current_hour" != "$previous_hour" ]]; then
    output_file="$output_dir/tcp_stats_${current_hour}.log"
    previous_hour="$current_hour"
    find "$output_dir" -type f -name "tcp_stats_*.log" -mtime +2 -delete 2>/dev/null || true
  fi

  conn_count=$(ss -tan state established | grep -v LISTEN | wc -l)
  echo "$(date '+%Y-%m-%d %H:%M:%S'): TCP_Connections=$conn_count" >> "$output_file"

  if (( conn_count >= tcp_threshold )); then
    if [[ ! -e "$TRIGGER_LOCK" ]]; then
      echo "[auto-tcp] Connection threshold exceeded -> Triggering collector_core.sh" | tee -a "$output_file"
      touch "$TRIGGER_LOCK"

      if [[ "$enable_dump" == true ]]; then
        nohup bash "$COLLECTOR" --auto --enable-dump > "$WORKDIR/auto_tcp_trigger.log" 2>&1 &
      else
        nohup bash "$COLLECTOR" --auto > "$WORKDIR/auto_tcp_trigger.log" 2>&1 &
      fi

      exit 0
    fi
  fi

  sleep "$frequency"
done
