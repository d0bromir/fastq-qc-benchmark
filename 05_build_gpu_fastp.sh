#!/usr/bin/env bash
# =============================================================================
# 05_build_gpu_fastp.sh
# Build BOTH CPU-only and GPU-accelerated variants of d0bromir/fastp.
#
# Source: https://github.com/d0bromir/fastp
# License: MIT (based on OpenGene fastp)
#
# GPU enhancements in d0bromir fork
# ----------------------------------
# • CUDA kernel (cuda_stats.cu): parallelises per-read statistics across GPU threads
#   – 256 CUDA threads/block, one thread per read, ~5-10× faster stat computation
#   – Batch size 4096 reads transferred to GPU memory at once
# • Filter::filterBatchGPU() replaces serial per-read quality checks
# • CPU fallback: if GPU unavailable at runtime, automatically uses CPU path
# • Transparent: same CLI flags as OpenGene fastp (add -w for worker threads)
#
# Binaries produced
# -----------------
#   ~/tools/bin/fastp_d0bromir_cpu   – CPU-only build (no CUDA dependency at runtime)
#   ~/tools/bin/fastp_d0bromir_gpu   – CUDA-enabled build (requires CUDA runtime)
#
# GPU spec: NVIDIA A100 80GB PCIe  →  Compute Capability 8.0  →  CUDA_ARCH=80
#
# CPU mode at run time:  CUDA_VISIBLE_DEVICES="" ./fastp_d0bromir_gpu ...
# GPU mode at run time:  ./fastp_d0bromir_gpu ...  (GPU auto-detected)
# =============================================================================
set -euo pipefail

TOOLS_DIR="$HOME/tools"
SRC_DIR="$TOOLS_DIR/src/fastp_d0bromir"
BIN_DIR="$TOOLS_DIR/bin"
mkdir -p "$BIN_DIR"

# NVIDIA A100 Compute Capability
CUDA_ARCH=80

# ── Resolve CUDA toolkit path ─────────────────────────────────────────────────
CUDA_PATH=""
for candidate in /usr/local/cuda /usr/local/cuda-12 /usr/local/cuda-12.6 \
                  /usr/local/cuda-12.5 /usr/local/cuda-12.4; do
    if [[ -x "$candidate/bin/nvcc" ]]; then
        CUDA_PATH="$candidate"
        break
    fi
done
if [[ -z "$CUDA_PATH" ]]; then
    echo "WARNING: nvcc not found – GPU build will be skipped." >&2
    GPU_AVAILABLE=0
else
    export PATH="$CUDA_PATH/bin:$PATH"
    export LD_LIBRARY_PATH="$CUDA_PATH/lib64:${LD_LIBRARY_PATH:-}"
    echo ">>> CUDA toolkit: $CUDA_PATH"
    echo ">>> nvcc: $(nvcc --version 2>&1 | grep release | tr -d '\n')"
    GPU_AVAILABLE=1
fi

# ── Clone ─────────────────────────────────────────────────────────────────────
if [[ -d "$SRC_DIR" ]]; then
    echo ">>> Source directory exists – pulling latest changes"
    cd "$SRC_DIR" && git pull
else
    echo ">>> Cloning d0bromir/fastp"
    git clone --depth 1 https://github.com/d0bromir/fastp.git "$SRC_DIR"
fi
cd "$SRC_DIR"
echo ">>> Source: $SRC_DIR  (commit: $(git rev-parse --short HEAD))"

# ─────────────────────────────────────────────────────────────────────────────
# Build 1: CPU-only (Makefile, no CUDA)
# ─────────────────────────────────────────────────────────────────────────────
echo ""
echo "=== [1/2] Building CPU-only variant ==="
make clean >/dev/null 2>&1 || true
make -j"$(nproc)" CXXFLAGS="-O3 -march=native" 2>&1

# Verify
if [[ ! -f "$SRC_DIR/fastp" ]]; then
    echo "ERROR: CPU build failed – fastp binary not found" >&2
    exit 1
