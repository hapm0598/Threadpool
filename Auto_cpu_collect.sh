#!/bin/bash
set -euo pipefail

#
# Auto CPU Monitor (FINAL + AUTO-CORE-DETECT)
# Mirrors Auto_resp_collect.sh logic exactly, but monitors CPU instead of response time.
#

script_name=${0##*/}
# Detect instance name (App Service instance ID)
instancehome=$(hostname)

# WORKDIR unique for this instance
WORKDIR="/home/Troubleshooting/${instancehome}"

COLLECTOR="$WORKDIR/collector_core.sh"
mkdir -p "$WORKDIR"

############################################
# FUNCTIONS (same as Auto_resp)
############################################

function usage() {
  echo "###Syntax: $script_name -p <percent_total> -f <freq>"
  echo "-p <percent_total>  CPU percent of TOTAL container CPU (default 80)"
  echo "-f <frequency>      polling interval seconds (default 10)"
}

function die() {
  echo "$1" && exit "${2:-1}"
}

function teardown() {
  echo "Shutting down 'dotnet-trace collect' process..."
  kill -SIGTERM $(ps -ef \
        | grep "/tools/dotnet-trace" \
        | grep -v grep \
        | tr -s " " \
        | cut -d" " -f2 \
        | xargs) 2>/dev/null || true

  echo "Shutting down 'dotnet-dump collect' process..."
  kill -SIGTERM $(ps -ef \
        | grep "/tools/dotnet-dump" \
        | grep -v grep \
        | tr -s " " \
        | cut -d" " -f2 \
        | xargs) 2>/dev/null || true

  echo "Shutting down 'azcopy copy' process..."
  kill -SIGTERM $(ps -ef \
        | grep "/tools/azcopy" \
        | grep -v grep \
        | tr -s " " \
        | cut -d" " -f2 \
        | xargs) 2>/dev/null || true

  echo "Shutting down $script_name process..."
  kill -SIGTERM $(ps -ef \
        | grep "$script_name" \
        | grep -v grep \
        | tr -s " " \
        | cut -d" " -f2 \
        | xargs) 2>/dev/null || true

  echo "Finishing up..."
  echo "Completed"
  exit 0
}

# PID detection identical to Auto_resp_collect.sh (PROVEN CORRECT)
function get_pid() {
  /tools/dotnet-dump ps \
    | grep "/usr/share/dotnet/dotnet" \
    | grep -v grep \
    | tr -s " " \
    | cut -d" " -f2 \
    | head -n 1
}

############################################
# ARGUMENT-PARSING (ORDER-INDEPENDENT)
############################################

ARGS=("$@")
percent_total=""
frequency=""

OPTIND=1
while getopts ":p:f:h" opt "${ARGS[@]}"; do
  case $opt in
    p) percent_total=$OPTARG ;;    # percent of TOTAL CPU (80 means 80% of all cores)
    f) frequency=$OPTARG ;;
    h) usage; exit 0 ;;
    *) echo "Invalid option: -$OPTARG"; exit 1 ;;
  esac
done

percent_total=${percent_total:-80}  # default 80%
frequency=${frequency:-10}         # default 10 seconds

############################################
# AUTO-DETECT CORES + COMPUTE ACTUAL THRESHOLD
############################################

cores=$(nproc)   # true core count in App Service container
cpu_threshold=$(( cores * percent_total ))

echo "###Info: Detected $cores cores → CPU threshold = ${cpu_threshold}% (=${percent_total}% total load)"

############################################
# LOG DIR + CLEANUP
############################################

instancehome=$(hostname)
output_dir="$WORKDIR/cpustats"
mkdir -p "$output_dir"

find "$output_dir" -type f -name "cpu_stats_*.log" -mtime +2 -delete 2>/dev/null || true

############################################
# START MONITOR LOOP
############################################

echo "###Info: Starting CPU monitoring every ${frequency}s"

previous_hour=""

while true; do

  current_hour=$(date +"%Y-%m-%d_%H")
  if [[ "$current_hour" != "$previous_hour" ]]; then
    output_file="$output_dir/cpu_stats_${current_hour}.log"
    previous_hour="$current_hour"

    find "$output_dir" -type f -name "cpu_stats_*.log" -mtime +2 -delete 2>/dev/null || true
  fi

  pid=$(get_pid)
  if [[ -z "$pid" ]]; then
    echo "$(date '+%Y-%m-%d %H:%M:%S'): No .NET PID found" >> "$output_file"
    sleep "$frequency"
    continue
  fi

  CPU_RAW=$(ps -p "$pid" -o %cpu --no-headers 2>/dev/null || echo "0")
  CPU=${CPU_RAW%.*}

  echo "$(date '+%Y-%m-%d %H:%M:%S'): CPU=${CPU}% (raw=${CPU_RAW}%) PID=$pid" >> "$output_file"

  ############################################
  # TRIGGER
  ############################################
  if (( CPU >= cpu_threshold )); then
    if [[ ! -e "$WORKDIR/auto_trigger.lock" ]]; then
      echo "[auto-cpu] CPU threshold exceeded (${CPU}% >= ${cpu_threshold}%) → Triggering collector_core.sh" \
        | tee -a "$output_file"

      touch "$WORKDIR/auto_trigger.lock"
      nohup bash "$COLLECTOR" --auto > "$WORKDIR/auto_trigger.log" 2>&1 &
      exit 0
    fi
  fi

  sleep "$frequency"
done
