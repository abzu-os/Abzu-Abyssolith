# Install rEFInd boot manager (requires sudo)
install-refind:
    #!/usr/bin/bash
    set -euo pipefail
    sudo /usr/local/share/abzu/install-refind.sh

# Repair the EFI System Partition / boot chain on Intel Macs (32-bit and
# 64-bit EFI models such as the MacBook Pro 4,1). Run after an installer
# that failed at "Starting deployment", or any time the machine boots to
# a question-mark folder. Requires sudo. See docs/MAC-INSTALL.md.
fix-mac-efi:
    #!/usr/bin/bash
    set -euo pipefail
    sudo /usr/local/share/abzu/fix-mac-efi.sh

# Fetch the Broadcom b43 offline firmware pack into THIS repo checkout so it
# gets baked into the next ISO build (files/mac-wifi-pkgs -> image path
# /usr/local/share/mac-wifi-pkgs). Run once on any internet-connected machine;
# then commit the downloaded RPM with `git add -f files/mac-wifi-pkgs/*.rpm`.
# No network is needed on the target Mac afterwards -- see docs/MAC-INSTALL.md.
mac-wifi-setup:
    #!/usr/bin/bash
    set -euo pipefail
    bash files/scripts/install-mac-wifi-offline.sh

# Install PC Cartridge System components (requires sudo)
install-cartridge:
    #!/usr/bin/bash
    set -euo pipefail
    sudo /usr/local/share/abzu/install-cartridge.sh

# Run Fono's setup wizard
fono-setup:
    #!/usr/bin/bash
    set -euo pipefail
    echo "Running Fono setup wizard..."
    fono setup

# Install and authenticate icloud-cli-tools
icloud-tools-setup:
    #!/usr/bin/bash
    set -euo pipefail
    echo "Setting up icloud-cli-tools..."
    python3 -m venv ~/.local/share/icloud-cli-tools-venv
    ~/.local/share/icloud-cli-tools-venv/bin/pip install --upgrade pip
    ~/.local/share/icloud-cli-tools-venv/bin/pip install icloud-cli-tools
    echo ""
    echo "Installation complete. To authenticate, run:"
    echo "  ~/.local/share/icloud-cli-tools-venv/bin/icloud --help"
    echo ""
    echo "You will be prompted for your Apple ID and an app-specific password."

# Set up Zaparoo user service
zaparoo-setup:
    #!/usr/bin/bash
    set -euo pipefail
    /usr/local/bin/zaparoo -install service
    /usr/local/bin/zaparoo -install desktop
    systemctl --user daemon-reload
    systemctl --user enable --now zaparoo.service
    echo "Zaparoo service installed and started."
    echo "For NFC hardware support, run: sudo /usr/local/bin/zaparoo -install hardware"

# Enable the Ground Station user service
ground-station-setup:
    #!/usr/bin/bash
    set -euo pipefail
    systemctl --user daemon-reload
    systemctl --user enable --now ground-station.service
    echo "Ground Station enabled at http://localhost:7000"

# Launch gMTP with MTP support check
gmtp-sync:
    #!/usr/bin/bash
    set -euo pipefail
    echo "Checking MTP support..."
    if ! rpm -q gvfs-mtp &>/dev/null; then
        echo "gvfs-mtp is not installed. MTP devices may not be detected."
        echo "It should be part of the base image; if missing, please report this."
    fi
    echo "Ensure your Walkman is connected and unlocked, then launching gMTP..."
    # Launch gmtp (RPM version)
    flatpak run app.gmtp.gMTP &

# Seed Quiver Launcher's library with the entries that used to be installed
# standalone (Daggerfall Unity, Ship of Harkinian, 2 Ship 2 Harkinian and
# Super Mario Bros. Remastered).
# Quiver stores apps.json beside its AppImage, which is read-only on Abzu,
# so it falls back to ~/.local/share/QuiverLauncher/. This recipe copies the
# seeded file there; it never overwrites an existing library. Run once, before
# the first launch of Quiver.
quiver-setup:
    #!/usr/bin/bash
    set -euo pipefail
    DEST="${XDG_DATA_HOME:-$HOME/.local/share}/QuiverLauncher"
    SEED="$HOME/.local/share/QuiverLauncher/apps.json"
    if [ ! -f "${SEED}" ]; then
        echo "Seed file ${SEED} not found. Nothing to do."
        exit 0
    fi
    mkdir -p "${DEST}"
    if [ -f "${DEST}/apps.json" ]; then
        echo "A library already exists at ${DEST}/apps.json -- leaving it untouched."
        echo "To merge the seeded entries by hand, compare with: ${SEED}"
    else
        cp "${SEED}" "${DEST}/apps.json"
        echo "Seeded Quiver library at ${DEST}/apps.json"
    fi

    echo ""
    echo "Launch Quiver Launcher from the applications grid, or run:"
    echo "  /opt/quiver/quiver.AppImage"
    echo "Tip: subscribe to the built-in community catalog in App Catalog for"
    echo "many more ports (it also lists SoH, 2SoH and Daggerfall Unity)."
    echo "Note: the seeded Wave Race 64 entry (DomazinUS/RaceWave46, ray-traced"
    echo "water) ships Windows-only builds so far -- enable its Wine/Proton"
    echo "wrapper in Quiver until upstream adds a Linux release."
