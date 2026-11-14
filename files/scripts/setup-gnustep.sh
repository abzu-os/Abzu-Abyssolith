#!/usr/bin/env bash
set -euo pipefail
trap 'echo "setup-gnustep.sh failed at line $LINENO (exit $?)" >&2' ERR

# -----------------------------------------------------------------------------
# Build a complete GNUstep stack from source using Clang + libobjc2.
#
# Order:
#   1. libobjc2 (Objective-C runtime)
#   2. libdispatch (GCD - recommended)
#   3. gnustep-make (build system)
#   4. libs-base (Foundation)
#   5. libs-gui  (AppKit + Tools/GSspell)
#   6. libs-back (display back-end)
# -----------------------------------------------------------------------------

export HOME="${HOME:-/root}"
export USER="${USER:-root}"
export LOGNAME="${LOGNAME:-root}"
export TERM="${TERM:-xterm-256color}"
export XDG_DATA_DIRS="${XDG_DATA_DIRS:-/usr/local/share:/usr/share}"

export CC="${CC:-/usr/bin/clang}"
export CXX="${CXX:-/usr/bin/clang++}"
export LD="${LD:-/usr/bin/ld.lld}"
export LDFLAGS="${LDFLAGS:--fuse-ld=/usr/bin/ld.lld}"

BUILD_ROOT="/tmp/abzu-gnustep-build"
mkdir -p "${BUILD_ROOT}"
cd "${BUILD_ROOT}"

# --- 0. Pre-flight checks ----------------------------------------------------
echo "--- Verifying GNUstep build prerequisites ---"
require_cmd() {
  if ! command -v "$1" >/dev/null 2>&1; then
    echo "ERROR: required command '$1' is not installed." >&2
    exit 1
  fi
}
require_cmd clang clang++ cmake make pkg-config git python3
pkg-config --exists x11 || { echo "ERROR: X11 headers missing."; exit 1; }
pkg-config --exists cairo || { echo "ERROR: Cairo headers missing."; exit 1; }
pkg-config --exists libffi || { echo "ERROR: libffi headers missing."; exit 1; }
pkg-config --exists gnutls || { echo "ERROR: GnuTLS headers missing."; exit 1; }
pkg-config --exists libxml-2.0 || { echo "ERROR: libxml2 headers missing."; exit 1; }
pkg-config --exists libxslt || { echo "ERROR: libxslt headers missing."; exit 1; }
pkg-config --exists zlib || { echo "ERROR: zlib headers missing."; exit 1; }
pkg-config --exists libcurl || { echo "ERROR: libcurl headers missing."; exit 1; }
echo "Prerequisites satisfied."

# --- 1. Build libobjc2 -------------------------------------------------------
echo "--- Building libobjc2 (Clang-compatible Objective-C runtime) ---"
git clone --recurse-submodules https://github.com/gnustep/libobjc2.git
cd libobjc2
mkdir -p build && cd build
cmake .. \
    -DCMAKE_C_COMPILER="${CC}" \
    -DCMAKE_CXX_COMPILER="${CXX}" \
    -DCMAKE_ASM_COMPILER="${CC}" \
    -DCMAKE_LINKER="${LD}" \
    -DCMAKE_BUILD_TYPE=RelWithDebInfo \
    -DCMAKE_INSTALL_PREFIX=/usr/local
make -j"$(nproc)"
make install
cd "${BUILD_ROOT}"

# --- 2. Build libdispatch (GCD) ---------------------------------------------
# Recommended for a complete Foundation (NSOperationQueue, dispatch queues, etc.).
echo "--- Building libdispatch (Grand Central Dispatch) ---"
git clone https://github.com/apple/swift-corelibs-libdispatch.git
cd swift-corelibs-libdispatch
mkdir -p build && cd build
cmake .. \
    -DCMAKE_C_COMPILER="${CC}" \
    -DCMAKE_CXX_COMPILER="${CXX}" \
    -DCMAKE_BUILD_TYPE=RelWithDebInfo \
    -DINSTALL_PRIVATE_HEADERS=YES \
    -DCMAKE_INSTALL_PREFIX=/usr/local
make -j"$(nproc)"
make install
cd "${BUILD_ROOT}"

# --- 3. Build and install gnustep-make with Clang + libobjc2 ----------------
echo "--- Building gnustep-make (with Clang + libobjc2) ---"
git clone https://github.com/gnustep/tools-make.git
cd tools-make
./configure \
    --prefix=/usr/local \
    --with-layout=gnustep \
    --with-library-combo=ng-gnu-gnu \
    --with-objc-lib-flag=objc2 \
    --enable-native-objc-exceptions \
    --enable-objc-arc \
    CC="${CC}" CXX="${CXX}"
make -j"$(nproc)"
make install
cd "${BUILD_ROOT}"

GNUSTEP_SH="/usr/local/System/Library/Makefiles/GNUstep.sh"
if [ ! -f "${GNUSTEP_SH}" ]; then
    echo "ERROR: expected ${GNUSTEP_SH} not found." >&2
    find /usr/local /usr/lib64 /usr/share -name 'GNUstep.sh' 2>/dev/null || true
    exit 1
fi
echo "Found GNUstep.sh at ${GNUSTEP_SH}"

# Make GNUstep libraries discoverable at runtime.
mkdir -p /etc/ld.so.conf.d
echo "/usr/local/System/Library/Libraries" > /etc/ld.so.conf.d/gnustep.conf
ldconfig || true

