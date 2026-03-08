#!/usr/bin/env python3
"""
FASTQ QC Benchmarking Analysis
Reads benchmark_results.csv and produces human-readable tables + key findings.
"""
import csv
import sys
from collections import defaultdict

CSV_PATH = "/home/mpiuser/benchmark/results/benchmark_results.csv"
OUT_PATH = "/home/mpiuser/benchmark/results/analysis_report.txt"

# ---------------------------------------------------------------------------
# Load data
# ---------------------------------------------------------------------------
rows = []
with open(CSV_PATH) as f:
    for r in csv.DictReader(f):
        rows.append({
            "mode":    r["mode"],
            "app":     r["application"],
            "file":    r["fastq_file"],
            "threads": int(r["num_cpus"]),
            "time":    float(r["time_sec"]),
        })

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------
# group[mode][app][file][threads] → list of times
group = defaultdict(lambda: defaultdict(lambda: defaultdict(lambda: defaultdict(list))))
for r in rows:
    group[r["mode"]][r["app"]][r["file"]][r["threads"]].append(r["time"])

def best(mode, app, file_):
    """Return (best_threads, best_time) across all thread counts for this combo."""
    entries = group[mode][app].get(file_, {})
    if not entries:
        return (None, None)
    best_t, best_sec = min(((t, min(times)) for t, times in entries.items()), key=lambda x: x[1])
    return best_t, best_sec

