#!/usr/bin/env bash
set -euo pipefail
trap 'echo "setup-gnustep.sh failed at line $LINENO (exit $?)" >&2' ERR

# -----------------------------------------------------------------------------
# Build and install GNUstep GUI/back from source, then the Gershwin
# components (Eau theme, Menu.app) and GSDock.
#
# Fedora 45 does not package gnustep-gui or gnustep-back. This script builds
# them directly from upstream source. Fedora's hardening flags include
# -Werror=format-security, which GNUstep's NSApplication.m triggers. We add a
# GNUmakefile.preamble to disable that specific error without patching source.
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

# Disable -Werror=format-security for this source tree.
# GNUstep's NSApplication.m uses a non-literal format string, which
# Fedora's default hardening flags turn into a fatal error. This is a
# known upstream incompatibility, not a local defect.
cat > GNUmakefile.preamble <<'EOF'
ADDITIONAL_OBJCFLAGS += -Wno-error=format-security
ADDITIONAL_CFLAGS += -Wno-error=format-security
EOF

./configure --prefix=/usr/local
make -j"$(nproc)"
make install

cd "${BUILD_ROOT}"

echo "--- Building gnustep-back from source ---"

git clone --depth 1 https://github.com/gnustep/libs-back.git
cd libs-back

# Apply the same format-security override here as a precaution. The
# libs-back source does not currently trigger the error, but it uses the
# same compiler flags and may do so in a future revision.
cat > GNUmakefile.preamble <<'EOF'
ADDITIONAL_OBJCFLAGS += -Wno-error=format-security
ADDITIONAL_CFLAGS += -Wno-error=format-security
EOF

./configure --prefix=/usr/local
make -j"$(nproc)"
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
