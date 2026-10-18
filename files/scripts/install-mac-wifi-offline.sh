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
# - b43-firmware: the actual BCM43xx firmware tarball wrapper. Lives ONLY in
#   RPM Fusion's *tainted* repo (it is extracted from Apple's proprietary
#   broadcom-stc source, hence "tainted"). The firmware it installs is a
#   plain data payload — no build steps, no kmod deps — so one RPM serves
#   every Fedora release; you do NOT need to match your target version.
# - RPM-GPG-KEY-rpmfusion-nonfree: extracted locally from the official
#   rpmfusion-nonfree-release RPM (no external key URL needed).
#
# NOTE: the tainted *release* package itself is intentionally NOT bundled.
# Its upstream download path does not exist ("rpmfusion-nonfree-release-
# tainted-XX.noarch.rpm" is a 404), and it would pull gpgme/python deps onto
# an offline base system. The on-image installer therefore installs only the
# firmware + key; enabling the tainted repo for updates is a one-liner once
# the Mac is online (see docs/MAC-INSTALL.md).
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

echo "--- Locating an RPM Fusion tainted mirror (repo id: nonfree-fedora-tainted-$FEDORA_VERSION) ---"
# NOTE: the canonical layout is .../nonfree/fedora/tainted/<ver>/x86_64/, NOT
# .../rpmfusion-nonfree-tainted-<ver>/ — and there is no standalone
# "rpmfusion-nonfree-release-tainted" download (it ships inside the regular
# rpmfusion-nonfree-release package). We resolve a real mirror via metalink.
MIRROR=$(curl -fsSL "http://mirrors.rpmfusion.org/mirrorlist?repo=nonfree-fedora-tainted-${FEDORA_VERSION}&arch=x86_64" \
    | grep -m1 '^http')
[ -n "$MIRROR" ] || { echo "ERROR: could not resolve a tainted repo mirror." >&2; exit 1; }
echo "Using mirror: $MIRROR"

echo "--- Fetching b43-firmware from RPM Fusion tainted ---"
# Preferred path: use local dnf if available (resolves arch/version correctly).
if command -v dnf >/dev/null 2>&1 && command -v rpm2cpio >/dev/null 2>&1; then
    TMPROOT=$(mktemp -d)
    trap 'rm -rf "$TMPROOT"' EXIT
    sudo dnf install -y --installroot="$TMPROOT" --releasever="$FEDORA_VERSION" \
        "https://mirrors.rpmfusion.org/nonfree/fedora/rpmfusion-nonfree-release-${FEDORA_VERSION}.noarch.rpm" \
        >/dev/null 2>&1 || true
    # Enable only the tainted repo, then download just the firmware RPM.
    ( cd "$DEST" && sudo dnf download --releasever="$FEDORA_VERSION" \
        --repofrompath="tainted,$MIRROR" --repo=tainted b43-firmware ) \
        || ( cd "$DEST" && dnf download --releasever="$FEDORA_VERSION" \
             --repofrompath="tainted,$MIRROR" --repo=tainted b43-firmware )
    # Extract the RPM Fusion nonfree GPG key from the official release RPM.
    RELRPM=$(find "$TMPROOT"/var/cache -name 'rpmfusion-nonfree-release*.rpm' | head -1)
    if [ -n "$RELRPM" ]; then
        TMPKEY=$(mktemp -d)
        ( cd "$TMPKEY" && rpm2cpio "$RELRPM" | cpio -id --quiet )
        cp "$TMPKEY/etc/pki/rpm-gpg/RPM-GPG-KEY-rpmfusion-nonfree-fedora-latest" \
            "$DEST/RPM-GPG-KEY-rpmfusion-nonfree" || true
        rm -rf "$TMPKEY"
    fi
else
    # Portable fallback (works on Debian/Ubuntu helper machines too):
    # scrape the mirror's package tree for the newest b43-firmware RPM.
    URL=$(curl -fsSL "${MIRROR}b/" | grep -oE 'b43-firmware[^"]*\.noarch\.rpm' | sort -V | tail -n1)
    [ -n "$URL" ] || { echo "ERROR: could not locate b43-firmware RPM under $MIRROR" >&2; exit 1; }
    curl -fL "${MIRROR}b/$URL" -o "$DEST/$URL"

    # GPG key: extract locally from the official nonfree release RPM
    # (avoids depending on any external raw key URL).
    curl -fL "https://mirrors.rpmfusion.org/nonfree/fedora/rpmfusion-nonfree-release-${FEDORA_VERSION}.noarch.rpm" \
        -o "$DEST/.tmp-rel.rpm"
    TMPKEY=$(mktemp -d)
    ( cd "$TMPKEY" && rpm2cpio "$DEST/.tmp-rel.rpm" | cpio -id --quiet )
    cp "$TMPKEY/etc/pki/rpm-gpg/RPM-GPG-KEY-rpmfusion-nonfree-fedora-latest" \
        "$DEST/RPM-GPG-KEY-rpmfusion-nonfree"
    rm -rf "$TMPKEY" "$DEST/.tmp-rel.rpm"
fi

ls -la "$DEST"
cat <<'EOF'

Done. Commit the downloaded RPMs (they must be tracked with `git add -f`)
and push; CI will bake them into the image at /usr/local/share/mac-wifi-pkgs/.
On the Mac, from a booted Abzu ISO or live environment, run:

    sudo /usr/local/share/abzu/install-mac-wifi-offline.sh

No network required.
EOF
