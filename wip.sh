#!/usr/bin/env bash
# archinstall-lite: experimental Arch installer inspired by archinstall
# USE AT YOUR OWN RISK — WILL DESTROY DATA ON THE SELECTED DISK!
set -euo pipefail

### Globals
DISK=""
PART_PREFIX=""        # '' for sdX/vdX, 'p' for nvme0n1pX
BOOT_MODE="UEFI"      # UEFI or BIOS (detected)
FILESYSTEM="ext4"     # ext4|btrfs|xfs
SWAP_MODE="none"      # none|partition|file
SWAP_SIZE_GIB=0       # for partition or file
BOOTLOADER="grub"     # grub|systemd-boot (UEFI only)
PROFILE="minimal"     # minimal|desktop|server
NETWORK="networkmanager" # networkmanager|systemd-networkd|static
DE="none"             # none|gnome|kde|xfce
HOSTNAME=""
USERNAME=""
PASSWORD=""
TIMEZONE=""
PACKAGES=()

# Calculated device paths
BOOT_PART=""
ROOT_PART=""
SWAP_PART=""

### Helpers
confirm() { read -rp "$1 [y/N]: " _ans; [[ "${_ans:-}" =~ ^[Yy]$ ]]; }
ask() { read -rp "$1: " _val; echo "${_val}"; }
menu() {
  local prompt="$1"; shift; local options=("$@")
  echo "$prompt"; local i=1; for o in "${options[@]}"; do echo "  $i) $o"; ((i++)); done
  local c; read -rp "Select option: " c; echo "${options[$((c-1))]}"
}

require_cmds() {
  local missing=()
  for c in "$@"; do command -v "$c" >/dev/null 2>&1 || missing+=("$c"); done
  if ((${#missing[@]})); then
    echo "Installing missing tools: ${missing[*]} ..."
    pacman -Sy --noconfirm "${missing[@]}"
  fi
}

detect_boot_mode() {
  if [[ -d /sys/firmware/efi/efivars ]]; then BOOT_MODE="UEFI"; else BOOT_MODE="BIOS"; fi
  echo "🔍 Boot mode: $BOOT_MODE"
}

select_disk() {
  echo "Available disks:"
  lsblk -dpno NAME,SIZE,MODEL | grep -E "/dev/(sd|nvme|vd)"
  DISK="$(ask 'Enter target disk (e.g. /dev/sda, /dev/nvme0n1, /dev/vda)')"
  case "$DISK" in
    /dev/nvme*) PART_PREFIX="p" ;;
    /dev/sd*|/dev/vd*) PART_PREFIX="" ;;
    *) echo "Unknown disk type: $DISK"; exit 1 ;;
  esac
  echo "🔍 Partition prefix: '${PART_PREFIX}'"
}

configure_mirrors() {
  echo "Configuring mirrors (reflector) ..."
  require_cmds reflector
  local region; region="$(menu 'Select mirror region:' 'Worldwide' 'US' 'Europe' 'Asia')"
  case "$region" in
    Worldwide) reflector --latest 20 --sort rate --save /etc/pacman.d/mirrorlist ;;
    US)        reflector --country "United States" --latest 20 --sort rate --save /etc/pacman.d/mirrorlist ;;
    Europe)    reflector --continent Europe --latest 20 --sort rate --save /etc/pacman.d/mirrorlist ;;
    Asia)      reflector --continent Asia --latest 20 --sort rate --save /etc/pacman.d/mirrorlist ;;
  esac
}

