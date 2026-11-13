#!/usr/bin/env bash
set -euo pipefail
trap 'echo "setup-gnustep.sh failed at line $LINENO (exit $?)" >&2' ERR

# -----------------------------------------------------------------------------
# Build and install GNUstep GUI/back from source, then the Gershwin
# components (Eau theme, Menu.app) and GSDock.
#
# Fedora 45 does not package gnustep-gui or gnustep-back. This script builds
# them directly from upstream source.
#
# Fedora's hardening flags include -Werror=format-security and
# -Werror=incompatible-pointer-types, both of which GNUstep's source triggers.
# We override OBJCFLAGS on the make command line so these specific warnings
# remain warnings rather than fatal errors.
#
# Both GSTheme.m (in libs-gui) and XGServerEvent.m (in libs-back) use the
# GS_FOR_IN / GS_END_FOR macros, which are defined in GSFastEnumeration.h.
# That header is not on the include path during these builds. We patch both
# files to use standard fast-enumeration loops instead.  The patch for
# XGServerEvent.m uses a small Python script because the macro invocations
# span multiple lines and contain pointer types.
#
# The GSspell service fails to build during the main gnustep-gui build because
# make_services cannot locate the freshly compiled libgnustep-gui. The
# documented workaround is to exclude the Tools subdirectory from the main
# build, then build GSspell separately after the library is installed.
# The separate build requires the GNUstep makefile environment (GNUSTEP_MAKEFILES)
# to be set; otherwise make cannot find common.make.  On Fedora the makefiles
# live in /usr/lib64/GNUstep/Makefiles (installed by the gnustep-make RPM),
# not under /usr/local.
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

# --- 1. Build GNUstep GUI (library only) -------------------------------------
echo "--- Building gnustep-gui (library only) ---"
git clone --depth 1 https://github.com/gnustep/libs-gui.git
cd libs-gui

# Patch NSApplication.m format-security violation.
sed -i \
  's|format: _(@"\[NSApplication -init\] called more than once")|format: @"%@", _(@"[NSApplication -init] called more than once")|' \
  Source/NSApplication.m || true
echo "Patched NSApplication.m format-security violation."

# Patch GSTheme.m to replace GS_FOR_IN / GS_END_FOR macros.
sed -i -E \
  's/GS_FOR_IN\(([^,]+),\s*([^,]+),\s*([^)]+)\)/for (\1 \2 in \3) {/g' \
  Source/GSTheme.m
sed -i -E 's/GS_END_FOR\([^)]*\)/}/g' Source/GSTheme.m
echo "Patched GSTheme.m fast-enumeration macros."

# Remove the Tools entry from the SUBPROJECTS list without corrupting the
# multi-line backslash syntax. The Tools directory contains GSspell, which
# fails during the main build due to a make_services library path issue.
sed -i '/^Tools \\$/d' GNUmakefile
echo "Removed Tools from SUBPROJECTS in libs-gui GNUmakefile."

GUI_OBJCFLAGS="-Wno-error=format-security -Wno-error=incompatible-pointer-types"
./configure --prefix=/usr/local
make -j"$(nproc)" OBJCFLAGS="${GUI_OBJCFLAGS}"
make install
cd "${BUILD_ROOT}"

# --- 2. Build GNUstep Back ---------------------------------------------------
echo "--- Building gnustep-back ---"
git clone --depth 1 https://github.com/gnustep/libs-back.git
cd libs-back

# Patch XGServerEvent.m to replace GS_FOR_IN / GS_END_FOR macros.
# The Python script below balances parentheses and handles multi-line
# invocations and pointer types (e.g. "NSWindow *").
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

# Replace GS_FOR_IN( type, var, collection ) { ... } with a standard
# fast-enumeration loop.  The macro body is everything up to the matching
# GS_END_FOR.
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
        # Split arguments at the top level (ignoring nested parentheses).
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
            # Fallback: leave as-is if the shape is unexpected.
            out.append(text[i: paren_end + 1])
        i = paren_end + 1
    elif text.startswith("GS_END_FOR", i):
        # Consume GS_END_FOR(...) and emit a closing brace.
        paren_start = text.find('(', i)
        if paren_start != -1:
            paren_end = find_matching_paren(text, paren_start)
            if paren_end != -1:
                i = paren_end + 1
                out.append('}')
                continue
        out.append(text[i])
        i += 1
    else:
        out.append(text[i])
        i += 1

