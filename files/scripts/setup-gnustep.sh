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
# files to use standard fast-enumeration loops instead.
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

# --- 0. Pre-flight checks -------------------------------------------------
echo "--- Verifying GNUstep build prerequisites ---"
require_cmd() {
  if ! command -v "$1" >/dev/null 2>&1; then
    echo "ERROR: required command '$1' is not installed." >&2
    exit 1
  fi
}
require_cmd clang clang++ cmake make pkg-config git
pkg-config --exists x11 || { echo "ERROR: X11 headers missing."; exit 1; }
pkg-config --exists cairo || { echo "ERROR: Cairo headers missing."; exit 1; }
echo "Prerequisites satisfied."

# --- 1. Build GNUstep GUI -------------------------------------------------
echo "--- Building gnustep-gui ---"
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

GUI_OBJCFLAGS="-Wno-error=format-security -Wno-error=incompatible-pointer-types"
./configure --prefix=/usr/local
make -j"$(nproc)" OBJCFLAGS="${GUI_OBJCFLAGS}"
make install

cd "${BUILD_ROOT}"

# --- 2. Build GNUstep Back ------------------------------------------------
echo "--- Building gnustep-back ---"
git clone --depth 1 https://github.com/gnustep/libs-back.git
cd libs-back

# Patch XGServerEvent.m to replace GS_FOR_IN / GS_END_FOR macros.
sed -i -E \
  's/GS_FOR_IN\(([^,]+),\s*([^,]+),\s*([^)]+)\)/for (\1 \2 in \3) {/g' \
  Source/x11/XGServerEvent.m
sed -i -E 's/GS_END_FOR\([^)]*\)/}/g' Source/x11/XGServerEvent.m
echo "Patched XGServerEvent.m fast-enumeration macros."

BACK_OBJCFLAGS="-Wno-error=format-security -Wno-error=incompatible-pointer-types"
./configure --prefix=/usr/local
make -j"$(nproc)" OBJCFLAGS="${BACK_OBJCFLAGS}"
make install

cd "${BUILD_ROOT}"

# --- 3. Build Gershwin components ----------------------------------------
echo "--- Building Gershwin components (Eau theme, Menu.app) ---"
git clone --depth 1 https://github.com/gershwin-desktop/gershwin-developer.git /Developer
cd /Developer
make eau-theme
make menu
make install
cd "${BUILD_ROOT}"

# --- 4. Build GSDock -----------------------------------------------------
echo "--- Building GSDock ---"
if git clone --depth 1 https://github.com/gnustep/GSDock.git; then
  cd GSDock
  make
  make install
  cd "${BUILD_ROOT}"
else
  echo "WARNING: GSDock could not be cloned; skipping." >&2
fi

# --- 5. Session startup wrapper -----------------------------------------
cat > /usr/local/bin/abzu-windowmaker-session <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
export GNUSTEP_USER_ROOT="${HOME}/GNUstep"
export GNUSTEP_LOCAL_ROOT="/usr/local/share/GNUstep"
export GNUSTEP_SYSTEM_ROOT="/usr/share/GNUstep"
export PATH="${GNUSTEP_USER_ROOT}/Tools:${GNUSTEP_LOCAL_ROOT}/Tools:${GNUSTEP_SYSTEM_ROOT}/Tools:${PATH}"
if command -v Menu >/dev/null 2>&1; then Menu & fi
if command -v GSDock >/dev/null 2>&1; then GSDock & fi
exec wmaker
EOF
chmod +x /usr/local/bin/abzu-windowmaker-session

echo "--- setup-gnustep.sh complete ---"
