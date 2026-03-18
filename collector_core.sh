#!/bin/bash
set -euo pipefail

##########################################
# CLEANUP BEFORE START
##########################################
echo "[collector] Cleaning stale processes..."
pkill -f dotnet-counters 2>/dev/null || true
pkill -f dotnet-trace    2>/dev/null || true
pkill -f dotnet-dump     2>/dev/null || true
pkill -f azcopy          2>/dev/null || true
echo "[collector] Cleanup OK."

##########################################
# CONFIG
##########################################
WORKDIR="/home/Threadpool"
TOOLS_DIR="/tools"
mkdir -p "$WORKDIR"
cd "$WORKDIR"

TRACE_DURATION_SECONDS=90
COUNTERS_DURATION=300
COUNTER_LIST="System.Runtime,System.Threading.Tasks.TplEventSource,Microsoft.AspNetCore.Hosting,Microsoft-AspNetCore-Server-Kestrel"
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
# GET PID USING OLD WORKING PIPELINE
##########################################
pid=$("$TOOLS_DIR/dotnet-dump" ps \
      | grep "/usr/share/dotnet/dotnet" \
      | grep -v grep \
      | tr -s " " \
      | cut -d" " -f2 || true)

if [[ -z "${pid:-}" ]]; then
    echo "[error] Could not find .NET PID"
    exit 1
fi

##########################################
# GET ENV FROM PID
##########################################
instance=$(cat /proc/$pid/environ | tr '\0' '\n' | grep -w COMPUTERNAME | cut -d'=' -f2)
sas_url=$(cat /proc/$pid/environ | tr '\0' '\n' | grep -w DIAGNOSTICS_AZUREBLOBCONTAINERSASURL | cut -d'=' -f2)

if [[ -z "$instance" ]]; then
    echo "[error] Cannot read COMPUTERNAME"
    exit 1
fi

if [[ -z "$sas_url" ]]; then
    echo "[error] Cannot read DIAGNOSTICS_AZUREBLOBCONTAINERSASURL"
    exit 1
fi

##########################################
# CREATE OUTPUT FOLDER
##########################################
TS=$(date '+%Y%m%d_%H%M%S')
OUTPUT_DIR="${instance}_${TS}"
mkdir -p "$OUTPUT_DIR"

##########################################
# UPLOAD FUNCTION (UPLOAD → DELETE)
##########################################
upload_and_cleanup() {
    local file="$1"
    if [[ ! -e "$file" ]]; then return 0; fi

    local dest="${sas_url%/}/${OUTPUT_DIR}/$(basename "$file")"
    local attempt=1

    while [[ $attempt -le $MAX_UPLOAD_RETRY ]]; do
        echo "[upload] Uploading $file (attempt $attempt)..."
        OUT=$("$TOOLS_DIR/azcopy" copy "$file" "$dest" 2>&1 || true)

        if echo "$OUT" | grep -q "Final Job Status: Completed"; then
            echo "[upload] SUCCESS → removing $file"
            rm -f "$file"
            return 0
        fi

        attempt=$((attempt+1))
        sleep 3
    done

    echo "[upload] FAILED → keeping $file" >> "$WORKDIR/upload_errors.log"
    return 1
}

##########################################
# 1) START COUNTERS (BACKGROUND, 300s)
##########################################
counter_file="$OUTPUT_DIR/counters_${instance}_${TS}.csv"

echo "[counter] Starting dotnet-counters 300s (background)..."
"$TOOLS_DIR/dotnet-counters" collect \
    --process-id "$pid" \
    --counters "$COUNTER_LIST" \
    --refresh-interval 1 \
    --format csv \
    --output "$counter_file" > /dev/null &

COUNTERS_PID=$!
COUNTERS_START_TS=$(date +%s)

##########################################
# 2) CAPTURE STACKTRACE (FAST)
##########################################
stack_file="$OUTPUT_DIR/stack_${instance}_${TS}.txt"
echo "[stack] Capturing stacktrace..."
"$TOOLS_DIR/dotnet-stack" report -p "$pid" > "$stack_file" 2>/dev/null || true

##########################################
# 3) CAPTURE TRACE (BLOCK 90s)
##########################################
trace_file="$OUTPUT_DIR/trace_${instance}_${TS}.nettrace"

echo "[trace] Collecting trace for ${TRACE_DURATION_SECONDS}s..."
"$TOOLS_DIR/dotnet-trace" collect \
    -p "$pid" \
    --providers "Microsoft-DotNETCore-SampleProfiler,Microsoft-Windows-DotNETRuntime:0x0001C001:5,Microsoft-AspNetCore-Hosting:0xFFFFFFFFFFFFFFFF:4,Microsoft-AspNetCore-Server-Kestrel:0xFFFFFFFFFFFFFFFF:4,System.Net.Http:0xFFFFFFFFFFFFFFFF:4,System.Net.Sockets:0xFFFFFFFFFFFFFFFF:4,Microsoft.Data.SqlClient.EventSource:5" \
    -o "$trace_file" \
    --duration "00:01:30" > /dev/null || true

##########################################
# 4) OPTIONAL DUMP (AFTER TRACE)
##########################################
dump_file=""

if [[ "$MODE" == "manual" ]]; then
    if [[ "$DUMP_POLICY" == "yes" ]]; then
        dump_file="$OUTPUT_DIR/dump_${instance}_${TS}.dmp"
        echo "[dump] Collecting dump..."
        "$TOOLS_DIR/dotnet-dump" collect -p "$pid" -o "$dump_file" > /dev/null || true
    fi
else
    # AUTO MODE: dump only once
    if [[ ! -e "$WORKDIR/dump_taken.lock" ]]; then
        echo "[dump] AUTO MODE: Creating dump lock"
        touch "$WORKDIR/dump_taken.lock"
        dump_file="$OUTPUT_DIR/dump_${instance}_${TS}.dmp"
        "$TOOLS_DIR/dotnet-dump" collect -p "$pid" -o "$dump_file" > /dev/null || true
    else
        echo "[dump] AUTO MODE: dump already taken → skipping"
    fi
fi

##########################################
# WAIT COUNTERS FULL 300s
##########################################
COUNTERS_END_TS=$(date +%s)
ELAPSED=$((COUNTERS_END_TS - COUNTERS_START_TS))

if [[ "$ELAPSED" -lt "$COUNTERS_DURATION" ]]; then
    REMAIN=$((COUNTERS_DURATION - ELAPSED))
    echo "[counter] Ensuring 300s duration → sleeping ${REMAIN}s..."
    sleep "$REMAIN"
fi

echo "[counter] Stopping dotnet-counters..."
kill "$COUNTERS_PID" 2>/dev/null || true
wait "$COUNTERS_PID" 2>/dev/null || true

##########################################
# UPLOAD (WITH DELETE)
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

echo "[collector] DONE — all data collected and uploaded."
exit 0