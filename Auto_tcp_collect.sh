#!/bin/bash
set -euo pipefail

# ============================================================
# Auto TCP Outbound Connection Monitor (FINAL, CLEAN, INTEGRATED)
# Same engine style as Auto_resp_collect / Auto_cpu_collect / Auto_mem_collect
# Monitors outbound TCP connections and triggers collector_core.sh when threshold exceeded
# ============================================================

script_name=${0##*/}
# Detect instance name (App Service instance ID)
instancehome=$(hostname)

# WORKDIR unique for this instance
WORKDIR="/home/Troubleshooting/${instancehome}"

COLLECTOR="$WORKDIR/collector_core.sh"
mkdir -p "$WORKDIR"


# ------------------------------------------------------------
# ARGUMENT PARSER
# ------------------------------------------------------------
ARGS=("$@")
tcp_threshold=""
frequency=""

while getopts ":t:f:h" opt "${ARGS[@]}"; do
  case $opt in
    t) tcp_threshold=$OPTARG ;;
    f) frequency=$OPTARG ;;
    h) echo "Usage: $script_name -t <threshold> -f <frequency>"; exit 0 ;;
    *) echo "Invalid option: -$OPTARG"; exit 1 ;;
  esac
done
shift $(( OPTIND - 1 ))
# ------------------------------------------------------------
# PARSE POSITIONAL FLAGS (for --enable-dump)
# ------------------------------------------------------------
enable_dump=false

for arg in "${ARGS[@]}"; do
  case "$arg" in
    --enable-dump)
        enable_dump=true
        ;;
  esac
done


tcp_threshold=${tcp_threshold:-200}   # default: 200 outbound connections
frequency=${frequency:-10}

# ------------------------------------------------------------
# LOG DIRECTORY
# ------------------------------------------------------------
output_dir="$WORKDIR/tcpstats"
mkdir -p "$output_dir"

# Cleanup logs older than 2 days
find "$output_dir" -type f -name "tcp_stats_*.log" -mtime +2 -delete 2>/dev/null || true

echo "###Info: Starting TCP monitor: threshold=${tcp_threshold}, frequency=${frequency}s"

previous_hour=""

# ------------------------------------------------------------
# MONITOR LOOP
# ------------------------------------------------------------
while true; do

    # Rotate hourly log
    current_hour=$(date +"%Y-%m-%d_%H")
    if [[ "$current_hour" != "$previous_hour" ]]; then
        output_file="$output_dir/tcp_stats_${current_hour}.log"
        previous_hour="$current_hour"

        find "$output_dir" -type f -name "tcp_stats_*.log" -mtime +2 -delete 2>/dev/null || true
    fi

    # --------------------------------------------------------
    # Count outbound ESTABLISHED connections
    # --------------------------------------------------------
    conn_count=$(ss -tan state established | grep -v LISTEN | wc -l)

    echo "$(date '+%Y-%m-%d %H:%M:%S'): TCP_Connections=$conn_count" >> "$output_file"

    # --------------------------------------------------------
    # Trigger Collector if threshold exceeded
    # --------------------------------------------------------
if (( conn_count >= tcp_threshold )); then
    if [[ ! -e "$WORKDIR/auto_trigger.lock" ]]; then
        echo "[auto-tcp] Connection threshold exceeded → Triggering collector_core.sh" | tee -a "$output_file"
        touch "$WORKDIR/auto_trigger.lock"

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
