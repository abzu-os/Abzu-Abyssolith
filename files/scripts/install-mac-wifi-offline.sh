#!/usr/bin/env bash
# One-time offline Wi-Fi firmware installer for old Intel Macs.
#
# WHY THIS EXISTS
# ---------------
# Abzu's image already contains b43-firmware (BCM4321/4322, the 2008-2011
# MacBook Pro/Air/Mini Wi-Fi chips) and linux-firmware's brcmsmac/brcmfmac
# blobs. But a Fedora *Silverblue live USB* does not contain them, and at
# work you have only Wi-Fi — no Ethernet, no usable USB tethering. That made
# rebasing to Abzu a chicken-and-egg problem: you need the network to fetch
# the drivers, but you need the drivers to get the network.
#
# This script closes that loop. Run it ONCE on any internet-connected Linux
# machine (home, or even the installed system later). It downloads the
# driver packages into this repository under files/mac-wifi-pkgs/, and the
# next BlueBuild CI run copies them into the image at
# /usr/local/share/mac-wifi-pkgs/. After that, an Abzu ISO is self-healing:
# boot it on a Mac with dead Wi-Fi, click "Install Wi-Fi Firmware", and the
# b43 firmware lands without any network at all.
#
# WHAT IT DOWNLOADS
# -----------------
# - rpmfusion-nonfree-release-tainted  (+ its GPG key): needed so the target
#   machine can `rpm -ivh` and later dnf-update the tainted repo.
# - b43-firmware: the actual BCM43xx firmware tarball wrapper. Lives ONLY in
#   RPM Fusion's *tainted* repo (it is extracted from Apple's proprietary
#   broadcom-stc source, hence "tainted").
#
# The open-source brcmsmac/brcmfmac blobs (for 2012+ Broadcom chips) are
# already part of linux-firmware in stock Fedora/Silverblue — nothing to do
# for those; see docs/MAC-INSTALL.md.
#
# NOTE: `rpm -E %fedora` only works on RPM systems. On a Debian/Ubuntu or
# other non-RPM helper machine, set the target Fedora version explicitly:
#   FEDORA_VERSION=44 bash files/scripts/install-mac-wifi-offline.sh
set -euo pipefail

REPO_ROOT="$(git rev-parse --show-toplevel)"
DEST="$REPO_ROOT/files/mac-wifi-pkgs"
FEDORA_VERSION="${FEDORA_VERSION:-$(rpm -E %fedora 2>/dev/null || echo 44)}"

if [ ! -d "$DEST" ]; then
    echo "ERROR: $DEST does not exist. Run this from inside the abzu repo." >&2
    exit 1
fi

echo "--- Fetching RPM Fusion tainted release package + GPG key (Fedora $FEDORA_VERSION) ---"
curl -fL "https://mirrors.rpmfusion.org/nonfree/fedora/rpmfusion-nonfree-release-tainted-${FEDORA_VERSION}.noarch.rpm" \
    -o "$DEST/rpmfusion-nonfree-release-tainted.noarch.rpm"

# The tainted repo's signing key (RPM Fusion nonfree release key, ASCII-armored).
curl -fL "https://raw.githubusercontent.com/rpmfusion/rpmfusion-nonfree-release/master/RPM-GPG-KEY-rpmfusion-nonfree-fedora-latest" \
    -o "$DEST/RPM-GPG-KEY-rpmfusion-nonfree-fedora"

echo "--- Fetching b43-firmware from RPM Fusion tainted ---"
# Preferred path: use local dnf if available (resolves arch/version correctly).
if command -v dnf >/dev/null 2>&1; then
    TMPROOT=$(mktemp -d)
    trap 'rm -rf "$TMPROOT"' EXIT
    sudo dnf install -y --installroot="$TMPROOT" --releasever="$FEDORA_VERSION" \
        "https://mirrors.rpmfusion.org/nonfree/fedora/rpmfusion-nonfree-release-${FEDORA_VERSION}.noarch.rpm" \
        "https://mirrors.rpmfusion.org/nonfree/fedora/rpmfusion-nonfree-release-tainted-${FEDORA_VERSION}.noarch.rpm" \
        >/dev/null 2>&1 || true
    # Now download just the firmware RPM into DEST.
    ( cd "$DEST" && sudo dnf download --releasever="$FEDORA_VERSION" b43-firmware ) \
        || ( cd "$DEST" && dnf download --releasever="$FEDORA_VERSION" b43-firmware )
else
    # Fallback: scrape the tainted repo directory listing for the newest RPM.
    BASE="https://mirrors.rpmfusion.org/vol/rpmfusion/nonfree/fedora/releases/$FEDORA_VERSION/Everything/x86_64/rpms"
    URL=$(curl -fsSL "$BASE/" | grep -oP 'href="\Kb43-firmware[^"]*\.rpm' | sort -V | tail -n1)
    [ -n "$URL" ] || { echo "ERROR: could not locate b43-firmware RPM at $BASE" >&2; exit 1; }
    curl -fL "$BASE/$URL" -o "$DEST/$URL"
fi

ls -la "$DEST"
cat <<'EOF'

Done. Commit the downloaded RPMs (they must be tracked with `git add -f`)
and push; CI will bake them into the image at /usr/local/share/mac-wifi-pkgs/.
On the Mac, from a booted Abzu ISO or live environment, run:

    sudo /usr/local/share/abzu/install-mac-wifi-offline.sh

No network required.
EOF
