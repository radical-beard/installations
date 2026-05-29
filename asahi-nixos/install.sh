#!/usr/bin/env bash
#
# NixOS on Apple Silicon — External SSD Installer
#
# Installs NixOS onto an external SSD (e.g., Samsung T7). The Asahi boot
# stub on the internal SSD chainloads into NixOS on the external drive.
#
# Usage (from the NixOS live installer, after connecting to WiFi):
#
#   curl -sL https://raw.githubusercontent.com/radical-beard/installations/main/asahi-nixos/install.sh | sudo bash
#
# Prerequisites:
#   - Asahi bootloader already installed (curl https://alx.sh | sh)
#   - Booted into the NixOS live installer via the Asahi UEFI entry
#   - Connected to WiFi (nmcli device wifi connect "SSID" password "PASS")
#   - External SSD plugged in (will be wiped)

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
echo -e "${BOLD}  NixOS on Apple Silicon — External SSD Installer${NC}"
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

if ! command -v gh &>/dev/null; then
  warn "Could not install gh via nix-env, trying nix-shell..."
  export NIX_SHELL_DEPS="true"
fi

run_with_deps() {
  if [ "${NIX_SHELL_DEPS:-}" = "true" ]; then
    local quoted=""
    local arg
    for arg in "$@"; do
      quoted+=" $(printf '%q' "$arg")"
    done
    nix-shell -p gh git --run "${quoted# }"
  else
    "$@"
  fi
}

# ─── GitHub Authentication ──────────────────────────────────────────────────

echo ""
echo -e "${BOLD}─── GitHub Authentication ───${NC}"
echo ""
info "You need to authenticate with GitHub to access your private config repo."
info "This uses GitHub's device flow — you'll approve it on your phone."
echo ""

run_with_deps gh auth login -p https -h github.com

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
run_with_deps gh repo clone "$CONFIG_REPO" /tmp/nixos-config
ok "Config cloned to /tmp/nixos-config"

# ─── Discover disks ─────────────────────────────────────────────────────────

echo ""
echo -e "${BOLD}─── Disk Selection ───${NC}"
echo ""
info "Available disks:"
echo ""
lsblk -d -o NAME,SIZE,MODEL,TRAN | grep -v loop
echo ""
info "Your internal SSD is the 'nvme' disk. Your external SSD should"
info "show as 'usb' in the TRAN column (e.g., sda)."
echo ""

ask "Which disk is your EXTERNAL SSD for NixOS? (e.g., sda): "
read -r EXT_DISK_NAME
EXT_DISK="/dev/$EXT_DISK_NAME"

if [ ! -b "$EXT_DISK" ]; then
  err "$EXT_DISK does not exist"
  exit 1
fi

# Safety check: refuse if they picked the internal NVMe
if [[ "$EXT_DISK" == *"nvme"* ]]; then
  err "That looks like the internal SSD. This script installs to an EXTERNAL disk."
  err "If you really want to install to the internal SSD, edit the script."
  exit 1
fi

EXT_DISK_SIZE=$(lsblk -dno SIZE "$EXT_DISK" | tr -d ' ')
EXT_DISK_MODEL=$(lsblk -dno MODEL "$EXT_DISK" | tr -d '[:space:]')
echo ""
warn "THIS WILL ERASE THE ENTIRE DISK: $EXT_DISK ($EXT_DISK_SIZE, $EXT_DISK_MODEL)"
warn "All data on this disk will be permanently destroyed."
echo ""
ask "Type 'yes' to confirm: "
read -r CONFIRM
if [ "$CONFIRM" != "yes" ]; then
  info "Aborted."
  exit 0
fi

# ─── Find Asahi EFI partition ───────────────────────────────────────────────

echo ""
info "Looking for Asahi EFI partition on internal SSD..."
echo ""

INTERNAL_DISK="/dev/nvme0n1"
lsblk -o NAME,SIZE,TYPE,FSTYPE,LABEL "$INTERNAL_DISK"
echo ""

