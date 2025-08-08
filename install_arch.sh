#!/bin/bash
set -e

echo "=== Arch Linux Installer ==="

# Ensure root
if [ "$EUID" -ne 0 ]; then
  echo "Please run as root"
  exit 1
fi

# List and select disk
lsblk -d -n -o NAME,SIZE
read -rp "Enter target disk (e.g., /dev/sda or /dev/nvme0n1): " DISK

read -rp "This will erase ALL DATA on $DISK. Type YES to continue: " CONFIRM
[[ "$CONFIRM" != "YES" ]] && { echo "Aborted."; exit 1; }

# Determine correct partition naming
if [[ "$DISK" =~ nvme ]]; then
  PART_PREFIX="${DISK}p"
else
  PART_PREFIX="${DISK}"
fi

# Partition layout
read -rp "Create separate /home partition? (y/n): " SEP_HOME
read -rp "Use swap? (y/n): " USE_SWAP
if [[ "$USE_SWAP" == "y" ]]; then
  read -rp "Enter swap size (e.g., 2G): " SWAP_SIZE
fi

# Filesystem
read -rp "Choose filesystem (ext4/btrfs/xfs): " FS
FS=${FS:-ext4}

# System info
read -rp "Enter hostname: " HOSTNAME
read -rp "Enter timezone (e.g., America/New_York): " TIMEZONE
read -rp "Enter locale (default: en_US.UTF-8): " LOCALE
LOCALE=${LOCALE:-en_US.UTF-8}

# User credentials
read -rp "Enter username: " USERNAME
read -sp "Enter password: " PASSWORD
echo

# Desktop Environment
echo "Choose a Desktop Environment:"
select DE in "None (minimal)" "GNOME" "KDE Plasma" "XFCE" "Cinnamon"; do
  case $REPLY in
    1) DE_PKGS=""; DM=""; break ;;
    2) DE_PKGS="gnome gnome-extra"; DM="gdm"; break ;;
    3) DE_PKGS="plasma kde-applications"; DM="sddm"; break ;;
    4) DE_PKGS="xfce4 xfce4-goodies"; DM="lightdm lightdm-gtk-greeter"; break ;;
    5) DE_PKGS="cinnamon"; DM="lightdm lightdm-gtk-greeter"; break ;;
    *) echo "Invalid choice"; continue ;;
  esac
done

# Extra packages
read -rp "Extra packages (space separated): " EXTRA_PKGS

echo "=== Partitioning $DISK ==="
wipefs -af "$DISK"
sgdisk -Z "$DISK"

# Create partitions
sgdisk -n 1:0:+512M -t 1:ef00 "$DISK"  # EFI
INDEX=2

if [[ "$USE_SWAP" == "y" ]]; then
  sgdisk -n ${INDEX}:0:+${SWAP_SIZE} -t ${INDEX}:8200 "$DISK"
  SWAP_PART="${PART_PREFIX}${INDEX}"
  ((INDEX++))
fi

sgdisk -n ${INDEX}:0:+20G -t ${INDEX}:8300 "$DISK"
ROOT_PART="${PART_PREFIX}${INDEX}"
((INDEX++))

if [[ "$SEP_HOME" == "y" ]]; then
  sgdisk -n ${INDEX}:0:0 -t ${INDEX}:8302 "$DISK"
  HOME_PART="${PART_PREFIX}${INDEX}"
fi

EFI_PART="${PART_PREFIX}1"

echo "=== Formatting ==="
mkfs.fat -F32 "$EFI_PART"
mkfs."$FS" "$ROOT_PART"
[[ "$SEP_HOME" == "y" ]] && mkfs."$FS" "$HOME_PART"
[[ "$USE_SWAP" == "y" ]] && mkswap "$SWAP_PART"

echo "=== Mounting ==="
mount "$ROOT_PART" /mnt
mkdir -p /mnt/boot
mount "$EFI_PART" /mnt/boot
[[ "$SEP_HOME" == "y" ]] && mkdir /mnt/home && mount "$HOME_PART" /mnt/home
[[ "$USE_SWAP" == "y" ]] && swapon "$SWAP_PART"

echo "=== Installing Base System ==="
pacstrap /mnt base linux linux-firmware networkmanager sudo vim $DE_PKGS $DM $EXTRA_PKGS

genfstab -U /mnt >> /mnt/etc/fstab

echo "=== Configuring System ==="
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
[[ "$DM" == *gdm* ]] && systemctl enable gdm
[[ "$DM" == *sddm* ]] && systemctl enable sddm
[[ "$DM" == *lightdm* ]] && systemctl enable lightdm

bootctl install
PARTUUID=\$(blkid -s PARTUUID -o value $ROOT_PART)
cat > /boot/loader/loader.conf <<LOADER
default arch
timeout 3
editor no
LOADER

cat > /boot/loader/entries/arch.conf <<BOOT
title   Arch Linux
linux   /vmlinuz-linux
initrd  /initramfs-linux.img
options root=PARTUUID=\$PARTUUID rw
BOOT
EOF

echo "=== Installation Complete! You can now reboot. ==="