partition_disk() {
  echo "⚠️ About to wipe partition table on $DISK"
  confirm "Proceed and ERASE $DISK?" || { echo "Aborted."; exit 1; }

  wipefs -a "$DISK" || true
  sgdisk -Z "$DISK" || true
  parted --script "$DISK" mklabel gpt

  if [[ "$BOOT_MODE" == "UEFI" ]]; then
    # ESP 1MiB–512MiB
    parted --script "$DISK" mkpart ESP fat32 1MiB 512MiB
    parted --script "$DISK" set 1 esp on
    BOOT_PART="${DISK}${PART_PREFIX}1"
    local start="512MiB"
  else
    # BIOS: create tiny bios_grub 1MiB–3MiB, then boot (optional) not needed; root next
    parted --script "$DISK" mkpart bios_grub 1MiB 3MiB
    parted --script "$DISK" set 1 bios_grub on
    BOOT_PART=""  # No separate /boot; GRUB installs to MBR + core.img
    local start="3MiB"
  fi

  if [[ "$SWAP_MODE" == "partition" ]]; then
    local end_swap="$(( SWAP_SIZE_GIB ))GiB"
    parted --script "$DISK" mkpart linux-swap "${start}" "${end_swap}"
    SWAP_PART="${DISK}${PART_PREFIX}$( [[ "$BOOT_MODE" == "UEFI" ]] && echo 2 || echo 2 )"
    start="${end_swap}"
  fi

  # Root partition uses the rest
  parted --script "$DISK" mkpart root "${start}" 100%
  ROOT_PART="${DISK}${PART_PREFIX}$( [[ "$BOOT_MODE" == "UEFI" ]] && ( [[ "$SWAP_MODE" == "partition" ]] && echo 3 || echo 2 ) || ( [[ "$SWAP_MODE" == "partition" ]] && echo 3 || echo 2 ) )"

  # Format
  if [[ "$BOOT_MODE" == "UEFI" ]]; then
    mkfs.fat -F32 "$BOOT_PART"
  fi
  case "$FILESYSTEM" in
    ext4) mkfs.ext4 -F "$ROOT_PART" ;;
    btrfs) mkfs.btrfs -f "$ROOT_PART" ;;
    xfs) mkfs.xfs -f "$ROOT_PART" ;;
  esac
  if [[ -n "${SWAP_PART:-}" ]]; then mkswap "$SWAP_PART"; swapon "$SWAP_PART"; fi

  # Mount
  mount "$ROOT_PART" /mnt
  if [[ "$FILESYSTEM" == "btrfs" ]]; then
    # simple subvol layout
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

install_base() {
  echo "Installing base system..."
  local BASE=(base linux linux-firmware vim sudo)
  case "$PROFILE" in
    minimal) BASE+=(networkmanager) ;;
    desktop) BASE+=(networkmanager xorg) ;;
    server)  BASE+=(openssh) ;;
  esac
  pacstrap /mnt "${BASE[@]}" "${PACKAGES[@]}"
  genfstab -U /mnt >> /mnt/etc/fstab

  if [[ "$SWAP_MODE" == "file" ]]; then
    echo "Creating swapfile (${SWAP_SIZE_GIB}G)..."
    arch-chroot /mnt bash -euxo pipefail -c "
      fallocate -l ${SWAP_SIZE_GIB}G /swapfile
      chmod 600 /swapfile
      mkswap /swapfile
      echo '/swapfile none swap defaults 0 0' >> /etc/fstab
    "
  fi
}

configure_system() {
  echo "Configuring system..."
  arch-chroot /mnt ln -sf "/usr/share/zoneinfo/$TIMEZONE" /etc/localtime
  arch-chroot /mnt hwclock --systohc
  echo "$HOSTNAME" > /mnt/etc/hostname

  # locale (en_US.UTF-8 default; user can adjust later)
  sed -i 's/^#en_US.UTF-8/en_US.UTF-8/' /mnt/etc/locale.gen
  arch-chroot /mnt locale-gen
  echo "LANG=en_US.UTF-8" > /mnt/etc/locale.conf

  # users
  arch-chroot /mnt bash -c "echo 'root:$PASSWORD' | chpasswd"
  arch-chroot /mnt useradd -m -G wheel -s /bin/bash "$USERNAME"
  arch-chroot /mnt bash -c "echo '$USERNAME:$PASSWORD' | chpasswd"
  echo '%wheel ALL=(ALL) ALL' > /mnt/etc/sudoers.d/10-wheel

  # networking base
  case "$NETWORK" in
    networkmanager)
      arch-chroot /mnt pacman -Sy --noconfirm networkmanager
      arch-chroot /mnt systemctl enable NetworkManager
      ;;
    systemd-networkd)
      arch-chroot /mnt systemctl enable systemd-networkd systemd-resolved
      arch-chroot /mnt ln -sf /run/systemd/resolve/stub-resolv.conf /etc/resolv.conf
      ;;
    static)
      arch-chroot /mnt systemctl enable systemd-networkd systemd-resolved
      arch-chroot /mnt ln -sf /run/systemd/resolve/stub-resolv.conf /etc/resolv.conf
      # basic wired config; adjust as needed
      cat >/mnt/etc/systemd/network/20-wired.network <<'EOF'
