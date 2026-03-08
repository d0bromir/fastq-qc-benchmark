#!/usr/bin/env bash
# =============================================================================
# 01_install_deps.sh
# Install ALL build-time and run-time dependencies for the FASTQ QC benchmark:
#   FastQC   – requires Java JDK + Apache Ant
#   Falco    – requires autotools, zlib
#   fastp (OpenGene) – requires cmake, zlib, libdeflate, isa-l
#   fastp (d0bromir) – above + NVIDIA CUDA Toolkit (for GPU build)
#
# System: Ubuntu 25.10, aarch64 (ARM64), NVIDIA A100 80GB GPUs
# CUDA arch: 8.0 (A100)
# =============================================================================
set -euo pipefail

TOOLS_DIR="$HOME/tools"
mkdir -p "$TOOLS_DIR/src"
cd "$TOOLS_DIR/src"

ARCH=$(uname -m)   # aarch64
echo ">>> Architecture: $ARCH"
echo ">>> Ubuntu $(lsb_release -rs 2>/dev/null || cat /etc/os-release | grep VERSION_ID | cut -d= -f2)"

# ── System packages ──────────────────────────────────────────────────────────
echo ""
echo "=== [1/5] Installing system packages via apt ==="
sudo apt-get update -y

sudo apt-get install -y \
    build-essential \
    git wget curl \
    openjdk-21-jdk ant \
    autoconf automake libtool pkg-config \
    cmake \
    zlib1g-dev \
    libhts-dev \
    time \
    bc \
    nasm yasm

echo ">>> Java version: $(java -version 2>&1 | head -1)"
echo ">>> cmake version: $(cmake --version | head -1)"

# ── libdeflate ───────────────────────────────────────────────────────────────
echo ""
echo "=== [2/5] Install libdeflate ==="
if pkg-config --exists libdeflate 2>/dev/null; then
    echo ">>> libdeflate already available via pkg-config, skipping build"
else
    sudo apt-get install -y libdeflate-dev 2>/dev/null && \
        echo ">>> libdeflate installed from apt" || {
        echo ">>> Building libdeflate from source..."
        git clone --depth 1 https://github.com/ebiggers/libdeflate.git libdeflate_src
        cd libdeflate_src
        cmake -B build -DCMAKE_INSTALL_PREFIX=/usr/local
        cmake --build build -j"$(nproc)"
        sudo cmake --install build
        cd ..
        sudo ldconfig
        echo ">>> libdeflate built and installed"
    }
fi

# ── Intel ISA-L (libisal) ─────────────────────────────────────────────────
# isa-l has ARM64 support since v2.30; required by OpenGene fastp.
echo ""
echo "=== [3/5] Install Intel ISA-L (libisal) ==="
if pkg-config --exists libisal 2>/dev/null || ldconfig -p 2>/dev/null | grep -q libisal; then
    echo ">>> libisal already installed"
else
    # Try apt first (Ubuntu 22.04+ has libisal in main repos)
    sudo apt-get install -y libisal-dev 2>/dev/null && \
        echo ">>> libisal installed from apt" || {
        echo ">>> Building Intel ISA-L from source (ARM64-compatible)..."
        git clone --depth 1 https://github.com/intel/isa-l.git isa-l_src
        cd isa-l_src
        ./autogen.sh
        # ARM64 support: isa-l uses NEON SIMD on AArch64
        ./configure --prefix=/usr/local --libdir=/usr/local/lib
        make -j"$(nproc)"
        sudo make install
        cd ..
        sudo ldconfig
        echo ">>> ISA-L built and installed"
    }
fi

# ── NVIDIA CUDA Toolkit ───────────────────────────────────────────────────────
# The d0bromir/fastp GPU build needs nvcc + CUDA runtime headers.
# Driver already installed (NVIDIA 590-server). We add the CUDA toolkit.
# Using SBSA (Server Base System Architecture) = ARM64 server platform.
echo ""
echo "=== [4/5] Install NVIDIA CUDA Toolkit ==="
if command -v nvcc &>/dev/null; then
    echo ">>> nvcc already in PATH: $(nvcc --version | head -1)"