info "The Asahi EFI partition is a small FAT32 partition (~512MB)"
info "created by the Asahi installer. It's usually one of the last partitions."
echo ""
ask "Enter the EFI partition number on $INTERNAL_DISK (e.g., 5): "
read -r EFI_PART_NUM
EFI_PART="${INTERNAL_DISK}p${EFI_PART_NUM}"

if [ ! -b "$EFI_PART" ]; then
  err "Partition $EFI_PART does not exist"
  exit 1
fi

EFI_FSTYPE=$(lsblk -no FSTYPE "$EFI_PART" 2>/dev/null || echo "")
if [[ "$EFI_FSTYPE" != *"fat"* && "$EFI_FSTYPE" != *"vfat"* ]]; then
  warn "Partition $EFI_PART doesn't look like a FAT32 EFI partition (type: $EFI_FSTYPE)"
  ask "Continue anyway? [y/N]: "
  read -r CONFIRM
  if [[ "$CONFIRM" != "y" && "$CONFIRM" != "Y" ]]; then
    exit 0
  fi
fi
ok "EFI partition: $EFI_PART (on internal SSD)"

# ─── Allocate root size ─────────────────────────────────────────────────────

echo ""
NIXOS_ROOT_SIZE="${NIXOS_ROOT_SIZE:-}"
if [ -z "$NIXOS_ROOT_SIZE" ]; then
  ask "NixOS root partition size [default: 60G]: "
  read -r NIXOS_ROOT_SIZE
  NIXOS_ROOT_SIZE="${NIXOS_ROOT_SIZE:-60G}"
fi

# ─── Partition external SSD ─────────────────────────────────────────────────

echo ""
info "Partitioning $EXT_DISK..."
info "  Partition 1: NixOS root (ext4, ${NIXOS_ROOT_SIZE})"
info "  Partition 2: ZFS workplace (remaining space)"
echo ""

# Wipe and create GPT
sgdisk --zap-all "$EXT_DISK"

# Partition 1: NixOS root
sgdisk -n 1:0:+${NIXOS_ROOT_SIZE} -t 1:8300 -c 1:nixos-root "$EXT_DISK"

# Partition 2: ZFS workplace (remaining space)
sgdisk -n 2:0:0 -t 2:BF00 -c 2:zfs-workplace "$EXT_DISK"

partprobe "$EXT_DISK" 2>/dev/null || true
sleep 2

# Determine partition naming
if [[ "$EXT_DISK" == *"nvme"* ]]; then
  ROOT_PART="${EXT_DISK}p1"
  ZFS_PART="${EXT_DISK}p2"
else
  ROOT_PART="${EXT_DISK}1"
  ZFS_PART="${EXT_DISK}2"
fi

ok "Created NixOS root: $ROOT_PART"
ok "Created ZFS partition: $ZFS_PART"

# ─── Format ─────────────────────────────────────────────────────────────────

info "Formatting NixOS root as ext4..."
mkfs.ext4 -L nixos-root "$ROOT_PART"
ok "Formatted $ROOT_PART"

# ─── Mount ───────────────────────────────────────────────────────────────────

info "Mounting filesystems..."
mount "$ROOT_PART" /mnt
mkdir -p /mnt/boot
mount "$EFI_PART" /mnt/boot
ok "Mounted root at /mnt (external SSD), boot at /mnt/boot (internal EFI)"

# ─── Generate Hardware Config ────────────────────────────────────────────────

info "Generating hardware-configuration.nix..."
nixos-generate-config --root /mnt
ok "Generated hardware-configuration.nix"

# Verify USB storage modules are present in initrd
HW_CONFIG="/mnt/etc/nixos/hardware-configuration.nix"
if ! grep -q "usb_storage\|uas" "$HW_CONFIG"; then
  warn "USB storage modules not auto-detected. Adding them..."
  sed -i '/boot.initrd.availableKernelModules/s/\];/  "usb_storage" "uas" \];/' "$HW_CONFIG"
  ok "Added USB storage modules to initrd"
fi

# ─── Apply Config ────────────────────────────────────────────────────────────