text = ''.join(out)
with open(path, 'w') as f:
    f.write(text)
print("Patched XGServerEvent.m fast-enumeration macros.")
PYEOF

BACK_OBJCFLAGS="-Wno-error=format-security -Wno-error=incompatible-pointer-types"
./configure --prefix=/usr/local
make -j"$(nproc)" OBJCFLAGS="${BACK_OBJCFLAGS}"
make install
cd "${BUILD_ROOT}"

# --- 3. Build GSspell separately ---------------------------------------------
echo "--- Building GSspell separately ---"
git clone --depth 1 https://github.com/gnustep/libs-gui.git libs-gui-spell
cd libs-gui-spell
# Only build the Tools subdirectory (which provides GSspell).
cd Tools
# Source the GNUstep makefile environment so that GNUSTEP_MAKEFILES is set
# and common.make can be found. On Fedora the makefiles live under
# /usr/lib64/GNUstep/Makefiles (installed by the gnustep-make RPM); on other
# setups they may live under /usr/local/share. Try each known location,
# and fall back to exporting GNUSTEP_MAKEFILES directly.
GNUSTEP_SH=""
for candidate in \
  /usr/lib64/GNUstep/Makefiles/GNUstep.sh \
  /usr/local/share/GNUstep/Makefiles/GNUstep.sh \
  /usr/share/GNUstep/Makefiles/GNUstep.sh \
  /usr/local/lib64/GNUstep/Makefiles/GNUstep.sh ; do
  if [ -f "${candidate}" ]; then
    GNUSTEP_SH="${candidate}"
    break
  fi
done
if [ -n "${GNUSTEP_SH}" ]; then
  echo "Sourcing GNUstep environment from ${GNUSTEP_SH}"
  # shellcheck source=/dev/null
  . "${GNUSTEP_SH}"
else
  echo "WARNING: GNUstep.sh not found; exporting GNUSTEP_MAKEFILES directly." >&2
  export GNUSTEP_MAKEFILES=/usr/lib64/GNUstep/Makefiles
fi
# Set LD_LIBRARY_PATH to the install prefix so the newly installed library is found.
export LD_LIBRARY_PATH="/usr/local/lib64:/usr/local/lib:${LD_LIBRARY_PATH:-}"
make -j"$(nproc)"
make install
cd "${BUILD_ROOT}"

# --- 4. Build Gershwin components --------------------------------------------
echo "--- Building Gershwin components (Eau theme, Menu.app) ---"
git clone --depth 1 https://github.com/gershwin-desktop/gershwin-developer.git /Developer
cd /Developer
make eau-theme
make menu
make install
cd "${BUILD_ROOT}"

# --- 5. Build GSDock ---------------------------------------------------------
echo "--- Building GSDock ---"
if git clone --depth 1 https://github.com/gnustep/GSDock.git; then
  cd GSDock
  make
  make install
  cd "${BUILD_ROOT}"
else
  echo "WARNING: GSDock could not be cloned; skipping." >&2
fi

# --- 6. Session startup wrapper ----------------------------------------------
cat > /usr/local/bin/abzu-windowmaker-session <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
export GNUSTEP_USER_ROOT="${HOME}/GNUstep"
export GNUSTEP_LOCAL_ROOT="/usr/local/share/GNUstep"
export GNUSTEP_SYSTEM_ROOT="/usr/share/GNUstep"
export PATH="${GNUSTEP_USER_ROOT}/Tools:${GNUSTEP_LOCAL_ROOT}/Tools:${GNUSTEP_SYSTEM_ROOT}/Tools:${PATH}"
if command -v Menu >/dev/null 2>&1; then
  Menu &
fi
if command -v GSDock >/dev/null 2>&1; then
  GSDock &
fi
exec wmaker
EOF
chmod +x /usr/local/bin/abzu-windowmaker-session

echo "--- setup-gnustep.sh complete ---"
