#!/usr/bin/env bash
# =============================================================================
# 06_run_benchmarks.sh
# Run the FASTQ QC benchmark suite across all tools and configurations.
#
# Results are saved to:
#   ~/benchmark/results/benchmark_results.csv   (raw data – all runs)
#   ~/benchmark/results/benchmark_summary.csv   (min per combination)
#
# CSV columns: mode,application,fastq_file,num_cpus,time_sec
#
# ── Benchmark matrix ─────────────────────────────────────────────────────────
# Tools
#   fastqc         – FastQC (Java), -t controls simultaneous files
#   falco          – Falco (C++), threading NOT implemented (always 1 thread)
#   fastp_opengene – OpenGene fastp, -w controls worker threads
#   fastp_cpu      – d0bromir/fastp CPU build, -w controls worker threads
#   fastp_gpu      – d0bromir/fastp GPU build (CUDA stats), same -w arg
#
# Files tested (from small to large for progressive timing insight)
#   ~/FASTQ/S1A_S1_L001_R1_001.fastq.gz            (~148 MB gzip, panel)
#   ~/FASTQ/WGS/ERR1044906_1.fastq.gz              (~6.0 GB gzip, WGS)
#   ~/FASTQ/WGS/ERR1044900_1.fastq.gz              (~8.5 GB gzip, WGS)
#   ~/FASTQ/WGS/ERR1044320_1.fastq.gz              (~9.5 GB gzip, WGS)
#
# Thread counts
#   fastp variants  : 1 2 4 8 16 32 (worker threads, -w)
#   FastQC single   : 1             (single file; -t doesn't help for 1 file)
#   FastQC multi    : 1 2 4 8       (ALL small FASTQ files passed together)
#   Falco           : 1             (threading not implemented)
#
# Repetitions: 3 for small, 2 for WGS.  Minimum wall-clock time is reported.
#
# Notes
# -----
# • fastp output is discarded (-o /dev/null) to focus on I/O-read + processing.
# • FastQC and Falco write reports to a temp directory that is cleaned each run.
# • GPU mode: CUDA_VISIBLE_DEVICES is unset so GPU is auto-selected.
# • Page-cache drop is attempted between reps (requires sudo; silent skip if denied).
# =============================================================================
set -euo pipefail

# ── Configuration ─────────────────────────────────────────────────────────────
TOOLS_DIR="$HOME/tools"
BIN_DIR="$TOOLS_DIR/bin"
RESULTS_DIR="$HOME/benchmark/results"
TMPOUT="/tmp/fqc_bench_$$"
mkdir -p "$RESULTS_DIR" "$TMPOUT"

# Derived paths
FASTQC="$BIN_DIR/fastqc"
FALCO="$BIN_DIR/falco"
FASTP_OG="$BIN_DIR/fastp_opengene"
FASTP_CPU="$BIN_DIR/fastp_d0bromir_cpu"
FASTP_GPU="$BIN_DIR/fastp_d0bromir_gpu"
FALCO_CFG="$TOOLS_DIR/falco_config"

# Output CSV
RAW_CSV="$RESULTS_DIR/benchmark_results.csv"
printf "mode,application,fastq_file,num_cpus,time_sec\n" > "$RAW_CSV"

# ── Helper: verify tools exist ─────────────────────────────────────────────────
echo "=== Verifying tool binaries ==="
MISSING=0
for TOOL_BIN in "$FASTQC" "$FALCO" "$FASTP_OG" "$FASTP_CPU" "$FASTP_GPU"; do
    if [[ -x "$TOOL_BIN" ]]; then
        echo "  [OK]  $TOOL_BIN"
    else
        echo "  [MISSING]  $TOOL_BIN"
        MISSING=1
    fi
done
if [[ "$MISSING" -eq 1 ]]; then
    echo ""
    echo "ERROR: One or more tools missing. Run build scripts 02–05 first." >&2
    exit 1
fi

# ── File lists ─────────────────────────────────────────────────────────────────
SMALL_FILE="$HOME/FASTQ/S1A_S1_L001_R1_001.fastq.gz"

# WGS files: small, medium and large examples (select existing ones)
WGS_SMALL="$HOME/FASTQ/WGS/ERR1044906_1.fastq.gz"
WGS_MEDIUM="$HOME/FASTQ/WGS/ERR1044900_1.fastq.gz"
WGS_LARGE="$HOME/FASTQ/WGS/ERR1044320_1.fastq.gz"

