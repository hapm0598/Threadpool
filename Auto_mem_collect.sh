#!/bin/bash
set -euo pipefail

#
# Auto Memory Monitor (FINAL)
# Monitor TOTAL container memory (MemTotal/MemAvailable) and trigger collector_core.sh
# Trigger when: percent_used_real >= threshold_percent
#

script_name=${0##*/}

# Detect instance name (App Service instance ID)
instance=$(hostname)

# WORKDIR unique for this instance
WORKDIR="/home/${instance}-Troubleshooting

COLLECTOR="$WORKDIR/collector_core.sh"
mkdir -p "$WORKDIR"

############################################
# FUNCTIONS — same teardown style
############################################

function usage() {
  echo "###Syntax: $script_name -t <threshold_percent> -f <frequency>"
  echo "-t <threshold_percent>   memory usage percent (real usage) default=80"
  echo "-f <frequency>           seconds between checks   default=10"
}

function die() {
  echo "$1" && exit "${2:-1}"
}

function teardown() {
  echo "Shutting down related processes..."

  kill -SIGTERM $(ps -ef | grep "/tools/dotnet-trace" | grep -v grep | awk '{print $2}' | xargs) 2>/dev/null || true
  kill -SIGTERM $(ps -ef | grep "/tools/dotnet-dump" | grep -v grep | awk '{print $2}' | xargs) 2>/dev/null || true
  kill -SIGTERM $(ps -ef | grep "/tools/azcopy" | grep -v grep | awk '{print $2}' | xargs) 2>/dev/null || true
  kill -SIGTERM $(ps -ef | grep "$script_name" | grep -v grep | awk '{print $2}' | xargs) 2>/dev/null || true

  echo "Completed"
  exit 0
}

############################################
# ARGUMENT-PARSING (order-independent)
############################################

ARGS=("$@")
threshold_percent=""
frequency=""

OPTIND=1
while getopts ":t:f:h" opt "${ARGS[@]}"; do
  case $opt in
    t) threshold_percent=$OPTARG ;;
    f) frequency=$OPTARG ;;
    h) usage; exit 0 ;;
    *) echo "Invalid option: -$OPTARG"; exit 1 ;;
  esac
done

threshold_percent=${threshold_percent:-80}   # default 80%
frequency=${frequency:-10}

############################################
# LOG DIRECTORY + CLEANUP
############################################

instance=$(hostname)
output_dir="$WORKDIR/memstats"
mkdir -p "$output_dir"

# Cleanup >2 days
find "$output_dir" -type f -name "mem_stats_*.log" -mtime +2 -delete 2>/dev/null || true

############################################
# START MONITOR
############################################

echo "###Info: Starting Memory Monitor: trigger when REAL usage >= ${threshold_percent}%"
echo "###Info: Polling every ${frequency}s"

previous_hour=""

while true; do

  # LOG ROTATION
  current_hour=$(date +"%Y-%m-%d_%H")
  if [[ "$current_hour" != "$previous_hour" ]]; then
      output_file="$output_dir/mem_stats_${current_hour}.log"
      previous_hour="$current_hour"

      find "$output_dir" -type f -name "mem_stats_*.log" -mtime +2 -delete 2>/dev/null || true
  fi

  ############################################
  # GET TOTAL + AVAILABLE MEMORY (kB)
  ############################################

  total_kb=$(grep MemTotal /proc/meminfo | awk '{print $2}')
  avail_kb=$(grep MemAvailable /proc/meminfo | awk '{print $2}')

  total_mb=$(( total_kb / 1024 ))
  avail_mb=$(( avail_kb / 1024 ))

  # REAL USED MEMORY
  used_real_percent=$(( ( (total_kb - avail_kb) * 100 ) / total_kb ))

  echo "$(date '+%Y-%m-%d %H:%M:%S'): MemTotal=${total_mb}MB  MemAvail=${avail_mb}MB  UsedReal=${used_real_percent}%" \
       >> "$output_file"

  ############################################
  # TRIGGER COLLECTOR WHEN REAL USAGE HIGH
  ############################################
  if (( used_real_percent >= threshold_percent )); then
      if [[ ! -e "$WORKDIR/auto_trigger.lock" ]]; then
          echo "[auto-mem] Memory threshold exceeded → Triggering collector_core.sh" | tee -a "$output_file"
          touch "$WORKDIR/auto_trigger.lock"
          nohup bash "$COLLECTOR" --auto > "$WORKDIR/auto_trigger.log" 2>&1 &
          exit 0
      fi
  fi

  sleep "$frequency"
done