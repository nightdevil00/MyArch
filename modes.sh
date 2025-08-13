#!/bin/bash
set -e

# ========== CONFIGURATION ==========
USERNAME="mihai"
PASSWORD="1234"
HOSTNAME="arch"
LOCALE="en_US.UTF-8"
TIMEZONE="Europe/Bucharest"
# ==================================

list_disks() {
    echo "Available disks:"
    lsblk -dpno NAME,SIZE,MODEL | grep -v 'loop' | nl
}

prompt_size() {
    local part_name=$1
    read -p "Enter size for $part_name (in GB): " size
    echo $size
}

detect_efi() {
    local disk=$1
    blkid | grep -i "$disk" | grep -i 'EFI System' | awk -F: '{print $1}' || true
}

# Select target disk
echo "Select target disk for Arch installation:"
list_disks
read -p "Enter the number of the disk: " disk_num
DISK=$(lsblk -dpno NAME | grep -v 'loop' | sed -n "${disk_num}p")
echo "Selected disk: $DISK"

# Detect existing partitions
PARTITIONS=$(lsblk -ln $DISK | awk '{print $1}')
EFI_PART=$(detect_efi $DISK)

# Choose installation mode
if [ -z "$PARTITIONS" ] || [ "$PARTITIONS" == "$DISK" ]; then
    echo "Disk seems empty. Mode 3 (empty disk) will be used."
    MODE=3
else
    echo "Select installation mode:"
    echo "1) Reinstall on existing Linux partitions (format root, keep /home)"
    echo "2) Dual boot with Windows (create root/home in free space, reuse Windows EFI)"
    echo "3) Full empty-disk setup (create EFI/root/home or reuse existing)"
    read -p "Enter mode (1/2/3): " MODE
fi

if [ "$MODE" == "1" ]; then
    # Mode 1: existing Linux partitions
    echo "Detected partitions on $DISK:"
    lsblk -o NAME,SIZE,FSTYPE,LABEL,MOUNTPOINT $DISK

    read -p "Enter EFI partition (e.g., /dev/nvme0n1p1): " EFI_PART
    read -p "Enter root partition (to format): " ROOT_PART
    read -p "Enter home partition (will NOT be formatted, just mount): " HOME_PART

    mkfs.ext4 $ROOT_PART
    mount $ROOT_PART /mnt
    mkdir -p /mnt/boot/efi
    mount $EFI_PART /mnt/boot/efi
    mkdir -p /mnt/home
    mount $HOME_PART /mnt/home

elif [ "$MODE" == "2" ]; then
    # Mode 2: dual-boot with Windows
    if [ -z "$EFI_PART" ]; then
        echo "No EFI found. You need a Windows EFI to reuse, or create one in free space."
        exit 1
    else
        echo "Using existing EFI: $EFI_PART"
    fi

    echo "Available free space on disk (in GB):"
    lsblk -f $DISK

    ROOT_SIZE=$(prompt_size "root")
    HOME_SIZE=$(prompt_size "home (optional, press enter to skip)")

    echo "Creating root partition in free space..."
    sgdisk -n 0:0:+${ROOT_SIZE}G -t 0:8300 $DISK
    if [[ "$DISK" =~ nvme ]]; then
        ROOT_PART="$(lsblk -dpno NAME | grep $DISK | tail -n1)"
    else
        ROOT_PART="$(lsblk -dpno NAME | grep $DISK | tail -n1)"
    fi
    mkfs.ext4 $ROOT_PART

    mount $ROOT_PART /mnt
    mkdir -p /mnt/boot/efi
    mount $EFI_PART /mnt/boot/efi

    if [ ! -z "$HOME_SIZE" ]; then
        echo "Creating home partition in free space..."
        sgdisk -n 0:0:+${HOME_SIZE}G -t 0:8300 $DISK
        if [[ "$DISK" =~ nvme ]]; then
            HOME_PART="$(lsblk -dpno NAME | grep $DISK | tail -n1)"
        else
            HOME_PART="$(lsblk -dpno NAME | grep $DISK | tail -n1)"
        fi
        mkfs.ext4 $HOME_PART
        mkdir -p /mnt/home
        mount $HOME_PART /mnt/home
    fi

elif [ "$MODE" == "3" ]; then
    # Mode 3: empty disk or full setup
    if [ -z "$EFI_PART" ]; then
        read -p "No EFI found. Create new EFI partition? (y/n): " create_efi
        if [ "$create_efi" == "y" ]; then
            EFI_SIZE=$(prompt_size "EFI")
            sgdisk -n 1:0:+${EFI_SIZE}G -t 1:ef00 $DISK
            if [[ "$DISK" =~ nvme ]]; then
                EFI_PART="${DISK}p1"
            else
                EFI_PART="${DISK}1"
            fi
            mkfs.fat -F32 $EFI_PART
        fi
    fi

    ROOT_SIZE=$(prompt_size "root")
    HOME_SIZE=$(prompt_size "home")

    sgdisk -n 2:0:+${ROOT_SIZE}G -t 2:8300 $DISK
    sgdisk -n 3:0:+${HOME_SIZE}G -t 3:8300 $DISK

    if [[ "$DISK" =~ nvme ]]; then
        ROOT_PART="${DISK}p2"
        HOME_PART="${DISK}p3"
    else
        ROOT_PART="${DISK}2"
        HOME_PART="${DISK}3"
    fi

    mkfs.ext4 $ROOT_PART
    mkfs.ext4 $HOME_PART

    mount $ROOT_PART /mnt
    mkdir -p /mnt/boot/efi
    mount $EFI_PART /mnt/boot/efi
    mkdir -p /mnt/home
    mount $HOME_PART /mnt/home
fi

# --- Installation steps ---
echo "Installing base system..."
pacstrap /mnt base linux linux-firmware sudo vim grub efibootmgr networkmanager gnome gdm gnome-tweaks nvidia linux-headers flatpak spotify-launcher wget 7zip firefox

echo "Generating fstab..."
genfstab -U /mnt >> /mnt/etc/fstab

# Chroot configuration
arch-chroot /mnt /bin/bash -e <<EOF

echo $HOSTNAME > /etc/hostname
cat > /etc/hosts <<HOSTS
127.0.0.1	localhost
::1	localhost
127.0.1.1	$HOSTNAME.localdomain $HOSTNAME
HOSTS

ln -sf /usr/share/zoneinfo/$TIMEZONE /etc/localtime
hwclock --systohc

echo "$LOCALE UTF-8" > /etc/locale.gen
locale-gen
echo "LANG=$LOCALE" > /etc/locale.conf

echo root:$PASSWORD | chpasswd
useradd -m -G wheel -s /bin/bash $USERNAME
echo $USERNAME:$PASSWORD | chpasswd
sed -i 's/# %wheel ALL=(ALL:ALL) ALL/%wheel ALL=(ALL:ALL) NOPASSWD: ALL/' /etc/sudoers

systemctl enable NetworkManager.service
systemctl enable bluetooth.service
systemctl enable gdm.service

grub-install --target=x86_64-efi --efi-directory=/boot/efi --bootloader-id=GRUB
grub-mkconfig -o /boot/grub/grub.cfg
EOF

echo "Arch Linux installation complete. You can reboot now."

