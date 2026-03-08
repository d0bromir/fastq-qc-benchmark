#!/usr/bin/env bash
# =============================================================================
# validate_gpu_correctness.sh
#
# For each benchmark input file, runs both:
#   (A) fastp_d0bromir_cpu  -- original CPU-only build
#   (B) fastp_d0bromir_gpu  -- modified GPU-augmented build (GPU mode active)
#
# with identical settings and -w 8, then:
#   1. Saves JSON statistics from both runs
#   2. Compares key stats (read counts, pass/fail, Q20/Q30 bases, GC%)
#   3. For the small Panel file also compares actual FASTQ output byte-for-byte
#   4. Emits a PASS/FAIL verdict per file and an overall summary
#
# Output: results/validation/
# =============================================================================
set -euo pipefail

CPU_BIN="$HOME/tools/bin/fastp_d0bromir_cpu"
GPU_BIN="$HOME/tools/bin/fastp_d0bromir_gpu"

PANEL="$HOME/FASTQ/S1A_S1_L001_R1_001.fastq.gz"
WGS6G="$HOME/FASTQ/WGS/ERR1044906_1.fastq.gz"
WGS8G="$HOME/FASTQ/WGS/ERR1044900_1.fastq.gz"
WGS9G="$HOME/FASTQ/WGS/ERR1044320_1.fastq.gz"

THREADS=8
OUTDIR="$HOME/benchmark/results/validation"
mkdir -p "$OUTDIR"
LOG="$OUTDIR/validation_run.log"
REPORT="$OUTDIR/validation_report.txt"

exec > >(tee -a "$LOG") 2>&1

echo "=============================================================="
echo " fastp GPU correctness validation — $(date -u)"
echo " CPU: $CPU_BIN"
echo " GPU: $GPU_BIN"
echo " Threads: $THREADS"
echo "=============================================================="
echo ""

PASS=0
FAIL=0

# ── Helper: extract a numeric value from fastp JSON ──────────────────────────
jget() {
    # jget <json_file> <key_path> (simple grep-based; works without jq)
    grep -o "\"${2}\":[^,}]*" "$1" | head -1 | grep -o '[0-9.]*$'
}

