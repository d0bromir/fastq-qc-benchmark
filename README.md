# FASTQ QC Benchmarking — ARM HPC + NVIDIA A100

> **Associated publication:**  
> *Benchmarking FASTQ Quality Control Tools on ARM HPC Hardware with GPU Acceleration: A Comparative Performance Study*  
> PhD research, March 2026.  
> Full paper: [`paper/main.pdf`](paper/main.pdf) · Source: [`paper/main.tex`](paper/main.tex)

---

## Overview

A reproducible benchmarking suite comparing four FASTQ quality-control tools
across multiple file sizes, thread counts, and compute modes (CPU / GPU) on a
128-core ARM Neoverse N2 server with dual NVIDIA A100-80GB GPUs.

| Tool | Version | Mode | Language |
|------|---------|------|----------|
| [FastQC](https://github.com/s-andrews/FastQC) | 0.12.1 | CPU (multi-file `-t N`) | Java |
| [Falco](https://github.com/smithlabcode/falco) | 1.2.4 | CPU (single-threaded) | C++ |
| [fastp](https://github.com/OpenGene/fastp) (OpenGene) | 0.23.4 | CPU (`-w N`) | C++ |
| [fastp](https://github.com/d0bromir/fastp) (d0bromir) | 1.2.2 | CPU + GPU (CUDA) | C++/CUDA |

---

## Hardware

| Component | Specification |
|-----------|---------------|
| Architecture | ARM AArch64 (Neoverse N2) |
| CPU logical cores | 128 |
| System RAM | 246 GiB |
| GPU | 2 × NVIDIA A100-SXM4 80 GB (Compute Capability 8.0) |
| OS | Ubuntu 25.10 aarch64 |
| CUDA Toolkit | 13.1 |
| Driver | 590.48.01 |

---

## Key Results

### Best wall-clock time per tool (optimal thread count)

| Tool (mode) | Panel 148 MB | WGS 6 GB | WGS 8.5 GB | WGS 9.5 GB |
|-------------|:------------:|:--------:|:----------:|:----------:|
| FastQC (CPU, 1T) | 15.3 s | 434 s | 635 s | 704 s |
| Falco (CPU, 1T) | 6.6 s | 250 s | 367 s | 412 s |
| fastp OpenGene (CPU, 8T) | **3.8 s** | **97 s** | **145 s** | **158 s** |
| fastp d0bromir (CPU, 16T) | 3.8 s | 100 s | 146 s | 160 s |
| fastp d0bromir **(GPU, 16T)** | 7.3 s | 104 s | 150 s | 164 s |

### Speedup vs FastQC baseline

| Tool | WGS 6 GB | WGS 8.5 GB | WGS 9.5 GB |
|------|:--------:|:----------:|:----------:|
| Falco (1T) | 1.73× | 1.73× | 1.71× |
| fastp OpenGene (8T) | **4.49×** | 4.39× | **4.46×** |
| fastp d0bromir CPU (16T) | 4.36× | 4.36× | 4.39× |
| fastp d0bromir GPU (16T) | 4.20× | 4.22× | 4.30× |

### Key findings

1. **Falco** is the fastest single-threaded QC-only tool — 1.7× faster than FastQC with identical HTML output.
2. **fastp saturates at 8 worker threads** on WGS files; beyond 8T the gzip decompression bottleneck prevents further speedup.
3. **GPU mode adds ~1.5 s overhead** at every tested thread count on the A100. GPU kernel launch latency consistently exceeds the savings from CUDA-accelerated quality scoring at this workload's arithmetic intensity.
4. On the **small panel file (148 MB)**, the GPU binary is 2× *slower* than CPU due to fixed CUDA context initialisation cost (~3 s).

---

## Repository Layout

```
benchmark/
├── 01_install_deps.sh          # Install system deps (CUDA, libisal, libdeflate, Java)
├── 02_build_fastqc.sh          # Build FastQC from source
├── 03_build_falco.sh           # Build Falco from source
├── 04_build_opengene_fastp.sh  # Build fastp (OpenGene) from source
├── 05_build_gpu_fastp.sh       # Build fastp (d0bromir) — CPU + GPU binaries
├── 06_run_benchmarks.sh        # Run all benchmarks (thread sweep, GPU vs CPU)
├── 07_analyze_results.sh       # Shell-based results summary
├── 08_analyze_python.py        # Python analysis — all paper tables
│
├── results/
│   ├── benchmark_results.csv   # Raw timings (all 134 runs)
│   ├── benchmark_summary.csv   # Min time per (mode, tool, file, threads)
│   ├── benchmark_table.txt     # Human-readable aligned table
│   ├── optimal_threads.txt     # Best thread count per configuration
│   └── analysis_report.txt     # Full analysis report (text)
│
└── paper/
    ├── main.tex                # LaTeX source (full scientific paper)
    ├── main.pdf                # Compiled PDF (23 pages)
    └── Makefile                # Build: cd paper && make
```

---

## Reproducing the Benchmarks

> **Requirements:** Ubuntu 22.04+ aarch64, NVIDIA GPU with driver >= 525, ~50 GB free disk.

```bash
# 1. Clone this repo
git clone https://github.com/d0bromir/fastq-qc-benchmark.git
cd fastq-qc-benchmark

# 2. Install dependencies (~5 min)
bash 01_install_deps.sh

# 3. Build all tools from source (~10 min)
bash 02_build_fastqc.sh
bash 03_build_falco.sh
bash 04_build_opengene_fastp.sh
bash 05_build_gpu_fastp.sh        # builds both CPU and GPU binaries

# 4. Download input FASTQ files (ENA accessions: ERR1044906, ERR1044900, ERR1044320)
mkdir -p ~/FASTQ/WGS
# Use ena-file-downloader or wget from ENA FTP

# 5. Run benchmarks (may take several hours for WGS files)
bash 06_run_benchmarks.sh

# 6. Analyse results
python3 08_analyze_python.py
```

Binaries are installed to `~/tools/bin/`. Results land in `results/`.

### CUDA Build Notes (aarch64 / glibc 2.41)

Building the GPU fastp fork on Ubuntu 25.10 requires two workarounds:

1. **Host compiler**: pass `-ccbin g++-13` to nvcc — GCC 15.x is not yet supported by CUDA 13.1.
2. **glibc 2.41 / CUDA 13.1 conflict**: `bits/mathcalls.h` declares `rsqrt()`/`rsqrtf()` with `noexcept(true)` while CUDA's `crt/math_functions.h` omits it, causing a hard C++ error. Fix: add `noexcept` to both declarations in the CUDA system header.

Both patches are applied automatically by `05_build_gpu_fastp.sh`.

---

## Input Datasets

| ID | ENA Accession | Type | Compressed |
|----|---------------|------|-----------|
| Panel | S1A_S1_L001_R1 | Targeted panel, Illumina PE | 148 MB |
| WGS-6G | [ERR1044906](https://www.ebi.ac.uk/ena/browser/view/ERR1044906) | Human WGS, PE 150 bp | 6.0 GB |
| WGS-8G | [ERR1044900](https://www.ebi.ac.uk/ena/browser/view/ERR1044900) | Human WGS, PE 150 bp | 8.5 GB |
| WGS-9G | [ERR1044320](https://www.ebi.ac.uk/ena/browser/view/ERR1044320) | Human WGS, PE 150 bp | 9.5 GB |

All WGS reads are from ENA project [PRJEB10929](https://www.ebi.ac.uk/ena/browser/view/PRJEB10929).

---

## Compiling the Paper

```bash
# Requires: texlive-latex-extra texlive-science texlive-fonts-recommended
cd paper
make          # produces main.pdf (23 pages)
```

---

## Citation

If you use these benchmark results or scripts in your work, please cite:

```
[Author]. (2026). Benchmarking FASTQ Quality Control Tools on ARM HPC Hardware
with GPU Acceleration. PhD research, [Institution].
https://github.com/d0bromir/fastq-qc-benchmark
```

---

## License

Scripts and analysis code: MIT License.
Paper (main.tex / main.pdf): All rights reserved — PhD thesis material.
