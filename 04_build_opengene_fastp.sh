#!/usr/bin/env bash
# =============================================================================
# 04_build_opengene_fastp.sh
# Build fastp (OpenGene upstream) from source and install to ~/tools/bin/
#
# fastp: https://github.com/OpenGene/fastp
# License: MIT
#
# Dependencies: libdeflate, Intel ISA-L (libisal), pthreads, zlib
# Threading: -w N  (worker threads, default 3; controls per-file parallelism)
#
# Optimisation: march=native, O3 – let the compiler exploit A64FX/Neoverse
# SIMD. ISA-L uses NEON/SVE on AArch64 for fast CRC/DEFLATE.
# =============================================================================
set -euo pipefail

TOOLS_DIR="$HOME/tools"
SRC_DIR="$TOOLS_DIR/src/fastp_opengene"
BIN_DIR="$TOOLS_DIR/bin"
mkdir -p "$BIN_DIR"

echo "=== Building OpenGene fastp from source ==="

# ── Clone ─────────────────────────────────────────────────────────────────────
if [[ -d "$SRC_DIR" ]]; then
    echo ">>> Source directory exists – pulling latest changes"
    cd "$SRC_DIR" && git pull
else
    echo ">>> Cloning OpenGene/fastp"
    git clone --depth 1 https://github.com/OpenGene/fastp.git "$SRC_DIR"
fi
cd "$SRC_DIR"
echo ">>> Source: $SRC_DIR  (commit: $(git rev-parse --short HEAD))"

# ── Verify shared library presence ───────────────────────────────────────────
MISSING_LIBS=()
for LIB in isal deflate; do
    if ! ldconfig -p 2>/dev/null | grep -q "lib${LIB}\.so" && \
       ! ls /usr/local/lib/lib${LIB}.* &>/dev/null && \
       ! ls /usr/lib/lib${LIB}.* &>/dev/null && \
       ! ls /usr/lib/aarch64-linux-gnu/lib${LIB}.* &>/dev/null; then
        MISSING_LIBS+=("lib${LIB}")
    fi
done
if [[ ${#MISSING_LIBS[@]} -gt 0 ]]; then
    echo "ERROR: Missing libraries: ${MISSING_LIBS[*]}" >&2
    echo "       Please run 01_install_deps.sh first." >&2
    exit 1
fi

# ── Build ─────────────────────────────────────────────────────────────────────
# Inject march=native for maximal AArch64 vectorisation (Neoverse N2/V2 on A100 host)
echo ">>> Building with $(nproc) parallel jobs (O3 + march=native)"
make -j"$(nproc)" CXXFLAGS="-O3 -march=native" 2>&1

# ── Install wrapper ───────────────────────────────────────────────────────────
BIN_DEST="$BIN_DIR/fastp_opengene"
cp "$SRC_DIR/fastp" "$BIN_DEST"
chmod +x "$BIN_DEST"
echo ">>> Binary installed: $BIN_DEST"

# ── Verify ────────────────────────────────────────────────────────────────────
echo ""
echo "=== OpenGene fastp build complete ==="
echo "Binary : $BIN_DEST"
"$BIN_DEST" --version 2>&1 | head -3
echo ""
echo "Usage example (QC-only, no output, 8 worker threads):"
echo "  $BIN_DEST -w 8 -i sample.fastq.gz -o /dev/null"
echo ""
echo "Thread scaling: -w 1  -w 2  -w 4  -w 8  -w 16  -w 32"
