#!/usr/bin/env bash
#
# NixOS on Intel Mac — Full Disk Automated Installer
#
# This wipes macOS entirely and installs NixOS as the only OS.
#
# Usage (from the NixOS live installer USB, after connecting to network):
#
#   curl -sL https://raw.githubusercontent.com/radical-beard/installations/main/intel-nixos/install.sh | sudo bash
#
# Prerequisites:
#   - Booted from a standard NixOS minimal ISO USB (x86_64)
#   - Connected to network (WiFi or ethernet)
#   - YOU ARE OKAY WITH WIPING THE ENTIRE DISK

set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

info()  { echo -e "${CYAN}[INFO]${NC} $1"; }
ok()    { echo -e "${GREEN}[OK]${NC} $1"; }
warn()  { echo -e "${YELLOW}[WARN]${NC} $1"; }
err()   { echo -e "${RED}[ERROR]${NC} $1"; }
ask()   { echo -en "${BOLD}$1${NC}"; }

echo ""
echo -e "${BOLD}═══════════════════════════════════════════════════${NC}"
echo -e "${BOLD}  NixOS on Intel Mac — Full Disk Installer${NC}"
echo -e "${BOLD}═══════════════════════════════════════════════════${NC}"
echo ""

# ─── Preflight ───────────────────────────────────────────────────────────────

if [ "$(id -u)" -ne 0 ]; then
  err "Run as root: sudo bash install.sh"
  exit 1
fi

if ! ping -c 1 -W 3 github.com &>/dev/null; then
  err "No network. Connect first:"
  echo "  WiFi:     nmcli device wifi connect \"SSID\" password \"PASS\""
  echo "  Ethernet: should auto-connect"
  exit 1
fi
ok "Network connected"

# ─── Install dependencies ───────────────────────────────────────────────────

info "Setting up tools (git, gh)..."
nix-env -iA nixos.git nixos.gh 2>/dev/null || nix-env -f '<nixpkgs>' -iA git gh 2>/dev/null || true

if ! command -v gh &>/dev/null; then
  warn "Could not install gh via nix-env, trying nix-shell..."
  export NIX_SHELL_DEPS="true"
fi

# ─── GitHub Auth ─────────────────────────────────────────────────────────────

echo ""
echo -e "${BOLD}─── GitHub Authentication ───${NC}"
echo ""
info "Authenticate with GitHub to access your private config repo."
info "Approve the device code on your phone."
echo ""

if [ "${NIX_SHELL_DEPS:-}" = "true" ]; then
  nix-shell -p gh --run "gh auth login -p https -h github.com"
else
  gh auth login -p https -h github.com
fi
ok "Authenticated with GitHub"

# ─── Config Repo ─────────────────────────────────────────────────────────────

echo ""
CONFIG_REPO="${NIXOS_CONFIG_REPO:-}"
if [ -z "$CONFIG_REPO" ]; then
  ask "GitHub repo URL for your NixOS config (e.g., https://github.com/user/nixos-config): "
  read -r CONFIG_REPO
fi

info "Cloning config from $CONFIG_REPO..."
if [ "${NIX_SHELL_DEPS:-}" = "true" ]; then
  nix-shell -p gh git --run "gh repo clone $CONFIG_REPO /tmp/nixos-config"
else
  gh repo clone "$CONFIG_REPO" /tmp/nixos-config
fi
ok "Config cloned"

# ─── Discover Disk ──────────────────────────────────────────────────────────

echo ""
info "Available disks:"
echo ""
lsblk -d -o NAME,SIZE,MODEL | grep -v loop
echo ""

ask "Which disk to install on? (e.g., sda, nvme0n1): "
read -r DISK_NAME
DISK="/dev/$DISK_NAME"

if [ ! -b "$DISK" ]; then
  err "$DISK does not exist"
  exit 1
fi

DISK_SIZE=$(lsblk -dno SIZE "$DISK" | tr -d ' ')
echo ""
warn "THIS WILL ERASE THE ENTIRE DISK: $DISK ($DISK_SIZE)"
warn "All data on this disk will be permanently destroyed."
echo ""
ask "Type 'yes' to confirm: "
read -r CONFIRM
if [ "$CONFIRM" != "yes" ]; then
  info "Aborted."
  exit 0
fi

# ─── Partition ──────────────────────────────────────────────────────────────

info "Partitioning $DISK..."

# Determine partition naming (nvme uses p1, sda uses 1)
if [[ "$DISK" == *"nvme"* ]]; then
  PART_PREFIX="${DISK}p"