else
    # Check if CUDA exists at a non-PATH location
    for CUDA_CANDIDATE in /usr/local/cuda /usr/local/cuda-12 /usr/local/cuda-12.6; do
        if [[ -x "$CUDA_CANDIDATE/bin/nvcc" ]]; then
            echo ">>> Found nvcc at $CUDA_CANDIDATE — adding to PATH"
            export PATH="$CUDA_CANDIDATE/bin:$PATH"
            export LD_LIBRARY_PATH="$CUDA_CANDIDATE/lib64:${LD_LIBRARY_PATH:-}"
            echo "export PATH=$CUDA_CANDIDATE/bin:\$PATH" >> ~/.bashrc
            echo "export LD_LIBRARY_PATH=$CUDA_CANDIDATE/lib64:\${LD_LIBRARY_PATH:-}" >> ~/.bashrc
            break
        fi
    done

    if ! command -v nvcc &>/dev/null; then
        echo ">>> nvcc not found – installing CUDA Toolkit via NVIDIA keyring (sbsa/arm64)"
        # NVIDIA CUDA keyring for Ubuntu 22.04 SBSA is compatible with 24.04/25.x
        KEYRING_DEB="cuda-keyring_1.1-1_all.deb"
        wget -q "https://developer.download.nvidia.com/compute/cuda/repos/ubuntu2404/sbsa/$KEYRING_DEB" \
             -O "/tmp/$KEYRING_DEB"
        sudo dpkg -i "/tmp/$KEYRING_DEB"
        sudo apt-get update -y
        # Install CUDA toolkit (compiler + headers + libraries) without the driver
        sudo apt-get install -y cuda-toolkit-12-6 || \
        sudo apt-get install -y cuda-toolkit-12-5 || \
        sudo apt-get install -y cuda-toolkit-12-4
        # Add CUDA to PATH
        CUDA_PATH=$(ls -d /usr/local/cuda-12.* 2>/dev/null | sort -V | tail -1 || echo /usr/local/cuda)
        export PATH="$CUDA_PATH/bin:$PATH"
        export LD_LIBRARY_PATH="$CUDA_PATH/lib64:${LD_LIBRARY_PATH:-}"
        echo "export PATH=$CUDA_PATH/bin:\$PATH" >> ~/.bashrc
        echo "export LD_LIBRARY_PATH=$CUDA_PATH/lib64:\${LD_LIBRARY_PATH:-}" >> ~/.bashrc
        echo ">>> CUDA Toolkit installed: $(nvcc --version 2>&1 | head -1)"
    fi
fi

# ── Verification ─────────────────────────────────────────────────────────────
echo ""
echo "=== [5/5] Dependency check summary ==="
check() {
    local name=$1; local cmd=$2
    if eval "$cmd" &>/dev/null ; then
        echo "  [OK]  $name"
    else
        echo "  [MISSING] $name  <-- action required"
    fi
}

check "Java JDK"          "java -version"
check "ant"               "ant -version"
check "cmake"             "cmake --version"
check "autoconf"          "autoconf --version"
check "automake"          "automake --version"
check "zlib-dev"          "pkg-config --exists zlib"
check "libdeflate"        "pkg-config --exists libdeflate || ldconfig -p | grep -q libdeflate"
check "libisal"           "ldconfig -p | grep -q libisal || pkg-config --exists libisal"
check "nvcc (CUDA)"       "nvcc --version 2>/dev/null || /usr/local/cuda/bin/nvcc --version"
check "nvidia-smi"        "nvidia-smi"
check "/usr/bin/time"     "test -x /usr/bin/time"

echo ""
echo "DONE – all dependencies installed (check for any [MISSING] above)."
echo "Run subsequent build scripts (02, 03, 04, 05) to compile each tool."
