#!/usr/bin/env bash
set -euo pipefail

echo "--- Enabling RPM Fusion (including tainted repositories) ---"

# Install the RPM Fusion release packages for the current Fedora version.
dnf install -y \
  "https://mirrors.rpmfusion.org/free/fedora/rpmfusion-free-release-$(rpm -E %fedora).noarch.rpm" \
  "https://mirrors.rpmfusion.org/nonfree/fedora/rpmfusion-nonfree-release-$(rpm -E %fedora).noarch.rpm"

# DNF5 replaced `config-manager --enable` with `config-manager setopt`.
# Enable the free, nonfree, and tainted repositories.
dnf config-manager setopt rpmfusion-free.enabled=1
dnf config-manager setopt rpmfusion-nonfree.enabled=1
dnf config-manager setopt rpmfusion-free-tainted.enabled=1
dnf config-manager setopt rpmfusion-nonfree-tainted.enabled=1

# Refresh metadata so the newly enabled repositories are visible.
dnf makecache

echo "--- RPM Fusion enabled ---"
