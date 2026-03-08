#!/usr/bin/env bash
# =============================================================================
# 03_build_falco.sh
# Build Falco from source (C++/autotools) and install to ~/tools/bin/
#
# Falco: https://github.com/smithlabcode/falco
# License: GPL-3.0
#
# Threading notes
# ---------------
# Falco's -t/--threads parameter is NOT YET IMPLEMENTED.
# Each invocation processes a single file in a single thread.
# Parallelism over multiple files must be orchestrated externally (e.g., parallel).
# In the benchmark we run Falco with thread count = 1 only.
#
# Optimisation flags: -O3 -march=native for the target aarch64 CPU.
# =============================================================================
set -euo pipefail

TOOLS_DIR="$HOME/tools"
SRC_DIR="$TOOLS_DIR/src/falco"
INSTALL_PREFIX="$TOOLS_DIR/falco_install"
BIN_DIR="$TOOLS_DIR/bin"
mkdir -p "$BIN_DIR" "$INSTALL_PREFIX"

echo "=== Building Falco from source ==="

# ── Clone ─────────────────────────────────────────────────────────────────────
if [[ -d "$SRC_DIR" ]]; then
    echo ">>> Source directory exists – pulling latest changes"
    cd "$SRC_DIR" && git pull
else
    echo ">>> Cloning smithlabcode/falco"
    git clone --depth 1 https://github.com/smithlabcode/falco.git "$SRC_DIR"
fi
cd "$SRC_DIR"
echo ">>> Source: $SRC_DIR  (commit: $(git rev-parse --short HEAD))"

# ── Generate configure script ─────────────────────────────────────────────────
echo ">>> Generating configure script (autoreconf / autogen.sh)"
if [[ -f autogen.sh ]]; then
    ./autogen.sh
else
    autoreconf -ivf
fi

# ── Configure and build ───────────────────────────────────────────────────────
echo ">>> Configuring (O3, march=native, prefix: $INSTALL_PREFIX)"
./configure \
    CXXFLAGS="-O3 -march=native -Wall" \
    --prefix="$INSTALL_PREFIX"

echo ">>> Building with $(nproc) parallel jobs"
make -j"$(nproc)" all

echo ">>> Installing to $INSTALL_PREFIX"
make install

# ── Symlink to ~/tools/bin/ ───────────────────────────────────────────────────
ln -sf "$INSTALL_PREFIX/bin/falco" "$BIN_DIR/falco"
echo ">>> Symlinked: $BIN_DIR/falco -> $INSTALL_PREFIX/bin/falco"

# ── Copy Configuration files alongside binary ─────────────────────────────────
# Falco looks for Configuration/ relative to the binary (or via --contaminants / --adapters).
# We keep them in the source dir and pass explicit paths in the benchmark.
FALCO_CONF_DIR="$TOOLS_DIR/falco_config"
mkdir -p "$FALCO_CONF_DIR"
if [[ -d "$SRC_DIR/Configuration" ]]; then
    cp -r "$SRC_DIR/Configuration/"* "$FALCO_CONF_DIR/"
    echo ">>> Configuration files copied to $FALCO_CONF_DIR"
fi

# ── Verify ────────────────────────────────────────────────────────────────────
echo ""
echo "=== Falco build complete ==="
echo "Binary  : $BIN_DIR/falco"
"$BIN_DIR/falco" --version 2>&1 || true
echo ""
echo "Usage example:"
echo "  $BIN_DIR/falco -o /tmp/falco_out \\"
echo "      --contaminants $FALCO_CONF_DIR/contaminant_list.txt \\"
echo "      --adapters $FALCO_CONF_DIR/adapter_list.txt \\"
echo "      sample.fastq.gz"
