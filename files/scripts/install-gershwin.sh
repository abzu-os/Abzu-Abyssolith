#!/usr/bin/env bash
set -euo pipefail

# -----------------------------------------------------------------------------
# install-gershwin.sh
#
# Builds and installs the core Gershwin desktop environment components
# on top of the source-built GNUstep stack produced by setup-gnustep.sh:
#
#   • Eau theme        (visual theme, global menu integration)
#   • Menu.app         (global menu bar)
#   • Workspace.app    (file manager + desktop + Dock)
#   • WindowManager    (native X11 window manager)
#
# The script deliberately does NOT use gershwin-build / gershwin-developer,
# because that orchestrator rebuilds the entire GNUstep core stack. We already
# have a consistent Clang + libobjc2 stack from setup-gnustep.sh and want to
# build only the Gershwin-specific components against it.
#
# It is idempotent: re-running it re-clones and rebuilds the components.
# -----------------------------------------------------------------------------

# --- GNUstep environment ----------------------------------------------------
# setup-gnustep.sh installs gnustep-make with --with-layout=gnustep, so the
# environment script lives here. Source it so gmake, gnustep-config and the
# GNUstep filesystem layout are correct for every component build.
GNUSTEP_SH="/usr/local/System/Library/Makefiles/GNUstep.sh"
if [[ ! -f "${GNUSTEP_SH}" ]]; then
    echo "ERROR: ${GNUSTEP_SH} not found. Run setup-gnustep.sh first." >&2
    exit 1
fi

# GNUstep.sh references some unset variables (e.g. ZSH_VERSION), so we must
# relax nounset while sourcing it.
set +u
# shellcheck disable=SC1090
. "${GNUSTEP_SH}"
set -u

# Make sure the source-built gnustep-config is the one that will be used.
export PATH="/usr/local/System/Tools:${PATH}"

echo "--- Verifying GNUstep environment ---"
if ! command -v gnustep-config >/dev/null 2>&1; then
    echo "ERROR: gnustep-config not found after sourcing ${GNUSTEP_SH}." >&2
    exit 1
fi
echo "GNUSTEP_MAKEFILES: $(gnustep-config --variable=GNUSTEP_MAKEFILES)"
echo "GNUSTEP_SYSTEM_LIBRARIES: $(gnustep-config --variable=GNUSTEP_SYSTEM_LIBRARIES)"

# --- Build root --------------------------------------------------------------
BUILD_ROOT="/tmp/abzu-gershwin-build"
mkdir -p "${BUILD_ROOT}"
cd "${BUILD_ROOT}"

# --- Helper: clone, build and install one component -------------------------
# Usage: build_component <name> <repository-url> <make-target-optional>
build_component() {
    local name="$1"
    local repo="$2"
    local make_target="${3:-}"

    echo "--- Building ${name} ---"
    if [[ -d "${name}" ]]; then
        echo "Removing existing ${name} checkout"
        rm -rf "${name}"
    fi

    git clone --depth 1 "${repo}" "${name}"
    cd "${name}"

    if [[ -n "${make_target}" ]]; then
        # Some components (e.g. the WindowManager) provide a top-level target
        # that builds all subprojects.
        gmake "${make_target}"
    else
        gmake
    fi
    gmake install

    cd "${BUILD_ROOT}"
}

# --- 1. Eau theme -----------------------------------------------------------
# The Eau theme provides the macOS-like look and the Distributed Objects IPC
# hooks that Menu.app uses to populate the global menu bar.
build_component \
    "gershwin-eau-theme" \
    "https://github.com/gershwin-desktop/gershwin-eau-theme.git"

# --- 2. Gershwin components (includes Menu.app) -----------------------------
# gershwin-components is a monorepo of applications and preference panes.
# We build the whole repository; the Menu target will produce Menu.app.
# It requires libdbus for the Canonical AppMenu protocol; the BlueBuild recipe
# already installs dbus-devel.
build_component \
    "gershwin-components" \
    "https://github.com/gershwin-desktop/gershwin-components.git"

# --- 3. Gershwin Workspace (File Manager, Desktop and Dock) -----------------
# Workspace.app provides the desktop, file manager and the Dock that the
# Gershwin environment uses.
build_component \
    "gershwin-workspace" \
    "https://github.com/gershwin-desktop/gershwin-workspace.git"

# --- 4. Gershwin Window Manager ---------------------------------------------
# The native X11 window manager is required for the full Gershwin experience
# (window decorations, focus handling, workspace switching).
build_component \
    "gershwin-windowmanager" \
    "https://github.com/gershwin-desktop/gershwin-windowmanager.git"

# --- 5. Verification --------------------------------------------------------
echo "--- Verifying Gershwin installation ---"

check_path() {
    local path="$1"
    local description="$2"
    if [[ -e "${path}" ]]; then
        echo "OK: ${description} (${path})"
    else
        echo "WARNING: ${description} not found at ${path}" >&2
    fi
}

GNUSTEP_SYSTEM_LIB="$(gnustep-config --variable=GNUSTEP_SYSTEM_LIBRARIES)"
GNUSTEP_SYSTEM_APPS="$(gnustep-config --variable=GNUSTEP_SYSTEM_APPS)"

check_path "${GNUSTEP_SYSTEM_LIB}/Themes/Eau.theme" "Eau theme"
check_path "${GNUSTEP_SYSTEM_APPS}/Menu.app" "Menu.app"
check_path "${GNUSTEP_SYSTEM_APPS}/Workspace.app" "Workspace.app"
check_path "${GNUSTEP_SYSTEM_APPS}/WindowManager.app" "WindowManager.app"

echo "--- Gershwin installation complete ---"
