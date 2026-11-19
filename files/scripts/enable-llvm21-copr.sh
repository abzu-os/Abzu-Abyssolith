#!/usr/bin/env bash
set -euo pipefail

# Enable the Fedora LLVM compatibility COPR that provides clang21 / llvm21 /
# lld21 for Fedora. Clang 21 is the last known-good version to support the GNUSTep stack.
dnf -y copr enable @fedora-llvm-team/llvm-compat-packages
