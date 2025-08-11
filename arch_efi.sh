#!/bin/bash
set -e

# ========== CONFIGURATION ==========
DISK="/dev/sda"       # e.g., /dev/vda, /dev/sda, /dev/nvme0n1
USERNAME="mihai"
PASSWORD="1234"
HOSTNAME="archuefi"
LOCALE="en_US.UTF-8"
TIMEZONE="UTC"
# ==================================

# Detect partition suffix for NVMe drives
if [[ "$DISK" =~ nvme ]]; then
  EFI_PART="${DISK}p1"
  ROOT_PART="${DISK}p2"
else
  EFI_PART="${DISK}1"
  ROOT_PART="${DISK}2"
fi

echo "Starting Arch Linux UEFI installation on $DISK..."

# 1. Wipe existing partitions
echo "Wiping existing partitions on $DISK..."
sgdisk --zap-all $DISK

# 2. Create partitions:
#  - 1024MB EFI system partition (type EF00)
#  - rest as root partition (type 8300)
echo "Creating partitions..."
sgdisk -n 1:0:+1024M -t 1:ef00 $DISK
sgdisk -n 2:0:0     -t 2:8300 $DISK

# 3. Format partitions
echo "Formatting EFI partition as FAT32..."
mkfs.fat -F32 $EFI_PART

echo "Formatting root partition as ext4..."
mkfs.ext4 $ROOT_PART

# 4. Mount partitions
echo "Mounting root partition..."
mount $ROOT_PART /mnt

echo "Creating and mounting EFI partition..."
mkdir -p /mnt/boot/efi
mount $EFI_PART /mnt/boot/efi

# 5. Install base packages, grub EFI, networkmanager
echo "Installing base system and networkmanager..."
pacstrap /mnt base linux linux-firmware sudo vim grub efibootmgr networkmanager git

# 6. Generate fstab
echo "Generating fstab..."
genfstab -U /mnt >> /mnt/etc/fstab

# 7. Configure system inside chroot
echo "Configuring system..."
arch-chroot /mnt /bin/bash -e <<EOF

echo $HOSTNAME > /etc/hostname

# Setup hosts file
cat > /etc/hosts <<HOSTS
127.0.0.1	localhost
::1		    localhost
127.0.1.1	$HOSTNAME.localdomain $HOSTNAME
HOSTS

# Timezone setup
ln -sf /usr/share/zoneinfo/$TIMEZONE /etc/localtime
hwclock --systohc

# Locale setup
echo "$LOCALE UTF-8" > /etc/locale.gen
locale-gen
echo "LANG=$LOCALE" > /etc/locale.conf

# Set root password
echo root:$PASSWORD | chpasswd

# Add user, set password, add to wheel group for sudo
useradd -m -G wheel -s /bin/bash $USERNAME
echo $USERNAME:$PASSWORD | chpasswd

# Allow wheel group sudo without password prompt (optional)
sed -i 's/# %wheel ALL=(ALL:ALL) ALL/%wheel ALL=(ALL:ALL) NOPASSWD: ALL/' /etc/sudoers

# Enable NetworkManager so networking works on boot
systemctl enable NetworkManager.service

# Install and configure GRUB for UEFI
grub-install --target=x86_64-efi --efi-directory=/boot/efi --bootloader-id=GRUB
grub-mkconfig -o /boot/grub/grub.cfg

EOF

echo "Arch Linux UEFI installation complete. You can reboot now."
