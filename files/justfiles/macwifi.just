# Offline Wi-Fi firmware helpers for old Intel Macs (BCM4321/4322)
[group('Mac Wi-Fi')]

# Install Broadcom b43 firmware from the on-image offline pack (no network needed).
mac-wifi-offline:
    sudo /usr/local/share/abzu/install-mac-wifi-offline.sh

# Show what's in the offline pack baked into this image.
mac-wifi-status:
    ls -la /usr/local/share/mac-wifi-pkgs/ 2>/dev/null || echo "No offline pack in this build."
    rpm -q b43-firmware 2>/dev/null && echo "b43-firmware RPM installed." || echo "b43-firmware RPM not yet layered — run: just mac-wifi-offline"
    [ -d /lib/firmware/b43 ] && echo "Firmware present at /lib/firmware/b43/" || echo "Firmware NOT present."
