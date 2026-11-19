#!/usr/bin/env bash
set -euo pipefail
trap 'echo "install-triforce.sh failed at line $LINENO (exit $?)" >&2' ERR

# =============================================================================
# Triforce -- Linux AppImage, built from source.
#
#   https://git.triforceproject.com/triforce/source
#
# Triforce is a static recompilation of the 2026 Switch 2 remake of
# The Legend of Zelda: Ocarina of Time: the game's AArch64 code lifted to C
# and compiled natively for x86-64, with the Horizon OS / NVN2 layer
# reimplemented and the GPU work replayed on Vulkan. No emulator at run time.
#
# This script builds the project's own Linux artifact, the *builder* AppImage
# (scripts/linux/deps.sh + scripts/linux/appimage.sh), which carries LLVM's
# clang/lld, a CPython toolchain with the recompiler's modules, a glibc
# sysroot, FFmpeg (dav1d), SDL2 and the prebuilt Vulkan back end. It contains
# NO game data: each user points it at their own copy of the game and Triforce
# compiles their native build on their machine (~40 minutes the first time).
# That is why this project cannot be seeded in Quiver Launcher: Quiver pulls
# release assets from GitHub/GitLab, Triforce lives on self-hosted Gitea, has
# no Gitea releases at all (`/api/v1/repos/triforce/source/releases` -> []),
# and upstream publishes no Linux binary -- so the image builds the AppImage
# from source instead.
#
# Upstream CI builds this AppImage inside an Ubuntu 22.04 container (glibc
# 2.35) and its deps.sh copies Debian paths (/usr/lib/x86_64-linux-gnu,
# /usr/share/doc/libxft2) into the sysroot and licenses. On Fedora we keep
# those steps working by building inside an ephemeral Ubuntu 22.04 podman
# container; everything else runs natively.
# =============================================================================

REPO_URL="https://git.triforceproject.com/triforce/source.git"
REF="v0.5.2"                                    # newest tag (2026-11-19); see notes below
ICON_SHA256="bb3ed66edfd55af76d1ee16ab45b28fcc0afc9eaaf9072beaf63cf717362c912"

BUILD_ROOT=/tmp/abzu-triforce-build
SRC="$BUILD_ROOT/source"
STAGE=/opt/triforce
APPIMAGE_NAME="Triforce-${REF}-x86_64.AppImage"

echo "--- Triforce: building the Linux AppImage from source (${REF}) ---"

if [ "$(uname -m)" != "x86_64" ]; then
    echo "ERROR: the Triforce builder AppImage is x86_64-only (upstream ships no arm64 build)." >&2
    exit 1
fi

# -----------------------------------------------------------------------------
# Build tools. Most are already in the recipe's dnf list (git, curl, make,
# cmake, ninja-build, meson, pkgconf-pkg-config, python3 comes with the base
# image). These are the ones it does not pull in; `dnf -y install` is a no-op
# when a package is already present.
#   patchelf       : RPATH rewrite step below
#   libseccomp-devel: runc requires it when it is compiled from source by
#                     podman's distro build tag (see the podman note)
#   gcc-c++        : already listed, asserted here because appimage.sh links
#                    C++ pieces with the host compiler
# -----------------------------------------------------------------------------
echo "  Ensuring build tools are present..."
if command -v dnf >/dev/null 2>&1; then
    dnf install -y patchelf libseccomp-devel gcc-c++ make \
        >/dev/null 2>&1 || {
        echo "  WARNING: dnf install of build tools failed; continuing and" >&2
        echo "           letting the build itself report what is missing." >&2
    }
fi
for tool in git curl tar xz python3; do
    command -v "${tool}" >/dev/null 2>&1 || { echo "ERROR: ${tool} is required." >&2; exit 1; }
done

# -----------------------------------------------------------------------------
# Source checkout, pinned to a tag, with the retry pattern used by the other
# source-build installers in this image (transient network failures must not
# abort the whole image build).
# -----------------------------------------------------------------------------
rm -rf "$BUILD_ROOT"
mkdir -p "$SRC"
CLONE_OK=false
for attempt in 1 2 3 4; do
    if git clone --depth 1 --branch "$REF" "$REPO_URL" "$SRC"; then
        CLONE_OK=true
        break
    fi
    echo "  WARNING: triforce clone failed (attempt ${attempt}/4), retrying in $((attempt * 5))s..." >&2
    rm -rf "$SRC"
    mkdir -p "$SRC"
    sleep $((attempt * 5))
