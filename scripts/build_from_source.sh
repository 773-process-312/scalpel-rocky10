#!/usr/bin/env bash
# =============================================================================
#  build_from_source.sh
#  Builds and installs Scalpel 2.1 + libtre 0.8.0 from source on Rocky Linux 10
#
#  Usage: sudo bash scripts/build_from_source.sh
#
#  What this does:
#    1. Installs all build dependencies via dnf
#    2. Downloads and builds libtre 0.8.0 from source
#    3. Clones scalpel 2.1 from GitHub (sleuthkit/scalpel)
#    4. Applies C++17 compatibility patches (scalpel_fix.sh logic)
#    5. Compiles scalpel against the local libtre
#    6. Installs both to /usr/local/
#    7. Installs scalpel.conf with PCAP rules
#
#  Why this is needed:
#    - Scalpel has NO package in any Rocky Linux 10 repo (BaseOS, AppStream, EPEL)
#    - foremost is also unavailable for el10
#    - Scalpel's source uses dynamic exception specifications and other patterns
#      that are removed in C++17 — patches are required before compilation
#    - libtre is scalpel's regex dependency; also not packaged for el10
#
#  Verified build environment:
#    OS      : Rocky Linux 10.1 (Red Quartz)
#    Compiler: GCC 14.3.1 (Red Hat 14.3.1-2)
#    libtre  : 0.8.0 (from http://laurikari.net/tre/)
#    scalpel : 2.1 (from https://github.com/sleuthkit/scalpel)
# =============================================================================

set -euo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; BOLD='\033[1m'; RESET='\033[0m'
info()    { echo -e "${CYAN}[INFO]${RESET}  $*"; }
success() { echo -e "${GREEN}[OK]${RESET}    $*"; }
warn()    { echo -e "${YELLOW}[WARN]${RESET}  $*"; }
error()   { echo -e "${RED}[ERROR]${RESET} $*" >&2; exit 1; }

BUILD_BASE="/tmp/scalpel_rocky10_build"
INSTALL_PREFIX="/usr/local"
LIBTRE_VERSION="0.8.0"
LIBTRE_URL="http://laurikari.net/tre/tre-${LIBTRE_VERSION}.tar.gz"
SCALPEL_REPO="https://github.com/sleuthkit/scalpel.git"
SCALPEL_TAG="scalpel-2.1"

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

[[ $EUID -ne 0 ]] && error "Run as root: sudo bash $0"

# ---------------------------------------------------------------------------
# STEP 1 — Install build dependencies
# ---------------------------------------------------------------------------
echo ""
info "========== Step 1: Installing Build Dependencies =========="

dnf install -y \
    gcc \
    gcc-c++ \
    make \
    autoconf \
    automake \
    libtool \
    wget \
    git \
    tar \
    gzip \
    && success "Build dependencies installed." \
    || error "Failed to install build dependencies."

# ---------------------------------------------------------------------------
# STEP 2 — Build libtre 0.8.0 from source
# libtre provides regex support required by scalpel
# It has no el10 package — must be built from source
# ---------------------------------------------------------------------------
echo ""
info "========== Step 2: Building libtre ${LIBTRE_VERSION} from Source =========="

mkdir -p "${BUILD_BASE}/tre"
cd "${BUILD_BASE}/tre"

if [[ -f "/tmp/tre-${LIBTRE_VERSION}.tar.gz" ]]; then
    info "Using cached tarball from /tmp/tre-${LIBTRE_VERSION}.tar.gz"
    cp "/tmp/tre-${LIBTRE_VERSION}.tar.gz" .
else
    info "Downloading libtre ${LIBTRE_VERSION}..."
    wget -q --timeout=60 "${LIBTRE_URL}" -O "tre-${LIBTRE_VERSION}.tar.gz" \
        || error "Failed to download libtre. Check: ${LIBTRE_URL}"
fi

tar -xzf "tre-${LIBTRE_VERSION}.tar.gz"
cd "tre-${LIBTRE_VERSION}"

info "Configuring libtre..."
./configure --prefix="${INSTALL_PREFIX}" \
    || error "libtre ./configure failed."

info "Compiling libtre..."
make -j"$(nproc)" \
    || error "libtre make failed."

info "Installing libtre to ${INSTALL_PREFIX}..."
make install \
    || error "libtre make install failed."

# Register libtre with ldconfig
if ! grep -q "${INSTALL_PREFIX}/lib" /etc/ld.so.conf 2>/dev/null && \
   ! grep -rl "${INSTALL_PREFIX}/lib" /etc/ld.so.conf.d/ &>/dev/null; then
    echo "${INSTALL_PREFIX}/lib" > /etc/ld.so.conf.d/local-libs.conf
    info "Registered ${INSTALL_PREFIX}/lib in ldconfig."
