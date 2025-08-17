#!/bin/bash
set -e

# ================= CONFIG =================
RECOVERY_PART="/dev/vda3"                  # Recovery partition
ARCH_ISO_URL="https://mirror.rackspace.com/archlinux/iso/latest/archlinux-x86_64.iso"
MOUNTPOINT="/mnt/recovery"
EFI_DIR="$MOUNTPOINT/EFI/ventoy"
GRUB_CFG="/boot/grub/grub.cfg"
# =========================================

echo "Mounting recovery partition..."
mkdir -p $MOUNTPOINT
mount $RECOVERY_PART $MOUNTPOINT

echo "Fetching latest Ventoy release URL from GitHub..."
VENTOY_URL=$(curl -s https://api.github.com/repos/ventoy/Ventoy/releases/latest \
    | grep browser_download_url \
    | grep 'linux.tar.gz"' \
    | cut -d '"' -f 4)

if [ -z "$VENTOY_URL" ]; then
    echo "Failed to detect Ventoy release URL!"
    exit 1
fi

echo "Downloading Ventoy..."
TMP_TAR="/tmp/ventoy.tar.gz"
curl -L "$VENTOY_URL" -o "$TMP_TAR"

echo "Extracting Ventoy files..."
mkdir -p /tmp/ventoy
tar -xzf $TMP_TAR -C /tmp/ventoy

echo "Copying Ventoy EFI bootloader to recovery partition..."
mkdir -p $EFI_DIR
cp /tmp/ventoy/Ventoy2Disk/EFI/BOOT/bootx64.efi $EFI_DIR/ventoyx64.efi

echo "Downloading Arch ISO..."
curl -L "$ARCH_ISO_URL" -o $MOUNTPOINT/archlinux.iso

echo "Setting permissions..."
chmod 644 $MOUNTPOINT/archlinux.iso
chmod 755 $EFI_DIR/ventoyx64.efi

echo "Adding GRUB entry to chainload Ventoy..."
UUID_RECOVERY=$(blkid -s UUID -o value $RECOVERY_PART)

if ! grep -q "Recovery Ventoy" $GRUB_CFG 2>/dev/null; then
cat <<EOF >> $GRUB_CFG

menuentry "Recovery Ventoy" {
    search --no-floppy --fs-uuid --set=root $UUID_RECOVERY
    chainloader /EFI/ventoy/ventoyx64.efi
}
EOF
fi

echo "Cleaning up..."
rm -rf /tmp/ventoy $TMP_TAR

umount $MOUNTPOINT

echo "Recovery partition with Ventoy and Arch ISO is ready!"
