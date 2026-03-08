#!/usr/bin/env bash
# =============================================================================
# 06b_rerun_gpu_benchmark.sh
# Re-run only the GPU benchmark rows using the updated dual-GPU fastp binary.
# Replaces all old gpu/cpu_forced fastp_d0bromir rows in benchmark_results.csv.
# =============================================================================
set -euo pipefail

BIN_DIR="$HOME/tools/bin"
RESULTS_DIR="$HOME/benchmark/results"
TMPOUT="/tmp/fqc_bench_gpu_$$"
mkdir -p "$RESULTS_DIR" "$TMPOUT"

FASTP_GPU="$BIN_DIR/fastp_d0bromir_gpu"

RAW_CSV="$RESULTS_DIR/benchmark_results.csv"
GPU_CSV="$RESULTS_DIR/benchmark_gpu_rerun.csv"

# ── File lists ─────────────────────────────────────────────────────────────────
SMALL_FILE="$HOME/FASTQ/S1A_S1_L001_R1_001.fastq.gz"
WGS_SMALL="$HOME/FASTQ/WGS/ERR1044906_1.fastq.gz"
WGS_MEDIUM="$HOME/FASTQ/WGS/ERR1044900_1.fastq.gz"
WGS_LARGE="$HOME/FASTQ/WGS/ERR1044320_1.fastq.gz"

FASTP_THREADS=(1 2 4 8 16 32)

# Verify GPU binary
if [[ ! -x "$FASTP_GPU" ]]; then
    echo "ERROR: GPU binary not found at $FASTP_GPU" >&2; exit 1
fi
echo "GPU binary: $(ls -lh "$FASTP_GPU" | awk '{print $5, $6, $7, $8, $9}')"
echo "Testing GPU init..."
"$FASTP_GPU" --version 2>&1 | head -5

# Write header to new GPU results file
printf "mode,application,fastq_file,num_cpus,time_sec\n" > "$GPU_CSV"

# ── Timing helper ──────────────────────────────────────────────────────────────
run_timed() {
    local mode="$1" app="$2" file_label="$3" num_cpus="$4" n_reps="$5"
    shift 5
    local cmd=("$@")

    echo "  → $app  threads=$num_cpus  file=$(basename "$file_label")  (${n_reps} rep(s))"
    for ((rep=1; rep<=n_reps; rep++)); do
        rm -rf "$TMPOUT"/* 2>/dev/null; mkdir -p "$TMPOUT"
        sync && sudo sh -c 'echo 3 > /proc/sys/vm/drop_caches' 2>/dev/null || true

        local start_s end_s elapsed
        start_s=$(date +%s%N)
        "${cmd[@]}" >/dev/null 2>&1
        end_s=$(date +%s%N)
        elapsed=$(echo "scale=3; ($end_s - $start_s) / 1000000000" | bc)

        printf "%s,%s,%s,%s,%s\n" \
            "$mode" "$app" "$(basename "$file_label")" "$num_cpus" "$elapsed" \
            >> "$GPU_CSV"
        echo "    rep $rep: ${elapsed}s"
    done
}

clean_tmp() { rm -rf "$TMPOUT"/* ; mkdir -p "$TMPOUT"; }

echo ""
echo "================================================================="
echo " GPU BENCHMARK START  $(date '+%Y-%m-%d %H:%M:%S')"
echo " Binary: $FASTP_GPU"
echo "================================================================="

# ── Section A: GPU mode, all files, full thread sweep ─────────────────────────
echo ""
echo "─── Section A: GPU mode — all files, -w 1..32 ───────────────────"

for INPUT_FILE in "$SMALL_FILE" "$WGS_SMALL" "$WGS_MEDIUM" "$WGS_LARGE"; do
    [[ -f "$INPUT_FILE" ]] || { echo "  SKIP (file not found): $INPUT_FILE"; continue; }

    FSIZE=$(stat -c%s "$INPUT_FILE")
    if (( FSIZE < 500000000 )); then NREPS=3; else NREPS=1; fi

    echo ""
    echo ">>> File: $INPUT_FILE  ($(du -sh "$INPUT_FILE" | cut -f1))"

    echo "  [fastp_d0bromir GPU — dual-GPU] sweeping -w 1..32"
    for W in "${FASTP_THREADS[@]}"; do
        clean_tmp
        run_timed "gpu" "fastp_d0bromir" "$INPUT_FILE" "$W" "$NREPS" \
            "$FASTP_GPU" \
                -w "$W" \
                -i "$INPUT_FILE" \
                -o /dev/null \
                -h /dev/null \
                -j /dev/null
    done
done

# ── Section C: CPU-forced vs GPU comparison ───────────────────────────────────
echo ""
echo "─── Section C: CPU-forced vs GPU comparison (WGS-6G) ────────────"

if [[ -f "$WGS_SMALL" ]]; then
    for W in 4 8 16; do
        echo "  [d0bromir GPU binary, FORCED CPU via CUDA_VISIBLE_DEVICES='']  -w $W"
        clean_tmp
        run_timed "cpu_forced" "fastp_d0bromir_gpu_binary" "$WGS_SMALL" "$W" 1 \
            env CUDA_VISIBLE_DEVICES="" \
                "$FASTP_GPU" -w "$W" -i "$WGS_SMALL" \
                -o /dev/null -h /dev/null -j /dev/null

        echo "  [d0bromir GPU binary, GPU mode]  -w $W"
        clean_tmp
        run_timed "gpu" "fastp_d0bromir_gpu_binary" "$WGS_SMALL" "$W" 1 \
            "$FASTP_GPU" -w "$W" -i "$WGS_SMALL" \
            -o /dev/null -h /dev/null -j /dev/null
    done
fi

# ── Merge: replace all old gpu/cpu_forced rows with the new results ────────────
echo ""
echo "─── Merging results into $RAW_CSV ───────────────────────────────"

# Keep all rows that are NOT (gpu or cpu_forced mode for fastp_d0bromir*)
HEADER=$(head -1 "$RAW_CSV")
KEPT=$(awk -F',' 'NR>1 && !($1=="gpu" || $1=="cpu_forced")' "$RAW_CSV")
GPU_DATA=$(tail -n +2 "$GPU_CSV")

{
    echo "$HEADER"
    echo "$KEPT"
    echo "$GPU_DATA"
} > "${RAW_CSV}.tmp" && mv "${RAW_CSV}.tmp" "$RAW_CSV"

echo "New row count: $(wc -l < "$RAW_CSV") (including header)"

# ── Cleanup ───────────────────────────────────────────────────────────────────
rm -rf "$TMPOUT"

echo ""
echo "================================================================="
echo " GPU BENCHMARK COMPLETE  $(date '+%Y-%m-%d %H:%M:%S')"
echo "================================================================="
echo ""
echo "Raw results : $RAW_CSV"
echo "GPU-only    : $GPU_CSV"
echo ""
echo "Re-run analysis:"
echo "  python3 ~/benchmark/08_analyze_python.py"
