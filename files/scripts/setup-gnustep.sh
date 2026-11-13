#!/usr/bin/env bash
set -euo pipefail
trap 'echo "setup-gnustep.sh failed at line $LINENO (exit $?)" >&2' ERR

# -----------------------------------------------------------------------------
# Build & install GNUstep GUI/back, then Gershwin (Eau theme, Menu.app, System
# Preferences) and GSDock.
#
# Fedora 45 does NOT ship gnustep-gui or gnustep-back. They are therefore built
# from source here by driving Gershwin's own build system, whose `corelibs`
# target builds libobjc2, gnustep-base, gnustep-gui and gnustep-back in the
# correct order, then installs the Gershwin components on top.
#
# The upstream repository is `gershwin-developer`, and it expects to be checked
# out at /Developer. The bootstrap and checkout scripts live in
# /Developer/Library/Scripts/.
# -----------------------------------------------------------------------------

export HOME="${HOME:-/root}"
export USER="${USER:-root}"
export LOGNAME="${LOGNAME:-root}"
export TERM="${TERM:-xterm-256color}"
export XDG_DATA_DIRS="${XDG_DATA_DIRS:-/usr/local/share:/usr/share}"

# Use clang/LLVM, which Gershwin and modern GNUstep expect.
export CC="${CC:-/usr/bin/clang}"
export CXX="${CXX:-/usr/bin/clang++}"
export LD="${LD:-/usr/bin/ld.lld}"
export LDFLAGS="${LDFLAGS:--fuse-ld=/usr/bin/ld.lld}"

BUILD_ROOT="/tmp/abzu-gnustep-build"
mkdir -p "${BUILD_ROOT}"
cd "${BUILD_ROOT}"

# --- 0. Pre-flight: verify build toolchain and required dev headers ---
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

# X11 and Cairo are needed for the gnustep-back X11/Cairo backend.
if ! pkg-config --exists x11; then
  echo "ERROR: X11 development headers not found." >&2
  echo "Add libX11-devel (and friends) to the recipe." >&2
  exit 1
fi
if ! pkg-config --exists cairo; then
  echo "ERROR: Cairo development headers not found." >&2
  echo "Add cairo-devel to the recipe." >&2
  exit 1
fi
if ! pkg-config --exists libart-2.0; then
  echo "WARNING: libart_lgpl development headers not found." >&2
  echo "The ART backend will be skipped; Cairo backend will still be built." >&2
fi

echo "Prerequisites satisfied."

# --- 1. Build GNUstep core libraries (gui/back) via Gershwin's corelibs target ---
echo "--- Building GNUstep GUI/back (via Gershwin corelibs) ---"

# The upstream repository is gershwin-developer, checked out at /Developer.
git clone --depth 1 https://github.com/gershwin-desktop/gershwin-developer.git /Developer

cd /Developer

# Bootstrap and checkout live in /Developer/Library/Scripts/.
/Developer/Library/Scripts/bootstrap.sh
/Developer/Library/Scripts/checkout.sh

# `make corelibs` builds libobjc2, gnustep-base, gnustep-gui and gnustep-back
# from source.
make corelibs

# Install the Gershwin components (Eau theme, Menu.app, System Preferences).
make install

# Sanity check: the Eau theme should now exist somewhere under /usr/local.
if [ ! -d "/usr/local/share/GNUstep/Themes/Eau" ] && \
   [ ! -d "/usr/local/share/GNUstep/Library/Themes/Eau" ]; then
  echo "WARNING: Eau theme directory not found after Gershwin install." >&2
  echo "Searching for Eau theme..." >&2
  find /usr/local -type d -iname '*Eau*' 2>/dev/null || true
fi

cd "${BUILD_ROOT}"

# --- 2. Build GSDock (OS X-style dock) ---
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

# --- 3. Session startup wrapper ---
# Starts WindowMaker and any GNUstep daemons needed for the Eau theme / Menu.app.
cat > /usr/local/bin/abzu-windowmaker-session <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

# GNUstep environment
export GNUSTEP_USER_ROOT="${HOME}/GNUstep"
export GNUSTEP_LOCAL_ROOT="/usr/local/share/GNUstep"
export GNUSTEP_SYSTEM_ROOT="/usr/share/GNUstep"
export PATH="${GNUSTEP_USER_ROOT}/Tools:${GNUSTEP_LOCAL_ROOT}/Tools:${GNUSTEP_SYSTEM_ROOT}/Tools:${PATH}"

# Start the global menu bar (Menu.app) if available
if command -v Menu >/dev/null 2>&1; then
  Menu &
fi

# Start GSDock if available
if command -v GSDock >/dev/null 2>&1; then
  GSDock &
fi

# Launch WindowMaker (foreground)
exec wmaker
EOF
chmod +x /usr/local/bin/abzu-windowmaker-session

echo "--- setup-gnustep.sh complete ---"
