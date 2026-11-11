#!/usr/bin/env bash
set -euo pipefail

# Only run once. Create a sentinel file after successful installation.
SENTINEL="/var/lib/abzu/refind-installed"

if [ -f "${SENTINEL}" ]; then
    exit 0
fi

echo "--- Installing rEFInd boot manager ---"

# Detect the EFI architecture.
# Older Macs (e.g., MacBook Pro 4,1) use 32-bit EFI and need refind_ia32.efi.
EFI_ARCH="x64"

if [ "$(uname -m)" = "x86_64" ]; then
    # Check whether the firmware is 32-bit or 64-bit.
    # On a 32-bit EFI Mac, the kernel is still x86_64, but the firmware is ia32.
    if [ -d /sys/firmware/efi ] && [ -f /sys/firmware/efi/fw_platform_size ]; then
        FW_SIZE=$(cat /sys/firmware/efi/fw_platform_size)
        if [ "${FW_SIZE}" = "32" ]; then
            EFI_ARCH="ia32"
        fi
    fi
fi

echo "Detected EFI architecture: ${EFI_ARCH}"

# Ensure the ESP is mounted at /boot/efi.
if ! mountpoint -q /boot/efi; then
    echo "Mounting ESP..."
    mkdir -p /boot/efi

    # Find the EFI System Partition by its GPT type GUID.
    # This is reliable even when /boot/efi is not currently mounted.
    ESP_DEVICE=$(lsblk -rno NAME,PARTTYPE,MOUNTPOINT \
        | awk '$2=="c12a7328-f81f-11d2-ba4b-00a0c93ec93b" && $3=="" {print "/dev/"$1; exit}')

    if [ -n "${ESP_DEVICE}" ]; then
        mount "${ESP_DEVICE}" /boot/efi 2>/dev/null || true
    fi
fi

if ! mountpoint -q /boot/efi; then
    echo "WARNING: Could not mount ESP. rEFInd installation skipped."
    echo "Run this script manually after ensuring /boot/efi is mounted."
    exit 1
fi

# Install rEFInd using the packaged refind-install script.
# For 32-bit EFI Macs, we must manually copy the ia32 binary.
if [ "${EFI_ARCH}" = "ia32" ]; then
    echo "Installing 32-bit rEFInd for older Mac hardware..."

    REFIND_SHARE="/usr/share/rEFInd/refind"

    mkdir -p /boot/efi/EFI/refind

    cp -v "${REFIND_SHARE}/refind_ia32.efi" /boot/efi/EFI/refind/
    cp -rv "${REFIND_SHARE}/drivers_ia32" /boot/efi/EFI/refind/ 2>/dev/null || true
    cp -rv "${REFIND_SHARE}/tools_ia32"   /boot/efi/EFI/refind/ 2>/dev/null || true
    cp -rv "${REFIND_SHARE}/fonts"        /boot/efi/EFI/refind/
    cp -rv "${REFIND_SHARE}/icons"        /boot/efi/EFI/refind/

    # On 32-bit EFI Macs, use hfs-bless instead of efibootmgr.
    if command -v hfs-bless >/dev/null 2>&1; then
        hfs-bless /boot/efi/EFI/refind/refind_ia32.efi
    else
        echo "hfs-bless not found. Install the mactel-boot package."
    fi
else
    echo "Installing 64-bit rEFInd..."
    refind-install --yes
fi

# Create the sentinel file to prevent re-running.
mkdir -p /var/lib/abzu
touch "${SENTINEL}"

echo "--- rEFInd installation complete ---"
