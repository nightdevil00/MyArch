#!/bin/bash

# Exit on error
set -e

# Function to prompt for input with validation
prompt() {
    local prompt_text="$1"
    local var_name="$2"
    local default="$3"
    read -p "$prompt_text [$default]: " input
    eval "$var_name=\"\${input:-$default}\""
}

# Detect available disks
echo "Available disks:"
lsblk -d -o NAME,TYPE | grep disk
echo

# Select target device
prompt "Enter the device to install Arch Linux on (e.g., /dev/sda):" target_device

# Confirm device
echo "Selected device: $target_device"
read -p "Are you sure? This will wipe all data on it. (yes/no): " confirm
if [[ "$confirm" != "yes" ]]; then
    echo "Aborting."
    exit 1
fi

# Detect if SSD/NVME
if [[ "$target_device" == /dev/nvme* ]]; then
    drive_type="NVMe"
elif [[ "$target_device" == /dev/sd* ]]; then
    drive_type="HDD/SSD"
else
    drive_type="Unknown"
fi

# Locale
prompt "Enter your locale (e.g., en_US.UTF-8):" locale "en_US.UTF-8"

# Keyboard layout
prompt "Enter your keyboard layout (e.g., us, de, fr):" keyboard_layout "us"

# Desktop Environment
echo "Choose Desktop Environment:"
select DE in "Minimal" "Gnome" "KDE" "None"; do
    case $DE in
        Minimal) desktop_env="none"; break ;;
        Gnome) desktop_env="gnome"; break ;;
        KDE) desktop_env="kde"; break ;;
        None) desktop_env="none"; break ;;
    esac
done

# Username
prompt "Enter username:" username

# Password
echo "Enter password for user $username:"
read -s password

# Sudo access
read -p "Should the user have sudo access? (yes/no): " sudo_access
if [[ "$sudo_access" == "yes" ]]; then
    sudo_group=true
else
    sudo_group=false
fi

# Hostname
prompt "Enter hostname:" hostname

# Bootloader choice
echo "Select bootloader:"
select bootloader in "GRUB" "systemd-boot" "rEFInd"; do
    case $bootloader in
        GRUB) bootloader_choice="grub"; break ;;
        systemd-boot) bootloader_choice="systemd"; break ;;
        rEFInd) bootloader_choice="refind"; break ;;
    esac
done

# Partitioning and formatting
echo "Partitioning disk..."
# Example partitioning with parted
parted --script "$target_device" mklabel gpt

# Create EFI partition
parted --script "$target_device" mkpart ESP fat32 1MiB 550MiB
parted --script "$target_device" set 1 esp on

# Create root partition
parted --script "$target_device" mkpart primary ext4 550MiB 100%

# Wait for device to recognize partitions
sleep 2

# Get partition names
if [[ "$drive_type" == "NVMe" ]]; then
    EFI_PART="${target_device}p1"
    ROOT_PART="${target_device}p2"
else
    EFI_PART="${target_device}1"
    ROOT_PART="${target_device}2"
fi

# Format partitions
mkfs.fat -F32 "$EFI_PART"
mkfs.ext4 "$ROOT_PART"

# Mount root
mount "$ROOT_PART" /mnt

# Create and mount EFI
mkdir -p /mnt/boot/efi
mount "$EFI_PART" /mnt/boot/efi

# Install base system
pacstrap /mnt base linux linux-firmware

# Generate fstab
genfstab -U /mnt >> /mnt/etc/fstab

# Chroot setup script
cat <<EOF > /mnt/setup.sh
#!/bin/bash
set -e

# Locale
echo "$locale UTF-8" > /etc/locale.gen
locale-gen
echo "LANG=$locale" > /etc/locale.conf

# Timezone
ln -sf /usr/share/zoneinfo/Region/City /etc/localtime
hwclock --systohc

# Hostname
echo "$hostname" > /etc/hostname

# Hosts
cat <<EOT >/etc/hosts
127.0.0.1   localhost
::1         localhost
127.0.1.1   $hostname.localdomain $hostname
EOT

# User setup
useradd -m -G wheel "$username"
echo "$username:$password" | chpasswd

# Sudo setup
if [ "$sudo_group" = true ]; then
    pacman -S --noconfirm sudo
    sed -i 's/# %wheel ALL=(ALL) ALL/%wheel ALL=(ALL) ALL/' /etc/sudoers
fi

# Kernel & initramfs
mkinitcpio -P

# Bootloader
if [ "$bootloader_choice" = "grub" ]; then
    pacman -S --noconfirm grub efibootmgr
    grub-install --target=x86_64-efi --efi-directory=/boot/efi --bootloader-id=GRUB
    sed -i 's/#GRUB_TIMEOUT=5/GRUB_TIMEOUT=5/' /etc/default/grub
    grub-mkconfig -o /boot/grub/grub.cfg
elif [ "$bootloader_choice" = "systemd" ]; then
    pacman -S --noconfirm systemd-boot
    bootctl install
    # Create loader entry
    mkdir -p /boot/loader/entries
    cat <<EOL >/boot/loader/entries/arch.conf
title   Arch Linux
linux   /vmlinuz-linux
initrd  /initramfs-linux.img
options root=PARTUUID=\$(blkid -s PARTUUID -o value "$ROOT_PART") rw
EOL
elif [ "$bootloader_choice" = "refind" ]; then
    pacman -S --noconfirm refind-efi
    refind-install
    # Additional configuration if needed
fi

# Enable services, e.g., NetworkManager
pacman -S --noconfirm networkmanager
systemctl enable NetworkManager

EOF

chmod +x /mnt/setup.sh

# Chroot and run setup.sh
arch-chroot /mnt /bin/bash /setup.sh

echo "Installation complete! You can now reboot."

# Prompt to chroot for customization
echo "To do further customization, chroot into your system:"
echo "arch-chroot /mnt"
