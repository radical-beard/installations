#!/usr/bin/env bash
#
# NixOS on Apple Silicon — Automated Installer
#
# Handles GitHub auth, clones your private config, partitions, and installs.
#
# Usage (from the NixOS live installer, after connecting to WiFi):
#
#   curl -sL https://raw.githubusercontent.com/radical-beard/installations/main/asahi-nixos/install.sh | bash
#
# Prerequisites:
#   - Asahi bootloader already installed (curl https://alx.sh | sh)
#   - Booted into the NixOS live installer
#   - Connected to WiFi (nmcli device wifi connect "SSID" password "PASS")

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
echo -e "${BOLD}  NixOS on Apple Silicon — Automated Installer${NC}"
echo -e "${BOLD}═══════════════════════════════════════════════════${NC}"
echo ""

# ─── Check we're root ────────────────────────────────────────────────────────

if [ "$(id -u)" -ne 0 ]; then
  err "This script must be run as root. Try: sudo bash install.sh"
  exit 1
fi

# ─── Check network ──────────────────────────────────────────────────────────

if ! ping -c 1 -W 3 github.com &>/dev/null; then
  err "No network. Connect to WiFi first:"
  echo '  nmcli device wifi connect "YOUR_SSID" password "YOUR_PASS"'
  exit 1
fi
ok "Network connected"

# ─── Install dependencies ───────────────────────────────────────────────────

info "Setting up tools (git, gh)..."
nix-env -iA nixos.git nixos.gh 2>/dev/null || nix-env -f '<nixpkgs>' -iA git gh 2>/dev/null || true

# Verify
if ! command -v gh &>/dev/null; then
  warn "Could not install gh via nix-env, trying nix-shell..."
  export NIX_SHELL_DEPS="true"
fi

# ─── GitHub Authentication ──────────────────────────────────────────────────

echo ""
echo -e "${BOLD}─── GitHub Authentication ───${NC}"
echo ""
info "You need to authenticate with GitHub to access your private config repo."
info "This uses GitHub's device flow — you'll approve it on your phone."
echo ""

if [ "${NIX_SHELL_DEPS:-}" = "true" ]; then
  nix-shell -p gh --run "gh auth login -p https -h github.com"
else
  gh auth login -p https -h github.com
fi

ok "Authenticated with GitHub"

# ─── Get config repo URL ────────────────────────────────────────────────────

echo ""
CONFIG_REPO="${NIXOS_CONFIG_REPO:-}"
if [ -z "$CONFIG_REPO" ]; then
  ask "GitHub repo URL for your NixOS config (e.g., https://github.com/user/nixos-config): "
  read -r CONFIG_REPO
fi

if [ -z "$CONFIG_REPO" ]; then
  err "Repo URL is required"
  exit 1
fi

# ─── Clone config ───────────────────────────────────────────────────────────

info "Cloning config from $CONFIG_REPO..."
if [ "${NIX_SHELL_DEPS:-}" = "true" ]; then
  nix-shell -p gh git --run "gh repo clone $CONFIG_REPO /tmp/nixos-config"
else
  gh repo clone "$CONFIG_REPO" /tmp/nixos-config
fi
ok "Config cloned to /tmp/nixos-config"

# ─── Allocate root size ─────────────────────────────────────────────────────

echo ""
NIXOS_ROOT_SIZE="${NIXOS_ROOT_SIZE:-}"
if [ -z "$NIXOS_ROOT_SIZE" ]; then
  ask "NixOS root partition size [default: 60G]: "
  read -r NIXOS_ROOT_SIZE
  NIXOS_ROOT_SIZE="${NIXOS_ROOT_SIZE:-60G}"
fi

# ─── Discover Partitions ────────────────────────────────────────────────────

echo ""
info "Scanning disk layout..."
echo ""

DISK="/dev/nvme0n1"
lsblk -o NAME,SIZE,TYPE,FSTYPE,LABEL "$DISK"
echo ""
fdisk -l "$DISK" 2>/dev/null || gdisk -l "$DISK" 2>/dev/null
echo ""

warn "Identify the Asahi-created Linux partition(s)."
warn "These are typically the LAST partitions on the disk."
warn "DO NOT touch macOS partitions."
echo ""

ask "Enter the partition number for the Asahi Linux space (e.g., 5): "
read -r ASAHI_PART_NUM
ASAHI_PART="${DISK}p${ASAHI_PART_NUM}"

if [ ! -b "$ASAHI_PART" ]; then
  err "Partition $ASAHI_PART does not exist"
  exit 1
fi

ASAHI_SIZE=$(blockdev --getsize64 "$ASAHI_PART" 2>/dev/null)
ASAHI_SIZE_GB=$((ASAHI_SIZE / 1024 / 1024 / 1024))
info "Selected partition: $ASAHI_PART (${ASAHI_SIZE_GB}GB)"

ask "Enter the EFI/boot partition number (created by Asahi, usually small ~512MB): "
read -r EFI_PART_NUM
EFI_PART="${DISK}p${EFI_PART_NUM}"

if [ ! -b "$EFI_PART" ]; then
  err "Partition $EFI_PART does not exist"
  exit 1
fi
ok "EFI partition: $EFI_PART"

# ─── Repartition ────────────────────────────────────────────────────────────

echo ""
info "Splitting $ASAHI_PART into:"
info "  1. NixOS root (ext4, ${NIXOS_ROOT_SIZE})"
info "  2. ZFS pool (remaining space)"
echo ""

ask "Proceed with repartitioning? This will ERASE the Linux partition. [y/N]: "
read -r CONFIRM
if [[ "$CONFIRM" != "y" && "$CONFIRM" != "Y" ]]; then
  info "Aborted."
  exit 0
fi

