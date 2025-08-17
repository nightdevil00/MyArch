#!/bin/bash
# add-archiso-grub.sh
# This script adds a GRUB menuentry to boot Arch Linux ISO from /dev/vda3

ISO_PATH="/archlinux.iso"
GRUB_CUSTOM="/etc/grub.d/40_custom"

# Backup the file just in case
sudo cp "$GRUB_CUSTOM" "$GRUB_CUSTOM.bak"

# Append the new entry if not already present
if ! grep -q "Arch Linux ISO (loopback)" "$GRUB_CUSTOM"; then
    cat <<EOF | sudo tee -a "$GRUB_CUSTOM"

menuentry "Arch Linux ISO (loopback)" {
    set isofile="$ISO_PATH"
    search --no-floppy --set=iso_part --file \$isofile
    loopback loop (\$iso_part)\$isofile
    linux (loop)/arch/boot/x86_64/vmlinuz-linux img_dev=/dev/vda3 img_loop=\$isofile earlymodules=loop
    initrd (loop)/arch/boot/x86_64/initramfs-linux.img
}
EOF
    echo "[+] GRUB entry added."
else
    echo "[*] Entry already exists in $GRUB_CUSTOM"
fi

# Update GRUB
if command -v update-grub &>/dev/null; then
    sudo update-grub
else
    sudo grub-mkconfig -o /boot/grub/grub.cfg
fi
