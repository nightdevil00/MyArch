#!/usr/bin/env bash
# archinstall-dialog-full.sh
set -euo pipefail

DISK=""
PART_PREFIX=""
BOOT_MODE="UEFI"
FILESYSTEM=""
SWAP_MODE=""
SWAP_SIZE_GIB=0
BOOTLOADER=""
PROFILE=""
NETWORK=""
DE=""
HOSTNAME=""
USERNAME=""
PASSWORD=""
TIMEZONE=""
PACKAGES=()

BOOT_PART=""
ROOT_PART=""
SWAP_PART=""

require_cmds() {
    local missing=()
    for c in "$@"; do command -v "$c" >/dev/null 2>&1 || missing+=("$c"); done
    if ((${#missing[@]})); then
        echo "Installing missing tools: ${missing[*]}"
        pacman -Sy --noconfirm "${missing[@]}"
    fi
}

dialog_menu() {
    local prompt="$1"
    shift
    local options=("$@")
    local optstr=()
    for i in "${!options[@]}"; do
        local idx=$((i+1))
        optstr+=("$idx" "${options[$i]}")
    done
    local choice
    choice=$(dialog --clear --title "$prompt" --menu "$prompt" 20 60 10 "${optstr[@]}" 3>&1 1>&2 2>&3)
    echo "${options[$((choice-1))]}"
}

ask_dialog() {
    local prompt="$1"
    local input
    input=$(dialog --clear --inputbox "$prompt" 10 50 3>&1 1>&2 2>&3)
    echo "$input"
}

confirm_dialog() {
    dialog --clear --yesno "$1" 7 50
    return $?
}

detect_boot_mode() {
    if [[ -d /sys/firmware/efi/efivars ]]; then BOOT_MODE="UEFI"; else BOOT_MODE="BIOS"; fi
    echo "Boot mode detected: $BOOT_MODE"
}

select_disk() {
    lsblk -dpno NAME,SIZE,MODEL | grep -E "/dev/(sd|nvme|vd)"
    DISK=$(ask_dialog "Enter target disk (e.g. /dev/sda, /dev/nvme0n1, /dev/vda)")
    case "$DISK" in
        /dev/nvme*) PART_PREFIX="p" ;;
        /dev/sd*|/dev/vd*) PART_PREFIX="" ;;
        *) dialog --msgbox "Unknown disk type: $DISK" 5 50; exit 1 ;;
    esac
}

configure_mirrors() {
    require_cmds reflector
    region=$(dialog_menu "Select mirror region" "Worldwide – Global mirrors" "US – United States mirrors" "Europe – European countries" "Asia – Asian countries")
    case "$region" in
        *Worldwide*) reflector --latest 20 --sort rate --save /etc/pacman.d/mirrorlist ;;
        *US*) reflector --country "United States" --latest 20 --sort rate --save /etc/pacman.d/mirrorlist ;;
        *Europe*)
            country=$(dialog_menu "Select European country" "Bucharest" "Germany" "Poland" "France" "Italy")
            reflector --country "$country" --latest 20 --sort rate --save /etc/pacman.d/mirrorlist ;;
        *Asia*)
            country=$(dialog_menu "Select Asian country" "Japan" "Japan" "China" "China" "Singapore" "Singapore" "India" "India")
            reflector --country "$country" --latest 20 --sort rate --save /etc/pacman.d/mirrorlist ;;
    esac
}

partition_disk() {
    confirm_dialog "WARNING: This will erase all data on $DISK. Proceed?" || exit 1
    wipefs -a "$DISK" || true
    sgdisk -Z "$DISK" || true
    parted --script "$DISK" mklabel gpt
    if [[ "$BOOT_MODE" == "UEFI" ]]; then
        parted --script "$DISK" mkpart ESP fat32 1MiB 512MiB
        parted --script "$DISK" set 1 esp on
        BOOT_PART="${DISK}${PART_PREFIX}1"
        start="512MiB"
    else
        parted --script "$DISK" mkpart bios_grub 1MiB 3MiB
        parted --script "$DISK" set 1 bios_grub on
        BOOT_PART=""
        start="3MiB"
    fi

    if [[ "$SWAP_MODE" == "partition" ]]; then
        end_swap="$(( SWAP_SIZE_GIB ))GiB"
        parted --script "$DISK" mkpart linux-swap "${start}" "${end_swap}"
        SWAP_PART="${DISK}${PART_PREFIX}2"
        start="${end_swap}"
    fi

    parted --script "$DISK" mkpart root "${start}" 100%
    if [[ "$SWAP_MODE" == "partition" && "$BOOT_MODE" == "UEFI" ]]; then ROOT_PART="${DISK}${PART_PREFIX}3"
    elif [[ "$SWAP_MODE" == "partition" && "$BOOT_MODE" == "BIOS" ]]; then ROOT_PART="${DISK}${PART_PREFIX}3"
    elif [[ "$BOOT_MODE" == "UEFI" ]]; then ROOT_PART="${DISK}${PART_PREFIX}2"
    else ROOT_PART="${DISK}${PART_PREFIX}2"; fi

    if [[ "$BOOT_MODE" == "UEFI" ]]; then mkfs.fat -F32 "$BOOT_PART"; fi
    mkfs."$FILESYSTEM" -F "$ROOT_PART"
    if [[ -n "${SWAP_PART:-}" ]]; then mkswap "$SWAP_PART"; swapon "$SWAP_PART"; fi

    mount "$ROOT_PART" /mnt
    if [[ "$FILESYSTEM" == "btrfs" ]]; then
        btrfs subvolume create /mnt/@
        btrfs subvolume create /mnt/@home
        umount /mnt
        mount -o subvol=@ "$ROOT_PART" /mnt
        mkdir -p /mnt/home
        mount -o subvol=@home "$ROOT_PART" /mnt/home
    fi
    if [[ "$BOOT_MODE" == "UEFI" ]]; then mkdir -p /mnt/boot; mount "$BOOT_PART" /mnt/boot; fi
}

