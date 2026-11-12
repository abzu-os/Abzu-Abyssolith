#!/usr/bin/env bash
set -euo pipefail

echo "--- Enabling COPR repositories for the current Fedora release ---"

# dnf copr enable resolves the correct chroot automatically, so this
# works regardless of which Fedora version base-main:latest is on.
dnf copr enable -y "@lemonade-server/lemonade"
dnf copr enable -y "bieszczaders/kernel-cachyos-addons"
dnf copr enable -y "atim/starship"

echo "--- COPR repositories enabled successfully ---"
