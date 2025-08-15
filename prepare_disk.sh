#!/bin/bash

set -euo pipefail

# Function: Detect correct partition naming scheme
get_part_path() {
    local drive="$1"
    local part_num="$2"

    if [[ "$drive" =~ nvme ]]; then
        echo "${drive}p${part_num}"
    else
        echo "${drive}${part_num}"
    fi
}

# Function: Create a partition if size is given
create_partition() {
    local part_name="$1"
    local default_fs="$2"

    read -p "Enter size for $part_name partition (e.g., 512MiB, 20GiB, 100%) or leave empty to skip: " size
    if [[ -z "$size" ]]; then
        echo "Skipping $part_name."
        return
    fi

    read -p "Choose filesystem for $part_name [$default_fs]: " fs
    fs=${fs:-$default_fs}

    # Get the start of the next free space (first free block after partitions)
    local start=$(parted -m "$DRIVE" unit MiB print free | awk -F: '/free/ && NR>1 {print $1; exit}')
    
    # Create the partition with alignment
    if [[ "$size" == "100%" ]]; then
        parted -a optimal -s "$DRIVE" mkpart "$part_name" "$start" 100%
    else
        parted -a optimal -s "$DRIVE" mkpart "$part_name" "$start" "$size"
    fi

    echo "Created $part_name."

    # Get partition number from parted
    local part_num=$(parted -m "$DRIVE" print | awk -F: -v name="$part_name" '$0 ~ name {print $1}')
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
