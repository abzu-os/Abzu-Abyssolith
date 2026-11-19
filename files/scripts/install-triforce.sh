#!/usr/bin/env bash
set -euo pipefail
trap 'echo "install-triforce.sh failed at line $LINENO (exit $?)" >&2' ERR

# =============================================================================
# Triforce for Abzu Abyssolith
#
# Triforce is a static recompilation of the 2026 Switch 2 remake of
# The Legend of Zelda: Ocarina of Time: the game's AArch64 code is lifted to C
# and compiled natively for x86-64, with the Horizon OS / NVN2 layer
# reimplemented and the GPU work replayed on Vulkan. No emulator at run time.
#
# Default:
#   Download the latest Linux builder AppImage from the project's downloads
#   repository:
#     https://git.triforceproject.com/triforce/downloads/releases
#
# Optional source build:
#   Set TRIFORCE_BUILD_FROM_SOURCE=1 to build the builder AppImage from source.
#   Upstream CI builds inside Ubuntu 22.04, so the source path needs podman or
#   docker for a correct glibc/sysroot build. It is much slower (20-40 min).
#
# The AppImage contains NO game data. Each user points it at their own copy of
# the game and Triforce compiles their native build on their machine.
# =============================================================================

SOURCE_REPO_URL="https://git.triforceproject.com/triforce/source.git"
RELEASES_API="https://git.triforceproject.com/api/v1/repos/triforce/downloads/releases"
FALLBACK_REF="v0.5.2"
STAGE="/opt/triforce"
BUILD_ROOT="/tmp/abzu-triforce-build"
SRC="${BUILD_ROOT}/source"
ICON_SHA256="bb3ed66edfd55af76d1ee16ab45b28fcc0afc9eaaf9072beaf63cf717362c912"
APPIMAGE_MIN_BYTES=$((100 * 1024 * 1024))

if [ "$(uname -m)" != "x86_64" ]; then
  echo "ERROR: the Triforce builder AppImage is x86_64-only (upstream ships no arm64 build)." >&2
  exit 1
fi

for tool in curl jq tar xz; do
  command -v "${tool}" >/dev/null 2>&1 || {
    echo "ERROR: ${tool} is required." >&2
    exit 1
  }
done

mkdir -p "$STAGE"

fetch_release_json() {
  local tag="${1:-}"
  local url
  if [ -n "$tag" ]; then
    url="${RELEASES_API}/tags/${tag}"
  else
    url="${RELEASES_API}?limit=1"
  fi
  curl -fsSL --retry 4 --retry-delay 10 --connect-timeout 30 "$url"
}

release_json=""
if release_json="$(fetch_release_json "${TRIFORCE_RELEASE_TAG:-}")"; then
  :
else
  if [ -z "${TRIFORCE_RELEASE_TAG:-}" ]; then
    echo "WARNING: latest-release API failed; falling back to ${FALLBACK_REF}." >&2
    release_json="$(fetch_release_json "$FALLBACK_REF")" || true
  fi
fi

release_fields=""
if [ -n "$release_json" ]; then
  release_fields="$(jq -r '
    (if type == "array" then .[0] else . end)
    | .tag_name as $tag
    | .assets[]
    | select(.name | test("x86_64\\.AppImage$"))
    | [$tag, .name, (.size | tostring), .browser_download_url]
    | @tsv
  ' <<<"$release_json" | head -n1)" || true
fi

TAG=""
if [ -n "$release_fields" ]; then
  IFS=$'\t' read -r TAG ASSET_NAME ASSET_SIZE ASSET_URL <<< "$release_fields"
fi

install_icon() {
  local cand icon=""
  for cand in /tmp/files/triforce/triforce.png "$PWD/assets/triforce.png"; do
    if [ -f "$cand" ] && echo "$ICON_SHA256  $cand" | sha256sum -c --status -; then
      icon="$cand"
      break
    fi
  done
  if [ -n "$icon" ]; then
    install -Dm644 "$icon" /usr/share/icons/hicolor/256x256/apps/triforce.png
    printf '%s\n' "triforce"
  else
    echo "WARNING: Triforce icon not found or checksum mismatch; using the generic games icon." >&2
    printf '%s\n' "applications-games"
  fi
}