done
if [ "$CLONE_OK" != true ]; then
    echo "ERROR: Failed to clone ${REPO_URL} after 4 attempts." >&2
    exit 1
fi
cd "$SRC"
echo "  Checked out $(git rev-parse --short HEAD) (${REF})."

# nx2/prompt_requirements.txt (drawn-in by requirements.txt) is not marked
# executable in the tree; pip reads it fine, but keep the mode sane for the
# container's non-root user.
chmod 644 requirements.txt nx2/prompt_requirements.txt 2>/dev/null || true

# -----------------------------------------------------------------------------
# Which environment we build in.
# -----------------------------------------------------------------------------
IN_UBUNTU=0
if [ -r /etc/os-release ] && grep -q '^ID=ubuntu' /etc/os-release; then
    IN_UBUNTU=1
fi

have_runtime() {
    command -v docker >/dev/null 2>&1 || command -v podman >/dev/null 2>&1
}

build_in_container() {
    # Ubuntu 22.04, exactly like upstream's linux-appimage workflow: deps.sh
    # needs Debian library paths for the sysroot it bakes into the AppImage.
    local rt
    if command -v docker >/dev/null 2>&1; then rt=docker; else rt=podman; fi
    echo "  Building inside ubuntu:22.04 (${rt}); this also fetches and builds"
    echo "  the bundled LLVM 23.1.5, CPython 3.12.16, Tcl/Tk 9.0.4, FFmpeg 9.0.2,"
    echo "  dav1d 1.5.4 and SDL2 2.32.10 -- expect 20-40 minutes."

    # The container user must own the checkout (deps.sh writes build-linux/
    # into it). Run as uid 1000 with the mounts owned by that uid.
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
                tries=$((tries+1)); [ $tries -ge 3 ] && exit 1; sleep 10
            done
            # Package list mirrors .github/workflows/linux-appimage.yml, plus
            # squashfs-tools / zstd / file / patchelf which appimagetool wants
            # when APPIMAGE_EXTRACT_AND_RUN makes the image without FUSE.
            apt-get install -y --no-install-recommends \
                software-properties-common gpg-agent ca-certificates
            add-apt-repository -y ppa:ubuntu-toolchain-r/test
            apt-get update
            apt-get install -y --no-install-recommends \
                g++-13 libstdc++-13-dev \
                git curl xz-utils zstd file unzip python3 python3-pip \
                build-essential gcc-12 g++-12 libstdc++-12-dev nasm meson ninja-build cmake pkg-config \
                libx11-dev libxext-dev libxrandr-dev libxcursor-dev libxi-dev libxss-dev libxfixes-dev libxinerama-dev \
                libxkbcommon-dev libwayland-dev wayland-protocols libdecor-0-dev libegl-dev libgles-dev libdrm-dev libgbm-dev \
                libpulse-dev libasound2-dev libpipewire-0.3-dev libudev-dev libdbus-1-dev libxft-dev libfontconfig1-dev zlib1g-dev \
                libfuse2 squashfs-core-utils patchelf
            # Tk license packaging: deps.sh copies these two copyright files
            # into the AppImage; they live in these Debian packages.
            apt-get install -y --no-install-recommends libxft2 libxrender1
            id -u abc >/dev/null 2>&1 || useradd -m -u 1000 -s /bin/bash abc
            chown -R abc:abc /src
            su abc -c "cd /src && HOOKSHOT_VERSION='"$REF"' JOBS=$(nproc) ./scripts/linux/deps.sh"
            su abc -c "cd /src && HOOKSHOT_VERSION='"$REF"' JOBS=$(nproc) ./scripts/linux/appimage.sh"
            # Prove the packaged image actually works, the way upstream CI does
            # before it uploads one (game-free: extracts the AppImage and runs
            # the builder up to the point where the player dump is needed).
            su abc -c "cd /src && ./scripts/linux/check_player_build.sh"
        '
}