fi
ldconfig
success "libtre ${LIBTRE_VERSION} built and installed."
info "  Library: ${INSTALL_PREFIX}/lib/libtre.so.5.0.0"
info "  Headers: ${INSTALL_PREFIX}/include/tre/"

# ---------------------------------------------------------------------------
# STEP 3 — Clone Scalpel 2.1
# ---------------------------------------------------------------------------
echo ""
info "========== Step 3: Cloning Scalpel ${SCALPEL_TAG} =========="

mkdir -p "${BUILD_BASE}/scalpel"
cd "${BUILD_BASE}/scalpel"

if [[ -d "scalpel/.git" ]]; then
    info "Scalpel repo already cloned. Resetting to tag ${SCALPEL_TAG}..."
    cd scalpel
    git fetch --tags &>/dev/null
    git checkout "${SCALPEL_TAG}" &>/dev/null \
        || git checkout main &>/dev/null \
        || true
else
    info "Cloning scalpel from ${SCALPEL_REPO}..."
    git clone "${SCALPEL_REPO}" scalpel \
        || error "git clone failed. Check network connectivity."
    cd scalpel
    git checkout "${SCALPEL_TAG}" 2>/dev/null || {
        warn "Tag ${SCALPEL_TAG} not found — using latest main branch."
        git checkout main 2>/dev/null || true
    }
fi
success "Scalpel source ready."

# ---------------------------------------------------------------------------
# STEP 4 — Apply C++17 Compatibility Patches
# Scalpel 2.1 uses dynamic exception specifications (throw(...)) which are
# removed in C++17, and has const char return type conflicts and unsafe
# strncpy usage that cause compilation failures with GCC 14 on Rocky Linux 10.
# ---------------------------------------------------------------------------
echo ""
info "========== Step 4: Applying C++17 Compatibility Patches =========="

SRC_DIR="$(pwd)/src"

if [[ ! -d "${SRC_DIR}" ]]; then
    error "Scalpel src/ directory not found at ${SRC_DIR}. Clone may be incomplete."
fi

# Patch 1: Remove dynamic exception specifications
# C++17 removed throw(...) — these cause hard compilation errors with GCC 14
info "Patch 1/4: Removing dynamic exception specifications (throw(...))..."
find "${SRC_DIR}" -type f \( -name "*.cpp" -o -name "*.h" \) \
    -exec sed -i 's/throw *([^)]*)//g' {} +
success "Dynamic exception specs removed."

# Patch 2: Fix const char return type conflicts
# 'const char functionName(...)' return type causes type conflict errors in C++17
info "Patch 2/4: Fixing const char return type conflicts..."
find "${SRC_DIR}" -type f \( -name "*.cpp" -o -name "*.h" \) \
    -exec sed -i 's/\bconst char \([a-zA-Z0-9_]*\)(/\1 char(/g' {} +

# Specifically fix scalpelInputIsOpen in both header and implementation
for FILE in "${SRC_DIR}/input_reader.h" "${SRC_DIR}/input_reader.cpp"; do
    if [[ -f "${FILE}" ]]; then
        sed -i 's/const char scalpelInputIsOpen/char scalpelInputIsOpen/' "${FILE}"
        info "  Fixed scalpelInputIsOpen in $(basename ${FILE})"
    fi
done
success "const char return type conflicts fixed."

# Patch 3: Replace unsafe strncpy with snprintf
# GCC 14 treats string truncation from strncpy as errors in strict mode
info "Patch 3/4: Replacing unsafe strncpy with snprintf..."
find "${SRC_DIR}" -type f -name "*.cpp" \
    -exec sed -i 's|strncpy(\(.*\), \(.*\), strlen(\2));|snprintf(\1, sizeof(\1), "%s", \2);|g' {} +
success "strncpy instances patched."

# Patch 4: Report any remaining strncpy calls for manual review
info "Patch 4/4: Checking for any remaining strncpy usage..."
REMAINING=$(grep -r --include="*.cpp" 'strncpy' "${SRC_DIR}" 2>/dev/null | wc -l)
if [[ "${REMAINING}" -gt 0 ]]; then
    warn "${REMAINING} strncpy occurrence(s) remain — may need manual review if build fails:"
    grep -r --include="*.cpp" -n 'strncpy' "${SRC_DIR}" | while IFS= read -r line; do
        warn "  ${line}"
    done
else
    success "No remaining strncpy usage found."
fi

success "All C++17 compatibility patches applied."

# ---------------------------------------------------------------------------
# STEP 5 — Configure and Compile Scalpel
# ---------------------------------------------------------------------------
echo ""
info "========== Step 5: Configuring and Compiling Scalpel =========="

# autoreconf generates ./configure from configure.ac — required for git clone
info "Running autoreconf to generate build system..."
autoreconf -fiv \
    || error "autoreconf failed. Check autoconf/automake/libtool are installed."

