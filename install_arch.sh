#!/bin/bash

set -euo pipefail

# Ensure running as root
if [ "$(id -u)" -ne 0 ]; then
  echo "Run as root"
  exit 1
fi

echo "=== Arch Linux Installer ==="

# Select disk
lsblk
read -rp "Enter the target disk (e.g. /dev/sda): " DISK

# Confirm disk wipe
read -rp "WARNING: This will erase all data on $DISK. Type YES to continue: " confirm
[[ "$confirm" != "YES" ]] && { echo "Aborted."; exit 1; }

# Partition layout
read -rp "Separate /home partition? (y/n): " SEP_HOME
read -rp "Use swap? (y/n): " USE_SWAP

# Filesystem
read -rp "Filesystem (ext4/btrfs/xfs): " FILESYSTEM

# Hostname and locale
read -rp "Enter hostname: " HOSTNAME
read -rp "Timezone (e.g., Europe/Bucharest): " TIMEZONE
read -rp "Locale (default: en_US.UTF-8): " LOCALE
LOCALE="${LOCALE:-en_US.UTF-8}"

# User setup
read -rp "Enter username: " USERNAME
read -sp "Enter password for $USERNAME: " PASSWORD
echo

# Desktop Environment
echo "Choose a Desktop Environment:"
select DE in "None (minimal)" "GNOME" "KDE Plasma" "XFCE" "Cinnamon"; do
    case $REPLY in
        1) DE_PKGS=""; break ;;
        2) DE_PKGS="gnome gnome-extra gdm"; break ;;
        3) DE_PKGS="plasma kde-applications sddm"; break ;;
        4) DE_PKGS="xfce4 xfce4-goodies lightdm lightdm-gtk-greeter"; break ;;
        5) DE_PKGS="cinnamon lightdm lightdm-gtk-greeter"; break ;;
        *) echo "Invalid choice."; continue ;;
    esac
done

# Additional packages
read -rp "Extra packages to install (space-separated): " EXTRA_PKGS

echo "Partitioning $DISK..."
wipefs -af "$DISK"
sgdisk -Z "$DISK"
sgdisk -n 1:0:+512M -t 1:ef00 "$DISK"
PART_NUM=2
if [[ "$USE_SWAP" == "y" ]]; then
    read -rp "Swap size (e.g., 2G): " SWAP_SIZE
    sgdisk -n $PART_NUM:0:+${SWAP_SIZE} -t $PART_NUM:8200 "$DISK"
    SWAP_PART="${DISK}${PART_NUM}"
    ((PART_NUM++))
fi
sgdisk -n $PART_NUM:0:+50G -t $PART_NUM:8300 "$DISK"
ROOT_PART="${DISK}${PART_NUM}"
((PART_NUM++))
if [[ "$SEP_HOME" == "y" ]]; then
    sgdisk -n $PART_NUM:0:0 -t $PART_NUM:8302 "$DISK"
    HOME_PART="${DISK}${PART_NUM}"
fi
EFI_PART="${DISK}1"

echo "Formatting..."
mkfs.fat -F32 "$EFI_PART"
mkfs."$FILESYSTEM" "$ROOT_PART"
[[ "$SEP_HOME" == "y" ]] && mkfs."$FILESYSTEM" "$HOME_PART"
[[ "$USE_SWAP" == "y" ]] && mkswap "$SWAP_PART"

echo "Mounting..."
mount "$ROOT_PART" /mnt
mkdir -p /mnt/boot
mount "$EFI_PART" /mnt/boot
if [[ "$SEP_HOME" == "y" ]]; then
    mkdir /mnt/home
    mount "$HOME_PART" /mnt/home
fi
[[ "$USE_SWAP" == "y" ]] && swapon "$SWAP_PART"

echo "Installing base system..."
pacstrap /mnt base linux linux-firmware sudo vim nano networkmanager $DE_PKGS $EXTRA_PKGS

genfstab -U /mnt >> /mnt/etc/fstab

echo "Configuring system..."
arch-chroot /mnt /bin/bash <<EOF
ln -sf /usr/share/zoneinfo/$TIMEZONE /etc/localtime
hwclock --systohc
echo "$LOCALE UTF-8" > /etc/locale.gen
locale-gen
echo "LANG=$LOCALE" > /etc/locale.conf
echo "$HOSTNAME" > /etc/hostname
echo "127.0.0.1 localhost" >> /etc/hosts
echo "::1       localhost" >> /etc/hosts
echo "127.0.1.1 $HOSTNAME.localdomain $HOSTNAME" >> /etc/hosts

echo root:$PASSWORD | chpasswd
useradd -m -G wheel -s /bin/bash $USERNAME
echo "$USERNAME:$PASSWORD" | chpasswd
echo "%wheel ALL=(ALL) ALL" > /etc/sudoers.d/wheel

systemctl enable NetworkManager

# Enable display manager if DE selected
[[ "$DE_PKGS" == *gdm* ]] && systemctl enable gdm
[[ "$DE_PKGS" == *sddm* ]] && systemctl enable sddm
[[ "$DE_PKGS" == *lightdm* ]] && systemctl enable lightdm

bootctl install
PARTUUID=\$(blkid -s PARTUUID -o value $ROOT_PART)
cat > /boot/loader/loader.conf <<LOADER
default arch
timeout 3
editor no
LOADER

cat > /boot/loader/entries/arch.conf <<BOOTENTRY
title   Arch Linux
linux   /vmlinuz-linux
initrd  /initramfs-linux.img
options root=PARTUUID=\$PARTUUID rw
BOOTENTRY
EOF

echo "Installation complete. You can now reboot."