PART_INFO=$(sgdisk -i "$ASAHI_PART_NUM" "$DISK" 2>/dev/null)
START_SECTOR=$(echo "$PART_INFO" | grep "First sector" | awk '{print $3}')
END_SECTOR=$(echo "$PART_INFO" | grep "Last sector" | awk '{print $3}')

if [ -z "$START_SECTOR" ] || [ -z "$END_SECTOR" ]; then
  err "Could not determine partition boundaries."
  echo "Manually partition with: gdisk $DISK"
  exit 1
fi

info "Repartitioning..."

sgdisk -d "$ASAHI_PART_NUM" "$DISK"
sgdisk -n "${ASAHI_PART_NUM}:${START_SECTOR}:+${NIXOS_ROOT_SIZE}" \
  -t "${ASAHI_PART_NUM}:8300" -c "${ASAHI_PART_NUM}:nixos-root" "$DISK"

ZFS_PART_NUM=$((ASAHI_PART_NUM + 1))
sgdisk -n "${ZFS_PART_NUM}:0:${END_SECTOR}" \
  -t "${ZFS_PART_NUM}:BF00" -c "${ZFS_PART_NUM}:zfs-workplace" "$DISK"

partprobe "$DISK" 2>/dev/null || true
sleep 2

NIXOS_PART="${DISK}p${ASAHI_PART_NUM}"
ZFS_PART="${DISK}p${ZFS_PART_NUM}"

ok "Created NixOS root: $NIXOS_PART"
ok "Created ZFS partition: $ZFS_PART"

# ─── Format ─────────────────────────────────────────────────────────────────

info "Formatting NixOS root as ext4..."
mkfs.ext4 -L nixos-root "$NIXOS_PART"
ok "Formatted $NIXOS_PART"

# ─── Mount ───────────────────────────────────────────────────────────────────

info "Mounting filesystems..."
mount "$NIXOS_PART" /mnt
mkdir -p /mnt/boot
mount "$EFI_PART" /mnt/boot
ok "Mounted root at /mnt, boot at /mnt/boot"

# ─── Generate Hardware Config ────────────────────────────────────────────────

info "Generating hardware-configuration.nix..."
nixos-generate-config --root /mnt
ok "Generated /mnt/etc/nixos/hardware-configuration.nix"

# ─── Apply Config ────────────────────────────────────────────────────────────

# Copy config files, preserving the generated hardware-configuration.nix
for f in /tmp/nixos-config/*.nix; do
  name=$(basename "$f")
  [ "$name" = "hardware-configuration.nix" ] && continue
  cp "$f" /mnt/etc/nixos/
done

# Copy scripts
if [ -d /tmp/nixos-config/scripts ]; then
  cp -r /tmp/nixos-config/scripts /mnt/etc/nixos/
fi

# Copy macOS files
if [ -d /tmp/nixos-config/macos ]; then
  cp -r /tmp/nixos-config/macos /mnt/etc/nixos/
fi

ok "Config files in place"

# ─── Set ZFS hostId ──────────────────────────────────────────────────────────

HOST_ID=$(head -c 8 /dev/urandom | xxd -p | head -c 8)
sed -i "s/REPLACE_ME/$HOST_ID/" /mnt/etc/nixos/zfs.nix
ok "Set networking.hostId = \"$HOST_ID\" in zfs.nix"

# ─── Initialize git repo in /etc/nixos ──────────────────────────────────────

# Set up /etc/nixos as a git repo tracking the private config
# This is needed for config-sync.nix (auto-pull/push on boot/shutdown)
info "Setting up /etc/nixos as a git repo..."
cd /mnt/etc/nixos
git init
git remote add origin "$CONFIG_REPO"
git add -A
git commit -m "Initial install config (machine-specific)" 2>/dev/null || true
ok "Git repo initialized in /etc/nixos"
cd /

# ─── Save partition info ────────────────────────────────────────────────────

cat > /mnt/etc/nixos/partition-info.txt << PARTINFO
# Partition info saved by installer
NIXOS_ROOT=$NIXOS_PART
EFI_BOOT=$EFI_PART
ZFS_DEVICE=$ZFS_PART
HOST_ID=$HOST_ID
PARTINFO

ok "Saved partition info"

# ─── Install NixOS ──────────────────────────────────────────────────────────

echo ""
echo -e "${BOLD}═══════════════════════════════════════════════════${NC}"
echo -e "${BOLD}  Ready to install NixOS${NC}"
echo -e "${BOLD}═══════════════════════════════════════════════════${NC}"
echo ""
info "Config files:"
ls -la /mnt/etc/nixos/*.nix
echo ""

ask "Install NixOS now? [Y/n]: "
read -r CONFIRM
if [[ "$CONFIRM" == "n" || "$CONFIRM" == "N" ]]; then
  info "Skipped. Run manually: nixos-install --flake /mnt/etc/nixos#asahi-mac"
  exit 0
fi

info "Running nixos-install (this will take a while)..."
nixos-install --flake /mnt/etc/nixos#asahi-mac

echo ""
echo -e "${GREEN}${BOLD}═══════════════════════════════════════════════════${NC}"
echo -e "${GREEN}${BOLD}  NixOS installed successfully!${NC}"
echo -e "${GREEN}${BOLD}═══════════════════════════════════════════════════${NC}"
echo ""
echo "Next steps:"
echo ""
echo "  1. Reboot into NixOS (hold power button → select NixOS)"
echo "  2. Log in as root, set your user password"
echo "  3. Log in as your user"
echo "  4. Run the post-install script to create the ZFS pool:"
echo ""
echo "     sudo bash /etc/nixos/scripts/post-install.sh"
echo ""
echo "  5. Reboot to macOS and set up OpenZFS (see install-guide.md Step 12)"
echo ""
