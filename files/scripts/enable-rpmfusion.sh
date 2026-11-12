#!/usr/bin/env bash
set -euo pipefail

echo "--- Enabling RPM Fusion (free, nonfree, and nonfree-tainted) ---"

# Install the base RPM Fusion release packages plus the nonfree-tainted
# release package. The tainted repository contains b43-firmware.
dnf install -y \
  "https://download1.rpmfusion.org/free/fedora/rpmfusion-free-release-$(rpm -E %fedora).noarch.rpm" \
  "https://download1.rpmfusion.org/nonfree/fedora/rpmfusion-nonfree-release-$(rpm -E %fedora).noarch.rpm" \
  "https://download1.rpmfusion.org/nonfree/fedora/rpmfusion-nonfree-release-tainted-$(rpm -E %fedora).noarch.rpm"

# DNF5 replaced `config-manager --enable` with `config-manager setopt`.
dnf config-manager setopt rpmfusion-free.enabled=1
dnf config-manager setopt rpmfusion-nonfree.enabled=1
dnf config-manager setopt rpmfusion-nonfree-tainted.enabled=1

# Refresh metadata so the newly enabled repositories are visible.
dnf makecache

echo "--- RPM Fusion enabled ---"
