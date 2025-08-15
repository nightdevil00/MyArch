#!/bin/bash

set -euo pipefail

# Convert GB to MiB
gb_to_mib() {
    echo $(( $1 * 1024 ))
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

# Create a partition with specified size (in GB or percentage)
create_partition() {
    local drive="$1"
    local part_name="$2"
    local default_fs="$3"

    # Get total disk size in MiB
    local total_size_mib
    total_size_mib=$(parted -m "$drive" unit MiB print | grep "^Disk" | awk '{print $3}' | sed 's/MiB//')

    # Get current free space start position
    local start_mib
    start_mib=$(parted -m "$drive" unit MiB print free | awk -F: '/free/ {print $1; exit}')

    # Prompt for partition size
    read -p "Enter size in GB for $part_name partition (e.g., 0.5, 20, 100%, 0 to skip): " size_input
    if [[ "$size_input" == "0" || -z "$size_input" ]]; then
        echo "Skipping $part_name."
        return 0
    fi

    # Prompt for filesystem
    read -p "Choose filesystem for $part_name [$default_fs]: " fs
    fs=${fs:-$default_fs}

    local end_mib

    if [[ "$size_input" == "100%" ]]; then
        # Use remaining space
        end_mib=$total_size_mib
        # Create partition
        parted -a optimal -s "$drive" mkpart "$part_name" "${start_mib}MiB" "${end_mib}MiB"
    else
        # Convert GB to MiB
        local size_mib
        size_mib=$(gb_to_mib "$size_input")
        end_mib=$(( start_mib + size_mib ))
        if (( end_mib > total_size_mib )); then
            echo "Error: Partition exceeds disk size. Please specify a smaller size."
            return 1
        fi
        # Create partition
        parted -a optimal -s "$drive" mkpart "$part_name" "${start_mib}MiB" "${end_mib}MiB"
    fi

    echo "$part_name partition created from ${start_mib}MiB to ${end_mib}MiB."

    # Refresh partition table
    partprobe "$drive"
    sleep 2

    # Get partition number
    local part_num
    part_num=$(parted -m "$drive" print | awk -F: -v name="$part_name" '$0 ~ name {print $1}')
    local part_path
    part_path=$(get_part_path "$drive" "$part_num")

    # Wait for device node
    while [ ! -b "$part_path" ]; do
        sleep 1
    done

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

# Create new GPT partition table
parted -s "$DRIVE" mklabel gpt

# Create EFI partition
echo "Creating EFI partition..."
create_partition "$DRIVE" "EFI" "fat32"

# Create root partition
echo "Creating root partition..."
create_partition "$DRIVE" "root" "ext4"

# Create swap partition
echo "Creating swap partition..."
create_partition "$DRIVE" "swap" "swap"

# Create home partition
echo "Creating home partition..."
create_partition "$DRIVE" "home" "ext4"

# Show final layout
echo "Final partition layout:"
parted "$DRIVE" print

echo "Partitioning complete!"