else
  PART_PREFIX="${DISK}"
fi

# Create GPT partition table
sgdisk --zap-all "$DISK"

# Partition 1: EFI System Partition (512MB)
sgdisk -n 1:0:+512M -t 1:EF00 -c 1:efi "$DISK"

# Partition 2: Root filesystem (remaining space)
sgdisk -n 2:0:0 -t 2:8300 -c 2:nixos-root "$DISK"

partprobe "$DISK" 2>/dev/null || true
sleep 2

EFI_PART="${PART_PREFIX}1"
ROOT_PART="${PART_PREFIX}2"

ok "Created EFI: $EFI_PART"
ok "Created root: $ROOT_PART"

# ─── Format ─────────────────────────────────────────────────────────────────

info "Formatting..."
mkfs.fat -F32 -n EFI "$EFI_PART"
mkfs.ext4 -L nixos-root "$ROOT_PART"
ok "Formatted"

# ─── Mount ───────────────────────────────────────────────────────────────────

mount "$ROOT_PART" /mnt
mkdir -p /mnt/boot
mount "$EFI_PART" /mnt/boot
ok "Mounted root at /mnt, boot at /mnt/boot"

# ─── Generate Hardware Config ────────────────────────────────────────────────

info "Generating hardware-configuration.nix..."
nixos-generate-config --root /mnt
ok "Generated"

# ─── Apply Config ────────────────────────────────────────────────────────────

# Copy machine-specific and common config
mkdir -p /mnt/etc/nixos/common /mnt/etc/nixos/machines/intel

cp /tmp/nixos-config/flake.nix /mnt/etc/nixos/
cp /tmp/nixos-config/common/*.nix /mnt/etc/nixos/common/
cp /tmp/nixos-config/machines/intel/default.nix /mnt/etc/nixos/machines/intel/
cp /tmp/nixos-config/machines/intel/syncthing.nix /mnt/etc/nixos/machines/intel/

# Copy the full machines/asahi dir too (needed by flake even if not used on this machine)
mkdir -p /mnt/etc/nixos/machines/asahi
cp /tmp/nixos-config/machines/asahi/*.nix /mnt/etc/nixos/machines/asahi/ 2>/dev/null || true

# Move generated hardware-configuration.nix into the machine dir
mv /mnt/etc/nixos/hardware-configuration.nix /mnt/etc/nixos/machines/intel/

# Remove the auto-generated configuration.nix (we use flakes)
rm -f /mnt/etc/nixos/configuration.nix

ok "Config files in place"

# ─── Init git repo for config-sync ──────────────────────────────────────────

info "Setting up /etc/nixos as a git repo..."
cd /mnt/etc/nixos
git init
git remote add origin "$CONFIG_REPO"
git add -A
git commit -m "Initial install config (intel-mac)" 2>/dev/null || true
cd /
ok "Git repo initialized"

# ─── Install ────────────────────────────────────────────────────────────────

echo ""
echo -e "${BOLD}═══════════════════════════════════════════════════${NC}"
echo -e "${BOLD}  Ready to install NixOS${NC}"
echo -e "${BOLD}═══════════════════════════════════════════════════${NC}"
echo ""
info "Config files:"
find /mnt/etc/nixos -name "*.nix" | sort
echo ""

ask "Install NixOS now? [Y/n]: "
read -r CONFIRM
if [[ "$CONFIRM" == "n" || "$CONFIRM" == "N" ]]; then
  info "Skipped. Run manually: nixos-install --flake /mnt/etc/nixos#intel-mac"
  exit 0
fi

info "Running nixos-install (this will take a while)..."
nixos-install --flake /mnt/etc/nixos#intel-mac

echo ""
echo -e "${GREEN}${BOLD}═══════════════════════════════════════════════════${NC}"
echo -e "${GREEN}${BOLD}  NixOS installed successfully!${NC}"
echo -e "${GREEN}${BOLD}═══════════════════════════════════════════════════${NC}"
echo ""
echo "Next steps:"
echo ""
echo "  1. Remove the USB drive and reboot"
echo "  2. Log in as root, set your password:  passwd jaaaacob"
echo "  3. Log in as jaaaacob — Hyprland should start"
echo "  4. Set up Syncthing:"
echo "     - Open http://localhost:8384 in Firefox"
echo "     - On your M1 Pro, open Syncthing and get the device ID"
echo "     - Add each machine as a remote device on the other"
echo "     - Share ~/workplace/ between both devices"
echo "  5. Create ~/workplace/ if it doesn't exist:"
echo "     mkdir -p ~/workplace"
echo ""
