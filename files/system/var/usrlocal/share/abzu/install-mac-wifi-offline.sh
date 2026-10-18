#!/usr/bin/env bash
# Offline Broadcom b43 Wi-Fi firmware installer — runs WITHOUT a network.
#
# Target: old Intel Macs (MacBook Pro/Air/Mac mini/iMac, ~2007-2011) whose
# BCM4321/BCM4322 chip needs /lib/firmware/b43/ firmware that stock Fedora
# cannot ship. Those blobs are baked into the Abzu image at
# /usr/local/share/mac-wifi-pkgs/ (see files/scripts/install-mac-wifi-offline.sh
# in the repo for how they get there).
#
# Usage (from a live session or an installed base Silverblue):
#   sudo /usr/local/share/abzu/install-mac-wifi-offline.sh
# Or from an Abzu system where the helper is preinstalled:
#   just mac-wifi-offline
set -euo pipefail

PKGS="/usr/local/share/mac-wifi-pkgs"
[ -d "$PKGS" ] || { echo "ERROR: $PKGS missing — this build lacks the offline pack." >&2; exit 1; }
[ "$(id -u)" = 0 ] || { echo "Please run with sudo." >&2; exit 1; }

ARCH=$(uname -m)
if [ "$ARCH" != x86_64 ]; then
    echo "NOTE: offline pack is x86_64-only; skipping on $ARCH." >&2
    exit 0
fi

echo "--- Importing RPM Fusion nonfree GPG key ---"
# The tainted repo's signing key ships with the pack. We deliberately do NOT
# install a tainted *release* package offline: b43-firmware is a pure data
# payload and needs no repo config to install. Once the Mac is online you can
# enable the tainted repo for updates with:
#   sudo rpm -Uvh https://mirrors.rpmfusion.org/nonfree/fedora/rpmfusion-nonfree-release-$(rpm -E %fedora).noarch.rpm
if [ -f "$PKGS/RPM-GPG-KEY-rpmfusion-nonfree" ]; then
    rpm --import "$PKGS/RPM-GPG-KEY-rpmfusion-nonfree" || true
fi

echo "--- Installing b43-firmware (offline) ---"
rpm -Uvh --replacepkgs "$PKGS"/b43-firmware*.rpm

echo "--- Ensuring b43/ssb module load policy ---"
# Our image blacklists the proprietary `wl` driver; make sure the open
# b43 stack is actually allowed to claim the card.
mkdir -p /etc/modprobe.d
if [ ! -e /etc/modprobe.d/broadcom-b43.conf ]; then
    printf '# added by install-mac-wifi-offline.sh\nblacklist wl\n' > /etc/modprobe.d/broadcom-b43.conf
fi

echo "--- Loading b43 now (no reboot needed) ---"
modprobe -r wl 2>/dev/null || true
modprobe b43 || true

if [ -d /lib/firmware/b43 ]; then
    echo "SUCCESS: b43 firmware present at /lib/firmware/b43/"
    echo "Wi-Fi should come up within a few seconds:"
    echo "  nmcli radio wifi on ; nmcli device status"
    echo
    echo "Next step once online: rebase to Abzu (docs/MAC-INSTALL.md, Part 3)."
else
    echo "WARNING: /lib/firmware/b43 still missing — check the RPM installed cleanly." >&2
    exit 1
fi
