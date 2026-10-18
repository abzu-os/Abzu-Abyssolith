# Installing Abzu on Intel Macs (MacBook Pro 4,1 and friends)

This guide is written so that **nothing here assumes you know what an EFI
partition is**. If a step says "type this", type it exactly. If anything
fails, each section ends with the single most likely fix.

**Who this is for:** any x86-64 Intel Mac (2006–2012 models — MacBook Pro
1,1 through 10,1, iMacs, MacBooks, Mac minis, etc.). These Macs have one of
two quirks that break the stock Fedora installer:

| Model year | Firmware | Quirk |
|---|---|---|
| ~2006–2008 (incl. **MBP 4,1**) | **32-bit EFI** on a 64-bit CPU | The installer can boot, but Anaconda's final "Starting deployment" step fails with *"An unknown error has occurred"* because it tries to write NVRAM boot entries the firmware rejects. There is also often no FAT "EFI System Partition" by default. |
| ~2008–2012 | 64-bit EFI | Usually installs fine via the USB stick; occasionally needs the same ESP repair. |

The good news: **the installation itself almost always succeeds.** It's the
*bootloader handoff* that errors out. This guide finishes that handoff
manually, once, with two commands. After that, rebasing to Abzu works like
any other Atomic Desktop.

---

## Part 1 — Install Fedora Silverblue