install_base() {
    BASE=(base linux linux-firmware vim)
    case "$PROFILE" in
        *minimal*) BASE+=(networkmanager) ;;
        *desktop*) BASE+=(networkmanager xorg) ;;
        *server*) BASE+=(openssh) ;;
    esac
    pacstrap /mnt "${BASE[@]}" ${PACKAGES[@]+"${PACKAGES[@]}"}
    genfstab -U /mnt >> /mnt/etc/fstab

    if [[ "$SWAP_MODE" == "file" ]]; then
        arch-chroot /mnt bash -c "
            fallocate -l ${SWAP_SIZE_GIB}G /swapfile
            chmod 600 /swapfile
            mkswap /swapfile
            echo '/swapfile none swap defaults 0 0' >> /etc/fstab
        "
    fi
}

configure_system() {
    arch-chroot /mnt ln -sf "/usr/share/zoneinfo/$TIMEZONE" /etc/localtime
    arch-chroot /mnt hwclock --systohc
    echo "$HOSTNAME" > /mnt/etc/hostname
    sed -i 's/^#en_US.UTF-8/en_US.UTF-8/' /mnt/etc/locale.gen
    arch-chroot /mnt locale-gen
    echo "LANG=en_US.UTF-8" > /mnt/etc/locale.conf
    arch-chroot /mnt bash -c "echo 'root:$PASSWORD' | chpasswd"
    arch-chroot /mnt useradd -m -G wheel -s /bin/bash "$USERNAME"
    arch-chroot /mnt bash -c "echo '$USERNAME:$PASSWORD' | chpasswd"
    echo '%wheel ALL=(ALL) ALL' > /mnt/etc/sudoers.d/10-wheel

    case "$NETWORK" in
        *networkmanager*) arch-chroot /mnt systemctl enable NetworkManager ;;
        *systemd-networkd*) arch-chroot /mnt systemctl enable systemd-networkd systemd-resolved ;;
        *static*)
            cat >/mnt/etc/systemd/network/20-wired.network <<EOF
[Match]
Name=en*
[Network]
Address=192.168.1.100/24
Gateway=192.168.1.1
DNS=1.1.1.1
EOF
            arch-chroot /mnt systemctl enable systemd-networkd systemd-resolved ;;
    esac
}

install_bootloader() {
    if [[ "$BOOT_MODE" == "UEFI" ]]; then
        case "$BOOTLOADER" in
            *grub*) arch-chroot /mnt pacman -Sy --noconfirm grub efibootmgr
                   arch-chroot /mnt grub-install --target=x86_64-efi --efi-directory=/boot --bootloader-id=GRUB
                   arch-chroot /mnt grub-mkconfig -o /boot/grub/grub.cfg ;;
            *systemd-boot*) arch-chroot /mnt bootctl install ;;
        esac
    else
        arch-chroot /mnt pacman -Sy --noconfirm grub
        arch-chroot /mnt grub-install --target=i386-pc "$DISK"
        arch-chroot /mnt grub-mkconfig -o /boot/grub/grub.cfg
    fi
}

install_de() {
    case "$DE" in
        *gnome*) arch-chroot /mnt pacman -Sy --noconfirm gnome gdm
                 arch-chroot /mnt systemctl enable gdm ;;
        *kde*)   arch-chroot /mnt pacman -Sy --noconfirm plasma sddm
                 arch-chroot /mnt systemctl enable sddm ;;
        *xfce*)  arch-chroot /mnt pacman -Sy --noconfirm xfce4 lightdm lightdm-gtk-greeter
                 arch-chroot /mnt systemctl enable lightdm ;;
        *none*)  ;;
    esac
}

main() {
    require_cmds pacstrap arch-chroot parted sgdisk reflector dialog
    detect_boot_mode
    select_disk
    configure_mirrors

    FILESYSTEM=$(dialog_menu "Choose filesystem" "ext4 " "btrfs" "xfs ")
    SWAP_MODE=$(dialog_menu "Swap mode" "none – no swap" "partition – swap partition" "file – swap file")
    if [[ "$SWAP_MODE" != "none" ]]; then SWAP_SIZE_GIB=$(ask_dialog "Swap size in GiB") ; fi

    TIMEZONE=$(ask_dialog "Timezone (e.g. Europe/Berlin)")
    HOSTNAME=$(ask_dialog "Hostname")
    USERNAME=$(ask_dialog "Username")
    PASSWORD=$(ask_dialog "Password")

    PROFILE=$(dialog_menu "Select profile" "minimal – base + network" "desktop – base + xorg" "server – base + openssh")
    NETWORK=$(dialog_menu "Networking option" "networkmanager – easy WiFi/Ethernet" "systemd-networkd – lightweight DHCP" "static – manual static IP")
    DE=$(dialog_menu "Desktop environment" "none – console only" "gnome – modern desktop" "kde – plasma desktop" "xfce – lightweight desktop")

    if [[ "$BOOT_MODE" == "UEFI" ]]; then
        BOOTLOADER=$(dialog_menu "Bootloader" "grub – BIOS+UEFI" "systemd-boot – UEFI only")
    else
        BOOTLOADER="grub"
    fi

    PACKAGES=$(ask_dialog "Additional packages (space-separated, optional)")
    PACKAGES=($PACKAGES)

    confirm_dialog "Proceed with installation?" || exit 1

    partition_disk
    install_base
    configure_system
    install_bootloader
    install_de

    dialog --msgbox "Installation complete. Run: umount -R /mnt && swapoff -a && reboot" 10 50
    clear
}

main
