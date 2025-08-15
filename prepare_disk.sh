#!/bin/bash

set -euo pipefail

# Convert GB to MiB (1GB = 1024MiB)
gb_to_mib() {
    local gb="$1"
    echo $(( gb * 1024 ))
}

# Detect correct partition naming scheme
get_part_path() {
    local drive="$1"
    local part_num="$2"

    if [[ "$drive" =~ nvme ]]; then
        echo "${drive}p${part_num}"
    else
        echo "${drive}${part_num}"
    fi
}

# Create a partition if size is given
create_partition() {
    local part_name="$1"
    local default_fs="$2"

    read -p "Enter size in GB for $part_name partition (e.g., 0.5 for 512MiB, 20 for 20GiB, 100% for remaining space, 0 to skip): " size_input
    if [[ "$size_input" == "0" || -z "$size_input" ]]; then
        echo "Skipping $part_name."
        return
    fi

    read -p "Choose filesystem for $part_name [$default_fs]: " fs
    fs=${fs:-$default_fs}

    # Get start in MiB (integer aligned)
    local start_mib
    start_mib=$(parted -m "$DRIVE" unit MiB print free | awk -F: '/free/ && NR>1 {print int($1); exit}')

    if [[ "$size_input" == "100%" ]]; then
        # Use all remaining space
        parted -a optimal -s "$DRIVE" mkpart "$part_name" "${start_mib}MiB" 100%
    else
        # Convert GB to MiB
        local size_mib
        size_mib=$(gb_to_mib "$size_input")
        local end_mib=$(( start_mib + size_mib ))

        parted -a optimal -s "$DRIVE" mkpart "$part_name" "${start_mib}MiB" "${end_mib}MiB"
    fi

    echo "Created $part_name."

    # Get partition number from parted
    local part_num
    part_num=$(parted -m "$DRIVE" print | awk -F: -v name="$part_name" '$0 ~ name {print $1}')
    local part_path
    part_path=$(get_part_path "$DRIVE" "$part_num")

    # Format partition
    case "$fs" in
        fat32) mkfs.vfat -F32 "$part_path" ;;
        ext4) mkfs.ext4 -F "$part_path" ;;
        ntfs) mkfs.ntfs -F "$part_path" ;;
        exfat) mkfs.exfat -F "$part_path" ;;
        swap) mkswap "$part_path" ;;
        *) echo "Unknown filesystem '$fs', skipping format." ;;
    esac
}

echo "=== Drive Selection ==="
lsblk -dpno NAME,SIZE,MODEL | grep -v "loop"

read -p "Enter the full path of the drive to partition (e.g., /dev/sda or /dev/nvme0n1): " DRIVE
if [[ ! -b "$DRIVE" ]]; then
    echo "Invalid drive."
    exit 1
fi

echo "WARNING: This will erase all data on $DRIVE!"
read -p "Type YES to continue: " CONFIRM
if [[ "$CONFIRM" != "YES" ]]; then
    echo "Aborted."
    exit 1
fi

# Create new GPT table
parted -s "$DRIVE" mklabel gpt

# Create partitions interactively
create_partition "EFI" "fat32"
create_partition "root" "ext4"
create_partition "swap" "swap"
create_partition "home" "ext4"

# Show final layout
parted "$DRIVE" print
echo "Partitioning complete!"
