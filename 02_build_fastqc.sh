#!/usr/bin/env bash
# =============================================================================
# 02_build_fastqc.sh
# Build FastQC from source (Java/Ant) and install to ~/tools/bin/
#
# FastQC: https://github.com/s-andrews/FastQC
# License: GPL-3.0 + Apache-2.0
#
# Threading notes
# ---------------
# FastQC's -t parameter controls the NUMBER OF FILES processed simultaneously.
# A single file is always processed by ONE thread. To benchmark thread scaling,
# we pass multiple files and vary -t. The benchmark script handles this.
#
# JVM tuning: We set max heap to 8g which is appropriate for large FASTQ files.
# =============================================================================
set -euo pipefail

TOOLS_DIR="$HOME/tools"
SRC_DIR="$TOOLS_DIR/src/FastQC"
BIN_DIR="$TOOLS_DIR/bin"
mkdir -p "$BIN_DIR"

echo "=== Building FastQC from source ==="

# ── Clone ─────────────────────────────────────────────────────────────────────
if [[ -d "$SRC_DIR" ]]; then
    echo ">>> Source directory exists – pulling latest changes"
    cd "$SRC_DIR" && git pull
else
    echo ">>> Cloning s-andrews/FastQC"
    git clone --depth 1 https://github.com/s-andrews/FastQC.git "$SRC_DIR"
fi

cd "$SRC_DIR"
echo ">>> Source: $SRC_DIR  (commit: $(git rev-parse --short HEAD))"

# ── Build with Ant ────────────────────────────────────────────────────────────
echo ">>> Running: ant build"
ant build 2>&1 | tail -5

# ── Verify build output ───────────────────────────────────────────────────────
if [[ ! -x "$SRC_DIR/fastqc" ]]; then
    echo "ERROR: fastqc launcher script not found after build" >&2
    exit 1
fi

echo ">>> Build successful"

# ── Tune JVM heap size in launcher ───────────────────────────────────────────
# The default is 250m which is too small for large WGS files.
# Replace with an adaptive setting (6g for this machine with plenty of RAM).
sed -i 's/-Xmx[0-9]*[mMgG]/-Xmx8g/g' "$SRC_DIR/fastqc"
echo ">>> JVM max heap set to 8g in fastqc launcher"

# ── Install wrapper to ~/tools/bin/ ───────────────────────────────────────────
cat > "$BIN_DIR/fastqc" <<EOF
#!/usr/bin/env bash
# Wrapper for FastQC installed at $SRC_DIR
exec "$SRC_DIR/fastqc" "\$@"
EOF
chmod +x "$BIN_DIR/fastqc"

# ── Verify ────────────────────────────────────────────────────────────────────
echo ""
echo "=== FastQC build complete ==="
echo "Binary wrapper : $BIN_DIR/fastqc"
echo "Source dir     : $SRC_DIR"
"$BIN_DIR/fastqc" --version 2>&1 || true
echo ""
echo "Usage example:"
echo "  $BIN_DIR/fastqc -t 4 --noextract -o /tmp/fqc_out sample.fastq.gz"
