#!/usr/bin/env bash
# =============================================================================
#  install_prebuilt.sh
#  Installs the pre-built Scalpel 2.1 binary and libtre 0.8.0 from this repo
#  onto a Rocky Linux 10 x86_64 system.
#
#  Usage: sudo bash scripts/install_prebuilt.sh
#
#  What this does:
#    1. Verifies OS and CPU compatibility
#    2. Copies scalpel binary to /usr/local/bin/
#    3. Copies libtre.so.5.0.0 to /usr/local/lib/ and creates symlinks
#    4. Runs ldconfig to register the new shared library
#    5. Installs scalpel.conf to /etc/scalpel/
#    6. Verifies the installation
# =============================================================================

set -euo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; BOLD='\033[1m'; RESET='\033[0m'
info()    { echo -e "${CYAN}[INFO]${RESET}  $*"; }
success() { echo -e "${GREEN}[OK]${RESET}    $*"; }
warn()    { echo -e "${YELLOW}[WARN]${RESET}  $*"; }
error()   { echo -e "${RED}[ERROR]${RESET} $*" >&2; exit 1; }

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# ---------------------------------------------------------------------------
# Must run as root
# ---------------------------------------------------------------------------
[[ $EUID -ne 0 ]] && error "Run as root: sudo bash $0"

# ---------------------------------------------------------------------------
# OS check
# ---------------------------------------------------------------------------
if [[ -f /etc/os-release ]]; then
    source /etc/os-release
    info "Detected: ${NAME} ${VERSION_ID}"
    MAJOR="${VERSION_ID%%.*}"
    if [[ "${ID}" != "rocky" ]] || [[ "${MAJOR}" != "10" ]]; then
        warn "This binary was built on Rocky Linux 10.1."
        warn "Detected: ${ID} ${VERSION_ID} — compatibility not guaranteed."
        read -rp "Continue anyway? [y/N] " confirm
        [[ "${confirm,,}" == "y" ]] || error "Aborted."
    fi
fi

# ---------------------------------------------------------------------------
# CPU check — Rocky Linux 10 requires x86-64-v3 (AVX2)
# ---------------------------------------------------------------------------
if ! grep -q avx2 /proc/cpuinfo 2>/dev/null; then
    warn "AVX2 not detected. This binary requires x86-64-v3."
    warn "It may not run on this CPU. Use build_from_source.sh instead."
fi

# ---------------------------------------------------------------------------
# Verify repo files are present
# ---------------------------------------------------------------------------
BINARY="${REPO_DIR}/bin/scalpel"
LIBTRE="${REPO_DIR}/lib/libtre.so.5.0.0"
CONF="${REPO_DIR}/config/scalpel.conf"

[[ -f "${BINARY}" ]] || error "Binary not found at ${BINARY}. Is this a full repo clone?"
[[ -f "${LIBTRE}" ]] || error "libtre not found at ${LIBTRE}. Is this a full repo clone?"
[[ -f "${CONF}" ]]   || error "scalpel.conf not found at ${CONF}."

# ---------------------------------------------------------------------------
# Verify SHA256 checksums
# ---------------------------------------------------------------------------
info "Verifying file integrity..."

EXPECTED_SCALPEL="1179ffa678ced34028d8dde7320ea1e361885629aed6b8fad16625842c1d9181"
EXPECTED_LIBTRE="6a6debff50ffac64a64ccc9dbdf86b4d63542eddfc0ea8141b3e61faeb1a735b"

ACTUAL_SCALPEL=$(sha256sum "${BINARY}" | awk '{print $1}')
ACTUAL_LIBTRE=$(sha256sum "${LIBTRE}" | awk '{print $1}')

if [[ "${ACTUAL_SCALPEL}" != "${EXPECTED_SCALPEL}" ]]; then
    error "SHA256 mismatch for scalpel binary. File may be corrupted or tampered."
fi
success "scalpel binary checksum verified."

if [[ "${ACTUAL_LIBTRE}" != "${EXPECTED_LIBTRE}" ]]; then
    error "SHA256 mismatch for libtre.so.5. File may be corrupted or tampered."
fi
success "libtre checksum verified."

