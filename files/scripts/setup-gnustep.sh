#!/usr/bin/env bash
set -euo pipefail
trap 'echo "setup-gnustep.sh failed at line $LINENO (exit $?)" >&2' ERR

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
echo "Prerequisites satisfied."

# --- 1. Build libobjc2 -------------------------------------------------------
echo "--- Building libobjc2 (Clang-compatible Objective-C runtime) ---"
git clone --depth 1 https://github.com/gnustep/libobjc2.git
cd libobjc2
mkdir -p build && cd build
cmake .. \
    -DCMAKE_C_COMPILER=clang \
    -DCMAKE_CXX_COMPILER=clang++ \
    -DCMAKE_INSTALL_PREFIX=/usr/local
make -j"$(nproc)"
make install
cd "${BUILD_ROOT}"

# --- 2. Build and install gnustep-make with Clang + libobjc2 ----------------
echo "--- Building gnustep-make (with Clang + libobjc2) ---"
git clone --depth 1 https://github.com/gnustep/tools-make.git
cd tools-make
./configure \
    --prefix=/usr/local \
    --with-layout=gnustep \
    --with-library-combo=ng-gnu-gnu \
    --with-objc-lib-flag=objc2 \
    CC=clang CXX=clang++
make -j"$(nproc)"
make install
cd "${BUILD_ROOT}"

# NOTE: With --with-layout=gnustep, the makefiles are installed under
# /usr/local/System/Library/Makefiles (NOT /usr/local/share/GNUstep/Makefiles).
GNUSTEP_SH="/usr/local/System/Library/Makefiles/GNUstep.sh"
if [ ! -f "${GNUSTEP_SH}" ]; then
    echo "ERROR: expected ${GNUSTEP_SH} not found. Available copies:" >&2
    find /usr/local /usr/lib64 /usr/share -name 'GNUstep.sh' 2>/dev/null || true
    exit 1
fi
echo "Found GNUstep.sh at ${GNUSTEP_SH}"

# Make GNUstep libraries discoverable at runtime, including for tools such as
# make_services that are invoked *during* the libs-gui install step.
mkdir -p /etc/ld.so.conf.d
echo "/usr/local/System/Library/Libraries" > /etc/ld.so.conf.d/gnustep.conf
ldconfig || true

# Source the GNUstep environment for subsequent builds.
# set +u is required because GNUstep.sh references some variables (e.g.
# ZSH_VERSION) without checking whether they are set.
set +u
# shellcheck disable=SC1090
. "${GNUSTEP_SH}"
set -u

echo "gnustep-config in PATH: $(command -v gnustep-config || echo 'NOT FOUND')"
if command -v gnustep-config >/dev/null 2>&1; then
    echo "GNUSTEP_MAKEFILES: $(gnustep-config --variable=GNUSTEP_MAKEFILES || true)"
fi

# --- 3. Build GNUstep GUI (full, including Tools/GSspell) -------------------
# We deliberately do NOT remove the Tools subproject. GSspell (which lives
# under Tools/) is built as part of the normal libs-gui "make all" / "make
# install" pass. Now that the whole stack consistently uses libobjc2, the
# make_services tool invoked during installation can generate the
# Info-gnustep.plist files correctly.
echo "--- Building gnustep-gui (full, including Tools/GSspell) ---"
git clone --depth 1 https://github.com/gnustep/libs-gui.git
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

# --- 4. Build GNUstep Back ---------------------------------------------------
echo "--- Building gnustep-back ---"
git clone --depth 1 https://github.com/gnustep/libs-back.git
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

# --- 5. Verify GSspell is installed -----------------------------------------
# GSspell should already be installed by the "make install" of libs-gui
# (it lives under Tools/GSspell). This is a defensive check only.
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

echo "--- GNUstep build complete (including GSspell) ---"
