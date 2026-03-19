#!/bin/bash
set -euo pipefail

#
# Auto Response Time Monitor (FINAL)
# Based 100% on old logic, with new trigger to collector_core.sh
#

script_name=${0##*/}

WORKDIR="/home/Threadpool"
COLLECTOR="$WORKDIR/collector_core.sh"
mkdir -p "$WORKDIR"

############################################
# FUNCTIONS FROM OLD SCRIPT
############################################

function usage()
{
  echo "###Syntax: $script_name -t <threshold> -l <URL> -f <interval>"
  echo "-l <URL> monitor URL (default http://localhost:80)"
  echo "-f <interval> polling frequency in seconds (default 10)"
  echo "-t <threshold> in ms (default 1000)"
}

function die()
{
  echo "$1" && exit $2
}

function teardown()
{
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

function getsasurl()
{
  sas_url=$(cat "/proc/$1/environ" | tr '\0' '\n' | grep -w DIAGNOSTICS_AZUREBLOBCONTAINERSASURL)
  sas_url=${sas_url#*=}
  echo "$sas_url"
}

function getcomputername()
{
  instance=$(cat "/proc/$1/environ" | tr '\0' '\n' | grep -w COMPUTERNAME)
  instance=${instance#*=}
  echo "$instance"
}

# URL external check
function is_external_url() {
  local url="$1"
  if [[ "$url" =~ ^https?:// ]] && [[ ! "$url" =~ localhost ]] && [[ ! "$url" =~ 127\.0\.0\.1 ]]; then
    return 0
  else
    return 1
  fi
}

############################################
# ARGUMENT-PARSING (ORDER-INDEPENDENT)
############################################

ARGS=("$@")

threshold=""
location=""
frequency=""
clean_flag=0

# Parse OPTIONS (-t, -f, -l, -c, -h)
OPTIND=1
while getopts ":t:l:f:hc" opt "${ARGS[@]}"; do
  case $opt in
    t) threshold=$OPTARG ;;
    l) location=$OPTARG ;;
    f) frequency=$OPTARG ;;
    h) usage; exit 0 ;;
    c) clean_flag=1 ;;
    *) echo "Invalid option: -$OPTARG"; exit 1 ;;
  esac
done

# Parse POSITIONAL PARAMS (enable-dump-trace)
enable_dump=false
enable_trace=false

for arg in "${ARGS[@]}"; do
  case "$arg" in
    enable-dump)
      enable_dump=true
      ;;
    enable-trace)
      enable_trace=true
      ;;
    enable-dump-trace)
      enable_dump=true
      enable_trace=true
      ;;
  esac
done

############################################
# INSTALL curl & bc (old logic)
############################################

if ! command -v curl >/dev/null; then
  echo "###Info: curl not installed, installing..."
  apt-get update && apt-get install -y curl
fi

if ! command -v bc >/dev/null; then
  echo "###Info: bc not installed, installing..."
  apt-get update && apt-get install -y bc
fi

############################################
# DETECT IF EXTERNAL URL
############################################
is_external=$(is_external_url "$location"; echo $?)

############################################
# FIND PID ONLY IF LOCAL MODE OR NEED TRACE/DUMP
############################################
pid=""

if [[ $is_external -eq 1 || "$enable_dump" == true || "$enable_trace" == true ]]; then

  pid=$(/tools/dotnet-dump ps \
        | grep /usr/share/dotnet/dotnet \
        | grep -v grep \
        | tr -s " " \
        | cut -d" " -f2)

  if [[ -z "$pid" ]]; then
    if [[ "$enable_dump" == true || "$enable_trace" == true ]]; then
      die "There is no .NET process running, cannot collect dumps/traces" 1
    else
      echo "###Warning: No .NET process found, but continuing external URL monitoring"
      pid=""
    fi
  fi

  if [[ -n "$pid" ]]; then
    instance=$(getcomputername "$pid")
    if [[ -z "$instance" ]]; then
      echo "###Warning: COMPUTERNAME missing, using hostname"
      instance=$(hostname)
    fi
  else
    instance=$(hostname)
  fi
else
  instance=$(hostname)
  pid=""
fi

############################################
# PREP LOG DIR
############################################
output_dir="$WORKDIR/resptime-logs-$instance"
mkdir -p "$output_dir"

dump_lock_file="dump_taken_${instance}.lock"
trace_lock_file="trace_taken_${instance}.lock"

timeout_seconds=$(( (threshold + 5000) / 1000 ))

url="${location#*://}"
host_and_port="${url%%/*}"

############################################
# START MONITORING LOOP
############################################
echo "###Info: Starting monitoring of $location with threshold ${threshold}ms every ${frequency}s"

previous_hour=""

while true; do

  current_hour=$(date +"%Y-%m-%d_%H")
  if [[ "$current_hour" != "$previous_hour" ]]; then
    output_file="$output_dir/resptime_stats_${current_hour}.log"
    previous_hour="$current_hour"
  fi

  # Request handling identical to old logic
  if [[ $is_external -eq 0 ]]; then
    read -r respTimeInSeconds httpCode <<< $(curl -so /dev/null -w "%{time_total} %{http_code}" -m $timeout_seconds "$location")
  elif [[ "$location" == "http://localhost"* ]]; then
    read -r respTimeInSeconds httpCode <<< $(curl -so /dev/null -w "%{time_total} %{http_code}" -m $timeout_seconds "$location" --resolve "$host_and_port":127.0.0.1)
  elif [[ "$host_and_port" == "www.unlimitedvacationclub.com"* ]]; then
    read -r respTimeInSeconds httpCode <<< $(curl -so /dev/null -w "%{time_total} %{http_code}" -m $timeout_seconds -H "Host:$host_and_port" "http://localhost")
  else
    read -r respTimeInSeconds httpCode <<< $(curl -so /dev/null -w "%{time_total} %{http_code}" -m $timeout_seconds -H "Host:$host_and_port" "http://localhost")
  fi

  curl_code=$?

  if [[ $curl_code -eq 28 ]]; then
    respTimeinMiliSeconds=$((timeout_seconds * 1000))
    echo "$(date '+%Y-%m-%d %H:%M:%S'): CURL request timed out (>${timeout_seconds}s)" >> "$output_file"
  else
    respTimeinMiliSeconds=$(echo "$respTimeInSeconds*1000/1" | bc)
    echo "$(date '+%Y-%m-%d %H:%M:%S'): Response Time $respTimeinMiliSeconds (ms), Status Code $httpCode for $location" >> "$output_file"
  fi

  ############################################
  # TRIGGER COLLECTOR (NEW LOGIC)
  ############################################
  if [[ "$respTimeinMiliSeconds" -ge "$threshold" ]]; then

    if [[ ! -e "$WORKDIR/auto_trigger.lock" ]]; then
      echo "[auto] Threshold exceeded → Triggering collector_core.sh"
      touch "$WORKDIR/auto_trigger.lock"

      nohup bash "$COLLECTOR" --auto > "$WORKDIR/auto_trigger.log" 2>&1 &
      exit 0
    fi

  fi

  sleep "$frequency"
done