write_desktop_entry() {
  local icon_id="$1"
  mkdir -p /usr/share/applications
  cat > /usr/share/applications/triforce.desktop << EOF
[Desktop Entry]
Type=Application
Name=Triforce
GenericName=Ocarina of Time (PC recompile)
Comment=Build a native PC version of The Legend of Zelda: Ocarina of Time (2026) from your own copy of the game
Exec=/opt/triforce/triforce.AppImage %F
TryExec=/opt/triforce/triforce.AppImage
Icon=${icon_id}
Terminal=false
Categories=Game;Building;
Keywords=zelda;ocarina of time;recomp;recompilation;vulkan;nintendo;switch;appimage;build;
StartupNotify=true
Actions=classic;play;

[Desktop Action classic]
Name=Open the classic builder window
Exec=/opt/triforce/triforce.AppImage --classic

[Desktop Action play]
Name=Play the last game you built
Exec=/opt/triforce/triforce.AppImage --play
EOF
  update-desktop-database /usr/share/applications >/dev/null 2>&1 || true
}

finish_install() {
  local built="$1"
  install -m 755 "$built" "$STAGE/triforce.AppImage"
  printf '%s\n' "$TAG" > "$STAGE/VERSION"
  local icon_id
  icon_id="$(install_icon)"
  write_desktop_entry "$icon_id"
  echo "--- Triforce ${TAG} AppImage installed to ${STAGE}/triforce.AppImage ---"
  echo "--- Users compile their own copy of the game from it (BYO game; ~60 GB free, ~40 min) ---"
}

download_appimage() {
  if [ -z "$release_fields" ] || [ -z "$ASSET_URL" ]; then
    echo "ERROR: no x86_64.AppImage asset found in the Triforce downloads release." >&2
    return 1
  fi

  local dl_dir="/tmp/abzu-triforce-download"
  local part="${dl_dir}/${ASSET_NAME}.part"
  local out="${dl_dir}/${ASSET_NAME}"
  rm -rf "$dl_dir"
  mkdir -p "$dl_dir"

  echo "--- Triforce: downloading ${TAG} Linux AppImage ---"
  echo " Asset: ${ASSET_NAME} (${ASSET_SIZE} bytes)"
  if ! curl -fL --retry 4 --retry-delay 10 --connect-timeout 30 -o "$part" "$ASSET_URL"; then
    echo "ERROR: failed to download ${ASSET_URL}" >&2
    return 1
  fi
  mv -f "$part" "$out"

  local actual_size
  actual_size="$(stat -c %s "$out")"
  if [ -n "$ASSET_SIZE" ] && [ "$ASSET_SIZE" != "null" ] && [ "$actual_size" -ne "$ASSET_SIZE" ]; then
    echo "ERROR: downloaded AppImage is ${actual_size} bytes, expected ${ASSET_SIZE}." >&2
    return 1
  fi

  local first_bytes
  first_bytes="$(od -A n -t x1 -N 4 "$out" | tr -d ' \n')"
  if [ "$first_bytes" != "7f454c46" ]; then
    echo "ERROR: downloaded file is not an ELF AppImage (magic ${first_bytes})." >&2
    return 1
  fi
  if [ "$actual_size" -lt "$APPIMAGE_MIN_BYTES" ]; then
    echo "ERROR: downloaded AppImage is suspiciously small (${actual_size} bytes)." >&2
    return 1
  fi

  finish_install "$out"
}

