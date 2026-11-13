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
# GSTheme.m in libs-gui uses the GS_FOR_IN / GS_END_FOR macros, which are
# defined in GSFastEnumeration.h. That header is no longer shipped at the
# expected path in libs-base. Rather than depending on it, we patch GSTheme.m
# to use standard fast-enumeration loops instead.
#
# The GSspell service fails to build because make_services cannot load the
# newly compiled libgnustep-gui library in this environment. This is a known
# issue; skipping the Tools/GSspell service allows the rest of gnustep-gui
# to install successfully.
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
    echo "Add the corresponding package to the recipe's dnf list." >&2
    exit 1
  fi
}

require_cmd clang
require_cmd clang++
require_cmd cmake
require_cmd make
require_cmd pkg-config
require_cmd git

if ! pkg-config --exists x11; then
  echo "ERROR: X11 development headers not found." >&2
  exit 1
fi
if ! pkg-config --exists cairo; then
  echo "ERROR: Cairo development headers not found." >&2
  exit 1
fi

echo "Prerequisites satisfied."

# --- 1. Build GNUstep GUI and back from upstream source ------------------
echo "--- Building gnustep-gui from source ---"

git clone --depth 1 https://github.com/gnustep/libs-gui.git
cd libs-gui

# Patch NSApplication.m format-security violation.
if grep -q 'format: _(@"\[NSApplication -init\] called more than once")' \
        Source/NSApplication.m; then
  sed -i \
    's|format: _(@"\[NSApplication -init\] called more than once")|format: @"%@", _(@"[NSApplication -init] called more than once")|' \
    Source/NSApplication.m
  echo "Patched NSApplication.m format-security violation."
else
  echo "WARNING: expected format-security line not found in NSApplication.m." >&2
fi

# Patch GSTheme.m to replace GS_FOR_IN / GS_END_FOR macros with standard loops.
if grep -q 'GS_FOR_IN' Source/GSTheme.m; then
  sed -i -E \
    's/GS_FOR_IN\(([^,]+),\s*([^,]+),\s*([^)]+)\)/for (\1 \2 in \3) {/g' \
    Source/GSTheme.m
  sed -i -E \
    's/GS_END_FOR\([^)]*\)/}/g' \
    Source/GSTheme.m
  echo "Patched GSTheme.m fast-enumeration macros."
else
  echo "GS_FOR_IN not found in GSTheme.m; no patch needed." >&2
fi

# Skip building the GSspell service, which fails because make_services
# cannot load libgnustep-gui in this environment. The rest of gnustep-gui
# builds and installs correctly without it.
if [ -f Tools/GNUmakefile ]; then
  # Comment out the GSspell service definition so it is not built.
  sed -i 's/^\(SERVICE_NAME = GSspell\)/# \1/' Tools/GNUmakefile
  echo "Patched Tools/GNUmakefile to skip GSspell service."
else
  echo "WARNING: Tools/GNUmakefile not found; GSspell may still be built." >&2
fi

GUI_OBJCFLAGS="-Wno-error=format-security -Wno-error=incompatible-pointer-types"

./configure --prefix=/usr/local
make -j"$(nproc)" OBJCFLAGS="${GUI_OBJCFLAGS}"
make install

cd "${BUILD_ROOT}"

echo "--- Building gnustep-back from source ---"

git clone --depth 1 https://github.com/gnustep/libs-back.git
cd libs-back

BACK_OBJCFLAGS="-Wno-error=format-security -Wno-error=incompatible-pointer-types"

./configure --prefix=/usr/local
make -j"$(nproc)" OBJCFLAGS="${BACK_OBJCFLAGS}"
make install

cd "${BUILD_ROOT}"

# --- 2. Build the Gershwin components we need ----------------------------
echo "--- Building Gershwin components (Eau theme, Menu.app) ---"

git clone --depth 1 https://github.com/gershwin-desktop/gershwin-developer.git /Developer
cd /Developer

make eau-theme
make menu
make install

cd "${BUILD_ROOT}"

# --- 3. Build GSDock -----------------------------------------------------
echo "--- Building GSDock ---"
if git clone --depth 1 https://github.com/gnustep/GSDock.git; then
  cd GSDock
  make
  make install
  cd "${BUILD_ROOT}"
else
  echo "WARNING: GSDock repository could not be cloned." >&2
  echo "The dock will be omitted; the rest of the session is unaffected." >&2
fi

# --- 4. Session startup wrapper -----------------------------------------
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
