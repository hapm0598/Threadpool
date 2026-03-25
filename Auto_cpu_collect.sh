#!/bin/bash
set -euo pipefail

#
# Auto CPU Monitor (FINAL + AUTO-CORE-DETECT)
# Mirrors Auto_resp_collect.sh logic exactly, but monitors CPU instead of response time.
#

script_name=${0##*/}

##########################################
# PID DETECTION (OLD WORKING PIPELINE)
##########################################
tools/dotnet-dump ps \
| grep /usr/share/dotnet/dotnet \
| grep -v grep \
| tr -s " " \
| cut -d" " -f2

if [[ -z "${pid:-}" ]]; then
    echo "[error] Could not find any running .NET process"
    exit 1
fi

##########################################
# READ ENV VARS FROM PID
##########################################
get_env_from_pid() {
    local pid="$1" key="$2"
    local val
    val=$(tr '\0' '\n' < "/proc/$pid/environ" \
          | grep -w "$key" || true)
    val=${val#*=}
    echo "${val:-}"
}
instancehome=$(get_env_from_pid "$pid" "COMPUTERNAME")

# WORKDIR unique for this instance
WORKDIR="/home/Troubleshooting/${instancehome}"
COLLECTOR="$WORKDIR/collector_core.sh"
TRIGGER_LOCK="$WORKDIR/auto_trigger_cpu.lock"
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

percent_total=""
frequency=""
enable_dump=false
max_days=""
max_seconds=""
trigger_window_seconds=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    -p)
      [[ $# -ge 2 ]] || die "Missing value for -p" 1
      percent_total="$2"
      shift 2
      ;;
    -f)
      [[ $# -ge 2 ]] || die "Missing value for -f" 1
      frequency="$2"
      shift 2
      ;;
    --enable-dump)
      enable_dump=true
      shift
      ;;
    --max-days)
      [[ $# -ge 2 ]] || die "Missing value for --max-days" 1
      max_days="$2"
      shift 2
      ;;
    --max-days=*)
      max_days="${1#*=}"
      shift
      ;;
    -d)
      [[ $# -ge 2 ]] || die "Missing value for -d" 1
      max_days="$2"
      shift 2
      ;;
    --trigger-window-seconds)
      [[ $# -ge 2 ]] || die "Missing value for --trigger-window-seconds" 1
      trigger_window_seconds="$2"
      shift 2
      ;;
    --trigger-window-seconds=*)
      trigger_window_seconds="${1#*=}"
      shift
      ;;
    -w)
      [[ $# -ge 2 ]] || die "Missing value for -w" 1
      trigger_window_seconds="$2"
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      die "Invalid option: $1" 1
      ;;
  esac
done

percent_total=${percent_total:-80}  # default 80%
frequency=${frequency:-10}         # default 10 seconds

[[ "$percent_total" =~ ^[0-9]+$ ]] || die "Invalid CPU threshold percent: $percent_total" 1
[[ "$frequency" =~ ^[0-9]+$ ]] || die "Invalid frequency: $frequency" 1

max_days=${max_days:-0}
[[ "$max_days" =~ ^[0-9]+$ ]] || die "Invalid max_days: $max_days" 1
if (( max_days > 0 )); then
  max_seconds=$((max_days * 24 * 3600))
else
  max_seconds=""
fi

trigger_window_seconds=${trigger_window_seconds:-30}
[[ "$trigger_window_seconds" =~ ^[0-9]+$ ]] || die "Invalid trigger_window_seconds: $trigger_window_seconds" 1
(( trigger_window_seconds > 0 )) || die "trigger_window_seconds must be > 0" 1

############################################
# AUTO-DETECT CORES + COMPUTE ACTUAL THRESHOLD
############################################

cores=$(nproc)   # true core count in App Service container
cpu_threshold=$(( cores * percent_total ))

echo "###Info: Detected $cores cores → CPU threshold = ${cpu_threshold}% (=${percent_total}% total load)"

############################################
# LOG DIR + CLEANUP
############################################

output_dir="$WORKDIR/cpustats"
mkdir -p "$output_dir"

find "$output_dir" -type f -name "cpu_stats_*.log" -mtime +2 -delete 2>/dev/null || true

############################################
# START MONITOR LOOP
############################################

echo "###Info: Starting CPU monitoring every ${frequency}s"
echo "###Info: Trigger window=${trigger_window_seconds}s consecutive above threshold"

previous_hour=""
output_file=""
start_ts=$(date +%s)
breach_start_ts=""

while true; do

  current_hour=$(date +"%Y-%m-%d_%H")
  if [[ "$current_hour" != "$previous_hour" ]]; then
    output_file="$output_dir/cpu_stats_${current_hour}.log"
    previous_hour="$current_hour"

    find "$output_dir" -type f -name "cpu_stats_*.log" -mtime +2 -delete 2>/dev/null || true
  fi

  if [[ -n "$max_seconds" ]]; then
    now_ts=$(date +%s)
    if (( now_ts - start_ts >= max_seconds )); then
      echo "[auto-cpu] monitor stopped by max-days policy, lock preserved (max_days=${max_days})." >> "${output_file:-/dev/null}"
      exit 0
    fi
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
  now_ts=$(date +%s)
  if (( CPU >= cpu_threshold )); then
    if [[ -z "$breach_start_ts" ]]; then
      breach_start_ts=$now_ts
    fi
    breach_duration=$(( now_ts - breach_start_ts ))

    if (( breach_duration < trigger_window_seconds )); then
      echo "$(date '+%Y-%m-%d %H:%M:%S'): Above threshold but waiting window (${breach_duration}/${trigger_window_seconds}s)" >> "$output_file"
    fi

    if (( breach_duration < trigger_window_seconds )); then
      sleep "$frequency"
      continue
    fi

    if [[ ! -e "$TRIGGER_LOCK" ]]; then
      echo "[auto-cpu] CPU threshold exceeded (${CPU}% >= ${cpu_threshold}%), triggered after ${breach_duration}s consecutive breach → Triggering collector_core.sh" \
        | tee -a "$output_file"

      touch "$TRIGGER_LOCK"
    
        if [[ "$enable_dump" == true ]]; then
            nohup bash "$COLLECTOR" --auto --enable-dump > "$WORKDIR/auto_cpu_trigger.log" 2>&1 &
        else
            nohup bash "$COLLECTOR" --auto > "$WORKDIR/auto_cpu_trigger.log" 2>&1 &
        fi

        exit 0
    fi
  else
    breach_start_ts=""
fi

  sleep "$frequency"
done