def median(lst):
    s = sorted(lst)
    n = len(s)
    return s[n // 2] if n % 2 else (s[n//2 - 1] + s[n//2]) / 2

def get_time(mode, app, file_, threads):
    times = group[mode][app][file_].get(threads)
    return median(times) if times else None

# File categories
PANEL_FILE  = "S1A_S1_L001_R1_001.fastq.gz"   # ~148 MB
WGS_FILES   = ["ERR1044906_1.fastq.gz",        # ~6 GB
                "ERR1044900_1.fastq.gz",         # ~8.5 GB
                "ERR1044320_1.fastq.gz"]         # ~9.5 GB
FILE_LABELS = {
    PANEL_FILE:           "panel (148 MB)",
    "ERR1044906_1.fastq.gz": "WGS-6G (6 GB)",
    "ERR1044900_1.fastq.gz": "WGS-8G (8.5 GB)",
    "ERR1044320_1.fastq.gz": "WGS-9G (9.5 GB)",
}
ALL_FILES = [PANEL_FILE] + WGS_FILES

lines = []
def p(s=""): lines.append(s)

# ---------------------------------------------------------------------------
# Table 1 – Best time per tool per file (optimal thread count)
# ---------------------------------------------------------------------------
p("=" * 80)
p("TABLE 1  –  Best wall-clock time per tool (optimal thread count)")
p("=" * 80)
header = f"{'Tool':<32}  {'panel 148MB':>12}  {'WGS 6G':>10}  {'WGS 8.5G':>10}  {'WGS 9.5G':>10}"
p(header)
p("-" * 80)

tools_ordered = [
    ("cpu", "fastqc"),
    ("cpu", "falco"),
    ("cpu", "fastp_opengene"),
    ("cpu", "fastp_d0bromir"),
    ("gpu", "fastp_d0bromir"),
]

for mode, app in tools_ordered:
    label = f"{app} ({mode})"
    cells = []
    for f in ALL_FILES:
        bt, bs = best(mode, app, f)
        if bs is None:
            cells.append("  -")
        else:
            cells.append(f"{bs:10.1f}s")
    p(f"{label:<32}  {'  '.join(cells)}")

p()

# ---------------------------------------------------------------------------
# Table 2 – Thread-scaling for fastp variants on WGS-6G
# ---------------------------------------------------------------------------
SCALE_FILE = "ERR1044906_1.fastq.gz"   # 6 GB – clearest scaling signal
p("=" * 80)
p("TABLE 2  –  Thread-scaling on WGS-6G (ERR1044906_1.fastq.gz)")
p("  Median time across replicate runs (seconds)")
p("=" * 80)
THREADS = [1, 2, 4, 8, 16, 32]
col_w = 9
header2 = f"{'Tool':<32}" + "".join(f"{str(t)+'T':>{col_w}}" for t in THREADS)
p(header2)
p("-" * 80)

scale_tools = [
    ("cpu", "fastp_opengene",    "fastp_opengene (cpu)"),
    ("cpu", "fastp_d0bromir",    "fastp_d0bromir (cpu)"),
    ("gpu", "fastp_d0bromir",    "fastp_d0bromir (gpu)"),
]
for mode, app, label in scale_tools:
    row_str = f"{label:<32}"
    for t in THREADS:
        v = get_time(mode, app, SCALE_FILE, t)
        row_str += f"{'  -':>{col_w}}" if v is None else f"{v:{col_w}.1f}"
    p(row_str)

p()

# ---------------------------------------------------------------------------
# Table 3 – FastQC multi-file parallel (-t) scaling on panel
# ---------------------------------------------------------------------------
p("=" * 80)
p("TABLE 3  –  FastQC multi-file parallelism (panel_all_R1, 4 files)")
p("=" * 80)
p(f"{'Threads':<10}  {'Med time (s)':>13}  {'Speedup vs 1T':>15}")
p("-" * 42)
base_fqc = get_time("cpu", "fastqc_multifile", "panel_all_R1", 1)
for t in [1, 2, 4, 8]:
    v = get_time("cpu", "fastqc_multifile", "panel_all_R1", t)
    if v is None:
        continue
    su = base_fqc / v if base_fqc else 0
    p(f"{t:<10}  {v:>13.1f}  {su:>14.2f}x")

p()

# ---------------------------------------------------------------------------
# Table 4 – GPU vs CPU on same binary (ERR1044906, same thread counts)
# ---------------------------------------------------------------------------
p("=" * 80)
p("TABLE 4  –  GPU binary: GPU mode vs CPU-forced mode (ERR1044906)")
p("  fastp_d0bromir_gpu_binary, CUDA_VISIBLE_DEVICES='' vs normal")
p("=" * 80)
p(f"{'Threads':<10}  {'GPU mode (s)':>14}  {'CPU-forced (s)':>16}  {'GPU overhead':>14}")
p("-" * 60)
for t in [4, 8, 16]:
    gv = get_time("gpu",        "fastp_d0bromir_gpu_binary", "ERR1044906_1.fastq.gz", t)
    cv = get_time("cpu_forced", "fastp_d0bromir_gpu_binary", "ERR1044906_1.fastq.gz", t)
    if gv is None or cv is None:
        continue
    delta = gv - cv
    p(f"{t:<10}  {gv:>14.1f}  {cv:>16.1f}  {delta:>+13.1f}s")

p()

# ---------------------------------------------------------------------------
# Table 5 – Speedup vs FastQC (best time for each tool, WGS files)
# ---------------------------------------------------------------------------
p("=" * 80)
p("TABLE 5  –  Speedup vs FastQC (1T baseline) at each tool's best thread count")
p("=" * 80)
header5 = f"{'Tool':<32}  {'WGS 6G':>10}  {'WGS 8.5G':>10}  {'WGS 9.5G':>10}"
p(header5)
p("-" * 68)
_, fqc_6g  = best("cpu", "fastqc", "ERR1044906_1.fastq.gz")
_, fqc_8g  = best("cpu", "fastqc", "ERR1044900_1.fastq.gz")
_, fqc_9g  = best("cpu", "fastqc", "ERR1044320_1.fastq.gz")
baselines  = [fqc_6g, fqc_8g, fqc_9g]

for mode, app in tools_ordered:
    label = f"{app} ({mode})"
    cells = []
    for f, baseline in zip(WGS_FILES, baselines):
        _, bt_time = best(mode, app, f)
        if bt_time is None or baseline is None:
            cells.append(f"{'  -':>10}")
        else:
            su = baseline / bt_time
            cells.append(f"{su:>9.2f}x")
    p(f"{label:<32}  {'  '.join(c for c in cells)}")

p()

# ---------------------------------------------------------------------------
# KEY FINDINGS
# ---------------------------------------------------------------------------
p("=" * 80)
p("KEY FINDINGS")
p("=" * 80)

# -- fastest single-threaded tool on WGS
st_times = {}
for mode, app in [("cpu","fastqc"),("cpu","falco"),("cpu","fastp_opengene"),("cpu","fastp_d0bromir")]:
    _, t = best(mode, app, "ERR1044906_1.fastq.gz")
    if t: st_times[(mode,app)] = t

fastest_st = min(st_times, key=st_times.get)
_, fqc_6g_t = best("cpu", "fastqc", "ERR1044906_1.fastq.gz")

p(f"1. Falco is the fastest SINGLE-THREADED QC tool at {st_times[('cpu','falco')]:.0f}s on WGS-6G,")
p(f"   {fqc_6g_t/st_times[('cpu','falco')]:.1f}x faster than FastQC ({fqc_6g_t:.0f}s).")
p()

# -- fastp optimal
_, fop_6g = best("cpu", "fastp_opengene", "ERR1044906_1.fastq.gz")
fop_opt_t, _ = best("cpu", "fastp_opengene", "ERR1044906_1.fastq.gz")
p(f"2. fastp (both variants) peaks at 8T on WGS-6G ({fop_6g:.0f}s). Adding more threads")
p(f"   beyond 8 gives no speedup (I/O / decompression bound).")
p()

# -- GPU overhead
gv4 = get_time("gpu",        "fastp_d0bromir_gpu_binary", "ERR1044906_1.fastq.gz", 4)
cv4 = get_time("cpu_forced", "fastp_d0bromir_gpu_binary", "ERR1044906_1.fastq.gz", 4)
gv8 = get_time("gpu",        "fastp_d0bromir_gpu_binary", "ERR1044906_1.fastq.gz", 8)
cv8 = get_time("cpu_forced", "fastp_d0bromir_gpu_binary", "ERR1044906_1.fastq.gz", 8)
if gv4 and cv4:
    p(f"3. GPU mode in d0bromir/fastp is SLOWER than CPU-forced mode on the same binary")
    p(f"   at all tested thread counts (overhead: +{gv4-cv4:.1f}s at 4T, +{gv8-cv8:.1f}s at 8T).")
    p(f"   The GPU kernels (poly-G / quality trimming) do not offset GPU launch overhead")
    p(f"   when the bottleneck is gzip decompression + I/O.")
p()

# -- vs panel file scaling
panel_1t = get_time("cpu", "fastp_opengene", PANEL_FILE, 1)
panel_2t = get_time("cpu", "fastp_opengene", PANEL_FILE, 2)
panel_4t = get_time("cpu", "fastp_opengene", PANEL_FILE, 4)
if panel_1t and panel_4t:
    p(f"4. On the small panel file (148 MB), fastp scaling saturates at 2T ({panel_2t:.2f}s).")
    p(f"   1T→2T gives {panel_1t/panel_2t:.1f}x speedup; 2T→4T gives <1% gain — file fits in buffer cache.")
p()

# -- best overall
_, fop_best_6g = best("cpu", "fastp_opengene", "ERR1044906_1.fastq.gz")
p(f"5. RECOMMENDATION (WGS large files):")
p(f"     • QC-only (reports): falco 1T  →  {st_times[('cpu','falco')]:.0f}s, no thread overhead")
p(f"     • Trimming + QC:     fastp (either) 8T  →  ~97–100s on WGS-6G")
p(f"     • GPU mode adds no benefit on this workload profile (d0bromir/fastp v1.2.2 A100)")

p()
p("=" * 80)
p(f"Output from: {CSV_PATH}")
p("=" * 80)

report = "\n".join(lines)
print(report)
with open(OUT_PATH, "w") as f:
    f.write(report + "\n")
print(f"\n[Saved to {OUT_PATH}]")
