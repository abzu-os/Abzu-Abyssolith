#!/usr/bin/env bash
set -euo pipefail

echo "--- Installing Quiver Launcher (AppImage) ---"

# Quiver Launcher is a single launcher that replaces the five standalone
# installs this image used to ship:
#   * Daggerfall Unity             -> Interkarma/daggerfall-unity            (community catalog)
#   * 2 Ship 2 Harkinian           -> HarbourMasters/2ship2harkinian         (community catalog)
#   * Super Mario Bros. Remastered -> JHDev2006/Super-Mario-Bros.-Remastered-Public (community catalog)
#   * SA Mod Manager               -> not covered; use Flatpak Hedge Mod Manager
# The games themselves are NOT baked into the image any more -- Quiver
# downloads and updates them per user, so the image stays slim.
#
# Deferred (Windows/macOS-only releases, no Linux build yet -- revisit when
# upstream ships one): elliotttate/DKC1Recomp, DKC2Recomp, DKC3Recomp.
# NOTE: Wave Race 64 IS seeded below -- the user picked DomazinUS/RaceWave46
# because it is the only WR64 recomp with ray-traced water (DXR via RT64).
# Its catalog entry (and elliotttate/wave-race-64-recomp's) are recorded in
# the community catalog should you want to subscribe instead.

REPO="tgeorgiadis/quiver-launcher"
ARCH="$(uname -m)"

case "${ARCH}" in
    x86_64)  ASSET_PATTERN="linux-x64.AppImage" ;;
    aarch64) ASSET_PATTERN="linux-arm64.AppImage" ;;
    *)
        echo "ERROR: Unsupported architecture for Quiver Launcher: ${ARCH}" >&2
        exit 1
        ;;
esac

echo "  Querying latest release of ${REPO} (${ASSET_PATTERN})..."
RELEASE_JSON=$(curl -fsSL "https://api.github.com/repos/${REPO}/releases/latest") || {
    echo "ERROR: Could not query releases for ${REPO}." >&2
    exit 1
}

# Match the AppImage asset for this architecture only. Release filenames are
# stable ("QuiverLauncher-linux-x64.AppImage"), but match on the suffix so an
# upstream version stamp in the name would not break us.
ASSET_URL=$(echo "${RELEASE_JSON}" \
    | jq -r --arg pat "${ASSET_PATTERN}" \
        '.assets[] | select(.name | endswith($pat)) | .browser_download_url' \
    | head -n 1)

if [ -z "${ASSET_URL}" ] || [ "${ASSET_URL}" = "null" ]; then
    echo "ERROR: No '${ASSET_PATTERN}' asset found in the latest release of ${REPO}." >&2
    echo "       Available assets:" >&2
    echo "${RELEASE_JSON}" | jq -r '.assets[].name' >&2 || true
    exit 1
fi

TAG=$(echo "${RELEASE_JSON}" | jq -r '.tag_name')
echo "  Latest release: ${TAG}"
echo "  Downloading: ${ASSET_URL}"

mkdir -p /opt/quiver
cd /opt/quiver
curl -fL -o quiver.AppImage "${ASSET_URL}"
chmod +x quiver.AppImage

# Sanity check: the download must be an ELF binary, not an HTML error page.
FIRST_BYTES=$(od -A n -t x1 -N 4 quiver.AppImage | tr -d ' \n')
if [ "${FIRST_BYTES}" != "7f454c46" ]; then
    echo "ERROR: quiver.AppImage does not start with the ELF magic bytes (got ${FIRST_BYTES})." >&2
    echo "       Downloaded $(stat -c %s quiver.AppImage) bytes; the download probably failed." >&2
    exit 1
fi

