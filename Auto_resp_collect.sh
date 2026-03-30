#!/bin/bash
set -euo pipefail

#
# Auto Response Time Monitor (FINAL)
# Based 100% on old logic, with new trigger to collector_core.sh
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

function get_website_instance_id()
{
  local proc_pid="$1"
  local instance_id
  instance_id=$(cat "/proc/$proc_pid/environ" | tr '\0' '\n' | grep -w WEBSITE_INSTANCE_ID | cut -d'=' -f2 || true)
  echo "$instance_id"
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
max_days=""
max_seconds=""
trigger_window_seconds=""
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

threshold=${threshold:-1000}
location=${location:-http://localhost:80}
frequency=${frequency:-10}

[[ "$threshold" =~ ^[0-9]+$ ]] || die "Invalid threshold: $threshold" 1
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
# GET WEBSITE_INSTANCE_ID FOR ARR AFFINITY
############################################
website_instance_id=""
if [[ $is_external -eq 0 ]]; then
  # For external URLs, find dotnet pid if not already found
  if [[ -z "$pid" ]]; then
    pid=$(/tools/dotnet-dump ps \
          | grep /usr/share/dotnet/dotnet \
          | grep -v grep \
          | tr -s " " \
          | cut -d" " -f2 || true)
  fi
  if [[ -n "$pid" ]]; then
    website_instance_id=$(get_website_instance_id "$pid")
  fi
  if [[ -n "$website_instance_id" ]]; then
    echo "###Info: ARR Affinity pinned to instance: $website_instance_id"
  else
    echo "###Warning: WEBSITE_INSTANCE_ID not found, external URL will be monitored without ARR Affinity pinning"
  fi
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
echo "###Info: Trigger window=${trigger_window_seconds}s consecutive above threshold"

previous_hour=""
output_file=""
start_ts=$(date +%s)
breach_start_ts=""
last_warned_code=""

while true; do

  current_hour=$(date +"%Y-%m-%d_%H")
  if [[ "$current_hour" != "$previous_hour" ]]; then
    output_file="$output_dir/resptime_stats_${current_hour}.log"
    previous_hour="$current_hour"
    
# Cleanup logs older than 2 days
    find "$output_dir" -type f -name "resptime_stats_*.log" -mtime +2 -delete 2>/dev/null || true

  fi

  if [[ -n "$max_seconds" ]]; then
    now_ts=$(date +%s)
    if (( now_ts - start_ts >= max_seconds )); then
      echo "[auto-resp] monitor stopped by max-days policy, lock preserved (max_days=${max_days})." >> "${output_file:-/dev/null}"
      exit 0
    fi
  fi

  # Request handling:
  # - External (custom hostname): call via internet pinned to current instance via ARRAffinitySameSite cookie
  # - Internal (http://localhost*): resolve to 127.0.0.1
  if [[ $is_external -eq 0 ]]; then
    # External/custom hostname: send request via internet, pin to current instance via ARR Affinity
    if [[ -n "$website_instance_id" ]]; then
      read -r respTimeInSeconds httpCode <<< $(curl -so /dev/null -w "%{time_total} %{http_code}" -m $timeout_seconds \
        -H "Cookie: ARRAffinitySameSite=$website_instance_id" "$location")
    else
      read -r respTimeInSeconds httpCode <<< $(curl -so /dev/null -w "%{time_total} %{http_code}" -m $timeout_seconds "$location")
    fi
  elif [[ "$location" == "http://localhost"* ]]; then
    # Internal localhost with explicit resolve
    read -r respTimeInSeconds httpCode <<< $(curl -so /dev/null -w "%{time_total} %{http_code}" -m $timeout_seconds "$location" --resolve "$host_and_port":127.0.0.1)
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
  # HTTP CODE VALIDATION
  ############################################
  if [[ $curl_code -ne 28 ]]; then
    if [[ "$httpCode" != "$last_warned_code" ]]; then
      if [[ "$httpCode" == "000" ]]; then
        echo ""
        echo "=========================================================="
        echo "[WARNING] No response received from: $location"
        echo "  HTTP Code : 000 (connection failed / no response)"
        echo "  Possible causes:"
        echo "    - Kestrel has not started yet or has crashed"
        echo "    - Wrong port (script uses :80 by default)"
        echo "    - Container is restarting"
        echo "  Action: verify the app is running, then restart this script"
        echo "=========================================================="
        echo ""
        echo "$(date '+%Y-%m-%d %H:%M:%S'): [WARNING] HTTP 000 - No response from $location" >> "$output_file"
        last_warned_code="$httpCode"

      elif [[ "$httpCode" =~ ^3 ]]; then
        echo ""
        echo "=========================================================="
        echo "[WARNING] URL is returning a REDIRECT (HTTP $httpCode)"
        echo "  Monitored URL : $location"
        echo "  This URL redirects elsewhere and may not reflect actual"
        echo "  app response time accurately."
        echo "  Action: replace with a direct endpoint that returns 200,"
        echo "          e.g. a /health or /ping endpoint"
        echo "  Tip: run the following to find the redirect target:"
        echo "    curl -sI -H \"Host:$host_and_port\" http://localhost | grep -i location"
        echo "=========================================================="
        echo ""
        echo "$(date '+%Y-%m-%d %H:%M:%S'): [WARNING] HTTP $httpCode - Redirect detected for $location" >> "$output_file"
        last_warned_code="$httpCode"

      elif [[ "$httpCode" =~ ^4 ]]; then
        echo ""
        echo "=========================================================="
        echo "[WARNING] URL returned a client error (HTTP $httpCode)"
        echo "  Monitored URL : $location"
        case "$httpCode" in
          401|403) echo "  Reason: authentication/authorization required" ;;
          404)     echo "  Reason: endpoint does not exist" ;;
          *)       echo "  Reason: client-side error" ;;
        esac
        echo "  Action: replace with a valid endpoint that returns 200,"
        echo "          e.g. a /health or /ping endpoint"
        echo "=========================================================="
        echo ""
        echo "$(date '+%Y-%m-%d %H:%M:%S'): [WARNING] HTTP $httpCode - Client error for $location" >> "$output_file"
        last_warned_code="$httpCode"

      elif [[ "$httpCode" =~ ^5 ]]; then
        echo ""
        echo "=========================================================="
        echo "[WARNING] URL returned a server error (HTTP $httpCode)"
        echo "  Monitored URL : $location"
        echo "  Reason: the application is experiencing an internal error"
        echo "  Action: check app logs for errors; monitoring continues"
        echo "=========================================================="
        echo ""
        echo "$(date '+%Y-%m-%d %H:%M:%S'): [WARNING] HTTP $httpCode - Server error for $location" >> "$output_file"
        last_warned_code="$httpCode"

      elif [[ "$httpCode" == "200" ]]; then
        if [[ -n "$last_warned_code" ]]; then
          echo "$(date '+%Y-%m-%d %H:%M:%S'): [RECOVERED] HTTP code back to 200 for $location" >> "$output_file"
        fi
        last_warned_code=""
      fi
    fi
  fi

  ############################################
  # TRIGGER COLLECTOR (NEW LOGIC)
  ############################################
  now_ts=$(date +%s)
  if [[ "$respTimeinMiliSeconds" -ge "$threshold" ]]; then
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
      echo "[auto-resp] Threshold exceeded, triggered after ${breach_duration}s consecutive breach → Triggering collector_core.sh"
      touch "$TRIGGER_LOCK"
        if [[ "$enable_dump" == true ]]; then
            nohup bash "$COLLECTOR" --auto --enable-dump > "$WORKDIR/auto_resp_trigger.log" 2>&1 &
        else
            nohup bash "$COLLECTOR" --auto > "$WORKDIR/auto_resp_trigger.log" 2>&1 &
        fi

        exit 0
    fi
  else
    breach_start_ts=""
fi


  sleep "$frequency"
done