# Configure with local libtre location
info "Running ./configure..."
./configure \
    --prefix="${INSTALL_PREFIX}" \
    CPPFLAGS="-I${INSTALL_PREFIX}/include" \
    LDFLAGS="-L${INSTALL_PREFIX}/lib" \
    || error "./configure failed. Check output above for missing dependencies."

info "Compiling scalpel (using $(nproc) cores)..."
make -j"$(nproc)" \
    || error "make failed. Check compiler errors above."

success "Scalpel compiled successfully."

# ---------------------------------------------------------------------------
# STEP 6 — Install Scalpel
# ---------------------------------------------------------------------------
echo ""
info "========== Step 6: Installing Scalpel =========="

make install \
    || error "make install failed."

success "Scalpel installed to ${INSTALL_PREFIX}/bin/scalpel"

# ---------------------------------------------------------------------------
# STEP 7 — Install scalpel.conf
# ---------------------------------------------------------------------------
echo ""
info "========== Step 7: Installing scalpel.conf =========="

mkdir -p /etc/scalpel

if [[ -f /etc/scalpel/scalpel.conf ]]; then
    BACKUP="/etc/scalpel/scalpel.conf.bak.$(date +%Y%m%d%H%M%S)"
    cp /etc/scalpel/scalpel.conf "${BACKUP}"
    warn "Existing config backed up to: ${BACKUP}"
fi

# Use the repo's pre-configured scalpel.conf if available
if [[ -f "${REPO_DIR}/config/scalpel.conf" ]]; then
    cp "${REPO_DIR}/config/scalpel.conf" /etc/scalpel/scalpel.conf
    info "Installed config from repo."
elif [[ -f "$(pwd)/scalpel.conf" ]]; then
    cp "$(pwd)/scalpel.conf" /etc/scalpel/scalpel.conf
    info "Installed default config from source tree."
fi

# Ensure PCAP rules are present and active
if [[ -f /etc/scalpel/scalpel.conf ]]; then
    PCAP_ACTIVE=$(grep -c "^pcap" /etc/scalpel/scalpel.conf 2>/dev/null || echo "0")
    if [[ "${PCAP_ACTIVE}" -lt 2 ]]; then
        info "Adding PCAP carving rules to scalpel.conf..."
        cat >> /etc/scalpel/scalpel.conf << 'PCAPEOF'

# PCAP file carving rules — added by build_from_source.sh
# Big-endian magic:    a1 b2 c3 d4  (standard libpcap / tcpdump)
# Little-endian magic: d4 c3 b2 a1  (modified libpcap, some appliance formats)
# Max file size: 100MB per carved file (adjust as needed)
pcap    y   104857600   \xa1\xb2\xc3\xd4
pcap    y   104857600   \xd4\xc3\xb2\xa1
PCAPEOF
        success "PCAP carving rules added."
    else
        success "PCAP rules already present (${PCAP_ACTIVE} rules active)."
    fi
fi

# ---------------------------------------------------------------------------
# STEP 8 — Final Verification
# ---------------------------------------------------------------------------
echo ""
info "========== Step 8: Verifying Installation =========="

export PATH="${INSTALL_PREFIX}/bin:${PATH}"

if command -v scalpel &>/dev/null; then
    VER=$(scalpel 2>&1 | grep -oi "scalpel version [0-9.]*" | head -1 || echo "v2.1")
    success "scalpel: $(command -v scalpel)  [${VER}]"
else
    error "scalpel not found in PATH. Add ${INSTALL_PREFIX}/bin to your PATH."
fi

if ldd "${INSTALL_PREFIX}/bin/scalpel" 2>/dev/null | grep -q "not found"; then
    error "Broken library links:\n$(ldd ${INSTALL_PREFIX}/bin/scalpel)"
else
    success "All shared library dependencies resolved."
fi

PCAP_COUNT=$(grep -c "^pcap" /etc/scalpel/scalpel.conf 2>/dev/null || echo "0")
success "PCAP rules active: ${PCAP_COUNT}"

# ---------------------------------------------------------------------------
# Done
# ---------------------------------------------------------------------------
echo ""
echo -e "${GREEN}${BOLD}========================================${RESET}"
echo -e "${GREEN}${BOLD}  Scalpel 2.1 build complete.${RESET}"
echo -e "${GREEN}${BOLD}========================================${RESET}"
echo ""
echo "  Binary : ${INSTALL_PREFIX}/bin/scalpel"
echo "  Config : /etc/scalpel/scalpel.conf"
echo "  libtre : ${INSTALL_PREFIX}/lib/libtre.so.5.0.0"
echo "  Build  : ${BUILD_BASE}  (safe to delete)"
echo ""
echo "Add to PATH permanently:"
echo "  echo 'export PATH=\"/usr/local/bin:\${PATH}\"' >> ~/.bashrc"
echo "  source ~/.bashrc"
echo ""
echo "Quick test:"
echo "  scalpel /path/to/disk.dd -o /path/to/output/"
echo ""
