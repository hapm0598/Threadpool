#!/bin/bash
set -euo pipefail

##########################################
# CLEANUP BEFORE START
##########################################
echo "[collector] Cleaning stale processes..."
pkill -f dotnet-counters 2>/dev/null || true
pkill -f dotnet-trace    2>/dev/null || true
pkill -f dotnet-dump     2>/dev/null || true
pkill -f dotnet-gcdump   2>/dev/null || true
pkill -f azcopy          2>/dev/null || true
echo "[collector] Cleanup OK."

##########################################
# CONFIG
##########################################

TOOLS_DIR="/tools"

get_env_from_pid() {
    local pid="$1" key="$2"
    local val
    val=$(tr '\0' '\n' < "/proc/$pid/environ" \
          | grep -w "$key" || true)
    val=${val#*=}
    echo "${val:-}"
}

pid=$("$TOOLS_DIR/dotnet-dump" ps \
      | awk '$0 ~ /\/usr\/share\/dotnet\/dotnet/ {print $1; exit}' || true)
if [[ -z "${pid:-}" ]]; then
    echo "[error] Could not find any running .NET process"
    exit 1
fi

instancehome=$(get_env_from_pid "$pid" "COMPUTERNAME")
if [[ -z "${instancehome:-}" ]]; then
    echo "[error] Could not find COMPUTERNAME environment variable"
    exit 1
fi
WORKDIR="/home/Troubleshooting/${instancehome}"
mkdir -p "$WORKDIR"
cd "$WORKDIR"

TRACE_DURATION_SECONDS=90
COUNTERS_DURATION=300
COUNTER_LIST="System.Runtime,System.Threading.Tasks.TplEventSource,Microsoft.AspNetCore.Hosting,Microsoft-AspNetCore-Server-Kestrel"
UPLOAD_INITIAL_DELAY=20
UPLOAD_GAP=10
MAX_UPLOAD_RETRY=5

##########################################
# ARGUMENTS
##########################################
MODE="manual"
DUMP_POLICY="no"
DUMP_TYPE="full"
AUTO_COLLECT_DUMP=false

if [[ "${1:-}" == "--auto" ]]; then
    MODE="auto"
    shift
    if [[ "${1:-}" == "--enable-fulldump" ]]; then
        AUTO_COLLECT_DUMP=true
        DUMP_TYPE="full"
    elif [[ "${1:-}" == "--enable-gcdump" ]]; then
        AUTO_COLLECT_DUMP=true
        DUMP_TYPE="gc"
    elif [[ "${1:-}" == "--enable-dump" ]]; then
        # Keep backward compatibility with old flag
        AUTO_COLLECT_DUMP=true
        DUMP_TYPE="full"
    fi
elif [[ "${1:-}" == "--manual" ]]; then
    MODE="manual"
    shift
    if [[ "${1:-}" == "--manual-fulldump" ]]; then
        DUMP_POLICY="yes"
        DUMP_TYPE="full"
    elif [[ "${1:-}" == "--manual-gcdump" ]]; then
        DUMP_POLICY="yes"
        DUMP_TYPE="gc"
    elif [[ "${1:-}" == "--manual-dump" ]]; then
        # Keep backward compatibility with old flag
        DUMP_POLICY="yes"
        DUMP_TYPE="full"
    else
        DUMP_POLICY="no"
    fi
fi

instance=$(get_env_from_pid "$pid" "COMPUTERNAME")
sas_url=$(get_env_from_pid "$pid" "DIAGNOSTICS_AZUREBLOBCONTAINERSASURL")

if [[ -z "$instance" ]]; then
    echo "[error] Could not find COMPUTERNAME environment variable"
    exit 1
fi

if [[ -z "$sas_url" ]]; then
    echo "[error] Could not find SAS URL"
    exit 1
fi

##########################################
# CREATE UPLOAD SUBDIR (OLD STYLE)
##########################################
UPLOAD_FOLDER_TS=$(date '+%Y%m%d_%H%M%S')
UPLOAD_SUBDIR="${instance}_${UPLOAD_FOLDER_TS}"

##########################################
# UPLOAD FUNCTION (100% ORIGINAL LOGIC)
##########################################
upload_to_blob() {
    local file_path="$1" sas_url="$2"
    local attempt=1

    local base sas_query filename dest

    if [[ "$sas_url" == *\?* ]]; then
        base="${sas_url%%\?*}"
        sas_query="?${sas_url#*\?}"
    else
        base="$sas_url"
        sas_query=""
    fi

    base="${base%/}"
    filename="$(basename "$file_path")"
    dest="${base}/${UPLOAD_SUBDIR}/${filename}${sas_query}"

    while [[ $attempt -le $MAX_UPLOAD_RETRY ]]; do
        echo "[upload] Uploading $file_path -> $dest (attempt $attempt/$MAX_UPLOAD_RETRY)..."
        azcopy_output=$("$TOOLS_DIR/azcopy" copy "$file_path" "$dest" 2>&1 || true)

        if echo "$azcopy_output" | grep -q "Final Job Status: Completed"; then
            echo "[upload] $file_path uploaded."
            return 0
        fi

        echo "[upload] Upload failed, retrying..."
        attempt=$((attempt+1))
        sleep 3
    done

    echo "[upload] Upload $file_path failed after $MAX_UPLOAD_RETRY attempts."
    return 1
}

##########################################
# 1) COUNTERS (BACKGROUND, OLD LOGIC)
##########################################
echo "[counter] Starting dotnet-counters in background..."
counter_file="countertrace_${instance}_$(date '+%Y%m%d_%H%M%S').csv"
COUNTERS_START_TS=$(date +%s)

"$TOOLS_DIR/dotnet-counters" collect \
    --process-id "$pid" \
    --counters "$COUNTER_LIST" \
    --refresh-interval 1 \
    --format csv \
    --output "$counter_file" > /dev/null &

COUNTERS_PID=$!

##########################################
# 2) STACKTRACE (OLD LOGIC)
##########################################
echo "[stack] Capturing stack trace..."
stack_file="stacktrace_${instance}_$(date '+%Y%m%d_%H%M%S').txt"

"$TOOLS_DIR/dotnet-stack" report -p "$pid" > "$stack_file" 2>/dev/null || {
    echo "[stack] Stack trace collection failed"
    rm -f "$stack_file"
}

if [[ -s "$stack_file" ]]; then
    echo "[stack] Stack trace collected."
else
    echo "[stack] Missing or empty."
fi

##########################################
# 3) NETTRACE (OLD LOGIC — 90s)
##########################################
echo "[trace] Collecting nettrace for ${TRACE_DURATION_SECONDS}s..."
trace_file="trace_${instance}_$(date '+%Y%m%d_%H%M%S').nettrace"

"$TOOLS_DIR/dotnet-trace" collect \
    -p "$pid" \
    --providers "Microsoft-DotNETCore-SampleProfiler,Microsoft-Windows-DotNETRuntime:0x0001C001:5,Microsoft-AspNetCore-Hosting:0xFFFFFFFFFFFFFFFF:4,Microsoft-AspNetCore-Server-Kestrel:0xFFFFFFFFFFFFFFFF:4,System.Net.Http:0xFFFFFFFFFFFFFFFF:4,System.Net.Sockets:0xFFFFFFFFFFFFFFFF:4,Microsoft.Data.SqlClient.EventSource:5" \
    -o "$trace_file" \
    --duration "00:01:30" > /dev/null || {
        echo "[trace] Nettrace collection failed"
        touch "$trace_file.failed"
    }

if [[ -s "$trace_file" ]]; then
    echo "[trace] Nettrace collected."
else
    echo "[trace] Missing or empty."
fi

##########################################
# 4) DUMP (ENHANCED WITH GC DUMP SUPPORT)
##########################################
dump_file=""

if [[ "$MODE" == "manual" ]]; then
    if [[ "$DUMP_POLICY" == "yes" ]]; then
        if [[ "$DUMP_TYPE" == "gc" ]]; then
            echo "[dump] Collecting GC dump..."
            dump_file="gcdump_${instance}_$(date '+%Y%m%d_%H%M%S').gcdump"

            "$TOOLS_DIR/dotnet-gcdump" collect -p "$pid" -o "$dump_file" > /dev/null || {
                echo "[dump] GC dump collection failed"
                rm -f "$dump_file"
                dump_file=""
            }

            if [[ -s "$dump_file" ]]; then
                echo "[dump] GC dump collected."
            else
                echo "[dump] Missing or empty."
            fi
        else
            echo "[dump] Collecting full memory dump..."
            dump_file="dump_${instance}_$(date '+%Y%m%d_%H%M%S').dmp"

            "$TOOLS_DIR/dotnet-dump" collect -p "$pid" -o "$dump_file" > /dev/null || {
                echo "[dump] Memory dump collection failed"
                rm -f "$dump_file"
                dump_file=""
            }

            if [[ -s "$dump_file" ]]; then
                echo "[dump] Memory dump collected."
            else
                echo "[dump] Missing or empty."
            fi
        fi
    else
        echo "[dump] Skipping memory dump collection as requested."
    fi

else
    # AUTO MODE: collect dump only if explicitly enabled
    if [[ "$AUTO_COLLECT_DUMP" == true ]]; then
        if [[ ! -e "$WORKDIR/dump_taken.lock" ]]; then
            touch "$WORKDIR/dump_taken.lock"

            if [[ "$DUMP_TYPE" == "gc" ]]; then
                echo "[dump] AUTO MODE: Collecting GC dump (first time)..."
                dump_file="gcdump_${instance}_$(date '+%Y%m%d_%H%M%S').gcdump"

                "$TOOLS_DIR/dotnet-gcdump" collect -p "$pid" -o "$dump_file" > /dev/null || {
                    echo "[dump] GC dump collection failed"
                    rm -f "$dump_file"
                    dump_file=""
                }

                if [[ -s "$dump_file" ]]; then
                    echo "[dump] GC dump collected."
                else
                    echo "[dump] Missing or empty."
                fi
            else
                echo "[dump] AUTO MODE: Collecting full memory dump (first time)..."
                dump_file="dump_${instance}_$(date '+%Y%m%d_%H%M%S').dmp"

                "$TOOLS_DIR/dotnet-dump" collect -p "$pid" -o "$dump_file" > /dev/null || {
                    echo "[dump] Memory dump collection failed"
                    rm -f "$dump_file"
                    dump_file=""
                }

                if [[ -s "$dump_file" ]]; then
                    echo "[dump] Memory dump collected."
                else
                    echo "[dump] Missing or empty."
                fi
            fi
        else
            echo "[dump] AUTO MODE: Dump already taken, skipping."
        fi
    else
        echo "[dump] AUTO MODE: Dump collection disabled by caller."
    fi
fi

##########################################
# ENSURE COUNTERS FULL 300s (OLD LOGIC)
##########################################
COUNTERS_END_TS=$(date +%s)
ELAPSED=$((COUNTERS_END_TS - COUNTERS_START_TS))

if [[ "$ELAPSED" -lt "$COUNTERS_DURATION" ]]; then
    REMAIN=$((COUNTERS_DURATION - ELAPSED))
    echo "[counter] Ensuring minimum duration, sleeping ${REMAIN}s..."
    sleep "$REMAIN"
fi

echo "[counter] Stopping dotnet-counters..."
kill "$COUNTERS_PID" 2>/dev/null || true
wait "$COUNTERS_PID" 2>/dev/null || true

if [[ -s "$counter_file" ]]; then
    echo "[counter] Counter trace collected."
else
    echo "[error] Counter trace missing or empty."
fi

##########################################
# UPLOAD (OLD ORDER + OLD MESSAGES)
##########################################
echo "All data have been collected, waiting for ${UPLOAD_INITIAL_DELAY}s before uploading to Blob."
sleep "$UPLOAD_INITIAL_DELAY"

# trace
if [[ -e "$trace_file" ]]; then
    echo "[trace] Uploading nettrace..."
    upload_to_blob "$trace_file" "$sas_url" || echo "[error] Nettrace upload failed"
    sleep "$UPLOAD_GAP"
fi

# dump
if [[ -n "$dump_file" && -e "$dump_file" ]]; then
    echo "[dump] Uploading memory dump..."
    upload_to_blob "$dump_file" "$sas_url" || echo "[error] Memory dump upload failed"
    sleep "$UPLOAD_GAP"
fi

# stack
if [[ -e "$stack_file" ]]; then
    echo "[stack] Uploading stack trace..."
    upload_to_blob "$stack_file" "$sas_url" || echo "[error] Stack trace upload failed"
    sleep "$UPLOAD_GAP"
fi

# counters
if [[ -e "$counter_file" ]]; then
    echo "[counter] Uploading counter trace..."
    upload_to_blob "$counter_file" "$sas_url" || echo "[error] Counter trace upload failed"
    sleep "$UPLOAD_GAP"
fi
echo "[done] All data collection and upload steps are complete. Hand off to Problem team. Have a great day!"
##########################################
# CLEANUP (OLD LOGIC)
##########################################
echo "[cleanup] Deleting diagnostic files in $WORKDIR..."
rm -f "$trace_file" "$dump_file" "$stack_file" "$counter_file" 2>/dev/null || true
# Also cleanup any gcdump files if they exist
rm -f gcdump_*.gcdump 2>/dev/null || true
echo "Completed"
exit 0