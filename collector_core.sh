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
DUMP_POLICY="ask"

if [[ "${1:-}" == "--auto" ]]; then
    MODE="auto"
    DUMP_POLICY="auto"
elif [[ "${1:-}" == "--manual" ]]; then
    MODE="manual"
    shift
    if [[ "${1:-}" == "--manual-dump" ]]; then
        DUMP_POLICY="yes"
    else
        DUMP_POLICY="no"
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
OUTPUT_DIR="${instance}_${TS}"
mkdir -p "$OUTPUT_DIR"

##########################################
# UPLOAD FUNCTION (with cleanup)
##########################################
upload_and_cleanup() {
    local file="$1"
    if [[ ! -e "$file" ]]; then return 0; fi

    local dest="${sas_url%/}/${OUTPUT_DIR}/$(basename "$file")"
    local attempt=1

    while [[ $attempt -le $MAX_UPLOAD_RETRY ]]; do
        echo "[upload] $file (attempt $attempt)"
        OUT=$("$TOOLS_DIR/azcopy" copy "$file" "$dest" 2>&1 || true)

        if echo "$OUT" | grep -q "Final Job Status: Completed"; then
            echo "[upload] OK → removing $file"
            rm -f "$file"
            return 0
        fi

        attempt=$((attempt+1))
        sleep 3
    done

    echo "[error] Upload failed → keeping $file" >> "$WORKDIR/upload_errors.log"
    return 1
}

##########################################
# CAPTURE STACK
##########################################
stack_file="$OUTPUT_DIR/stack_${instance}_${TS}.txt"
"$TOOLS_DIR/dotnet-stack" report -p "$pid" > "$stack_file" || true

##########################################
# CAPTURE COUNTERS (300s)
##########################################
counter_file="$OUTPUT_DIR/counters_${instance}_${TS}.csv"

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
# CAPTURE TRACE (90s)
##########################################
trace_file="$OUTPUT_DIR/trace_${instance}_${TS}.nettrace"

"$TOOLS_DIR/dotnet-trace" collect \
    -p "$pid" \
    --providers "Microsoft-DotNETCore-SampleProfiler,Microsoft-Windows-DotNETRuntime:0x0001C001:5,Microsoft-AspNetCore-Hosting:0xFFFFFFFFFFFFFFFF:4,Microsoft-AspNetCore-Server-Kestrel:0xFFFFFFFFFFFFFFFF:4,System.Net.Http:0xFFFFFFFFFFFFFFFF:4,System.Net.Sockets:0xFFFFFFFFFFFFFFFF:4,Microsoft.Data.SqlClient.EventSource:5" \
    -o "$trace_file" \
    --duration "00:01:30" > /dev/null || true

##########################################
# CAPTURE DUMP
##########################################
dump_file=""

if [[ "$MODE" == "manual" ]]; then
    if [[ "$DUMP_POLICY" == "yes" ]]; then
        dump_file="$OUTPUT_DIR/dump_${instance}_${TS}.dmp"
        "$TOOLS_DIR/dotnet-dump" collect -p "$pid" -o "$dump_file" > /dev/null || true
    fi

else
    # AUTO MODE: dump only once
    if [[ ! -e "$WORKDIR/dump_taken.lock" ]]; then
        touch "$WORKDIR/dump_taken.lock"
        dump_file="$OUTPUT_DIR/dump_${instance}_${TS}.dmp"
        "$TOOLS_DIR/dotnet-dump" collect -p "$pid" -o "$dump_file" > /dev/null || true
    fi
fi

##########################################
# UPLOAD + CLEANUP
##########################################
upload_and_cleanup "$stack_file"
sleep "$UPLOAD_GAP"

upload_and_cleanup "$counter_file"
sleep "$UPLOAD_GAP"

upload_and_cleanup "$trace_file"
sleep "$UPLOAD_GAP"

if [[ -n "$dump_file" ]]; then
    upload_and_cleanup "$dump_file"
    sleep "$UPLOAD_GAP"
fi

echo "[collector] DONE — all files uploaded (or preserved if failed)."
exit 0