build_natively() {
    echo "  No container runtime available: building natively against this"
    echo "  system's C library. NOTE: the sysroot deps.sh packs is taken from"
    echo "  the host, so the game this AppImage builds inherits the host's"
    echo "  glibc (upstream targets glibc >= 2.35)."
    export HOOKSHOT_VERSION="$REF"
    ./scripts/linux/deps.sh
    ./scripts/linux/appimage.sh
    ./scripts/linux/check_player_build.sh
}

if have_runtime; then
    build_in_container
else
    # podman/docker are deliberately NOT added to the recipe's dnf list: on a
    # Fedora atomic base they arrive through ublue's container stack, and
    # pulling in the full podman package set just for this step is heavy. If
    # neither runtime exists, fall back to a native build.
    build_natively
fi

# -----------------------------------------------------------------------------
# Collect the artifact.
# -----------------------------------------------------------------------------
BUILT=$(ls -t "$SRC"/build-linux/Triforce-*-x86_64.AppImage 2>/dev/null | head -1 || true)
if [ -z "$BUILT" ] || [ ! -f "$BUILT" ]; then
    echo "ERROR: scripts/linux/appimage.sh produced no AppImage in build-linux/." >&2
    ls -l "$SRC/build-linux" 2>/dev/null >&2 || true
    exit 1
fi

mkdir -p "$STAGE"
cp -f "$BUILT" "$STAGE/triforce.AppImage"
chmod 755 "$STAGE/triforce.AppImage"
echo "  Installed $BUILT -> $STAGE/triforce.AppImage ($(du -h "$STAGE/triforce.AppImage" | cut -f1))"

# Sanity check: the download/build output must be an ELF binary (the AppImage
# type-2 runtime prepended), not an HTML error page or an empty file.
FIRST_BYTES=$(od -A n -t x1 -N 4 "$STAGE/triforce.AppImage" | tr -d ' \n')
if [ "${FIRST_BYTES}" != "7f454c46" ]; then
    echo "ERROR: triforce.AppImage does not start with the ELF magic bytes (got ${FIRST_BYTES})." >&2
    exit 1
fi

# Keep the version visible to users and to whoever bumps REF above.
printf '%s\n' "$REF" > "$STAGE/VERSION"

# -----------------------------------------------------------------------------
# Icon. The repository is bind-mounted into the build sandbox at /tmp/files,
# so ship the crest rather than fetching it over the network again. Verified
# against a pinned SHA-256 (assets/triforce.png at v0.5.2).
# -----------------------------------------------------------------------------
ICON=""
for cand in /tmp/files/triforce/triforce.png "$PWD/assets/triforce.png"; do
    if [ -f "$cand" ] && echo "$ICON_SHA256  $cand" | sha256sum -c --status -; then
        ICON="$cand"
        break
    fi
done
if [ -n "$ICON" ]; then
    mkdir -p /usr/share/icons/hicolor/256x256/apps
    cp "$ICON" /usr/share/icons/hicolor/256x256/apps/triforce.png
    icon_id=triforce
else
    echo "  WARNING: Triforce icon not found or checksum mismatch; using the generic games icon." >&2
    icon_id=applications-games
fi

# -----------------------------------------------------------------------------
# Desktop entry. The AppImage is the builder: launching it opens Triforce's
# launcher window, where the user points at their own copy of the game and
# presses Build. Extra actions cover the CLI paths AppRun documents.
# -----------------------------------------------------------------------------
mkdir -p /usr/share/applications
cat > /usr/share/applications/triforce.desktop << EOF
[Desktop Entry]
Type=Application
Name=Triforce
GenericName=Ocarina of Time (PC recompile)
Comment=Build a native PC version of The Legend of Zelda: Ocarina of Time (2026) from your own copy of the game
Exec=/opt/triforce/triforce.AppImage %F
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

# -----------------------------------------------------------------------------
# Cleanup: nothing below /opt/triforce may keep the ~5 GB build tree, the
# downloaded dependency sources or the container caches.
# -----------------------------------------------------------------------------
rm -rf "$BUILD_ROOT"

echo "--- Triforce ${REF} AppImage installed to ${STAGE}/triforce.AppImage ---"
echo "--- Users compile their own copy of the game from it (BYO game; ~60 GB free, ~40 min) ---"