fi
cp "$SRC_DIR/fastp" "$BIN_DIR/fastp_d0bromir_cpu"
chmod +x "$BIN_DIR/fastp_d0bromir_cpu"
echo ">>> CPU binary: $BIN_DIR/fastp_d0bromir_cpu"

# ─────────────────────────────────────────────────────────────────────────────
# Build 2: GPU-accelerated (CMake for precise CUDA arch selection)
# ─────────────────────────────────────────────────────────────────────────────
echo ""
echo "=== [2/2] Building GPU-accelerated variant (CUDA_ARCH=${CUDA_ARCH}) ==="

if [[ "$GPU_AVAILABLE" -eq 0 ]]; then
    echo "WARNING: Skipping GPU build – nvcc not found."
    echo "         Install CUDA toolkit and rerun this script."
    # Create placeholder that falls back gracefully
    cp "$BIN_DIR/fastp_d0bromir_cpu" "$BIN_DIR/fastp_d0bromir_gpu"
    echo ">>> GPU binary placeholder: $BIN_DIR/fastp_d0bromir_gpu (CPU-only fallback)"
else
    # Use Makefile WITH_CUDA=1 (simpler than CMake, same result)
    make clean >/dev/null 2>&1 || true
    # NOTE: do NOT pass CXXFLAGS= here – command-line Make variables override all
    # Makefile := assignments, which would suppress -DHAVE_CUDA.  The Makefile
    # already appends -DHAVE_CUDA when CUDA_ENABLED=1.  Add -march=native via the
    # EXTRA_OPT variable (no-op if Makefile ignores it) or accept the Makefile's
    # built-in -O3.
    make -j"$(nproc)" \
        WITH_CUDA=1 \
        NVCC_ARCH_FLAGS="-gencode arch=compute_${CUDA_ARCH},code=sm_${CUDA_ARCH} -gencode arch=compute_${CUDA_ARCH},code=compute_${CUDA_ARCH}" \
        2>&1

    if [[ ! -f "$SRC_DIR/fastp" ]]; then
        echo "WARNING: GPU build via Makefile failed – falling back to CMake approach"
        # CMake fallback
        BUILD_DIR="$SRC_DIR/build_cuda"
        rm -rf "$BUILD_DIR"
        mkdir -p "$BUILD_DIR"
        cd "$BUILD_DIR"
        cmake \
            -DCUDA_ARCH="${CUDA_ARCH}" \
            -DCMAKE_CXX_FLAGS="-O3 -march=native" \
            -DCMAKE_CUDA_FLAGS="-O3" \
            -DCMAKE_INSTALL_PREFIX="$TOOLS_DIR/fastp_gpu_install" \
            .. 2>&1
        make -j"$(nproc)" 2>&1
        cd "$SRC_DIR"
        GPU_BIN="$BUILD_DIR/fastp"
    else
        GPU_BIN="$SRC_DIR/fastp"
    fi

    cp "$GPU_BIN" "$BIN_DIR/fastp_d0bromir_gpu"
    chmod +x "$BIN_DIR/fastp_d0bromir_gpu"
    echo ">>> GPU binary: $BIN_DIR/fastp_d0bromir_gpu"
fi

# ── Verify both binaries ───────────────────────────────────────────────────────
echo ""
echo "=== d0bromir/fastp build complete ==="
echo "CPU binary : $BIN_DIR/fastp_d0bromir_cpu"
"$BIN_DIR/fastp_d0bromir_cpu" --version 2>&1 | head -3
echo ""
echo "GPU binary : $BIN_DIR/fastp_d0bromir_gpu"
"$BIN_DIR/fastp_d0bromir_gpu" --version 2>&1 | head -3
echo ""
echo "Run-time modes:"
echo "  GPU mode : $BIN_DIR/fastp_d0bromir_gpu -w 4 -i in.fq.gz -o /dev/null"
echo "  CPU mode : $BIN_DIR/fastp_d0bromir_cpu -w 4 -i in.fq.gz -o /dev/null"
echo "  Force CPU on GPU binary: CUDA_VISIBLE_DEVICES='' $BIN_DIR/fastp_d0bromir_gpu ..."
