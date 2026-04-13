# installations

Automated NixOS installation scripts. Public entry points that authenticate with GitHub, clone private config, and handle the full install.

No secrets are stored in this public repo. NixOS configuration lives in a separate private repo, and device credentials are fetched from GitHub repository variables at install time.

---

## Setup 1: Intel Mac (dedicated NixOS)

Full-disk NixOS + Hyprland. Wipes macOS entirely. Syncs `~/workplace/` with other machines via Syncthing through an always-on server.

### What you need

- An Intel Mac (any model, T2 chip is fine)
- A USB flash drive (4GB+)
- WiFi or ethernet
- The [NixOS minimal ISO (x86_64)](https://nixos.org/download/)

### Steps

1. **Flash the USB** (from any computer):

   ```bash
   # macOS
   diskutil unmountDisk /dev/diskX
   sudo dd if=nixos-minimal.iso of=/dev/rdiskX bs=4m status=progress

   # Linux
   sudo dd if=nixos-minimal.iso of=/dev/sdX bs=4M status=progress
   ```

2. **Boot the Intel Mac from USB**:
   - Plug in the USB
   - Hold **Option** key at boot
   - Select the USB drive (labeled "EFI Boot")

3. **Connect to the network**:

   ```bash
   # WiFi
   nmcli device wifi connect "YOUR_WIFI" password "YOUR_PASSWORD"

   # Ethernet — should auto-connect
   ```

4. **Run the installer**:

   ```bash
   curl -sL https://raw.githubusercontent.com/radical-beard/installations/main/intel-nixos/install.sh | sudo bash
   ```

   It will:
   - Ask you to authenticate with GitHub (device code — approve on your phone)
   - Ask for your NixOS config repo URL
   - Fetch device credentials from GitHub repository variables
   - Show available disks and ask which one to wipe
   - Partition, format, and install NixOS

5. **After reboot** — set your password and run post-install:

   ```bash
   # As root:
   passwd jaaaacob

   # Log in as jaaaacob, then:
   sudo bash /etc/nixos/scripts/post-install-intel.sh
   ```

   The post-install script handles:
   - Joining your Tailscale network (browser auth)
   - Creating `~/workplace/`
   - Registering this machine with your Syncthing relay server
   - Files start syncing automatically

### Recovery

You cannot brick an Intel Mac. Even after a full disk wipe, hold **Cmd+Option+R** at boot to download a fresh macOS installer from Apple's servers (Internet Recovery, built into the T2 chip firmware).

---

## Setup 2: Apple Silicon Mac (NixOS on external SSD)

NixOS + Hyprland on an external SSD. macOS stays untouched on the internal drive (except a tiny ~3GB Asahi boot stub). Shares `~/workplace/` via a ZFS partition on the external SSD — accessible from both macOS (via OpenZFS) and NixOS.

### What you need

- An Apple Silicon Mac (M1/M2/M3/M4)
- An external SSD (USB-C or Thunderbolt — e.g., Samsung T7)
- A USB-C data cable for the SSD
- WiFi
- Mac plugged into power

### Steps

1. **Install the Asahi boot stub** (from macOS Terminal):

   ```bash
   curl https://alx.sh | sh
   ```

   - Follow the prompts
   - Choose **minimal** (UEFI environment only)
   - It creates a small (~3GB) stub partition on the internal SSD
   - It will ask you to shut down

2. **Boot into the Asahi UEFI environment**:
   - Plug in your external SSD
   - Hold the **Touch ID button** (top-right key) until you see "Loading startup options..."
   - Select the Asahi entry

3. **Connect to WiFi**:

   ```bash
   nmcli device wifi connect "YOUR_WIFI" password "YOUR_PASSWORD"
   ```

4. **Run the installer**:

   ```bash
   curl -sL https://raw.githubusercontent.com/radical-beard/installations/main/asahi-nixos/install.sh | sudo bash
   ```

   It will:
   - Ask you to authenticate with GitHub (device code — approve on your phone)
   - Ask for your NixOS config repo URL
   - Show all disks with transport type — your external SSD shows as `usb`, internal as `nvme`
   - Ask which disk is the external SSD (safety check prevents accidentally wiping the internal drive)
   - Ask you to identify the Asahi EFI partition on the internal NVMe
   - Partition the external SSD: NixOS root (ext4) + ZFS workplace
   - Install NixOS

5. **Reboot into NixOS**:
   - Hold the **Touch ID button** until "Loading startup options..."
   - Select the NixOS entry

6. **First boot setup**:

   ```bash
   # As root:
   passwd jaaaacob

   # Log in as jaaaacob, then:
   sudo bash /etc/nixos/scripts/post-install.sh
   ```

   This creates the ZFS workplace pool on the second partition of the external SSD and mounts it at `~/workplace/`.

7. **(Optional) Set up OpenZFS on macOS** so you can access `~/workplace/` from macOS when the SSD is plugged in. See `install-guide.md` in the nixos-config repo.

### Daily use

| Action | What happens |
|--------|-------------|
| Normal power on | Boots macOS (default) |
| Hold Touch ID button | Boot picker — choose NixOS (SSD must be plugged in) |
| NixOS shuts down | Next boot returns to macOS |
| Plug SSD into Mac running macOS | OpenZFS can mount the workplace pool |

### Recovery

Apple Silicon Macs are essentially unbrickable. Recovery is built into the Secure Enclave. If anything goes wrong:
- Hold Touch ID button and select Options for macOS Recovery
- Or: connect another Mac via USB-C and use Apple Configurator in DFU mode

---

## How the install scripts work

Both scripts follow the same pattern:

1. Authenticate with GitHub via device flow (approve on your phone)
2. Clone your private NixOS config repo
3. Fetch device credentials (Syncthing IDs, server hostnames) from GitHub repository variables — nothing is hardcoded
4. Partition and format the target disk
5. Generate machine-specific `hardware-configuration.nix`
6. Copy config files into `/etc/nixos/`
7. Run `nixos-install` with the appropriate flake target
