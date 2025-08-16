#!/usr/bin/env bash
# archinstall-lite.sh: educational Arch installer
# WILL ERASE THE TARGET DISK — run inside Arch ISO with internet
set -euo pipefail

### Globals
DISK=""
PART_PREFIX=""
BOOT_MODE="UEFI"
FILESYSTEM="ext4"
SWAP_MODE="none"
SWAP_SIZE_GIB=0
BOOTLOADER="grub"
PROFILE="minimal"
NETWORK="networkmanager"
DE="none"
HOSTNAME=""
USERNAME=""
PASSWORD=""
TIMEZONE=""
PACKAGES=()

BOOT_PART=""
ROOT_PART=""
SWAP_PART=""

### Helper functions
ask() { read -rp "$1: " _val; echo "${_val}"; }

menu() {
  local prompt="$1"; shift
  local options=("$@")
  local choice=""
  while true; do
    echo ""
    echo "=== $prompt ==="
    local i=1
    for opt in "${options[@]}"; do
      echo "  $i) $opt"
      ((i++))
    done
    read -rp "Enter choice [1-${#options[@]}]: " choice
    if [[ "$choice" =~ ^[0-9]+$ ]] && (( choice >= 1 && choice <= ${#options[@]} )); then
      echo "${options[$((choice-1))]}"
      return 0
    fi
    echo "❌ Invalid choice. Please try again."
  done
}

confirm() { read -rp "$1 [y/N]: " _ans; [[ "${_ans:-}" =~ ^[Yy]$ ]]; }

require_cmds() {
  local missing=()
  for c in "$@"; do command -v "$c" >/dev/null 2>&1 || missing+=("$c"); done
  if ((${#missing[@]})); then
    echo "Installing missing tools: ${missing[*]} ..."
    pacman -Sy --noconfirm "${missing[@]}"
  fi
}

### Detect boot mode
detect_boot_mode() {
  if [[ -d /sys/firmware/efi/efivars ]]; then BOOT_MODE="UEFI"; else BOOT_MODE="BIOS"; fi
  echo "🔍 Boot mode detected: $BOOT_MODE"
}

### Disk selection
select_disk() {
  echo ""
  echo "=== Available disks ==="
  lsblk -dpno NAME,SIZE,MODEL | grep -E "/dev/(sd|nvme|vd)"
  DISK="$(ask 'Enter target disk (e.g. /dev/sda, /dev/nvme0n1, /dev/vda)')"
  case "$DISK" in
    /dev/nvme*) PART_PREFIX="p" ;;
    /dev/sd*|/dev/vd*) PART_PREFIX="" ;;
    *) echo "❌ Unknown disk type: $DISK"; exit 1 ;;
  esac
  echo "🔍 Partition prefix: '${PART_PREFIX}'"
}

### Mirrors
configure_mirrors() {
  echo ""
  echo "=== Mirror Selection ==="
  require_cmds reflector
  local region; region="$(menu 'Select mirror region:' 'Worldwide' 'US' 'Europe' 'Asia')"
  case "$region" in
    Worldwide) reflector --latest 20 --sort rate --save /etc/pacman.d/mirrorlist ;;
    US)        reflector --country "United States" --latest 20 --sort rate --save /etc/pacman.d/mirrorlist ;;
    Europe)    reflector --continent Europe --latest 20 --sort rate --save /etc/pacman.d/mirrorlist ;;
    Asia)      reflector --continent Asia --latest 20 --sort rate --save /etc/pacman.d/mirrorlist ;;
  esac
}

### Partitioning
partition_disk() {
  echo ""
  echo "⚠️ This will ERASE all data on $DISK"
  confirm "Proceed?" || exit 1

  wipefs -a "$DISK" || true
  sgdisk -Z "$DISK" || true
  parted --script "$DISK" mklabel gpt

  if [[ "$BOOT_MODE" == "UEFI" ]]; then
    parted --script "$DISK" mkpart ESP fat32 1MiB 512MiB
    parted --script "$DISK" set 1 esp on
    BOOT_PART="${DISK}${PART_PREFIX}1"
    local start="512MiB"
  else
    parted --script "$DISK" mkpart bios_grub 1MiB 3MiB
    parted --script "$DISK" set 1 bios_grub on
    BOOT_PART=""
    local start="3MiB"
  fi

  if [[ "$SWAP_MODE" == "partition" ]]; then
    local end_swap="$(( SWAP_SIZE_GIB ))GiB"
    parted --script "$DISK" mkpart linux-swap "${start}" "${end_swap}"
    SWAP_PART="${DISK}${PART_PREFIX}2"
    start="${end_swap}"
  fi

  parted --script "$DISK" mkpart root "${start}" 100%
  if [[ "$SWAP_MODE" == "partition" && "$BOOT_MODE" == "UEFI" ]]; then
    ROOT_PART="${DISK}${PART_PREFIX}3"
  elif [[ "$SWAP_MODE" == "partition" && "$BOOT_MODE" == "BIOS" ]]; then
    ROOT_PART="${DISK}${PART_PREFIX}3"
  elif [[ "$BOOT_MODE" == "UEFI" ]]; then
    ROOT_PART="${DISK}${PART_PREFIX}2"
  else
    ROOT_PART="${DISK}${PART_PREFIX}2"
  fi

  # Format
  if [[ "$BOOT_MODE" == "UEFI" ]]; then mkfs.fat -F32 "$BOOT_PART"; fi
  mkfs."$FILESYSTEM" -F "$ROOT_PART"
  if [[ -n "${SWAP_PART:-}" ]]; then mkswap "$SWAP_PART"; swapon "$SWAP_PART"; fi

  # Mount
  mount "$ROOT_PART" /mnt
  if [[ "$FILESYSTEM" == "btrfs" ]]; then
    btrfs subvolume create /mnt/@
    btrfs subvolume create /mnt/@home
    umount /mnt
    mount -o subvol=@ "$ROOT_PART" /mnt
    mkdir -p /mnt/home
    mount -o subvol=@home "$ROOT_PART" /mnt/home
  fi
  if [[ "$BOOT_MODE" == "UEFI" ]]; then
    mkdir -p /mnt/boot
    mount "$BOOT_PART" /mnt/boot
  fi
}

