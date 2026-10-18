#!/usr/bin/env bash
set -euo pipefail

echo "--- Enabling RPM Fusion (including tainted repositories) ---"

FEDORA_VERSION=$(rpm -E %fedora)

# Standard free and nonfree release packages.
dnf install -y \
    "https://mirrors.rpmfusion.org/free/fedora/rpmfusion-free-release-${FEDORA_VERSION}.noarch.rpm" \
    "https://mirrors.rpmfusion.org/nonfree/fedora/rpmfusion-nonfree-release-${FEDORA_VERSION}.noarch.rpm"

# The tainted sub-repositories. These are needed for b43-firmware,
# which is not redistributable in a form RPM Fusion can ship in the
# ordinary nonfree repository.
# The tainted repo config file ships inside the nonfree release RPM
# installed above (rpmfusion-nonfree-tainted.repo) — there is no separate
# "rpmfusion-nonfree-release-tainted" package to install. Enable it and
# import its key:
dnf config-manager setopt rpmfusion-nonfree-tainted.enabled=1 2>/dev/null \
    || dnf config-manager --enable rpmfusion-nonfree-tainted
rpm --import /etc/pki/rpm-gpg/RPM-GPG-KEY-rpmfusion-nonfree-fedora-latest

# Refresh the repository metadata so the new tainted repos are visible
# to the next dnf invocation (the recipe's dnf module).
dnf makecache

echo "--- RPM Fusion enabled, including tainted ---"