# Copy config files preserving directory structure
mkdir -p /mnt/etc/nixos/common /mnt/etc/nixos/machines/asahi /mnt/etc/nixos/scripts

cp /tmp/nixos-config/flake.nix /mnt/etc/nixos/
cp /tmp/nixos-config/devices.nix /mnt/etc/nixos/ 2>/dev/null || true
cp /tmp/nixos-config/common/*.nix /mnt/etc/nixos/common/
cp /tmp/nixos-config/machines/asahi/default.nix /mnt/etc/nixos/machines/asahi/
cp /tmp/nixos-config/machines/asahi/zfs-shared.nix /mnt/etc/nixos/machines/asahi/

# Copy the full machines/intel dir too (needed by flake even if not used on this machine)
mkdir -p /mnt/etc/nixos/machines/intel
cp /tmp/nixos-config/machines/intel/*.nix /mnt/etc/nixos/machines/intel/ 2>/dev/null || true

# Move generated hardware-configuration.nix into the machine dir
mv /mnt/etc/nixos/hardware-configuration.nix /mnt/etc/nixos/machines/asahi/

# Copy scripts
cp /tmp/nixos-config/scripts/*.sh /mnt/etc/nixos/scripts/ 2>/dev/null || true
chmod +x /mnt/etc/nixos/scripts/*.sh 2>/dev/null || true

# Copy macOS helper files
if [ -d /tmp/nixos-config/macos ]; then
  cp -r /tmp/nixos-config/macos /mnt/etc/nixos/
fi

cat > /mnt/etc/nixos/.gitignore <<'GITIGNORE'
machines/*/hardware-configuration.nix
devices.env
partition-info.txt
GITIGNORE

ok "Config files in place"

# ─── Set ZFS hostId ──────────────────────────────────────────────────────────

HOST_ID=$(head -c 8 /dev/urandom | xxd -p | head -c 8)
sed -i "s/REPLACE_ME/$HOST_ID/" /mnt/etc/nixos/machines/asahi/zfs-shared.nix
ok "Set networking.hostId = \"$HOST_ID\""

# ─── Initialize git repo in /etc/nixos ──────────────────────────────────────

info "Setting up /etc/nixos as a git repo..."
cd /mnt/etc/nixos
git init
git remote add origin "$CONFIG_REPO"
git add -A -- . ':!machines/*/hardware-configuration.nix' ':!devices.env' ':!partition-info.txt'
git commit -m "Initial install config (asahi-mac, external SSD)" 2>/dev/null || true
cd /
ok "Git repo initialized in /etc/nixos"

# ─── Save partition info ────────────────────────────────────────────────────

cat > /mnt/etc/nixos/partition-info.txt << PARTINFO
# Partition info saved by installer
NIXOS_ROOT=$ROOT_PART
EFI_BOOT=$EFI_PART
ZFS_DEVICE=$ZFS_PART
EXT_DISK=$EXT_DISK
HOST_ID=$HOST_ID
PARTINFO

ok "Saved partition info"

# ─── Install NixOS ──────────────────────────────────────────────────────────

echo ""
echo -e "${BOLD}═══════════════════════════════════════════════════${NC}"
echo -e "${BOLD}  Ready to install NixOS${NC}"
echo -e "${BOLD}═══════════════════════════════════════════════════${NC}"
echo ""
info "Root:  $ROOT_PART (external SSD)"
info "Boot:  $EFI_PART (internal NVMe)"
info "ZFS:   $ZFS_PART (external SSD, configured in post-install)"
echo ""
info "Config files:"
find /mnt/etc/nixos -name "*.nix" | sort
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
echo "  1. Reboot (hold Touch ID button → select NixOS)"
echo "  2. Log in as root, set your password:  passwd jaaaacob"
echo "  3. Log in as jaaaacob — Hyprland should start"
echo "  4. Run the post-install script to create the ZFS workplace pool:"
echo ""
echo "     sudo bash /etc/nixos/scripts/post-install.sh"
echo ""
echo "  5. Set up OpenZFS on macOS so you can access ~/workplace/"
echo "     from macOS when the SSD is plugged in (see install-guide.md)"
echo ""
