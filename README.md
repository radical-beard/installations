# installations

Automated installation scripts for setting up machines. These are public entry points that authenticate with GitHub and then pull private configuration repos.

## Asahi NixOS (Apple Silicon dual-boot)

Dual-boot an Apple Silicon Mac with NixOS + Hyprland, sharing a ZFS workspace between macOS and Linux.

### Prerequisites

1. Run the Asahi installer on macOS: `curl https://alx.sh | sh`
2. Boot the NixOS installer from USB
3. Connect to WiFi: `nmcli device wifi connect "SSID" password "PASS"`

### Install

```bash
curl -sL https://raw.githubusercontent.com/radical-beard/installations/main/asahi-nixos/install.sh | sudo bash
```

This will:
- Authenticate you with GitHub (device flow — approve on your phone)
- Clone your private NixOS config
- Partition the disk (NixOS root + ZFS)
- Install NixOS with your config

After first boot, run: `sudo bash /etc/nixos/scripts/post-install.sh`
