#!/usr/bin/env bash
set -euo pipefail
trap 'echo "setup-gnustep.sh failed at line $LINENO (exit $?)" >&2' ERR

# -----------------------------------------------------------------------------
# Build and install GNUstep GUI/back from source, then the Gershwin
# components (Eau theme, Menu.app) and GSDock.
#
# This script ensures a consistent toolchain (Clang + libobjc2) is used for
# the entire GNUstep stack, which is required for make_services and GSspell
# to function correctly on Fedora.
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
echo "Prerequisites satisfied."

# --- 1. Build libobjc2 -------------------------------------------------------
echo "--- Building libobjc2 (Clang-compatible Objective-C runtime) ---"
git clone --depth 1 https://github.com/gnustep/libobjc2.git
cd libobjc2
mkdir -p build && cd build
cmake .. -DCMAKE_C_COMPILER=clang -DCMAKE_CXX_COMPILER=clang++ -DCMAKE_INSTALL_PREFIX=/usr/local
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

# Source the GNUstep environment for subsequent builds
. /usr/local/share/GNUstep/Makefiles/GNUstep.sh

# --- 3. Build GNUstep GUI (library and tools, including GSspell) ------------
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

# IMPORTANT: Do NOT remove the Tools directory. We need it for GSspell.
# The original workaround of excluding Tools is no longer necessary because
# the entire stack now uses libobjc2.

GUI_OBJCFLAGS="-Wno-error=format-security -Wno-error=incompatible-pointer-types"
./configure --prefix=/usr/local
make -j"$(nproc)" OBJCFLAGS="${GUI_OBJCFLAGS}"
make install
cd "${BUILD_ROOT}"

# --- 4. Build GNUstep Back ---------------------------------------------------
echo "--- Building gnustep-back ---"
git clone --depth 1 https://github.com/gnustep/libs-back.git
cd libs-back

# Patch XGServerEvent.m to replace GS_FOR_IN / GS_END_FOR macros.
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
            out.append(text[i:])
            break
        paren_end = find_matching_paren(text, paren_start)
        if paren_end == -1:
            out.append(text[i:])
            break
        args = text[paren_start + 1: paren_end]
        parts = []
        depth = 0
        current = []
        for ch in args:
            if ch == '(':
                depth += 1
            elif ch == ')':
                depth -= 1
            if ch == ',' and depth == 0:
                parts.append(''.join(current).strip())
                current = []
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
        out.append(text[i])
        i += 1
    else:
        out.append(text[i])
        i += 1

with open(path, 'w') as f:
    f.write(''.join(out))
PYEOF
echo "Patched XGServerEvent.m fast-enumeration macros."

./configure --prefix=/usr/local
make -j"$(nproc)"
make install
cd "${BUILD_ROOT}"

# --- 5. Build GSspell separately (as a safety net) --------------------------
# Even with a consistent toolchain, building GSspell after the main library
# installation is the most reliable sequence. This step is now largely
# redundant but ensures the service is properly registered.
echo "--- Building GSspell separately (ensuring service registration) ---"
cd "${BUILD_ROOT}/libs-gui"
# The Tools directory is already part of the tree. We build just the service.
export PATH="${BUILD_ROOT}/libs-gui/Tools:${PATH}"
export LD_LIBRARY_PATH="/usr/local/lib:/usr/local/lib64:${LD_LIBRARY_PATH:-}"
# Temporarily disable nounset for GNUstep.sh which references $ZSH_VERSION.
set +u
. /usr/local/share/GNUstep/Makefiles/GNUstep.sh
set -u
make -C Tools -j"$(nproc)" GSspell.all.service.variables
make -C Tools -j"$(nproc)" GSspell.install.service.variables
cd "${BUILD_ROOT}"

echo "--- GNUstep build complete (including GSspell) ---"