# ── Run one file ──────────────────────────────────────────────────────────────
run_and_compare() {
    local label="$1"
    local input="$2"
    local compare_fastq="$3"   # "yes" to also diff actual FASTQ output

    echo "--------------------------------------------------------------"
    echo "FILE: $label"
    echo "      $input"
    echo ""

    local cpu_json="$OUTDIR/${label}_cpu.json"
    local gpu_json="$OUTDIR/${label}_gpu.json"
    local cpu_html="$OUTDIR/${label}_cpu.html"
    local gpu_html="$OUTDIR/${label}_gpu.html"
    local cpu_out="$OUTDIR/${label}_cpu.fastq.gz"
    local gpu_out="$OUTDIR/${label}_gpu.fastq.gz"

    # ── CPU run ──
    echo "[CPU] running..."
    local t0=$(date +%s%N)
    if [ "$compare_fastq" = "yes" ]; then
        "$CPU_BIN" -w "$THREADS" \
            -i "$input" \
            -o "$cpu_out" \
            -j "$cpu_json" -h "$cpu_html" \
            2>>"$OUTDIR/${label}_cpu_stderr.log"
    else
        "$CPU_BIN" -w "$THREADS" \
            -i "$input" \
            -o /dev/null \
            -j "$cpu_json" -h "$cpu_html" \
            2>>"$OUTDIR/${label}_cpu_stderr.log"
    fi
    local t1=$(date +%s%N)
    local cpu_s=$(( (t1 - t0) / 1000000000 ))
    echo "[CPU] done in ${cpu_s}s"

    # ── GPU run ──
    echo "[GPU] running..."
    t0=$(date +%s%N)
    if [ "$compare_fastq" = "yes" ]; then
        "$GPU_BIN" -w "$THREADS" \
            -i "$input" \
            -o "$gpu_out" \
            -j "$gpu_json" -h "$gpu_html" \
            2>>"$OUTDIR/${label}_gpu_stderr.log"
    else
        "$GPU_BIN" -w "$THREADS" \
            -i "$input" \
            -o /dev/null \
            -j "$gpu_json" -h "$gpu_html" \
            2>>"$OUTDIR/${label}_gpu_stderr.log"
    fi
    t1=$(date +%s%N)
    local gpu_s=$(( (t1 - t0) / 1000000000 ))
    echo "[GPU] done in ${gpu_s}s"

    echo ""

    # ── Compare JSON statistics ───────────────────────────────────────────────
    local file_pass=1

    compare_stat() {
        local stat_name="$1"
        local cpu_val gpu_val
        # jq-free: parse the summary block from fastp JSON
        cpu_val=$(python3 -c "
import json,sys
d=json.load(open('$cpu_json'))
keys='$stat_name'.split('.')
v=d
for k in keys: v=v[k]
print(v)
" 2>/dev/null || echo "N/A")
        gpu_val=$(python3 -c "
import json,sys
d=json.load(open('$gpu_json'))
keys='$stat_name'.split('.')
v=d
for k in keys: v=v[k]
print(v)
" 2>/dev/null || echo "N/A")

        if [ "$cpu_val" = "N/A" ] || [ "$gpu_val" = "N/A" ]; then
            echo "  SKIP  $stat_name  (key not found)"
            return
        fi

        # For float comparison allow 0.01% relative tolerance
        local match
        match=$(python3 -c "
a,b=float('$cpu_val'),float('$gpu_val')
if a==0 and b==0:
    print('OK')
elif a==0:
    print('FAIL')
elif abs(a-b)/abs(a) < 1e-4:
    print('OK')
else:
    print('FAIL')
" 2>/dev/null || echo "FAIL")

        if [ "$match" = "OK" ]; then
            printf "  PASS  %-55s  cpu=%-15s gpu=%s\n" "$stat_name" "$cpu_val" "$gpu_val"
        else
            printf "  FAIL  %-55s  cpu=%-15s gpu=%s\n" "$stat_name" "$cpu_val" "$gpu_val"
            file_pass=0
        fi
    }

    # Summary fields — fastp JSON structure: summary.before_filtering / after_filtering
    compare_stat "summary.before_filtering.total_reads"
    compare_stat "summary.before_filtering.total_bases"
    compare_stat "summary.before_filtering.q20_bases"
    compare_stat "summary.before_filtering.q30_bases"
    compare_stat "summary.before_filtering.q20_rate"
    compare_stat "summary.before_filtering.q30_rate"
    compare_stat "summary.before_filtering.gc_content"
    compare_stat "summary.after_filtering.total_reads"
    compare_stat "summary.after_filtering.total_bases"
    compare_stat "summary.after_filtering.q20_bases"
    compare_stat "summary.after_filtering.q30_bases"
    compare_stat "summary.after_filtering.q20_rate"
    compare_stat "summary.after_filtering.q30_rate"
    compare_stat "filtering_result.passed_filter_reads"
    compare_stat "filtering_result.low_quality_reads"
    compare_stat "filtering_result.too_many_N_reads"
    compare_stat "filtering_result.too_short_reads"
    compare_stat "filtering_result.too_long_reads"

    # ── FASTQ byte comparison (Panel only) ───────────────────────────────────
    if [ "$compare_fastq" = "yes" ] && [ -f "$cpu_out" ] && [ -f "$gpu_out" ]; then
        echo ""
        echo "  [FASTQ diff] decompressing and comparing output..."
        local cpu_sum gpu_sum
        cpu_sum=$(zcat "$cpu_out" | md5sum | cut -d' ' -f1)
        gpu_sum=$(zcat "$gpu_out" | md5sum | cut -d' ' -f1)
        if [ "$cpu_sum" = "$gpu_sum" ]; then
            echo "  PASS  FASTQ output MD5 IDENTICAL  ($cpu_sum)"
        else
            echo "  WARN  FASTQ MD5 differs (may be benign if read order differs)"
            echo "        cpu_md5=$cpu_sum"
            echo "        gpu_md5=$gpu_sum"
            # Deep check: sort reads and compare
            local cpu_reads gpu_reads
            cpu_reads=$(zcat "$cpu_out" | paste - - - - | sort | md5sum | cut -d' ' -f1)
            gpu_reads=$(zcat "$gpu_out" | paste - - - - | sort | md5sum | cut -d' ' -f1)
            if [ "$cpu_reads" = "$gpu_reads" ]; then
                echo "  PASS  FASTQ read content IDENTICAL after sort ($cpu_reads)"
            else
                echo "  FAIL  FASTQ read content DIFFERS after sort"
                echo "        cpu_sorted_md5=$cpu_reads"
                echo "        gpu_sorted_md5=$gpu_reads"
                file_pass=0
            fi
        fi
    fi

    echo ""
    if [ $file_pass -eq 1 ]; then
        echo "  RESULT: PASS  $label"
        PASS=$(( PASS + 1 ))
    else
        echo "  RESULT: FAIL  $label"
        FAIL=$(( FAIL + 1 ))
    fi
    echo ""
}

# ── Run all four test files ───────────────────────────────────────────────────
run_and_compare "panel_S1A_R1"   "$PANEL"  "yes"
run_and_compare "wgs_6G_ERR1044906" "$WGS6G" "no"
run_and_compare "wgs_8G_ERR1044900" "$WGS8G" "no"
run_and_compare "wgs_9G_ERR1044320" "$WGS9G" "no"

# ── Overall summary ───────────────────────────────────────────────────────────
echo "=============================================================="
echo " VALIDATION SUMMARY"
echo " PASS: $PASS / $((PASS+FAIL))   FAIL: $FAIL / $((PASS+FAIL))"
echo " Completed: $(date -u)"
echo "=============================================================="

# Write terse report
{
echo "# fastp GPU Correctness Validation Report"
echo "# Generated: $(date -u)"
echo "# CPU binary: $CPU_BIN"
echo "# GPU binary: $GPU_BIN"
echo "# Threads: $THREADS"
echo "#"
echo "# Files tested:"
echo "#   Panel  148 MB  $PANEL"
echo "#   WGS-6G  6.0 GB  $WGS6G"
echo "#   WGS-8G  8.5 GB  $WGS8G"
echo "#   WGS-9G  9.5 GB  $WGS9G"
echo "#"
echo "# OVERALL: PASS=$PASS  FAIL=$FAIL"
echo "#"
echo "# See validation_run.log for per-stat details."
echo "# JSON reports: results/validation/<file>_{cpu,gpu}.json"
} > "$REPORT"

if [ $FAIL -gt 0 ]; then
    echo "SOME TESTS FAILED — see $LOG"
    exit 1
fi
echo "All tests passed."