# ---------------------------------------------------------------------------
# Install libtre shared library
# ---------------------------------------------------------------------------
info "Installing libtre 0.8.0 to /usr/local/lib/..."
cp -f "${LIBTRE}" /usr/local/lib/libtre.so.5.0.0
chmod 755 /usr/local/lib/libtre.so.5.0.0

# Create symlinks
ln -sf /usr/local/lib/libtre.so.5.0.0 /usr/local/lib/libtre.so.5
ln -sf /usr/local/lib/libtre.so.5.0.0 /usr/local/lib/libtre.so
success "libtre installed and symlinks created."

# Register with ldconfig
info "Running ldconfig to register libtre..."
# Ensure /usr/local/lib is in ldconfig search path
if ! grep -q "/usr/local/lib" /etc/ld.so.conf 2>/dev/null && \
   ! ls /etc/ld.so.conf.d/*.conf 2>/dev/null | xargs grep -l "/usr/local/lib" &>/dev/null; then
    echo "/usr/local/lib" > /etc/ld.so.conf.d/local-libs.conf
    info "Added /usr/local/lib to /etc/ld.so.conf.d/local-libs.conf"
fi
ldconfig
success "ldconfig updated."

# ---------------------------------------------------------------------------
# Install scalpel binary
# ---------------------------------------------------------------------------
info "Installing scalpel binary to /usr/local/bin/..."
cp -f "${BINARY}" /usr/local/bin/scalpel
chmod 755 /usr/local/bin/scalpel
success "scalpel binary installed."

# ---------------------------------------------------------------------------
# Install scalpel.conf
# ---------------------------------------------------------------------------
info "Installing scalpel.conf to /etc/scalpel/..."
mkdir -p /etc/scalpel

if [[ -f /etc/scalpel/scalpel.conf ]]; then
    BACKUP="/etc/scalpel/scalpel.conf.bak.$(date +%Y%m%d%H%M%S)"
    cp /etc/scalpel/scalpel.conf "${BACKUP}"
    warn "Existing scalpel.conf backed up to: ${BACKUP}"
fi

cp -f "${CONF}" /etc/scalpel/scalpel.conf
chmod 644 /etc/scalpel/scalpel.conf
success "scalpel.conf installed."

# ---------------------------------------------------------------------------
# Verify installation
# ---------------------------------------------------------------------------
info "Verifying installation..."

export PATH="/usr/local/bin:${PATH}"

if command -v scalpel &>/dev/null; then
    VER=$(scalpel 2>&1 | grep -oi "scalpel version [0-9.]*" | head -1 || echo "v2.1")
    success "scalpel is available: $(command -v scalpel)  [${VER}]"
else
    error "scalpel not found in PATH after install. Check /usr/local/bin is in your PATH."
fi

# Verify libtre linkage resolves
if ldd /usr/local/bin/scalpel 2>/dev/null | grep -q "not found"; then
    error "Broken library link detected:\n$(ldd /usr/local/bin/scalpel)"
else
    success "All shared library dependencies resolved."
fi

PCAP_RULES=$(grep -c "^pcap" /etc/scalpel/scalpel.conf 2>/dev/null || echo "0")
if [[ "${PCAP_RULES}" -ge 2 ]]; then
    success "PCAP carving rules active: ${PCAP_RULES} rules in /etc/scalpel/scalpel.conf"
else
    warn "Only ${PCAP_RULES} PCAP rules found — expected 2. Check /etc/scalpel/scalpel.conf"
fi

# ---------------------------------------------------------------------------
# Done
# ---------------------------------------------------------------------------
echo ""
echo -e "${GREEN}${BOLD}Scalpel 2.1 installed successfully.${RESET}"
echo ""
echo "  Binary : /usr/local/bin/scalpel"
echo "  Config : /etc/scalpel/scalpel.conf"
echo "  libtre : /usr/local/lib/libtre.so.5.0.0"
echo ""
echo "Quick test:"
echo "  scalpel /path/to/disk.dd -o /path/to/output/"
echo ""
echo "Add /usr/local/bin to your PATH if needed:"
echo "  export PATH=\"/usr/local/bin:\${PATH}\""
echo ""
