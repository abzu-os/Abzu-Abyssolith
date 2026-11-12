#!/usr/bin/env bash
set -euo pipefail

echo "--- Enabling RPM Fusion (free, nonfree, and nonfree-tainted) ---"

# Install the base RPM Fusion release packages plus the nonfree-tainted
# release package, which defines the rpmfusion-nonfree-tainted repository.
# b43-firmware (Broadcom Wi-Fi firmware for older Macs) lives in nonfree-tainted,
# not in the base nonfree repository.
dnf install -y \
  "https://mirrors.rpmfusion.org/free/fedora/rpmfusion-free-release-$(rpm -E %fedora).noarch.rpm" \
  "https://mirrors.rpmfusion.org/nonfree/fedora/rpmfusion-nonfree-release-$(rpm -E %fedora).noarch.rpm" \
  "https://mirrors.rpmfusion.org/nonfree/fedora/rpmfusion-nonfree-release-tainted-$(rpm -E %fedora).noarch.rpm"

# DNF5 replaced `config-manager --enable` with `config-manager setopt`.
dnf config-manager setopt rpmfusion-free.enabled=1
dnf config-manager setopt rpmfusion-nonfree.enabled=1
dnf config-manager setopt rpmfusion-nonfree-tainted.enabled=1

# Refresh metadata so the newly enabled repositories are visible.
dnf makecache

echo "--- RPM Fusion enabled ---"