build_from_source() {
  local ref="${TRIFORCE_REF:-${TAG:-$FALLBACK_REF}}"
  echo "--- Triforce: building the Linux AppImage from source (${ref}) ---"

  if command -v dnf >/dev/null 2>&1; then
    dnf install -y patchelf libseccomp-devel gcc-c++ make >/dev/null 2>&1 || {
      echo " WARNING: dnf install of build tools failed; continuing and" >&2
      echo " letting the build itself report what is missing." >&2
    }
  fi
  for tool in git curl tar xz python3; do
    command -v "${tool}" >/dev/null 2>&1 || {
      echo "ERROR: ${tool} is required for the source build." >&2
      exit 1
    }
  done

  rm -rf "$BUILD_ROOT"
  mkdir -p "$SRC"
  local cloned=false attempt
  for attempt in 1 2 3 4; do
    if git clone --depth 1 --branch "$ref" "$SOURCE_REPO_URL" "$SRC"; then
      cloned=true
      break
    fi
    echo " WARNING: triforce clone failed (attempt ${attempt}/4), retrying in $((attempt * 5))s..." >&2
    rm -rf "$SRC"
    mkdir -p "$SRC"
    sleep $((attempt * 5))
  done
  if [ "$cloned" != true ]; then
    echo "ERROR: Failed to clone ${SOURCE_REPO_URL} after 4 attempts." >&2
    exit 1
  fi

  cd "$SRC"
  echo " Checked out $(git rev-parse --short HEAD) (${ref})."
  chmod 644 requirements.txt nx2/prompt_requirements.txt 2>/dev/null || true

  if command -v docker >/dev/null 2>&1 || command -v podman >/dev/null 2>&1; then
    local rt
    if command -v docker >/dev/null 2>&1; then rt=docker; else rt=podman; fi
    echo " Building inside ubuntu:22.04 (${rt}); this fetches and builds"
    echo " LLVM 23.1.5, CPython 3.12.16, Tcl/Tk 9.0.4, FFmpeg 9.0.2,"
    echo " dav1d 1.5.4 and SDL2 2.32.10 -- expect 20-40 minutes."
    chmod -R a+rwX "$SRC"
    "$rt" run --rm \
      --name abzu-triforce-builder \
      -v "$SRC":/src:rw \
      -w /src \
      -e HOME=/tmp \
      -e DEBIAN_FRONTEND=noninteractive \
      -e GH_TOKEN="${GH_TOKEN:-}" \
      --entrypoint /bin/bash \
      ubuntu:22.04 -euo pipefail -c '
        set -x
        tries=0
        until apt-get update; do
          tries=$((tries+1))
          [ $tries -ge 3 ] && exit 1
          sleep 10
        done
        apt-get install -y --no-install-recommends software-properties-common gpg-agent ca-certificates
        add-apt-repository -y ppa:ubuntu-toolchain-r/test
        apt-get update
        apt-get install -y --no-install-recommends \
          g++-13 libstdc++-13-dev \
          git curl xz-utils zstd file unzip python3 python3-pip \
          build-essential gcc-12 g++-12 libstdc++-12-dev nasm meson ninja-build cmake pkg-config \
          libx11-dev libxext-dev libxrandr-dev libxcursor-dev libxi-dev libxss-dev libxfixes-dev libxinerama-dev \
          libxkbcommon-dev libwayland-dev wayland-protocols libdecor-0-dev libegl-dev libgles-dev libdrm-dev libgbm-dev \
          libpulse-dev libasound2-dev libpipewire-0.3-dev libudev-dev libdbus-1-dev libxft-dev libfontconfig1-dev zlib1g-dev \
          libfuse2 squashfs-tools patchelf libxft2 libxrender1
        id -u abc >/dev/null 2>&1 || useradd -m -u 1000 -s /bin/bash abc
        chown -R abc:abc /src
        su abc -c "cd /src && HOOKSHOT_VERSION='"$ref"' JOBS=$(nproc) ./scripts/linux/deps.sh"
        su abc -c "cd /src && HOOKSHOT_VERSION='"$ref"' JOBS=$(nproc) ./scripts/linux/appimage.sh"
        su abc -c "cd /src && ./scripts/linux/check_player_build.sh"
      '
  else
    echo " No container runtime available: building natively against this" >&2
    echo " system's C library. The sysroot deps.sh packs is taken from the" >&2
    echo " host, so the game this AppImage builds inherits the host's glibc." >&2
    export HOOKSHOT_VERSION="$ref"
    ./scripts/linux/deps.sh
    ./scripts/linux/appimage.sh
    ./scripts/linux/check_player_build.sh
  fi

  local built
  built="$(ls -t "$SRC"/build-linux/Triforce-*-x86_64.AppImage 2>/dev/null | head -n1 || true)"
  if [ -z "$built" ] || [ ! -f "$built" ]; then
    echo "ERROR: scripts/linux/appimage.sh produced no AppImage in build-linux/." >&2
    ls -l "$SRC/build-linux" 2>/dev/null >&2 || true
    exit 1
  fi

  TAG="$ref"
  finish_install "$built"
  rm -rf "$BUILD_ROOT"
}

if [ "${TRIFORCE_BUILD_FROM_SOURCE:-0}" = "1" ]; then
  build_from_source
else
  if ! download_appimage; then
    echo "ERROR: could not install the latest Triforce Linux AppImage." >&2
    echo "Set TRIFORCE_BUILD_FROM_SOURCE=1 to build it from source instead." >&2
    exit 1
  fi
fi