> 🛜 **Wi-Fi at work? (BCM4321/4322 Macs, no Ethernet)** A stock Silverblue
> live USB has no Broadcom firmware, so rebasing normally requires a network
> you can't reach. Two ways out:
>
> 1. **Abzu ISO route:** flash an Abzu-generated ISO instead of the
>    Silverblue one (see the README's ISO section). It ships the b43
>    firmware *and* an offline installer pack. From the live desktop run
>    `sudo /usr/local/share/abzu/install-mac-wifi-offline.sh` — no network
>    needed — then install/rebase from there.
> 2. **Manual route:** on any internet-connected machine, download just
>    `b43-firmware*.noarch.rpm` from RPM Fusion's tainted repo onto a USB
>    stick (it is a pure data payload — no release package or deps needed).
>    On the Silverblue live session: `rpm-ostree install /run/media/.../b43-firmware*.rpm`,
>    reboot to the live USB once, and Wi-Fi works for the rebase.
>
> The repo helper `files/scripts/install-mac-wifi-offline.sh` automates
> downloading these into the image (run it via `just mac-wifi-setup` from a
> repo checkout on any internet-connected machine, then commit the fetched
> RPM with `git add -f files/mac-wifi-pkgs/*.rpm`).

### What you need

1. A USB stick, **8 GB or larger**.
2. The **Fedora Silverblue live ISO** (GNOME Live edition) for your target
   version, from <https://fedoraproject.org/atomic-workstations/>.
3. Another computer (any OS) to write the USB stick.

### Step 1.1 — Write the USB stick

On the helper computer, flash the ISO to the USB stick:

- **macOS:** `sudo dd if=Fedora-Silverblue-*.iso of=/dev/rdiskN bs=4m`
  (find `N` with `diskutil list`; use `rdisk`, not `disk` — it's ~10× faster)
- **Windows:** use [balenaEtcher](https://etcher.balena.io/) — pick the ISO,
  pick the stick, press Flash. (If you prefer Rufus, choose **DD image
  mode**, not "ISO mode".)
- **Linux:** `sudo dd if=Fedora-Silverblue-*.iso of=/dev/sdX bs=4M status=progress`

> ⚠️ Hybrid ISOs must be written **raw** (`dd` / Etcher / Rufus-DD). Copying
> the ISO's files onto a FAT32 stick will not boot on these Macs.

### Step 1.2 — Boot the Mac from the USB stick

1. Shut down the Mac completely.
2. Plug the USB stick into a port **directly on the machine** (not through a
   keyboard or hub — hubs are the #1 cause of "my stick doesn't show up").
3. Power on and **immediately hold the `Option` (Alt) key**.
4. After ~10 seconds you'll see the boot picker. Choose:
   - **"EFI Boot"** (icon looks like a generic disk) — preferred.
   - If there is no "EFI Boot", choose **"Windows"** (this is what Apple
     calls any non-Mac legacy boot; harmless name).
5. At the Fedora GRUB menu, just press Enter. Wait for the GNOME live
   desktop.

> 💡 **Tip for very old Macs (2006–2007):** some cannot boot USB at all over
> EFI — only legacy BIOS emulation, which shows up as "Windows" in the
> picker. If neither entry appears, try a different USB stick; older
> firmwares are picky about stick controllers. A DVD burned at low speed
> always works on these models.

### Step 1.3 — Run the installer, and create the ESP yourself

This is the part that avoids the *"An unknown error has occurred"* crash.
Anaconda fails during its final bootloader/NVRAM transaction on 32-bit-EFI
Macs when it has to invent an EFI System Partition on the fly. Make the
partition yourself first:

1. Double-click **Install Fedora**.
2. Language/keyboard → continue.
3. On the **Installation Summary** screen, open **Installation Destination**,
   select your internal disk, and choose **"Custom" / "I will configure
   partitioning"**. Create:

   | Size | Type | Mount point | Notes |
   |---|---|---|---|
   | **512 MiB** | **FAT32 (vfat)** | **/boot/efi** | Put it at the **beginning** of the disk. ← **This is the critical bit.** Without it Anaconda dies populating an ESP that doesn't exist. |
   | 2 GiB | ext4 | `/boot` | Keep `/boot` separate — rEFInd reads ostree kernels from it directly. |
   | rest | ext4 | `/` | ext4 recommended on pre-2010 Macs (simplest driver story). btrfs also works. |

   *(If you want to keep macOS for dual-boot, shrink its partition with
   Disk Utility first and carve the above from free space.)*
4. Set root password + user account as usual, then begin installation.

**If it still fails at "Configuring bootloader" / "Starting deployment":**
don't panic. That failure happens *after* the filesystem and ostree
deployment are already written — about 95% of the install is on disk. Close
the installer, reboot back into the **live USB**, and go straight to
**Part 2**. The repair script finds your half-installed system and finishes
it. You do not need to reinstall from scratch.

### Step 1.4 — First boot attempt

Reboot. Hold `Option`. You may see **no Linux entry** (or one that beeps at
you). **This is expected on these Macs** — proceed to Part 2.

---

## Part 2 — Repair the boot chain (once, ~3 minutes)

You need the **same live USB** from Part 1.

1. Boot the live USB again (Option-key picker → "EFI Boot").
2. Open a **Terminal** (press `Super`, type "terminal").
3. Fetch and run the repair script (it ships in the Abzu repo at
   `files/system/var/usrlocal/share/abzu/fix-mac-efi.sh`; adjust the URL to
   wherever you publish):

   ```bash
   sudo curl -L https://raw.githubusercontent.com/YOUR_ORG/abzu/main/files/system/var/usrlocal/share/abzu/fix-mac-efi.sh \
     -o /tmp/fix-mac-efi.sh
   sudo bash /tmp/fix-mac-efi.sh
   ```

   Once Abzu ISOs ship, the script is preinstalled and you can instead run
   `sudo /usr/local/share/abzu/fix-mac-efi.sh` from the installed system,
   or `just fix-mac-efi`.

4. Reboot, hold `Option`, pick **EFI Boot**. You should now see the rEFInd
   menu with your Fedora/Abzu entry. Select it and boot normally.

What the script does, in plain terms:

- Mounts your installed system from the live session.
- Creates a proper FAT32 EFI System Partition if the installer didn't.
- Copies the **32-bit** rEFInd binary (`refind_ia32.efi`) into
  `/EFI/refind/` **and** the fallback names Apple firmware scans
  (`/EFI/BOOT/BOOTIA32.EFI`, plus `BOOTX86.EFI` for early 32-bit Mac
  firmwares). On 64-bit EFI Macs it installs `refind_x64.efi` normally.
- Writes a tiny rEFInd config so it auto-finds your ostree kernel.
- Touches **no NVRAM** — deliberately. Old Apple firmware corrupts its boot
  variables more often than Linux distros expect, and rEFInd doesn't need
  them.

---

## Part 3 — Rebase Silverblue → Abzu

Boot your installed Silverblue (via rEFInd), open a terminal, and run the
standard BlueBuild/Universal-Blue rebase sequence. Replace `YOUR_ORG` with
wherever you publish images:

```bash
# 1. Rebase to the unsigned image first (installs signing policy/keys):
rpm-ostree rebase ostree-unverified-registry:ghcr.io/YOUR_ORG/abzu:latest

# 2. Reboot into Abzu:
systemctl reboot

# 3. After reboot, switch to the signed image:
rpm-ostree rebase ostree-image-signed:docker://ghcr.io/YOUR_ORG/abzu:latest

# 4. Reboot again:
systemctl reboot
```

Verify:

```bash
rpm-ostree status   # should list ghcr.io/YOUR_ORG/abzu:latest as deployed
```

Then (re-)install the boot manager permanently from inside Abzu — keeps the
ESP current across image upgrades:

```bash
just install-refind
```

If Wi-Fi was still dead during the rebase (BCM4321/4322 machines), make the
firmware permanent inside Abzu as well — the RPMs are already on the ISO/image,
no network required:

```bash
sudo /usr/local/share/abzu/install-mac-wifi-offline.sh   # or: just mac-wifi-offline
```

> ℹ️ **Why rebase rather than installing an Abzu ISO directly?** The Anaconda
> bug above affects **every** RPM-ostree-based installer ISO, including
> Abzu's own. Installing base Silverblue (with the manual ESP from Step
> 1.3) and rebasing gets you to Abzu without ever trusting the installer's
> bootloader step — and after the first rebase, updates never touch that
> code path again. Future Abzu ISOs should embed `fix-mac-efi.sh` and a
> post-install hint so Mac users get the same two-command flow.

---

## Troubleshooting quick table

| Symptom | Cause | Fix |
|---|---|---|
| Installer dies at "Starting deployment" / "unknown error" | Anaconda ESP/NVRAM transaction on 32-bit EFI | Nothing was lost — reboot to live USB, run Part 2. Or redo the install with the manual ESP (Step 1.3). |
| Option-picker shows nothing after USB insert | Hub / flaky stick controller | Direct port; try another stick; burn a DVD. |
| Boots to blinking folder icon ❓ | No usable NVRAM boot entry (normal on these Macs) | Always boot via Option → EFI Boot; rEFInd handles the rest. To make it permanent from macOS: `sudo bless --folder /Volumes/<ESP>/EFI/refind --setBoot`. |
| rEFInd appears but no Fedora entry | Kernel/initramfs on a filesystem rEFInd can't read | Ensure `/boot` is ext4; the script installs `drivers_x86` (ext2/ext4/btrfs/f2fs/HFS+) for ia32 firmware. |
| Rebase downloads take a long time | The upstream uBlue stable base tag is large | Normal; ~15–25 min on 100 Mbps. |
| `just install-refind` says "Could not mount ESP" | ESP missing from fstab | Re-run `fix-mac-efi.sh` from the live USB. |

## Known hardware caveats for the MBP 4,1 (and siblings)

- **Wi-Fi (BCM4321/4322):** needs `b43-firmware` from RPM Fusion's tainted
  repo — already baked into Abzu's image.
- **Backlight & keyboard:** `applesmc` and the NVIDIA/MCP89 backlight paths
  work on current kernels; function keys need `hid_apple` (default).
- **GPU (GeForce 9400M):** nouveau only — the NVIDIA proprietary driver
  dropped this chip. Expect a solid desktop, no CUDA.
- **32-bit EFI vs 64-bit EFI:** everything in Part 2 branches automatically
  on `/sys/firmware/efi/fw_platform_size`; late-2008+ (64-bit EFI) models
  usually skip straight to `just install-refind`.