[Match]
Name=en*

[Network]
Address=192.168.1.100/24
Gateway=192.168.1.1
DNS=1.1.1.1
EOF
      ;;
  esac
}

install_bootloader() {
  echo "Installing bootloader..."
  if [[ "$BOOT_MODE" == "UEFI" ]]; then
    case "$BOOTLOADER" in
      grub)
        arch-chroot /mnt pacman -Sy --noconfirm grub efibootmgr
        arch-chroot /mnt grub-install --target=x86_64-efi --efi-directory=/boot --bootloader-id=GRUB
        arch-chroot /mnt grub-mkconfig -o /boot/grub/grub.cfg
        ;;
      systemd-boot)
        arch-chroot /mnt bootctl install
        # Create a simple loader entry using root UUID
        ROOT_UUID=$(blkid -s UUID -o value "$ROOT_PART")
        cat >/mnt/boot/loader/loader.conf <<EOF
default  arch
timeout  3
console-mode max
editor   no
EOF
        KVER=$(arch-chroot /mnt bash -c "uname -r" || echo "linux")
        # Use standard file names from pacman packages
        cat >/mnt/boot/loader/entries/arch.conf <<EOF
title   Arch Linux
linux   /vmlinuz-linux
initrd  /initramfs-linux.img
options root=UUID=${ROOT_UUID} rw
EOF
        ;;
    esac
  else
    # BIOS + GPT with bios_grub partition
    arch-chroot /mnt pacman -Sy --noconfirm grub
    arch-chroot /mnt grub-install --target=i386-pc "$DISK"
    arch-chroot /mnt grub-mkconfig -o /boot/grub/grub.cfg
  fi
}

install_de() {
  case "$DE" in
    none) return 0 ;;
    gnome)
      arch-chroot /mnt pacman -Sy --noconfirm gnome gdm
      arch-chroot /mnt systemctl enable gdm
      ;;
    kde)
      arch-chroot /mnt pacman -Sy --noconfirm plasma sddm
      arch-chroot /mnt systemctl enable sddm
      ;;
    xfce)
      arch-chroot /mnt pacman -Sy --noconfirm xfce4 lightdm lightdm-gtk-greeter
      arch-chroot /mnt systemctl enable lightdm
      ;;
  esac
}

### Orchestration
main() {
  require_cmds pacstrap arch-chroot parted sgdisk lsblk blkid
  detect_boot_mode
  configure_mirrors
  select_disk

  FILESYSTEM="$(menu 'Choose filesystem:' ext4 btrfs xfs)"
  SWAP_MODE="$(menu 'Swap mode:' none partition file)"
  if [[ "$SWAP_MODE" != "none" ]]; then
    SWAP_SIZE_GIB="$(ask 'Swap size in GiB (e.g. 8)')"
  fi
  TIMEZONE="$(ask 'Timezone (e.g. Europe/Berlin)')"
  HOSTNAME="$(ask 'Hostname')"
  USERNAME="$(ask 'Username')"
  PASSWORD="$(ask 'Password (shown in clear)')"
  PROFILE="$(menu 'Profile:' minimal desktop server)"
  NETWORK="$(menu 'Networking:' networkmanager systemd-networkd static)"
  DE="$(menu 'Desktop environment:' none gnome kde xfce)"
  BOOTLOADER="$(menu 'Bootloader:' grub $( [[ "$BOOT_MODE" == "UEFI" ]] && echo systemd-boot || true ))"

  read -rp "Additional packages (space-separated, optional): " pkgline || true
  [[ -n "${pkgline:-}" ]] && PACKAGES=($pkgline)

  partition_disk
  install_base
  configure_system
  install_bootloader
  install_de

  echo "✅ Installation complete. You can now: umount -R /mnt && swapoff -a (if any) && reboot"
}

main "$@"
