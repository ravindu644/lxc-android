#!/system/bin/sh

# LXC on Android - Alpine Rootfs Installation Functions
# Clean, minimal implementation

TMPDIR=/dev/tmp
ROOTFS_DIR="/data/local/alpine-rootfs"
VERSION_FILE="$ROOTFS_DIR/version"

mkdir -p "${ROOTFS_DIR}" 2>/dev/null

# Detect root method
detect_root() {
    if command -v magisk >/dev/null 2>&1; then
        ROOT_METHOD="magisk"
        echo -e "- Magisk detected\n"
        echo "- WARNING: You may face various terminal bugs with Magisk."
        echo -e "- You can try downgrading your Magisk version to v28 or v29.\n"
    elif command -v ksud >/dev/null 2>&1; then
        ROOT_METHOD="kernelsu"
        echo -e "- KernelSU detected\n"
    elif command -v apd >/dev/null 2>&1; then
        ROOT_METHOD="apatch"
        echo -e "- Apatch detected\n"
    else
        ROOT_METHOD="unknown"
        echo -e "- Unknown root method detected. Proceed with caution.\n"
    fi

    # Check for SuSFS compatibility
    if zcat /proc/config.gz 2>/dev/null | grep -q "CONFIG_KSU_SUSFS=y" || [ -d /data/adb/modules/susfs4ksu ]; then
        echo -e "WARNING: SuSFS detected. You may encounter mounting issues with \"/proc\".\n"
        echo -e "Fix: Disable \"HIDE SUS MOUNTS FOR ALL PROCESSES\" in SuSFS4KSU settings.\n"
    fi
}

# Extract core LXC management files
setup_rootfs() {
    mkdir -p "$MODPATH/system/bin"
    unzip -oj "$ZIPFILE" 'system/bin/lxcmgr' -d "$MODPATH/system/bin" >&2
    echo "- LXC management files extracted"
}

# Find rootfs file in ZIP
find_rootfs_file() {
    unzip -l "$ZIPFILE" 2>/dev/null | grep -E '\.tar\.gz$' | head -1 | while read -r line; do
        # Extract filename from the last field (handles spaces correctly)
        echo "$line" | rev | cut -d' ' -f1 | rev
    done
}

# Extract rootfs for LXC
extract_rootfs() {
    echo "- Preparing to extract Alpine rootfs for LXC..."

    # Extract rootfs config (for SPARSE_IMAGE_SIZE)
    if unzip -oj "$ZIPFILE" 'rootfs.conf' -d "$MODPATH" >&2 2>/dev/null; then
        . "$MODPATH/rootfs.conf" 2>/dev/null
    fi

    # Find rootfs file
    local rootfs_file
    rootfs_file=$(find_rootfs_file)

    if [ -z "$rootfs_file" ]; then
        echo "- No rootfs file found in ZIP archive. Skipping extraction..."
        return 0
    fi

    echo "- Found rootfs file: $rootfs_file"
    echo "- Extracting rootfs..."

    # Always use sparse image method
    extract_sparse "$rootfs_file"
}

# Extract to sparse image
extract_sparse() {
    local rootfs_file="$1"
    local img_file="$ROOTFS_DIR/rootfs.img"
    local rootfs_dir="$ROOTFS_DIR/rootfs"

    # Check if image already exists
    if [ -f "$img_file" ]; then
        echo "- Sparse image already exists. Skipping setup..."
        return 0
    fi

    # Get size from config
    SPARSE_IMAGE_SIZE=${SPARSE_IMAGE_SIZE:-8}
    echo -e "- Creating sparse image for LXC: ${SPARSE_IMAGE_SIZE}GB\n"

    # Create and format sparse image
    if ! truncate -s "${SPARSE_IMAGE_SIZE}G" "$img_file"; then
        echo "- Built-in truncate failed, trying busybox truncate..."
        busybox truncate -s "${SPARSE_IMAGE_SIZE}G" "$img_file" || return 1
    fi

    # Verify sparse image was created and is not 0 bytes
    if [ ! -f "$img_file" ] || [ ! -s "$img_file" ]; then
        echo "- Sparse image creation failed: file is 0 bytes or does not exist"
        rm -f "$img_file"
        return 1
    fi

    mkfs.ext4 -F -L "alpine-rootfs" "$img_file" || {
        rm -f "$img_file"
        return 1
    }

    # Mount and extract
    mkdir -p "$rootfs_dir"
    mount -t ext4 -o loop,rw,noatime,nodiratime "$img_file" "$rootfs_dir" || {
        rm -f "$img_file"
        return 1
    }

    # Extract rootfs to sparse image for LXC
    mkdir -p "$TMPDIR"
    echo -e "\n- Extracting Alpine rootfs to sparse image for LXC usage..."
    if unzip -oq "$ZIPFILE" "$rootfs_file" -d "$TMPDIR" && tar -xpf "$TMPDIR/$rootfs_file" -C "$rootfs_dir"; then
        echo "- rootfs extracted successfully to sparse image"
        umount "$rootfs_dir"
        return 0
    else
        echo "- Rootfs extraction failed"
        umount "$rootfs_dir" 2>/dev/null
        rm -f "$img_file"
        return 1
    fi
}
