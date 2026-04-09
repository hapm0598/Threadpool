#!/bin/bash
set -euo pipefail

#
# Auto Memory Monitor (FINAL)
# Monitor TOTAL container memory (MemTotal/MemAvailable) and trigger collector_core.sh
# Trigger when: percent_used_real >= threshold_percent
#

script_name=${0##*/}

##########################################
# GET INSTANCE FROM COMPUTERNAME
##########################################
get_instance_name() {
    local dotnet_pid
    dotnet_pid=$(/tools/dotnet-dump ps | awk '$0 ~ /\/usr\/share\/dotnet\/dotnet/ {print $1; exit}' || true)
    [[ -n "$dotnet_pid" ]] || return 1
    tr '\0' '\n' < "/proc/$dotnet_pid/environ" | awk -F'=' '$1=="COMPUTERNAME"{print $2; exit}'
}

instancehome="$(get_instance_name || true)"
if [[ -z "$instancehome" ]]; then
    echo "[error] Could not find COMPUTERNAME from running .NET process"
    exit 1
fi

# WORKDIR unique for this instance
WORKDIR="/home/Troubleshooting/${instancehome}"
COLLECTOR="$WORKDIR/collector_core.sh"
TRIGGER_LOCK="$WORKDIR/auto_trigger_mem.lock"
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
  kill -SIGTERM $(ps -ef | grep "/tools/dotnet-gcdump" | grep -v grep | awk '{print $2}' | xargs) 2>/dev/null || true
  kill -SIGTERM $(ps -ef | grep "/tools/azcopy" | grep -v grep | awk '{print $2}' | xargs) 2>/dev/null || true
  kill -SIGTERM $(ps -ef | grep "$script_name" | grep -v grep | awk '{print $2}' | xargs) 2>/dev/null || true

  echo "Completed"
  exit 0
}

############################################
# ARGUMENT-PARSING (order-independent)
############################################

threshold_percent=""
frequency=""
enable_dump=false
dump_type=""
max_days=""
max_seconds=""
trigger_window_seconds=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    -t)
      [[ $# -ge 2 ]] || die "Missing value for -t" 1
      threshold_percent="$2"
      shift 2
      ;;
    -f)
      [[ $# -ge 2 ]] || die "Missing value for -f" 1
      frequency="$2"
      shift 2
      ;;
    --enable-fulldump)
      enable_dump=true
      dump_type="full"
      shift
      ;;
    --enable-gcdump)
      enable_dump=true
      dump_type="gc"
      shift
      ;;
    --enable-dump)
      # Backward compatibility
      enable_dump=true
      dump_type="full"
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

threshold_percent=${threshold_percent:-80}   # default 80%
frequency=${frequency:-10}

[[ "$threshold_percent" =~ ^[0-9]+$ ]] || die "Invalid memory threshold percent: $threshold_percent" 1
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
# LOG DIRECTORY + CLEANUP
############################################

output_dir="$WORKDIR/memstats"
mkdir -p "$output_dir"

# Cleanup >2 days
find "$output_dir" -type f -name "mem_stats_*.log" -mtime +2 -delete 2>/dev/null || true

############################################
# START MONITOR
############################################

echo "###Info: Starting Memory Monitor: trigger when REAL usage >= ${threshold_percent}%"
echo "###Info: Polling every ${frequency}s"
echo "###Info: Trigger window=${trigger_window_seconds}s consecutive above threshold"

previous_hour=""
output_file=""
start_ts=$(date +%s)
breach_start_ts=""

while true; do

  # LOG ROTATION
  current_hour=$(date +"%Y-%m-%d_%H")
  if [[ "$current_hour" != "$previous_hour" ]]; then
      output_file="$output_dir/mem_stats_${current_hour}.log"
      previous_hour="$current_hour"

      find "$output_dir" -type f -name "mem_stats_*.log" -mtime +2 -delete 2>/dev/null || true
  fi

  if [[ -n "$max_seconds" ]]; then
    now_ts=$(date +%s)
    if (( now_ts - start_ts >= max_seconds )); then
      echo "[auto-mem] monitor stopped by max-days policy, lock preserved (max_days=${max_days})." >> "${output_file:-/dev/null}"
      exit 0
    fi
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
  now_ts=$(date +%s)
  if (( used_real_percent >= threshold_percent )); then
      if [[ -z "$breach_start_ts" ]]; then
          breach_start_ts=$now_ts
      fi
      breach_duration=$(( now_ts - breach_start_ts ))

      if (( breach_duration < trigger_window_seconds )); then
          echo "$(date '+%Y-%m-%d %H:%M:%S'): Above threshold but waiting window (${breach_duration}/${trigger_window_seconds}s)" >> "$output_file"
          sleep "$frequency"
          continue
      fi

      if [[ ! -e "$TRIGGER_LOCK" ]]; then
          echo "[auto-mem] Memory threshold exceeded, triggered after ${breach_duration}s consecutive breach → Triggering collector_core.sh" | tee -a "$output_file"
          touch "$TRIGGER_LOCK"
        if [[ "$enable_dump" == true ]]; then
            if [[ "$dump_type" == "gc" ]]; then
                echo "[auto-mem] Triggering with GC dump collection" | tee -a "$output_file"
                nohup bash "$COLLECTOR" --auto --enable-gcdump > "$WORKDIR/auto_mem_trigger.log" 2>&1 &
            else
                echo "[auto-mem] Triggering with full memory dump collection" | tee -a "$output_file"
                nohup bash "$COLLECTOR" --auto --enable-fulldump > "$WORKDIR/auto_mem_trigger.log" 2>&1 &
            fi
        else
            nohup bash "$COLLECTOR" --auto > "$WORKDIR/auto_mem_trigger.log" 2>&1 &
        fi

        exit 0
    fi
  else
    breach_start_ts=""
fi

  sleep "$frequency"
done