### Base install
install_base() {
  echo ""
  echo "=== Installing base system ==="
  local BASE=(base linux linux-firmware vim)
  case "$PROFILE" in
    minimal) BASE+=(networkmanager) ;;
    desktop) BASE+=(networkmanager xorg) ;;
    server)  BASE+=(openssh) ;;
  esac
  pacstrap /mnt "${BASE[@]}" "${PACKAGES[@]}"
  genfstab -U /mnt >> /mnt/etc/fstab

  if [[ "$SWAP_MODE" == "file" ]]; then
    arch-chroot /mnt bash -c "
      fallocate -l ${SWAP_SIZE_GIB}G /swapfile
      chmod 600 /swapfile
      mkswap /swapfile
      echo '/swapfile none swap defaults 0 0' >> /etc/fstab
    "
  fi
}

### Config system
configure_system() {
  arch-chroot /mnt ln -sf "/usr/share/zoneinfo/$TIMEZONE" /etc/localtime
  arch-chroot /mnt hwclock --systohc
  echo "$HOSTNAME" > /mnt/etc/hostname
  sed -i 's/^#en_US.UTF-8/en_US.UTF-8/' /mnt/etc/locale.gen
  arch-chroot /mnt locale-gen
  echo "LANG=en_US.UTF-8" > /mnt/etc/locale.conf
  arch-chroot /mnt bash -c "echo 'root:$PASSWORD' | chpasswd"
  arch-chroot /mnt useradd -m -G wheel -s /bin/bash "$USERNAME"
  arch-chroot /mnt bash -c "echo '$USERNAME:$PASSWORD' | chpasswd"
  echo '%wheel ALL=(ALL) ALL' > /mnt/etc/sudoers.d/10-wheel

  case "$NETWORK" in
    networkmanager)
      arch-chroot /mnt systemctl enable NetworkManager ;;
    systemd-networkd)
      arch-chroot /mnt systemctl enable systemd-networkd systemd-resolved ;;
    static)
      cat >/mnt/etc/systemd/network/20-wired.network <<'EOF'
[Match]
Name=en*
[Network]
Address=192.168.1.100/24
Gateway=192.168.1.1
DNS=1.1.1.1
EOF
      arch-chroot /mnt systemctl enable systemd-networkd systemd-resolved ;;
  esac
}

### Bootloader
install_bootloader() {
  if [[ "$BOOT_MODE" == "UEFI" ]]; then
    case "$BOOTLOADER" in
      grub)
        arch-chroot /mnt pacman -Sy --noconfirm grub efibootmgr
        arch-chroot /mnt grub-install --target=x86_64-efi --efi-directory=/boot --bootloader-id=GRUB
        arch-chroot /mnt grub-mkconfig -o /boot/grub/grub.cfg ;;
      systemd-boot)
        arch-chroot /mnt bootctl install ;;
    esac
  else
    arch-chroot /mnt pacman -Sy --noconfirm grub
    arch-chroot /mnt grub-install --target=i386-pc "$DISK"
    arch-chroot /mnt grub-mkconfig -o /boot/grub/grub.cfg
  fi
}

### Desktop Environment
install_de() {
  case "$DE" in
    gnome) arch-chroot /mnt pacman -Sy --noconfirm gnome gdm; arch-chroot /mnt systemctl enable gdm ;;
    kde)   arch-chroot /mnt pacman -Sy --noconfirm plasma sddm; arch-chroot /mnt systemctl enable sddm ;;
    xfce)  arch-chroot /mnt pacman -Sy --noconfirm xfce4 lightdm lightdm-gtk-greeter; arch-chroot /mnt systemctl enable lightdm ;;
  esac
}

### Main
main() {
  require_cmds pacstrap arch-chroot parted sgdisk reflector
  detect_boot_mode
  select_disk
  configure_mirrors

  FILESYSTEM="$(menu 'Choose filesystem' ext4 btrfs xfs)"
  SWAP_MODE="$(menu 'Swap option' none partition file)"
  if [[ "$SWAP_MODE" != "none" ]]; then
    SWAP_SIZE_GIB="$(ask 'Swap size in GiB (e.g. 8)')"
  fi
  TIMEZONE="$(ask 'Timezone (e.g. Europe/Berlin)')"
  HOSTNAME="$(ask 'Hostname')"
  USERNAME="$(ask 'Username')"
  PASSWORD="$(ask 'Password (visible as you type)')"
  PROFILE="$(menu 'Select profile' minimal desktop server)"
  NETWORK="$(menu 'Networking option' networkmanager systemd-networkd static)"
  DE="$(menu 'Desktop environment' none gnome kde xfce)"
  if [[ "$BOOT_MODE" == "UEFI" ]]; then
    BOOTLOADER="$(menu 'Bootloader' grub systemd-boot)"
  else
    BOOTLOADER="grub"
  fi

  read -rp "Additional packages (space-separated): " pkgline || true
  [[ -n "${pkgline:-}" ]] && PACKAGES=($pkgline)

  partition_disk
  install_base
  configure_system
  install_bootloader
  install_de

  echo ""
  echo "✅ Installation complete."
  echo "Run: umount -R /mnt && swapoff -a (if any) && reboot"
}

main "$@"
