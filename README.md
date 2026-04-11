# installations

Automated NixOS installation scripts. Public entry points that authenticate with GitHub, clone private config, and handle the full install.

## Available Setups

### 1. Intel Mac (dedicated NixOS)

Full-disk NixOS + Hyprland install on an Intel Mac. Wipes macOS entirely. Syncs ~/workplace/ with other machines via Syncthing.

**Boot a [standard NixOS minimal ISO](https://nixos.org/download/) USB, connect to network, then:**

```bash
curl -sL https://raw.githubusercontent.com/radical-beard/installations/main/intel-nixos/install.sh | sudo bash
```

### 2. Apple Silicon Mac (dual-boot)

Dual-boot NixOS + Hyprland alongside macOS on Apple Silicon. Shares ~/workplace/ via ZFS partition.

**Run the Asahi installer on macOS first (`curl https://alx.sh | sh`), then boot the [nixos-apple-silicon ISO](https://github.com/nix-community/nixos-apple-silicon/releases) from USB:**

```bash
curl -sL https://raw.githubusercontent.com/radical-beard/installations/main/asahi-nixos/install.sh | sudo bash
```

## What These Scripts Do

1. Authenticate you with GitHub (device flow — approve on your phone)
2. Clone your private NixOS config repo
3. Partition and format the disk
4. Generate machine-specific hardware config
5. Run `nixos-install`

No secrets are stored in this public repo. Your NixOS configuration lives in a separate private repo.