# Seed the library with the entries that used to be installed standalone.
# Quiver keeps apps.json beside the AppImage, which is read-only on an
# immutable image, so it falls back to $XDG_DATA_HOME/QuiverLauncher (i.e.
# ~/.local/share/QuiverLauncher -- note the capitalisation: Services/
# QuiverLauncherPaths.cs uses AppName = "QuiverLauncher"). Drop a starter
# file there via /etc/skel; the quiver-setup justfile recipe copies it in
# place if the user wants it.
#
# Every entry below is copied VERBATIM from the live community catalog
# (tgeorgiadis/quiver-community-app-catalog, community-app-catalog/*.json).
# That matters for two reasons:
#   1. Quiver identifies library tiles by InstanceKey =
#      "{source}:{repository}:{folderName}" (Services/RepositorySourceHelper.cs)
#      and dedupes local apps against subscribed catalogs on that key
#      (AppCatalogService.DedupeByRepository). Any deviation in folderName
#      creates a duplicate tile instead of merging with the catalog row.
#   2. The parser reads exactly these camelCase fields: name, project,
#      repository, folderName, tags, appIconUrl (GetIconUrl also accepts
#      gameIconUrl/customDefaultIconUrl as legacy aliases). Unknown or
#      mis-cased keys are silently dropped, so hand-rolled schemas break.
mkdir -p /etc/skel/.local/share/QuiverLauncher
cat > /etc/skel/.local/share/QuiverLauncher/apps.json << 'EOF'
{
  "apps": [
    {
      "name": "The Elder Scrolls II: Daggerfall",
      "project": "Daggerfall Unity",
      "repository": "Interkarma/daggerfall-unity",
      "folderName": "TheElderScrollsIIDaggerfall-DaggerfallUnity",
      "appIconUrl": "https://cdn2.steamgriddb.com/icon/f834b70560c3ca992ff72b5983170816/32/256x256.png",
      "tags": ["recreation", "pc", "elder scrolls"]
    },
    {
      "name": "The Legend of Zelda: Majora's Mask",
      "project": "2 Ship 2 Harkinian",
      "repository": "HarbourMasters/2ship2harkinian",
      "folderName": "TheLegendOfZeldaMajorasMask-2Ship2Harkinian",
      "appIconUrl": "https://raw.githubusercontent.com/HarbourMasters/2ship2harkinian/refs/heads/develop/mm/windows/2SHIP2HARKINIAN.ico",
      "tags": ["decomp", "n64", "harbour masters", "zelda"]
    },
    {
      "name": "Super Mario Bros. [Remastered]",
      "project": "Super Mario Bros. Remastered",
      "repository": "JHDev2006/Super-Mario-Bros.-Remastered-Public",
      "folderName": "SuperMarioBrosRemastered-SuperMarioBrosRemastered",
      "appIconUrl": "https://raw.githubusercontent.com/JHDev2006/Super-Mario-Bros.-Remastered-Public/main/icon.png",
      "tags": ["recreation", "nes", "mario", "nintendo", "nintendo entertainment system"]
    },
    {
      "name": "Wave Race 64",
      "project": "RaceWave46",
      "repository": "DomazinUS/RaceWave46",
      "folderName": "WaveRace64-RaceWave46",
      "appIconUrl": "https://raw.githubusercontent.com/DomazinUS/RaceWave46/refs/heads/main/assets/manual/RaceWave46_logo_noBackground.png",
      "tags": ["recomp", "n64", "wave race", "nintendo", "nintendo 64", "recompilation"]
    }
  ]
}
EOF
# Heads-up on the Wave Race 64 seed: RaceWave46 is the WR64 static recomp with
# ray-traced water (DXR via RT64), which is why it was chosen over
# elliotttate/wave-race-64-recomp. Its releases are currently Windows-only and
# the game is BYO-ROM, so run it through Quiver's Wine/Proton wrapper until
# upstream ships a Linux host (see notes on N64ModernRuntime task_win32.cpp).

# Desktop entry.
# NOTE ON SELF-UPDATE: Quiver ships an in-app updater that rewrites the binary
# next to itself. On an immutable image /opt/quiver is not writable, so the
# updater will fail -- updates arrive by rebuilding this image instead. If you
# would rather have per-user self-updates, drop the AppImage into /etc/skel
# (~/.local/share/QuiverLauncher) and point Exec at that path.
mkdir -p /usr/share/applications
cat > /usr/share/applications/quiver.desktop << 'EOF'
[Desktop Entry]
Type=Application
Name=Quiver Launcher
Comment=Download, install and update GitHub/GitLab game ports, mods and tools
Exec=/opt/quiver/quiver.AppImage
Icon=applications-games
Terminal=false
Categories=Game;Utility;
Keywords=launcher;mods;github;gitlab;soh;2s2h;daggerfall;mario;wave race;
StartupNotify=true
EOF

echo "--- Quiver Launcher installed to /opt/quiver/quiver.AppImage ---"
echo "--- Starter library seeded at /etc/skel/.local/share/QuiverLauncher/apps.json ---"
