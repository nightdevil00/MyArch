#!/bin/bash
set -e

# Install archiso if missing
if ! command -v mkarchiso &> /dev/null; then
    echo "Installing archiso..."
    sudo pacman -S --needed --noconfirm archiso
fi

# Prepare build folder
mkdir -p ~/gnome-archiso
cd ~/gnome-archiso

# Copy releng profile as base
cp -r /usr/share/archiso/configs/releng/* ./

# Add packages
cat >> packages.x86_64 <<'EOF'

# --- GNOME Desktop ---
xorg
mesa
gnome
gdm
gnome-tweaks
gnome-shell-extensions

# --- Drivers ---
nvidia
nvidia-utils
linux-headers
bluez
bluez-utils

# --- Networking ---
networkmanager
network-manager-applet
inetutils
iproute2
iputils
dhclient

# --- Tools ---
nano
vim
git
base-devel
wget
EOF

# Customize live environment
mkdir -p airootfs/root
cat > airootfs/root/customize_airootfs.sh <<'EOF'
#!/bin/bash
# Enable necessary services
systemctl enable gdm
systemctl enable NetworkManager
systemctl enable bluetooth

# Create user arch with passwordless sudo for yay and convenience
useradd -m -G wheel arch
echo "arch ALL=(ALL) NOPASSWD: ALL" > /etc/sudoers.d/arch
chmod 440 /etc/sudoers.d/arch

# yay and Google Chrome will need to be installed manually after boot
echo "To install yay and Google Chrome, after boot run:"
echo "  git clone https://aur.archlinux.org/yay-bin.git"
echo "  cd yay-bin"
echo "  makepkg -si"
echo "  yay -S google-chrome"

# Install Arc Menu extension via yay
#sudo -u arch yay -S --noconfirm gnome-shell-extension-arc-menu
#EOF
chmod +x airootfs/root/customize_airootfs.sh

# Enable autologin for GNOME in live session
mkdir -p airootfs/etc/gdm
cat > airootfs/etc/gdm/custom.conf <<'EOF'
[daemon]
AutomaticLoginEnable=True
AutomaticLogin=arch
EOF

# Add polkit GNOME authentication agent autostart
mkdir -p airootfs/etc/xdg/autostart
cat > airootfs/etc/xdg/autostart/polkit-gnome-authentication-agent.desktop <<'EOF'
[Desktop Entry]
Type=Application
Name=Polkit Authentication Agent
Exec=/usr/lib/polkit-gnome/polkit-gnome-authentication-agent-1
X-GNOME-Autostart-enabled=true
NoDisplay=true
EOF

# GNOME default settings + extensions
mkdir -p airootfs/etc/skel/.config/dconf
mkdir -p gnome-dconf

cat > gnome-dconf/settings.ini <<'EOF'
[org/gnome/desktop/interface]
color-scheme='prefer-dark'

[org/gnome/desktop/background]
picture-uri='file:///usr/share/backgrounds/custom-wallpaper.jpg'
picture-uri-dark='file:///usr/share/backgrounds/custom-wallpaper.jpg'

[org/gnome/shell]
enabled-extensions=['dash-to-dock@micxgx.gmail.com', 'arcmenu@arcmenu.com']

[org/gnome/shell/extensions/dash-to-dock]
dock-position='BOTTOM'
dash-max-icon-size=48
show-trash=false
show-mounts=false
intellihide=true

[org/gnome/shell/extensions/arcmenu]
position-in-panel='right'
EOF

# Download wallpaper
mkdir -p airootfs/usr/share/backgrounds
wget -O airootfs/usr/share/backgrounds/custom-wallpaper.jpg https://wallpapercave.com/wp/wp9165364.jpg

# Compile dconf database
dconf compile airootfs/etc/skel/.config/dconf/user gnome-dconf

# Add the Arch install script with NVMe support
cat > airootfs/root/install-arch.sh <<'EOF'
#!/bin/bash
set -euo pipefail

echo "Welcome to the Arch Linux installer script!"
echo

read -rp "Enter target disk (e.g. /dev/nvme0n1 or /dev/sda): " DISK

if [[ ! -b "$DISK" ]]; then
    echo "Error: Device $DISK not found."
    exit 1
fi

echo "This will erase all data on $DISK. Are you sure? (yes/no)"
read -r CONFIRM
if [[ "$CONFIRM" != "yes" ]]; then
    echo "Aborted."
    exit 1
fi

echo "Partitioning $DISK..."

# Clean partitions
sgdisk --zap-all "$DISK"

# Create partitions: EFI + root + home
if [[ "$DISK" =~ nvme ]]; then
    EFI_PART="${DISK}p1"
    ROOT_PART="${DISK}p2"
    HOME_PART="${DISK}p3"
else
    EFI_PART="${DISK}1"
    ROOT_PART="${DISK}2"
    HOME_PART="${DISK}3"
fi

sgdisk -n1:0:+512M -t1:ef00 -c1:"EFI system partition" "$DISK"
sgdisk -n2:0:+20G -t2:8300 -c2:"Root partition" "$DISK"
sgdisk -n3:0:0 -t3:8300 -c3:"Home partition" "$DISK"

echo "Formatting partitions..."

mkfs.fat -F32 "$EFI_PART"
mkfs.ext4 "$ROOT_PART"
mkfs.ext4 "$HOME_PART"

echo "Mounting partitions..."

mount "$ROOT_PART" /mnt
mkdir -p /mnt/boot/efi
mount "$EFI_PART" /mnt/boot/efi
mkdir -p /mnt/home
mount "$HOME_PART" /mnt/home

echo "Installing base system..."

pacstrap /mnt base base-devel linux linux-headers linux-firmware \
    networkmanager sudo vim git

echo "Generating fstab..."
genfstab -U /mnt >> /mnt/etc/fstab

echo "Configuring system..."

arch-chroot /mnt /bin/bash -c "
    ln -sf /usr/share/zoneinfo/UTC /etc/localtime
    hwclock --systohc
    echo 'en_US.UTF-8 UTF-8' > /etc/locale.gen
    locale-gen
    echo 'LANG=en_US.UTF-8' > /etc/locale.conf
    echo 'archlinux' > /etc/hostname
    echo '127.0.0.1 localhost' >> /etc/hosts
    echo '::1       localhost' >> /etc/hosts
    echo '127.0.1.1 archlinux.localdomain archlinux' >> /etc/hosts
    useradd -m -G wheel archuser
    echo 'archuser:archlinux' | chpasswd
    echo 'root:root' | chpasswd
    sed -i 's/^# %wheel ALL=(ALL) ALL/%wheel ALL=(ALL) ALL/' /etc/sudoers
    systemctl enable NetworkManager
"

echo "Installing and configuring GRUB..."

arch-chroot /mnt /bin/bash -c "
    pacman -Sy --noconfirm grub efibootmgr
    grub-install --target=x86_64-efi --efi-directory=/boot/efi --bootloader-id=GRUB
    grub-mkconfig -o /boot/grub/grub.cfg
"

echo "Unmounting partitions..."
umount -R /mnt

echo "Installation complete! Reboot and remove the installation media."
EOF
chmod +x airootfs/root/install-arch.sh

# Add desktop shortcut for the installer
mkdir -p airootfs/etc/skel/Desktop
cat > airootfs/etc/skel/Desktop/install-arch.desktop <<'EOF'
[Desktop Entry]
Name=Install Arch Linux
Comment=Run Arch Linux installer script
Exec=/root/install-arch.sh
Icon=system-install
Terminal=true
Type=Application
Categories=System;Installer;
EOF
chmod +x airootfs/etc/skel/Desktop/install-arch.desktop

# Custom profiledef.sh for ISO metadata
cat > profiledef.sh <<'EOF'
#!/usr/bin/env bash
iso_name="archlinux-gnome-custom"
iso_label="ARCH_GNOME_CUSTOM"
iso_publisher="Custom Arch Linux <https://archlinux.org>"
iso_application="Custom Arch Linux Live GNOME with Installer Script"
iso_version="$(date +%Y.%m.%d)"
install_dir="arch"
buildmodes=('iso')
bootmodes=('bios.syslinux.mbr' 'bios.syslinux.eltorito'
           'uefi-x64.systemd-boot.esp' 'uefi-x64.systemd-boot.eltorito')
arch="x86_64"
pacman_conf="pacman.conf"
airootfs_image_type="squashfs"
airootfs_image_tool_options=('-comp' 'xz' '-Xbcj' 'x86' '-b' '1M' '-Xdict-size' '1M')
file_permissions=(
  ["/root/customize_airootfs.sh"]="0:0:755"
  ["/root/install-arch.sh"]="0:0:755"
)
EOF

echo "✅ gnome-archiso folder ready at ~/gnome-archiso with GNOME, yay, Chrome, NVIDIA, and install script"
echo "Build your ISO with:"
echo "  cd ~/gnome-archiso"
echo "  mkarchiso -v ."

