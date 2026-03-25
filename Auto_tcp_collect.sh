#!/bin/bash
set -euo pipefail

# ============================================================
# Auto TCP Outbound Connection Monitor
# ============================================================

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
TRIGGER_LOCK="$WORKDIR/auto_trigger_tcp.lock"
mkdir -p "$WORKDIR"

tcp_threshold=""
frequency=""
enable_dump=false
max_days=""
max_seconds=""

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
    --max-days)
      [[ $# -ge 2 ]] || { echo "Missing value for --max-days"; exit 1; }
      max_days="$2"
      shift 2
      ;;
    --max-days=*)
      max_days="${1#*=}"
      shift
      ;;
    -d)
      [[ $# -ge 2 ]] || { echo "Missing value for -d"; exit 1; }
      max_days="$2"
      shift 2
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

max_days=${max_days:-0}
[[ "$max_days" =~ ^[0-9]+$ ]] || { echo "Invalid max_days: $max_days"; exit 1; }
if (( max_days > 0 )); then
  max_seconds=$((max_days * 24 * 3600))
else
  max_seconds=""
fi

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

is_external_ip() {
  local ip="$1"
  [[ -n "$ip" ]] || return 1

  # IPv6 localhost/ULA/link-local
  if [[ "$ip" == "::1" || "$ip" == fe80:* || "$ip" == fc* || "$ip" == fd* ]]; then
    return 1
  fi

  # IPv4 private/loopback/link-local
  if [[ "$ip" =~ ^127\. || "$ip" =~ ^10\. || "$ip" =~ ^192\.168\. || "$ip" =~ ^169\.254\. ]]; then
    return 1
  fi
  if [[ "$ip" =~ ^172\.([1][6-9]|2[0-9]|3[0-1])\. ]]; then
    return 1
  fi

  return 0
}

collect_outbound_lines() {
  if command -v ss >/dev/null 2>&1; then
    ss -tan 2>/dev/null | awk '
      NR>1 && ($1=="ESTAB" || $1=="TIME-WAIT" || $1=="CLOSE-WAIT" || $1=="FIN-WAIT-1" || $1=="FIN-WAIT-2") {
        print $4, $5, $1
      }'
    return
  fi

  if command -v netstat >/dev/null 2>&1; then
    netstat -tan 2>/dev/null | awk '
      /ESTABLISHED|TIME_WAIT|CLOSE_WAIT|FIN_WAIT/ {
        print $4, $5, $6
      }'
    return
  fi

  # Fallback only keeps ESTABLISHED without state details.
  awk 'NR>1 && $4=="01" {print $2, $3, "ESTABLISHED"}' /proc/net/tcp /proc/net/tcp6 2>/dev/null
}

monitor_connections_by_remote_ip() {
  # $1 output_file, $2 threshold
  local output_file="$1"
  local threshold="$2"
  local tmp_file
  tmp_file=$(mktemp)

  collect_outbound_lines | while read -r local_addr remote_addr conn_state; do
    local local_ip_port="$local_addr"
    local remote_ip_port="$remote_addr"

    local remote_ip="${remote_ip_port%:*}"
    local local_port="${local_ip_port##*:}"

    # Skip common inbound listener ports and malformed rows.
    if [[ "$local_port" =~ ^(80|443|2222)$ ]]; then
      continue
    fi
    [[ -n "$remote_ip" && -n "$remote_ip_port" ]] || continue

    # Normalize netstat/ss state names.
    local state="${conn_state//-/_}"

    if is_external_ip "$remote_ip"; then
      echo "$remote_ip|$remote_ip_port|$state" >> "$tmp_file"
    fi
  done

  echo "--------------------------------------------------------------------------------" >> "$output_file"
  printf "%-45s %-8s %s\n" "Remote Address:Port" "Total" "States (Count)" >> "$output_file"
  echo "--------------------------------------------------------------------------------" >> "$output_file"

  if [[ ! -s "$tmp_file" ]]; then
    echo "No external outbound TCP connections captured in target states." >> "$output_file"
    rm -f "$tmp_file"
    return 0
  fi

  awk -F'|' '
    {
      endpoint=$2
      state=$3
      endpoint_total[endpoint]++
      endpoint_state_count[endpoint, state]++
      if (!(seen[endpoint, state]++)) {
        endpoint_state_list[endpoint]=endpoint_state_list[endpoint] " " state
      }
    }
    END {
      for (e in endpoint_total) {
        states_text=""
        split(endpoint_state_list[e], states, " ")
        for (i in states) {
          s=states[i]
          if (s == "") continue
          states_text=states_text " " s "(" endpoint_state_count[e, s] ")"
        }
        printf "%-45s %-8d%s\n", e, endpoint_total[e], states_text
      }
    }' "$tmp_file" >> "$output_file"

  local max_per_ip top_ip
  max_per_ip=$(awk -F'|' '
    { ip_total[$1]++ }
    END {
      max=0
      for (ip in ip_total) if (ip_total[ip] > max) max=ip_total[ip]
      print max+0
    }' "$tmp_file")

  top_ip=$(awk -F'|' '
    {
      ip_total[$1]++
    }
    END {
      top=""
      max=0
      for (ip in ip_total) {
        if (ip_total[ip] > max) {
          max=ip_total[ip]
          top=ip
        }
      }
      print top
    }' "$tmp_file")

  rm -f "$tmp_file"

  if (( max_per_ip >= threshold )); then
    echo "$(date '+%Y-%m-%d %H:%M:%S'): Top offending IP: ${top_ip:-unknown} (${max_per_ip} connections)" >> "$output_file"
    echo "$(date '+%Y-%m-%d %H:%M:%S'): Connection threshold exceeded per remote IP (max=${max_per_ip}, threshold=${threshold})" >> "$output_file"
    return 1
  fi

  echo "$(date '+%Y-%m-%d %H:%M:%S'): Connection count within threshold per remote IP (max=${max_per_ip}, threshold=${threshold})" >> "$output_file"
  return 0
}

previous_hour=""
output_file=""
start_ts=$(date +%s)
while true; do
  current_hour=$(date +"%Y-%m-%d_%H")
  if [[ "$current_hour" != "$previous_hour" ]]; then
    output_file="$output_dir/tcp_stats_${current_hour}.log"
    previous_hour="$current_hour"
    find "$output_dir" -type f -name "tcp_stats_*.log" -mtime +2 -delete 2>/dev/null || true
  fi

  if [[ -n "$max_seconds" ]]; then
    now_ts=$(date +%s)
    if (( now_ts - start_ts >= max_seconds )); then
      echo "[auto-tcp] monitor stopped by max-days policy, lock preserved (max_days=${max_days})." >> "${output_file:-/dev/null}"
      exit 0
    fi
  fi

  if ! monitor_connections_by_remote_ip "$output_file" "$tcp_threshold"; then
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

  echo "Current timestamp: $(date '+%Y-%m-%d %H:%M:%S')" >> "$output_file"
  echo "--------------------------------------------------------------------------------" >> "$output_file"

  sleep "$frequency"
done
