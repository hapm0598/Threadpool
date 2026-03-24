#!/bin/bash
set -euo pipefail

#
# Auto Response Time Monitor (FINAL)
# Based 100% on old logic, with new trigger to collector_core.sh
#

script_name=${0##*/}

# Detect instance name (App Service instance ID)
instancehome=$(hostname)

# WORKDIR unique for this instance
WORKDIR="/home/Troubleshooting/${instancehome}"

COLLECTOR="$WORKDIR/collector_core.sh"
TRIGGER_LOCK="$WORKDIR/auto_trigger_resp.lock"
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

threshold=""
location=""
frequency=""
clean_flag=0
enable_dump=false
while [[ $# -gt 0 ]]; do
  case "$1" in
    -t)
      [[ $# -ge 2 ]] || die "Missing value for -t" 1
      threshold="$2"
      shift 2
      ;;
    -l)
      [[ $# -ge 2 ]] || die "Missing value for -l" 1
      location="$2"
      shift 2
      ;;
    -f)
      [[ $# -ge 2 ]] || die "Missing value for -f" 1
      frequency="$2"
      shift 2
      ;;
    -c)
      clean_flag=1
      shift
      ;;
    --enable-dump)
      enable_dump=true
      shift
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

threshold=${threshold:-1000}
location=${location:-http://localhost:80}
frequency=${frequency:-10}

[[ "$threshold" =~ ^[0-9]+$ ]] || die "Invalid threshold: $threshold" 1
[[ "$frequency" =~ ^[0-9]+$ ]] || die "Invalid frequency: $frequency" 1

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

if [[ $is_external -eq 1 || "$enable_dump" == true ]]; then

  pid=$(/tools/dotnet-dump ps \
        | grep /usr/share/dotnet/dotnet \
        | grep -v grep \
        | tr -s " " \
        | cut -d" " -f2)

  if [[ -z "$pid" ]]; then
    if [[ "$enable_dump" == true ]]; then
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
output_dir="$WORKDIR/resptime-logs"
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
    
# Cleanup logs older than 2 days
    find "$output_dir" -type f -name "resptime_stats_*.log" -mtime +2 -delete 2>/dev/null || true

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
    respTimeinMiliSeconds=$(echo "$respTimeInSeconds*1000/1" | bc 2>/dev/null || echo 0)
    echo "$(date '+%Y-%m-%d %H:%M:%S'): Response Time $respTimeinMiliSeconds (ms), Status Code $httpCode for $location" >> "$output_file"
  fi

  ############################################
  # TRIGGER COLLECTOR (NEW LOGIC)
  ############################################
  if [[ "$respTimeinMiliSeconds" -ge "$threshold" ]]; then

    if [[ ! -e "$TRIGGER_LOCK" ]]; then
      echo "[auto] Threshold exceeded → Triggering collector_core.sh"
      touch "$TRIGGER_LOCK"
        if [[ "$enable_dump" == true ]]; then
            nohup bash "$COLLECTOR" --auto --enable-dump > "$WORKDIR/auto_resp_trigger.log" 2>&1 &
        else
            nohup bash "$COLLECTOR" --auto > "$WORKDIR/auto_resp_trigger.log" 2>&1 &
        fi

        exit 0
    fi
fi


  sleep "$frequency"
done