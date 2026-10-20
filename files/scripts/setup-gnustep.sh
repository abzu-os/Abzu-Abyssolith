#!/usr/bin/env bash
set -euo pipefail
trap 'echo "setup-gnustep.sh failed at line $LINENO (exit $?)" >&2' ERR

# -----------------------------------------------------------------------------
# Build & install Gershwin (Eau theme, Menu.app, System Preferences) and GSDock.
#
# Gershwin provides the Aqua-style "Liquid Glass" GNUstep theme engine
# (gershwin-eau-theme) and the global menu bar (Menu.app).
# GSDock provides the macOS-style bottom dock.
#
# Both are built from source because neither is packaged for Fedora yet.
# -----------------------------------------------------------------------------

export HOME="${HOME:-/root}"
export USER="${USER:-root}"
export LOGNAME="${LOGNAME:-root}"
export TERM="${TERM:-xterm-256color}"
export XDG_DATA_DIRS="${XDG_DATA_DIRS:-/usr/local/share:/usr/share}"

BUILD_ROOT="/tmp/abzu-gnustep-build"
mkdir -p "${BUILD_ROOT}"
cd "${BUILD_ROOT}"

# --- 1. Build Gershwin (corelibs, windowmanager, systempreferences, Menu) ---
echo "--- Building Gershwin ---"
git clone --depth 1 https://github.com/gershwin-desktop/gershwin-build.git
cd gershwin-build

# Gershwin expects GNUstep to be installed; Fedora packages are already present.
# We only need to build the Gershwin components themselves.
./bootstrap.sh
./checkout.sh
make install

# The Gershwin install places its theme bundle and Menu.app under /usr/local.
# Verify the Eau theme landed.
if [ ! -d "/usr/local/share/GNUstep/Themes/Eau" ] && \
   [ ! -d "/usr/local/share/GNUstep/Library/Themes/Eau" ]; then
  echo "WARNING: Eau theme directory not found after Gershwin install." >&2
  echo "Searching for Eau theme..." >&2
  find /usr/local -type d -iname '*Eau*' 2>/dev/null || true
fi

cd "${BUILD_ROOT}"

# --- 2. Build GSDock (OS X-style dock) ---
echo "--- Building GSDock ---"
if git clone --depth 1 https://github.com/gnustep/GSDock.git 2>/dev/null; then
  cd GSDock
  # GSDock uses GNUstep-make
  make
  make install
  cd "${BUILD_ROOT}"
else
  echo "WARNING: GSDock repository could not be cloned." >&2
  echo "You may need to adjust the repository URL or install GSDock manually." >&2
fi

# --- 3. Session startup wrapper ---
# The wrapper starts WindowMaker and any GNUstep daemons needed for the
# Eau theme / Menu.app integration.
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