set +u
# shellcheck disable=SC1090
. "${GNUSTEP_SH}"
set -u

# --- 4. Build GNUstep Base (libs-base) from source --------------------------
# Building Base from source eliminates the system-header incompatibility
# (__block on an ivar) and guarantees ABI consistency with libobjc2.
echo "--- Building gnustep-base (libs-base) from source ---"
git clone https://github.com/gnustep/libs-base.git
cd libs-base

# The base configure should inherit the library combo from gnustep-make,
# but we pass the same flags explicitly to be safe.
# --disable-mixedabi avoids linking against the system GCC Objective-C runtime.
./configure \
    --prefix=/usr/local \
    --with-library-combo=ng-gnu-gnu \
    --with-objc-lib-flag=objc2 \
    --enable-native-objc-exceptions \
    --enable-objc-arc \
    --disable-mixedabi \
    CC="${CC}" CXX="${CXX}"
make -j"$(nproc)"
make install
cd "${BUILD_ROOT}"

# --- 5. Build GNUstep GUI (full, including Tools/GSspell) -------------------
echo "--- Building gnustep-gui (full, including Tools/GSspell) ---"
git clone https://github.com/gnustep/libs-gui.git
cd libs-gui

# Patch NSApplication.m format-security violation.
sed -i \
    's|format: _(@"\[NSApplication -init\] called more than once")|format: @"%@", _(@"[NSApplication -init] called more than once")|' \
    Source/NSApplication.m || true
echo "Patched NSApplication.m format-security violation."

# Patch GSTheme.m fast-enumeration macros.
sed -i -E \
    's/GS_FOR_IN\(([^,]+),\s*([^,]+),\s*([^)]+)\)/for (\1 \2 in \3) {/g' \
    Source/GSTheme.m
sed -i -E 's/GS_END_FOR\([^)]*\)/}/g' Source/GSTheme.m
echo "Patched GSTheme.m fast-enumeration macros."

GUI_OBJCFLAGS="-Wno-error=format-security -Wno-error=incompatible-pointer-types"
./configure --prefix=/usr/local
make -j"$(nproc)" OBJCFLAGS="${GUI_OBJCFLAGS}"
make install
cd "${BUILD_ROOT}"

# --- 6. Build GNUstep Back ---------------------------------------------------
echo "--- Building gnustep-back ---"
git clone https://github.com/gnustep/libs-back.git
cd libs-back

# Patch XGServerEvent.m fast-enumeration macros.
python3 - <<'PYEOF'
path = "Source/x11/XGServerEvent.m"
with open(path, 'r') as f:
    text = f.read()

def find_matching_paren(s, start):
    depth = 0
    i = start
    while i < len(s):
        ch = s[i]
        if ch == '(':
            depth += 1
        elif ch == ')':
            depth -= 1
            if depth == 0:
                return i
        i += 1
    return -1

out = []
i = 0
while i < len(text):
    if text.startswith("GS_FOR_IN", i):
        paren_start = text.find('(', i)
        if paren_start == -1:
            out.append(text[i:]); break
        paren_end = find_matching_paren(text, paren_start)
        if paren_end == -1:
            out.append(text[i:]); break
        args = text[paren_start + 1: paren_end]
        parts, depth, current = [], 0, []
        for ch in args:
            if ch == '(':
                depth += 1
            elif ch == ')':
                depth -= 1
            if ch == ',' and depth == 0:
                parts.append(''.join(current).strip()); current = []
            else:
                current.append(ch)
        if current:
            parts.append(''.join(current).strip())
        if len(parts) == 3:
            typ, var, coll = parts
            out.append(f"for ({typ} {var} in {coll}) {{")
        else:
            out.append(text[i: paren_end + 1])
        i = paren_end + 1
    elif text.startswith("GS_END_FOR", i):
        paren_start = text.find('(', i)
        if paren_start != -1:
            paren_end = find_matching_paren(text, paren_start)
            if paren_end != -1:
                i = paren_end + 1
                out.append("}")
                continue
        out.append(text[i]); i += 1
    else:
        out.append(text[i]); i += 1

with open(path, 'w') as f:
    f.write(''.join(out))
PYEOF
echo "Patched XGServerEvent.m fast-enumeration macros."

./configure --prefix=/usr/local
make -j"$(nproc)"
make install
cd "${BUILD_ROOT}"

# --- 7. Verify GSspell is installed -----------------------------------------
echo "--- Verifying GSspell is installed ---"
if ! find /usr/local -type d -name 'GSspell.service' 2>/dev/null | grep -q .; then
    echo "WARNING: GSspell.service not found after libs-gui install. Rebuilding Tools ..."
    cd "${BUILD_ROOT}/libs-gui"
    set +u
    # shellcheck disable=SC1090
    . "${GNUSTEP_SH}"
    set -u
    make -C Tools -j"$(nproc)"
    make -C Tools -j"$(nproc)" install
    cd "${BUILD_ROOT}"
fi

if find /usr/local -type d -name 'GSspell.service' 2>/dev/null | grep -q .; then
    echo "GSspell.service: OK"
    find /usr/local -type d -name 'GSspell.service' 2>/dev/null
else
    echo "ERROR: GSspell.service is still missing after rebuild." >&2
    exit 1
fi

echo "--- GNUstep build complete (including libs-base and GSspell) ---"
