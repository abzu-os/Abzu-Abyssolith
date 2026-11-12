#!/usr/bin/env bash
set -euo pipefail

echo "--- Enabling RPM Fusion (free, nonfree, and tainted repositories) ---"

# 1. Install the core free and nonfree release packages.
# These URLs are stable and work for the current Fedora release.
sudo dnf install -y \
  "https://mirrors.rpmfusion.org/free/fedora/rpmfusion-free-release-$(rpm -E %fedora).noarch.rpm" \
  "https://mirrors.rpmfusion.org/nonfree/fedora/rpmfusion-nonfree-release-$(rpm -E %fedora).noarch.rpm"

# 2. Install the tainted release packages by name.
# The repositories are now configured, so dnf will find the correct tainted packages.
sudo dnf install -y \
  rpmfusion-free-release-tainted \
  rpmfusion-nonfree-release-tainted

echo "--- RPM Fusion repositories enabled successfully ---"
