#!/usr/bin/env bash
# =============================================================================
# 07_analyze_results.sh
# Parse benchmark_results.csv and produce:
#   1. benchmark_summary.csv  – best (minimum) time per combination
#   2. benchmark_table.txt    – human-readable formatted table
#   3. optimal_threads.txt    – for each (mode+app+file), the -w that gave min time
#
# Also prints the table to stdout.
# Requires: awk, sort  (standard on Linux)
# =============================================================================
set -euo pipefail

RESULTS_DIR="$HOME/benchmark/results"
RAW_CSV="$RESULTS_DIR/benchmark_results.csv"
SUMMARY_CSV="$RESULTS_DIR/benchmark_summary.csv"
TABLE_TXT="$RESULTS_DIR/benchmark_table.txt"
OPTIMAL_TXT="$RESULTS_DIR/optimal_threads.txt"

if [[ ! -f "$RAW_CSV" ]]; then
    echo "ERROR: $RAW_CSV not found. Run 06_run_benchmarks.sh first." >&2
    exit 1
fi

echo "=== Analysing benchmark results ==="
echo "Input  : $RAW_CSV"
echo "Entries: $(tail -n +2 "$RAW_CSV" | wc -l)"
echo ""

# ── 1. Compute min time per (mode, app, file, num_cpus) ──────────────────────
# Skip header, group by first 4 fields, pick min of field 5
awk -F',' '
NR==1 { next }          # skip header
{
    key = $1 "," $2 "," $3 "," $4
    t = $5 + 0
    if (!(key in min_t) || t < min_t[key]) {
        min_t[key] = t
    }
}
END {
    print "mode,application,fastq_file,num_cpus,time_sec"
    for (k in min_t)
        print k "," min_t[k]
}
' "$RAW_CSV" | sort -t',' -k1,1 -k2,2 -k3,3 -k4,4n > "$SUMMARY_CSV"

echo "Summary CSV : $SUMMARY_CSV"

# ── 2. Pretty-print table ─────────────────────────────────────────────────────
{
printf "%-15s %-25s %-45s %-10s %-12s\n" \
       "mode" "application" "fastq_file" "num_cpus" "time_sec"
printf '%0.1s' "-"{1..110}; printf '\n'

awk -F',' '
NR==1 { next }
{
    printf "%-15s %-25s %-45s %-10s %-12s\n", $1,$2,$3,$4,$5
}
' "$SUMMARY_CSV"
} | tee "$TABLE_TXT"

echo ""
echo "Table saved : $TABLE_TXT"

# ── 3. Find optimal thread count per (mode+app+file) ─────────────────────────
awk -F',' '
NR==1 { next }
{
    # group key — without num_cpus
    gkey = $1 "," $2 "," $3
    t = $5 + 0
    if (!(gkey in min_t) || t < min_t[gkey]) {
        min_t[gkey] = t
        best_cpu[gkey] = $4
    }
}
END {
    printf "%-15s %-25s %-45s %-12s %-12s\n",
           "mode","application","fastq_file","optimal_cpus","best_time_sec"
    printf "%0.1s","-";
    for(i=1;i<=110;i++) printf "-"; printf "\n"
    for (k in min_t)
        printf "%-15s %-25s %-45s %-12s %-12s\n",
               gensub(/,/, "\t,\t", "g", k),  # placeholder split
               k, best_cpu[k], min_t[k]
}
' "$SUMMARY_CSV" 2>/dev/null || \

awk -F',' '
NR==1 { next }
{
    gkey = $1 SUBSEP $2 SUBSEP $3
    t = $5 + 0
    if (!(gkey in min_t) || t < min_t[gkey]) {
        min_t[gkey] = t
        best_cpu[gkey] = $4
        best_mode[gkey] = $1
        best_app[gkey]  = $2
        best_file[gkey] = $3
    }
}
END {
    print "mode,application,fastq_file,optimal_cpus,best_time_sec"
    for (k in min_t)
        printf "%s,%s,%s,%s,%s\n",
               best_mode[k], best_app[k], best_file[k], best_cpu[k], min_t[k]
}
' "$SUMMARY_CSV" | sort -t',' -k1 -k2 -k3 | tee "$OPTIMAL_TXT"

echo ""
echo "Optimal thread counts: $OPTIMAL_TXT"
echo ""
echo "All output files:"
echo "  Raw data       : $RAW_CSV"
echo "  Summary (min)  : $SUMMARY_CSV"
echo "  Formatted table: $TABLE_TXT"
echo "  Optimal threads: $OPTIMAL_TXT"
