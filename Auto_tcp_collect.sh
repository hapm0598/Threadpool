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
enable_dump=false

while [[ $# -gt 0 ]]; do
  case "$1" in
    -t)
      [[ $# -ge 2 ]] || { echo "Missing value for -t"; exit 1; }
      tcp_threshold="$2"
      shift 2
      ;;
    -f)
      [[ $# -ge 2 ]] || { echo "Missing value for -f"; exit 1; }
      frequency="$2"
      shift 2
      ;;
    --enable-dump)
      enable_dump=true
      shift
      ;;
    -h|--help)
      echo "Usage: $script_name -t <threshold> -f <frequency> [--enable-dump]"
      exit 0
      ;;
    *)
      echo "Invalid option: $1"
      exit 1
      ;;
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

ensure_netstat() {
  if command -v netstat >/dev/null 2>&1; then
    return 0
  fi

  if ! command -v apt-get >/dev/null 2>&1; then
    echo "###Warning: netstat missing and apt-get unavailable. Continue with other fallback methods."
    return 0
  fi

  echo "###Info: netstat is not installed. Installing net-tools."
  if apt-get update && apt-get install -y net-tools; then
    echo "###Info: net-tools installed successfully."
  else
    echo "###Warning: Failed to install net-tools. Continue with other fallback methods."
  fi
}

count_established_tcp_connections() {
  if command -v ss >/dev/null 2>&1; then
    ss -tan state established 2>/dev/null | grep -v "LISTEN" | wc -l
    return
  fi

  if command -v netstat >/dev/null 2>&1; then
    netstat -tan 2>/dev/null | grep "ESTABLISHED" | wc -l
    return
  fi

  # Last-resort fallback: parse kernel tcp tables directly (state 01 = ESTABLISHED)
  awk 'NR>1 && $4=="01" {c++} END {print c+0}' /proc/net/tcp /proc/net/tcp6 2>/dev/null
}

ensure_netstat

previous_hour=""
while true; do
  current_hour=$(date +"%Y-%m-%d_%H")
  if [[ "$current_hour" != "$previous_hour" ]]; then
    output_file="$output_dir/tcp_stats_${current_hour}.log"
    previous_hour="$current_hour"
    find "$output_dir" -type f -name "tcp_stats_*.log" -mtime +2 -delete 2>/dev/null || true
  fi

  conn_count=$(count_established_tcp_connections)
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
