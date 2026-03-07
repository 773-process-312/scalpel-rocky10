#!/usr/bin/env bash
# =============================================================================
#  scalpel_fix.sh
#  Patches Scalpel 2.1 source code for C++17 / GCC 14 compatibility
#  on Rocky Linux 10 (RHEL 10 / el10).
#
#  Usage: bash scripts/scalpel_fix.sh /path/to/scalpel/src
#         (called automatically by build_from_source.sh)
#
#  Why these patches are needed:
#    Rocky Linux 10 uses GCC 14 which enforces C++17 by default.
#    Scalpel 2.1 was written against older C++ standards and contains:
#
#    1. Dynamic exception specifications: throw(SomeException)
#       - Removed entirely in C++17 (was deprecated in C++11)
#       - GCC 14 rejects these as hard errors
#
#    2. const char return type conflicts
#       - 'const char functionName(...)' causes type conflict errors
#         when the return value is used as a non-const char in C++17
#
#    3. Unsafe strncpy usage
#       - GCC 14 treats string-truncation from strncpy as errors
#         in contexts where the source length equals the destination size
#       - Replaced with snprintf for safe, null-terminated copies
#
#  Tested on:
#    Rocky Linux 10.1, GCC 14.3.1 (Red Hat 14.3.1-2), Scalpel 2.1
# =============================================================================

set -euo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; CYAN='\033[0;36m'; RESET='\033[0m'
info()    { echo -e "${CYAN}[INFO]${RESET}  $*"; }
success() { echo -e "${GREEN}[OK]${RESET}    $*"; }
error()   { echo -e "${RED}[ERROR]${RESET} $*" >&2; exit 1; }

# Accept src dir as argument or use default
SRC_DIR="${1:-${HOME}/scalpel/src}"

[[ -d "${SRC_DIR}" ]] || error "Source directory not found: ${SRC_DIR}"

info "Patching Scalpel C++ source in: ${SRC_DIR}"
echo ""

# ---------------------------------------------------------------------------
# Patch 1: Remove dynamic exception specifications
# throw(...) is invalid in C++17 — GCC 14 rejects it as a hard error
# ---------------------------------------------------------------------------
info "Patch 1/4: Removing dynamic exception specifications (throw(...))..."
find "${SRC_DIR}" -type f \( -name "*.cpp" -o -name "*.h" \) \
    -exec sed -i 's/throw *([^)]*)//g' {} +
success "Dynamic exception specifications removed."

# ---------------------------------------------------------------------------
# Patch 2: Fix const char return type conflicts
# 'const char functionName(...)' causes type conflicts in C++17 contexts
# ---------------------------------------------------------------------------
info "Patch 2/4: Fixing const char return type conflicts..."
find "${SRC_DIR}" -type f \( -name "*.cpp" -o -name "*.h" \) \
    -exec sed -i 's/\bconst char \([a-zA-Z0-9_]*\)(/\1 char(/g' {} +

# Specifically fix scalpelInputIsOpen (confirmed affected in v2.1)
for FILE in "${SRC_DIR}/input_reader.h" "${SRC_DIR}/input_reader.cpp"; do
    if [[ -f "${FILE}" ]]; then
        sed -i 's/const char scalpelInputIsOpen/char scalpelInputIsOpen/' "${FILE}"
        info "  Fixed scalpelInputIsOpen in $(basename ${FILE})"
    fi
done
success "const char return type conflicts fixed."

# ---------------------------------------------------------------------------
# Patch 3: Replace unsafe strncpy with snprintf
# GCC 14 errors on strncpy where source length equals destination buffer size
# ---------------------------------------------------------------------------
info "Patch 3/4: Replacing unsafe strncpy usage with snprintf..."
find "${SRC_DIR}" -type f -name "*.cpp" \
    -exec sed -i \
    's|strncpy(\(.*\), \(.*\), strlen(\2));|snprintf(\1, sizeof(\1), "%s", \2);|g' \
    {} +
success "strncpy instances patched."

# ---------------------------------------------------------------------------
# Patch 4: Report any remaining strncpy calls
# ---------------------------------------------------------------------------
info "Patch 4/4: Scanning for remaining strncpy usage..."
REMAINING=$(grep -r --include="*.cpp" -l 'strncpy' "${SRC_DIR}" 2>/dev/null | wc -l)
if [[ "${REMAINING}" -gt 0 ]]; then
    echo -e "${YELLOW}[WARN]${RESET}  ${REMAINING} file(s) still contain strncpy — review if build fails:"
    grep -r --include="*.cpp" -n 'strncpy' "${SRC_DIR}" 2>/dev/null | \
        while IFS= read -r line; do echo "    ${line}"; done
else
    success "No remaining strncpy usage found."
fi

echo ""
success "All patches applied to ${SRC_DIR}"
echo ""
echo "Proceed with:"
echo "  autoreconf -fiv"
echo "  ./configure --prefix=/usr/local CPPFLAGS=\"-I/usr/local/include\" LDFLAGS=\"-L/usr/local/lib\""
echo "  make -j\$(nproc)"
echo "  sudo make install"
echo ""