# All small panel files (for FastQC multi-file -t test)
SMALL_FILES_GLOB=( "$HOME/FASTQ/"S*_R1_001.fastq.gz )

echo ""
echo "=== Input files ==="
for F in "$SMALL_FILE" "$WGS_SMALL" "$WGS_MEDIUM" "$WGS_LARGE"; do
    if [[ -f "$F" ]]; then
        SIZE=$(du -sh "$F" | cut -f1)
        echo "  [OK]  $F  ($SIZE)"
    else
        echo "  [MISSING]  $F"
    fi
done

# ── Thread count lists ─────────────────────────────────────────────────────────
FASTP_THREADS=(1 2 4 8 16 32)
FASTQC_MULTI_THREADS=(1 2 4 8)

# ── Timing helper ─────────────────────────────────────────────────────────────
#   run_timed <mode> <app> <file_label> <num_cpus> <n_reps> cmd...
#   Runs <cmd...> <n_reps> times, records wall time each run.
#   Appends rows to $RAW_CSV.
run_timed() {
    local mode="$1" app="$2" file_label="$3" num_cpus="$4" n_reps="$5"
    shift 5
    local cmd=("$@")

    echo "  → $app  threads=$num_cpus  file=$(basename "$file_label")  (${n_reps} rep(s))"
    for ((rep=1; rep<=n_reps; rep++)); do
        # Clean output temp dir before each rep (prevents report accumulation)
        rm -rf "$TMPOUT"/* 2>/dev/null; mkdir -p "$TMPOUT"

        # Drop OS page cache if possible (reduces caching advantage for repeated runs)
        sync && sudo sh -c 'echo 3 > /proc/sys/vm/drop_caches' 2>/dev/null || true

        # Time with nanosecond-resolution wall clock
        local start_s end_s elapsed
        start_s=$(date +%s%N)
        "${cmd[@]}" >/dev/null 2>&1
        end_s=$(date +%s%N)
        elapsed=$(echo "scale=3; ($end_s - $start_s) / 1000000000" | bc)

        printf "%s,%s,%s,%s,%s\n" \
            "$mode" "$app" "$(basename "$file_label")" "$num_cpus" "$elapsed" \
            >> "$RAW_CSV"
        echo "    rep $rep: ${elapsed}s"
    done
}

# Clean output temp dir between runs
clean_tmp() { rm -rf "$TMPOUT"/* ; mkdir -p "$TMPOUT"; }

# ──────────────────────────────────────────────────────────────────────────────
echo ""
echo "================================================================="
echo " BENCHMARK START  $(date '+%Y-%m-%d %H:%M:%S')"
echo "================================================================="

# ──────────────────────────────────────────────────────────────────────────────
# SECTION A: Single-file benchmarks
# ──────────────────────────────────────────────────────────────────────────
echo ""
echo "─── Section A: Single-file benchmarks ───────────────────────────"

for INPUT_FILE in "$SMALL_FILE" "$WGS_SMALL" "$WGS_MEDIUM" "$WGS_LARGE"; do
    [[ -f "$INPUT_FILE" ]] || { echo "  SKIP (file not found): $INPUT_FILE"; continue; }

    FSIZE=$(stat -c%s "$INPUT_FILE")
    # More reps for small files (fast), fewer for large WGS (slow)
    if (( FSIZE < 500000000 )); then
        NREPS=3
    else
        NREPS=1
    fi

    echo ""
    echo ">>> File: $INPUT_FILE  ($(du -sh "$INPUT_FILE" | cut -f1))"

    # ── FastQC (single file, -t 1; higher -t has no effect for 1 file) ──────
    echo "  [FastQC]"
    clean_tmp
    run_timed "cpu" "fastqc" "$INPUT_FILE" 1 "$NREPS" \
        "$FASTQC" -t 1 --noextract -q -o "$TMPOUT" "$INPUT_FILE"

    # ── Falco (single file, no threading) ────────────────────────────────────
    echo "  [Falco]"
    clean_tmp
    FALCO_EXTRA_ARGS=()
    [[ -f "$FALCO_CFG/contaminant_list.txt" ]] && \
        FALCO_EXTRA_ARGS+=(--contaminants "$FALCO_CFG/contaminant_list.txt")
    [[ -f "$FALCO_CFG/adapter_list.txt" ]] && \
        FALCO_EXTRA_ARGS+=( --adapters "$FALCO_CFG/adapter_list.txt")
    run_timed "cpu" "falco" "$INPUT_FILE" 1 "$NREPS" \
        "$FALCO" -q -o "$TMPOUT" "${FALCO_EXTRA_ARGS[@]}" "$INPUT_FILE"

    # ── fastp OpenGene – sweep -w ─────────────────────────────────────────────
    echo "  [fastp_opengene] sweeping -w 1..32"
    for W in "${FASTP_THREADS[@]}"; do
        clean_tmp
        run_timed "cpu" "fastp_opengene" "$INPUT_FILE" "$W" "$NREPS" \
            "$FASTP_OG" \
                -w "$W" \
                -i "$INPUT_FILE" \
                -o /dev/null \
                -h /dev/null \
                -j /dev/null
    done

    # ── fastp d0bromir CPU build – sweep -w ───────────────────────────────────
    echo "  [fastp_d0bromir CPU] sweeping -w 1..32"
    for W in "${FASTP_THREADS[@]}"; do
        clean_tmp
        run_timed "cpu" "fastp_d0bromir" "$INPUT_FILE" "$W" "$NREPS" \
            "$FASTP_CPU" \
                -w "$W" \
                -i "$INPUT_FILE" \
                -o /dev/null \
                -h /dev/null \
                -j /dev/null
    done

    # ── fastp d0bromir GPU build (full GPU auto-detected) – sweep -w ──────────
    echo "  [fastp_d0bromir GPU] sweeping -w 1..32"
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

done  # end INPUT_FILE loop

# ──────────────────────────────────────────────────────────────────────────────
# SECTION B: FastQC multi-file thread-scaling test
# (Pass all small panel FASTQ files; vary -t to show file-parallel speedup)
# ──────────────────────────────────────────────────────────────────────────────
echo ""
echo "─── Section B: FastQC multi-file -t scaling (panel FASTQ files) ─"
echo "    Files: ${SMALL_FILES_GLOB[*]}"

if [[ "${#SMALL_FILES_GLOB[@]}" -gt 1 ]]; then
    for T in "${FASTQC_MULTI_THREADS[@]}"; do
        clean_tmp
        run_timed "cpu" "fastqc_multifile" "panel_all_R1" "$T" 2 \
            "$FASTQC" -t "$T" --noextract -q -o "$TMPOUT" \
            "${SMALL_FILES_GLOB[@]}"
    done
else
    echo "  SKIP – not enough small panel FASTQ files found"
fi

# ──────────────────────────────────────────────────────────────────────────────
# SECTION C: d0bromir fastp – explicit CPU vs GPU comparison ( fixed -w )
# Run the same command with GPU binary in forced-CPU mode vs GPU mode
# Uses medium WGS file (more signal than small file)
# ──────────────────────────────────────────────────────────────────────────────
echo ""
echo "─── Section C: CPU vs GPU forced mode comparison (d0bromir) ─────"

if [[ -f "$WGS_SMALL" ]]; then
    for W in 4 8 16; do
        echo "  [d0bromir GPU binary, FORCED CPU via CUDA_VISIBLE_DEVICES='']  -w $W"
        clean_tmp
        run_timed "cpu_forced" "fastp_d0bromir_gpu_binary" "$WGS_SMALL" "$W" 1 \
            env CUDA_VISIBLE_DEVICES="" \
                "$FASTP_GPU" \
                    -w "$W" \
                    -i "$WGS_SMALL" \
                    -o /dev/null \
                    -h /dev/null \
                    -j /dev/null

        echo "  [d0bromir GPU binary, GPU mode]  -w $W"
        clean_tmp
        run_timed "gpu" "fastp_d0bromir_gpu_binary" "$WGS_SMALL" "$W" 1 \
            "$FASTP_GPU" \
                -w "$W" \
                -i "$WGS_SMALL" \
                -o /dev/null \
                -h /dev/null \
                -j /dev/null
    done
fi

# ──────────────────────────────────────────────────────────────────────────────
# Cleanup and summary
# ──────────────────────────────────────────────────────────────────────────────
rm -rf "$TMPOUT"

echo ""
echo "================================================================="
echo " BENCHMARK COMPLETE  $(date '+%Y-%m-%d %H:%M:%S')"
echo "================================================================="
echo ""
echo "Raw results : $RAW_CSV"
echo "Run the analysis script to produce formatted table:"
echo "  bash ~/benchmark/07_analyze_results.sh"
