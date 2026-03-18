#!/bin/bash
set -euo pipefail

##########################################
# CONFIG
##########################################
WORKDIR="/home/Threadpool"
TOOLS_DIR="/tools"
mkdir -p "$WORKDIR"
cd "$WORKDIR"

TRACE_DURATION=90
COUNTERS_DURATION=300
UPLOAD_GAP=5
MAX_UPLOAD_RETRY=5

##########################################
# ARGUMENTS
##########################################
MODE="manual"
DUMP_MODE="ask"

if [[ "${1:-}" == "--auto" ]]; then
    MODE="auto"
    DUMP_MODE="auto"
elif [[ "${1:-}" == "--manual" ]]; then
    MODE="manual"
    shift
    if [[ "${1:-}" == "--manual-dump" ]]; then
        DUMP_MODE="yes"
    else
        DUMP_MODE="no"
    fi
fi

##########################################
# FIND .NET PID + ENV VARS
##########################################
pid=$("$TOOLS_DIR/dotnet-dump" ps | grep "/usr/share/dotnet/dotnet" | grep -v grep | awk '{print $2}' || true)
if [[ -z "$pid" ]]; then
    echo "[error] No .NET PID found"
    exit 1
fi

instance=$(cat /proc/$pid/environ | tr '\0' '\n' | grep -w COMPUTERNAME | cut -d'=' -f2)
sas_url=$(cat /proc/$pid/environ | tr '\0' '\n' | grep -w DIAGNOSTICS_AZUREBLOBCONTAINERSASURL | cut -d'=' -f2)

##########################################
# CREATE FOLDER
##########################################
TS=$(date '+%Y%m%d_%H%M%S')
UPLOAD_DIR="${instance}_${TS}"
mkdir -p "$UPLOAD_DIR"

##########################################
# UPLOAD FUNCTION
##########################################
upload_file() {
    local file="$1"
    local dest="${sas_url%/}/${UPLOAD_DIR}/$(basename "$file")"

    local attempt=1
    while [[ $attempt -le $MAX_UPLOAD_RETRY ]]; do
        echo "[upload] $file (attempt $attempt)"
        out=$("$TOOLS_DIR/azcopy" copy "$file" "$dest" 2>&1 || true)
        if echo "$out" | grep -q "Final Job Status: Completed"; then
            echo "[upload] OK"
            return 0
        fi
        attempt=$((attempt+1))
        sleep 3
    done

    echo "[upload] FAILED"
    return 1
}

##########################################
# STACKTRACE
##########################################
stack_file="$UPLOAD_DIR/stack_${instance}_${TS}.txt"
"$TOOLS_DIR/dotnet-stack" report -p "$pid" > "$stack_file" || true

##########################################
# COUNTERS (300s)
##########################################
counter_file="$UPLOAD_DIR/counter_${instance}_${TS}.csv"
"$TOOLS_DIR/dotnet-counters" collect \
    --process-id "$pid" \
    --counters "System.Runtime,System.Threading.Tasks.TplEventSource,Microsoft.AspNetCore.Hosting,Microsoft-AspNetCore-Server-Kestrel" \
    --refresh-interval 1 \
    --format csv \
    --output "$counter_file" > /dev/null &
CPID=$!

sleep "$COUNTERS_DURATION"
kill "$CPID" || true

##########################################
# TRACE (90s)
##########################################
trace_file="$UPLOAD_DIR/trace_${instance}_${TS}.nettrace"
"$TOOLS_DIR/dotnet-trace" collect \
    -p "$pid" \
    --providers "Microsoft-DotNETCore-SampleProfiler,Microsoft-Windows-DotNETRuntime:0x0001C001:5,Microsoft-AspNetCore-Hosting:0xFFFFFFFFFFFFFFFF:4,Microsoft-AspNetCore-Server-Kestrel:0xFFFFFFFFFFFFFFFF:4,System.Net.Http:0xFFFFFFFFFFFFFFFF:4,System.Net.Sockets:0xFFFFFFFFFFFFFFFF:4,Microsoft.Data.SqlClient.EventSource:5" \
    -o "$trace_file" \
    --duration "00:01:30" > /dev/null || true

##########################################
# DUMP
##########################################
dump_file=""
if [[ "$MODE" == "manual" ]]; then
    if [[ "$DUMP_MODE" == "yes" ]]; then
        dump_file="$UPLOAD_DIR/dump_${instance}_${TS}.dmp"
        "$TOOLS_DIR/dotnet-dump" collect -p "$pid" -o "$dump_file" > /dev/null || true
    fi
else
    # AUTO MODE — dump only once
    if [[ ! -e "dump_taken.lock" ]]; then
        touch dump_taken.lock
        dump_file="$UPLOAD_DIR/dump_${instance}_${TS}.dmp"
        "$TOOLS_DIR/dotnet-dump" collect -p "$pid" -o "$dump_file" > /dev/null || true
    fi
fi

##########################################
# UPLOAD ALL
##########################################
upload_file "$stack_file"
sleep "$UPLOAD_GAP"

upload_file "$counter_file"
sleep "$UPLOAD_GAP"

upload_file "$trace_file"
sleep "$UPLOAD_GAP"

if [[ -n "$dump_file" ]]; then
    upload_file "$dump_file"
    sleep "$UPLOAD_GAP"
fi

echo "[collector] DONE"
exit 0