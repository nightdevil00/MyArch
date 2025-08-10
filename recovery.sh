
#!/bin/bash
set -e

# === CONFIG ===
DISK="/dev/nvme1n1"
USERNAME="mihai"
PASSWORD="1234"
LOCALE="en_US.UTF-8"
KEYMAP="us"
TIMEZONE="Europe/Bucharest"
EXTRA_PKGS_FILE="./extra_packages.txt"
ARCH_ISO_URL="https://mirror.rackspace.com/archlinux/iso/latest/archlinux-x86_64.iso"

# === READ EXTRA PACKAGES ===
if [ -f "$EXTRA_PKGS_FILE" ]; then
    EXTRA_PKGS=$(grep -vE "^\s*#|^\s*$" "$EXTRA_PKGS_FILE" | tr '\n' ' ')
else
    echo "Warning: $EXTRA_PKGS_FILE not found. Continuing without extra packages."
    EXTRA_PKGS=""
fi

# === CHECKS ===
if [ ! -d /sys/firmware/efi ]; then
    echo "Error: UEFI firmware not detected. Boot in UEFI mode."
    exit 1
fi

echo "=== Partitioning $DISK ==="
sgdisk -Z $DISK
sgdisk -n 1:0:+512M -t 1:ef00 -c 1:"EFI System Partition" $DISK
sgdisk -n 2:0:+5G    -t 2:8300 -c 2:"Recovery Partition" $DISK
sgdisk -n 3:0:0      -t 3:8300 -c 3:"Linux filesystem" $DISK

echo "=== Formatting partitions ==="
mkfs.fat -F32 ${DISK}p1
mkfs.ext4 -F ${DISK}p2  # Recovery partition
mkfs.ext4 -F ${DISK}p3  # Root partition

echo "=== Mounting partitions ==="
mount ${DISK}p3 /mnt
mkdir /mnt/boot
mount ${DISK}p1 /mnt/boot
mkdir /mnt/recovery
mount ${DISK}p2 /mnt/recovery

echo "=== Downloading and extracting Arch ISO to recovery partition ==="
TMP_ISO="/tmp/archlinux.iso"
curl -L "$ARCH_ISO_URL" -o "$TMP_ISO"

mkdir -p /mnt/iso
mount -o loop "$TMP_ISO" /mnt/iso

cp -a /mnt/iso/. /mnt/recovery/

umount /mnt/iso
rm "$TMP_ISO"
rmdir /mnt/iso

echo "=== Installing base system and GNOME ==="
pacstrap /mnt base linux linux-firmware sudo networkmanager gnome gnome-extra grub efibootmgr $EXTRA_PKGS

echo "=== Generating fstab ==="
genfstab -U /mnt >> /mnt/etc/fstab

echo "=== Chroot into system and configure ==="
arch-chroot /mnt /bin/bash <<EOF
set -e

echo "=== Setting timezone ==="
ln -sf /usr/share/zoneinfo/$TIMEZONE /etc/localtime
hwclock --systohc

echo "=== Setting locales ==="
sed -i "s/#$LOCALE UTF-8/$LOCALE UTF-8/" /etc/locale.gen
locale-gen
echo "LANG=$LOCALE" > /etc/locale.conf
echo "KEYMAP=$KEYMAP" > /etc/vconsole.conf

echo "=== Setting hostname ==="
echo "$USERNAME-pc" > /etc/hostname
cat <<HOSTS > /etc/hosts
127.0.0.1   localhost
::1         localhost
127.0.1.1   $USERNAME-pc.localdomain $USERNAME-pc
HOSTS

echo "=== Setting root password ==="
echo "root:$PASSWORD" | chpasswd

echo "=== Creating user $USERNAME ==="
useradd -m -G wheel -s /bin/bash $USERNAME
echo "$USERNAME:$PASSWORD" | chpasswd

echo "=== Configuring sudo ==="
if [ -f /etc/sudoers ]; then
    sed -i 's/# %wheel ALL=(ALL) ALL/%wheel ALL=(ALL) ALL/' /etc/sudoers
fi

echo "=== Enable services ==="
systemctl enable NetworkManager
systemctl enable gdm

echo "=== Installing GRUB ==="
mkdir -p /boot/efi
mount ${DISK}p1 /boot/efi
grub-install --target=x86_64-efi --efi-directory=/boot/efi --bootloader-id=GRUB

UUID_RECOVERY=\$(blkid -s UUID -o value ${DISK}p2)

echo "=== Adding GRUB recovery entry ==="
cat <<GRUBENTRY >> /etc/grub.d/40_custom

menuentry "Recovery (Arch Linux Extracted)" {
    search --no-floppy --fs-uuid --set=root $UUID_RECOVERY
    linux /arch/boot/x86_64/vmlinuz-linux img_dev=/dev/disk/by-uuid/$UUID_RECOVERY earlymodules=loop
    initrd /arch/boot/x86_64/initramfs-linux.img
}
GRUBENTRY

grub-mkconfig -o /boot/grub/grub.cfg

echo "=== Creating ISO update script ==="
cat <<UPDATESCRIPT > /usr/local/bin/update-recovery-iso
#!/bin/bash
set -e
UUID="$UUID_RECOVERY"
MOUNTPOINT="/tmp/recovery-\$UUID"
mkdir -p "\$MOUNTPOINT"
mount UUID="\$UUID" "\$MOUNTPOINT"
echo "Downloading latest Arch ISO..."
TMP_ISO="/tmp/archlinux.iso"
curl -L "$ARCH_ISO_URL" -o "\$TMP_ISO"
mount -o loop "\$TMP_ISO" /mnt/iso
cp -a /mnt/iso/. "\$MOUNTPOINT/"
umount /mnt/iso
rm "\$TMP_ISO"
umount "\$MOUNTPOINT"
echo "Recovery ISO updated."
UPDATESCRIPT

chmod +x /usr/local/bin/update-recovery-iso

echo "=== Creating systemd service and timer ==="
cat <<SERVICE > /etc/systemd/system/update-recovery-iso.service
[Unit]
Description=Update Recovery ISO

[Service]
Type=oneshot
ExecStart=/usr/local/bin/update-recovery-iso
SERVICE

cat <<TIMER > /etc/systemd/system/update-recovery-iso.timer
[Unit]
Description=Weekly update of Recovery ISO

[Timer]
OnCalendar=weekly
Persistent=true

[Install]
WantedBy=timers.target
TIMER

systemctl enable update-recovery-iso.timer
EOF

echo "=== Unmounting and finishing ==="
umount -R /mnt
echo "Installation complete! The recovery ISO will auto-update weekly."
