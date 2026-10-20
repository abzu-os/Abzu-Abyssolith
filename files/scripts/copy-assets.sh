#!/usr/bin/env bash
set -oue pipefail

# -----------------------------------------------------------------------------
# copy-assets.sh
#
# Retains and deploys the Abzu-specific visual assets that survive the
# transition to GNUstep / WindowMaker:
#
#   • Custom wallpapers  → /usr/share/backgrounds/abzu
#   • Custom icons      → /usr/share/icons/hicolor
#   • Icon cache        → regenerated so GNUstep launchers (GSDock, Menu.app)
#                         and any retained GTK applications see the icons
#
# The script is intentionally idempotent and safe to run on every build.
# -----------------------------------------------------------------------------

echo "::group::Deploying Abzu visual assets"

# --- Wallpapers -------------------------------------------------------------
# Wallpapers are expected under files/wallpapers/ in the repository.
# If that directory does not exist, the build continues without failing.
WALLPAPER_SRC="/tmp/files/wallpapers"
WALLPAPER_DEST="/usr/share/backgrounds/abzu"

if [[ -d "${WALLPAPER_SRC}" ]]; then
  echo "Deploying wallpapers from ${WALLPAPER_SRC} to ${WALLPAPER_DEST}"
  mkdir -p "${WALLPAPER_DEST}"
  # Copy all files while preserving relative paths and permissions.
  cp -a "${WALLPAPER_SRC}/." "${WALLPAPER_DEST}/"
else
  echo "No files/wallpapers/ directory found — skipping wallpaper deployment."
fi

# --- Custom Icons ----------------------------------------------------------
# The declarative files module already copies files/system/usr/share/icons/
# hicolor into the image, but we re-assert the deployment here so that the
# icon cache is regenerated after any scripted changes.
ICON_SRC="/tmp/files/system/usr/share/icons/hicolor"
ICON_DEST="/usr/share/icons/hicolor"

if [[ -d "${ICON_SRC}" ]]; then
  echo "Deploying custom icons from ${ICON_SRC} to ${ICON_DEST}"
  mkdir -p "${ICON_DEST}"
  cp -a "${ICON_SRC}/." "${ICON_DEST}/"
else
  echo "Custom icon source not found — relying on files-module deployment."
fi

# --- Icon cache -------------------------------------------------------------
# Regenerate the hicolor icon cache so GSDock, Menu.app and any retained GTK
# applications immediately see the Abzu icons without a logout.
if [[ -d "${ICON_DEST}" ]]; then
  echo "Regenerating hicolor icon cache"
  gtk-update-icon-cache -f -t "${ICON_DEST}" || {
    echo "gtk-update-icon-cache failed — icon cache may be stale." >&2
  }
fi

echo "::endgroup::"
echo "Asset deployment complete."
