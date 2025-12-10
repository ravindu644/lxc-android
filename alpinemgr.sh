#!/system/bin/sh

# Alpine rootfs manager
# Made to run LXC installed on a minimal Alpine rootfs

# --- Configuration ---
BASE_CHROOT_DIR="${BASE_CHROOT_DIR:-/data/local/alpine-rootfs}"
CHROOT_PATH="${BASE_CHROOT_DIR}/rootfs"
ROOTFS_IMG="${BASE_CHROOT_DIR}/rootfs.img"
SCRIPT_NAME="$(basename "$0")"
SCRIPT_DIR="$(dirname "$0")"
C_HOSTNAME="alpine"
MOUNTED_FILE="${BASE_CHROOT_DIR}/mount.points"
HOLDER_PID_FILE="${BASE_CHROOT_DIR}/holder.pid"
SILENT=0

# --- Pre-flight Checks ---
if [ "$(id -u)" -ne 0 ]; then
    echo "[ERROR] Must be run as root."
    exit 1
fi

for cmd in busybox unshare; do
    if ! command -v "$cmd" >/dev/null 2>&1; then
        echo "[ERROR] Required command '$cmd' not found."
        exit 1
    fi
done

# --- Logging ---
log() { [ "$SILENT" -eq 0 ] && echo "[INFO] $1"; }
warn() { [ "$SILENT" -eq 0 ] && echo "[WARN] $1"; }
error() { echo "[ERROR] $1"; }

# --- Android Optimization ---
android_optimizations() {
    local mode="$1"
    if [ "$mode" = "--enable" ]; then
        # Prevent Android from killing the rootfs process
        cmd device_config put activity_manager max_phantom_processes 2147483647 >/dev/null 2>&1
        cmd device_config set_sync_disabled_for_tests persistent >/dev/null 2>&1
        dumpsys deviceidle disable >/dev/null 2>&1
    else
        # Revert
        cmd device_config put activity_manager max_phantom_processes 32 >/dev/null 2>&1
        cmd device_config set_sync_disabled_for_tests none >/dev/null 2>&1
        dumpsys deviceidle enable >/dev/null 2>&1
    fi
}

# --- Namespace Handling ---

_get_ns_flags() {
    local flags_file="$HOLDER_PID_FILE.flags"
    if [ -f "$flags_file" ]; then
        # Translate long flags to busybox short flags
        local long_flags=$(cat "$flags_file")
        local short_flags=""
        for flag in $long_flags; do
            case "$flag" in
                --mount) short_flags="$short_flags -m" ;;
                --uts)   short_flags="$short_flags -u" ;;
                --ipc)   short_flags="$short_flags -i" ;;
                --pid)   short_flags="$short_flags -p" ;;
            esac
        done
        echo "$short_flags"
    else
        echo "-m" # Absolute minimum fallback for flags, though strict logic usually catches this earlier
    fi
}

_execute_in_ns() {
    local holder_pid
    if [ -f "$HOLDER_PID_FILE" ] && kill -0 "$(cat "$HOLDER_PID_FILE")" 2>/dev/null; then
        holder_pid=$(cat "$HOLDER_PID_FILE")
        busybox nsenter --target "$holder_pid" $(_get_ns_flags) -- "$@"
    else
        error "Namespace not running. Execution failed."
        exit 1
    fi
}

run_in_ns() {
    # Wrapper to execute a command in the namespace but not yet in the rootfs.
    # Falls back to direct execution if namespace not available.
    if [ -f "$HOLDER_PID_FILE" ] && kill -0 "$(cat "$HOLDER_PID_FILE")" 2>/dev/null; then
        _execute_in_ns "$@"
    else
        # If no namespace holder is running, execute command directly.
        "$@"
    fi
}

run_in_rootfs() {
    local command="$*"
    local path_export="export PATH='/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin'"
    _execute_in_ns chroot "$CHROOT_PATH" /bin/sh -c "$path_export; $command"
}

create_namespace() {
    local pid_file="$1"
    local unshare_flags=""
    
    # Check supported namespaces
    for ns_flag in --pid --mount --uts --ipc; do
        if unshare "$ns_flag" true 2>/dev/null; then
            unshare_flags+=" $ns_flag"
        fi
    done

    # strict check: must have mount namespace
    if ! echo "$unshare_flags" | grep -q -- "--mount"; then
        error "Kernel does not support Mount Namespace. Cannot proceed."
        return 1
    fi

    echo "$unshare_flags" > "${pid_file}.flags"

    # Start the namespace holder
    # We unshare, then background sleep infinity, and echo that backgrounded PID to the file
    unshare $unshare_flags sh -c 'busybox sleep infinity & echo $! > "$1"' -- "$pid_file"

    # Wait for PID
    local attempts=0
    while [ $attempts -lt 10 ]; do
        if [ -f "$pid_file" ] && kill -0 "$(cat "$pid_file")" 2>/dev/null; then
            return 0
        fi
        sleep 0.1
        attempts=$((attempts + 1))
    done

    error "Failed to create isolated namespace."
    rm -f "$pid_file"
    return 1
}

# --- Setup Functions ---

advanced_mount() {
    local src="$1" tgt="$2" type="$3" opts="$4"
    local mount_exit=0
    [ ! -d "$tgt" ] && _execute_in_ns mkdir -p "$tgt" 2>/dev/null
    
    if [ "$type" = "bind" ]; then
        _execute_in_ns mount --bind "$src" "$tgt"
        mount_exit=$?
    else
        _execute_in_ns mount -t "$type" $opts "$type" "$tgt"
        mount_exit=$?
    fi

    if [ $mount_exit -eq 0 ]; then
        echo "$tgt" >> "$MOUNTED_FILE"
    else
        warn "Failed to mount $tgt"
    fi

    return $mount_exit
}

apply_internet_fix() {
    log "Applying networking fixes..."
    
    # 1. Resolver
    local dns_servers="nameserver 8.8.8.8\nnameserver 8.8.4.4"
    # Try to grab android props
    local d1=$(getprop net.dns1 2>/dev/null)
    local d2=$(getprop net.dns2 2>/dev/null)
    [ -n "$d1" ] && dns_servers="nameserver $d1"
    [ -n "$d2" ] && dns_servers="$dns_servers\nnameserver $d2"

    run_in_rootfs "echo '$C_HOSTNAME' > /etc/hostname"
    run_in_rootfs "echo '127.0.0.1 localhost $C_HOSTNAME' > /etc/hosts"
    run_in_rootfs hostname "$C_HOSTNAME"
    run_in_rootfs "echo -e '$dns_servers' > /etc/resolv.conf"

    # 1.5. Enable IPv4 forwarding and disable IPv6
    sysctl -w net.ipv4.ip_forward=1 >/dev/null 2>&1
    sysctl -w net.ipv6.conf.all.disable_ipv6=1 >/dev/null 2>&1
    sysctl -w net.ipv6.conf.default.disable_ipv6=1 >/dev/null 2>&1

    # 1.6. Detect default gateway & interface
    # Fixes tailscale issues
    DEFAULT_IFACE=$(ip route get 8.8.8.8 | awk '{for(i=1;i<=NF;i++) if($i=="dev") print $(i+1)}')
    DEFAULT_GW=$(ip route get 8.8.8.8 | awk '/via/ {for(i=1;i<=NF;i++) if($i=="via") print $(i+1)}')
    if [ -n "$DEFAULT_IFACE" ] && [ -n "$DEFAULT_GW" ]; then
        ip route add default via "$DEFAULT_GW" dev "$DEFAULT_IFACE" >/dev/null 2>&1 || true
        log "Added default route via $DEFAULT_GW on $DEFAULT_IFACE"
    fi

    # 2. Android GIDs (Permissions)
    run_in_rootfs "grep -q '^aid_inet:' /etc/group || echo 'aid_inet:x:3003:root' >> /etc/group"
    run_in_rootfs "grep -q '^aid_net_raw:' /etc/group || echo 'aid_net_raw:x:3004:root' >> /etc/group"

    # 3. Fix root groups if usermod exists, otherwise we rely on manual /etc/group editing above
    run_in_rootfs "command -v usermod >/dev/null && usermod -a -G aid_inet,aid_net_raw root 2>/dev/null || true"

    # 4. Flush filter chains and forward all the LXC traffic to localhost
    run_in_ns iptables -t filter -F
    run_in_ns ip6tables -t filter -F

    # Forward all traffic to localhost
    run_in_ns iptables -P FORWARD ACCEPT
    run_in_ns iptables -t nat -A OUTPUT -p tcp -d 127.0.0.1 -m tcp --dport 1:65535 -j REDIRECT --to-ports 1-65535 || true
    run_in_ns iptables -t nat -A OUTPUT -p udp -d 127.0.0.1 -m udp --dport 1:65535 -j REDIRECT --to-ports 1-65535 || true
}

start_rootfs() {
    if [ -f "$HOLDER_PID_FILE" ] && kill -0 "$(cat "$HOLDER_PID_FILE")" 2>/dev/null; then
        log "Rootfs already running."
        return
    fi

    log "Starting Alpine Rootfs..."
    setenforce 0 2>/dev/null

    # 1. Create Namespace
    create_namespace "$HOLDER_PID_FILE" || exit 1
    log "Namespace created (PID: $(cat "$HOLDER_PID_FILE"))"

    # 1.5. Handle sparse image if it exists
    if [ -f "$ROOTFS_IMG" ]; then
        log "Sparse image detected"

        if mountpoint -q "$CHROOT_PATH" 2>/dev/null; then
            log "Sparse image already mounted, unmounting first..."
            if umount -f "$CHROOT_PATH" 2>/dev/null || umount -l "$CHROOT_PATH" 2>/dev/null; then
                log "Previous mount cleaned up"
            else
                warn "Failed to unmount previous mount, continuing anyway"
            fi
        fi

        # Enable journal if missing
        if ! tune2fs -l "$ROOTFS_IMG" 2>/dev/null | grep -q "has_journal"; then
            log "Sparse image does not have journal - Enabling..."
            tune2fs -O has_journal "$ROOTFS_IMG" 2>/dev/null || warn "Failed to enable journal"
            tune2fs -o journal_data_writeback "$ROOTFS_IMG" 2>/dev/null || warn "Failed to set journal mode"
        fi

        # Check and repair filesystem before mounting
        log "Checking filesystem integrity..."
        local fsck_output=$(e2fsck -f -y "$ROOTFS_IMG" 2>&1)
        local fsck_exit=$?

        # Exit codes: 0=no errors, 1=corrected, 2=corrected/reboot, 4+=failed
        if [ $fsck_exit -ge 4 ]; then
            error "Filesystem check failed (exit: $fsck_exit)"
            error "Output: $fsck_output"
            error "Filesystem corruption detected - cannot safely mount"
            exit 1
        elif [ $fsck_exit -ne 0 ]; then
            log "Filesystem check corrected issues (exit: $fsck_exit)"
        else
            log "Filesystem integrity verified"
        fi

        sleep 1

        log "Mounting sparse image to rootfs..."
        if ! _execute_in_ns mount -t ext4 -o loop,rw,noatime,nodiratime,errors=remount-ro "$ROOTFS_IMG" "$CHROOT_PATH"; then
            error "Failed to mount sparse image"
            exit 1
        else
            log "Sparse image mounted successfully"
        fi
    else
        # Directory-based rootfs - check if directory exists
        [ ! -d "$CHROOT_PATH" ] && { error "Directory $CHROOT_PATH not found"; exit 1; }
    fi

    # 2. Prepare Mounts
    rm -f "$MOUNTED_FILE"

    # Set mount propagation to rprivate
    if _execute_in_ns busybox mount --make-rprivate / 2>/dev/null; then
        log "Set entire namespace to recursive private propagation"
    else
        warn "Failed to set root to rprivate propagation"
    fi

    # Standard Linux Mounts
    advanced_mount "proc" "$CHROOT_PATH/proc" "proc" "-o rw,nosuid,nodev,noexec,relatime"
    advanced_mount "sysfs" "$CHROOT_PATH/sys" "sysfs" "-o rw,nosuid,nodev,noexec,relatime"

    # Essential for LXC functionality
    log "Setting up cgroups for LXC..."

    _execute_in_ns mkdir -p "$CHROOT_PATH/sys/fs/cgroup"

    if _execute_in_ns mount -t tmpfs -o mode=755,rw,nosuid,nodev,noexec,relatime tmpfs "$CHROOT_PATH/sys/fs/cgroup" 2>/dev/null; then
        echo "$CHROOT_PATH/sys/fs/cgroup" >> "$MOUNTED_FILE"

        # Mount 'devices' cgroup (Critical for LXC)
        _execute_in_ns mkdir -p "$CHROOT_PATH/sys/fs/cgroup/devices"
        if grep -q devices /proc/cgroups 2>/dev/null; then
            if _execute_in_ns mount -t cgroup -o devices cgroup "$CHROOT_PATH/sys/fs/cgroup/devices" 2>/dev/null; then
                log "Cgroup devices mounted successfully."
                echo "$CHROOT_PATH/sys/fs/cgroup/devices" >> "$MOUNTED_FILE"
            else
                warn "Failed to mount cgroup devices."
            fi
        else
            warn "Devices cgroup controller not available."
        fi

        # Mount 'systemd' cgroup
        if ! advanced_mount "cgroup" "$CHROOT_PATH/sys/fs/cgroup/systemd" "cgroup" "-o none,name=systemd"; then
            warn "Failed to mount cgroup systemd."
        fi
    else
        warn "Failed to mount cgroup tmpfs."
    fi

    # Dev Mounts
    if grep -q devtmpfs /proc/filesystems; then
        advanced_mount "devtmpfs" "$CHROOT_PATH/dev" "devtmpfs" "-o mode=755"
        run_in_rootfs "umount /dev/fd 2>/dev/null || true && rm -rf /dev/fd && ln -sf /proc/self/fd /dev/ 2>/dev/null || true"
    else
        advanced_mount "/dev" "$CHROOT_PATH/dev" "bind"
    fi

    # Mount binfmt_misc if supported
    if grep -q binfmt_misc /proc/filesystems; then
        advanced_mount "binfmt_misc" "$CHROOT_PATH/proc/sys/fs/binfmt_misc" "binfmt_misc" ""
    fi

    advanced_mount "devpts" "$CHROOT_PATH/dev/pts" "devpts" "-o rw,nosuid,noexec,relatime,gid=5,mode=620,ptmxmode=000"
    advanced_mount "tmpfs" "$CHROOT_PATH/tmp" "tmpfs" "-o rw,nosuid,nodev,relatime,size=256M"
    advanced_mount "tmpfs" "$CHROOT_PATH/run" "tmpfs" "-o rw,nosuid,nodev,relatime,size=64M"
    advanced_mount "tmpfs" "$CHROOT_PATH/dev/shm" "tmpfs" "-o mode=1777"

    # 3. Optimizations & Fixes
    apply_internet_fix
    android_optimizations --enable

    log "Rootfs started successfully."
}

umount_rootfs() {
    log "Unmounting rootfs filesystems..."

    # Unmount mounts recorded in file
    if [ -f "$MOUNTED_FILE" ]; then
        # Unmount in reverse order (deepest first)
        sort -r "$MOUNTED_FILE" | while read -r mount_point; do
            case "$mount_point" in
                "$CHROOT_PATH"/sys*) run_in_ns umount -l "$mount_point" 2>/dev/null ;;
                *) run_in_ns umount "$mount_point" 2>/dev/null ;;
            esac
        done
        rm -f "$MOUNTED_FILE"
        log "All rootfs mounts unmounted."
    fi
}

stop_rootfs() {
    log "Stopping rootfs..."
    
    # Kill processes inside rootfs path
    local pids=$(lsof 2>/dev/null | grep "$CHROOT_PATH" | awk '{print $2}' | uniq)
    [ -n "$pids" ] && kill -9 $pids 2>/dev/null

    # Unmount filesystems (BEFORE killing namespace holder)
    umount_rootfs

    # Unmount sparse image if it exists
    if [ -f "$ROOTFS_IMG" ] && mountpoint -q "$CHROOT_PATH" 2>/dev/null; then
        log "Unmounting sparse image..."
        if umount -f "$CHROOT_PATH" 2>/dev/null || umount -l "$CHROOT_PATH" 2>/dev/null; then
            log "Sparse image unmounted successfully."
        else
            warn "Failed to unmount sparse image."
        fi
    fi

    # Kill Namespace Holder
    if [ -f "$HOLDER_PID_FILE" ]; then
        kill "$(cat "$HOLDER_PID_FILE")" 2>/dev/null
        rm -f "$HOLDER_PID_FILE" "$HOLDER_PID_FILE.flags"
    fi

    android_optimizations --disable
    log "Stopped."
}

enter_rootfs() {
    local user="${1:-root}"

    # Check for running Namespace
    if [ ! -f "$HOLDER_PID_FILE" ] || ! kill -0 "$(cat "$HOLDER_PID_FILE")" 2>/dev/null; then
        error "Rootfs is not running. Use '$SCRIPT_NAME start' first."
        exit 1
    fi

    # Non-interactive shell detection
    if [ ! -t 1 ]; then
        error "Non-interactive environment detected. Cannot enter shell."
        exit 1
    fi

    log "Entering shell as $user..."
    
    # Alpine typically uses /bin/sh (ash). bash might not be installed.
    local common_exports="export PATH='/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin' ; unset TERM"
    local shell_cmd="$common_exports; exec /bin/su - $user"
    
    _execute_in_ns chroot "$CHROOT_PATH" /bin/sh -c "$shell_cmd"
}

backup_rootfs() {
    local backup_file="$1"
    [ -z "$backup_file" ] && { error "Usage: backup <path.tar.gz>"; exit 1; }
    
    log "Backing up to $backup_file..."
    
    # Stop rootfs if running
    if [ -f "$HOLDER_PID_FILE" ] && kill -0 "$(cat "$HOLDER_PID_FILE")" 2>/dev/null; then
        stop_rootfs
    fi

    sync && sleep 1

    local backup_dir=$(dirname "$backup_file")
    mkdir -p "$backup_dir"
    
    local tar_exit_code=1

    if [ -f "$ROOTFS_IMG" ]; then
        # Sparse image backup method
        log "Using sparse image backup method."

        local temp_mount_point="${CHROOT_PATH}_bkmnt"
        mkdir -p "$temp_mount_point"

        # Check and repair filesystem before mounting
        log "Checking filesystem integrity before backup..."
        local fsck_output=$(e2fsck -f -y "$ROOTFS_IMG" 2>&1)
        local fsck_exit=$?

        if [ $fsck_exit -ge 4 ]; then
            error "Filesystem check failed (exit: $fsck_exit)"
            error "Output: $fsck_output"
            error "Filesystem corruption detected - cannot safely backup"
            rmdir "$temp_mount_point" >/dev/null 2>&1
            exit 1
        fi

        [ $fsck_exit -ne 0 ] && log "Filesystem check corrected issues (exit: $fsck_exit)"
        sleep 1

        # Mount the image read-only for safety
        if mount -t ext4 -o loop,ro "$ROOTFS_IMG" "$temp_mount_point"; then
            log "Sparse image mounted cleanly for backup."

            if busybox tar -czf "$backup_file" -C "$temp_mount_point" .; then
                tar_exit_code=0
            fi

            sync
            umount "$temp_mount_point"
            rmdir "$temp_mount_point"
        else
            error "Failed to create a clean mount of the sparse image for backup."
            rmdir "$temp_mount_point" >/dev/null 2>&1
        fi
    else
        # Directory backup method
        log "Using directory backup method."
        if busybox tar -czf "$backup_file" -C "$CHROOT_PATH" .; then
            tar_exit_code=0
        fi
    fi

    if [ "$tar_exit_code" -eq 0 ]; then
        local size=$(du -h "$backup_file" 2>/dev/null | cut -f1)
        log "Backup complete: $backup_file (${size:-unknown size})"
    else
        error "Backup failed. Removing incomplete file."
        rm -f "$backup_file"
        exit 1
    fi
}

restore_rootfs() {
    local backup_file="$1"
    [ ! -f "$backup_file" ] && { error "File not found: $backup_file"; exit 1; }
    
    log "Restoring from $backup_file..."

    # Stop rootfs if running
    if [ -f "$HOLDER_PID_FILE" ] && kill -0 "$(cat "$HOLDER_PID_FILE")" 2>/dev/null; then
        stop_rootfs
    fi

    # Unmount sparse image if mounted
    if [ -f "$ROOTFS_IMG" ] && mountpoint -q "$CHROOT_PATH" 2>/dev/null; then
        log "Unmounting sparse image..."
        umount -f "$CHROOT_PATH" 2>/dev/null || umount -l "$CHROOT_PATH" 2>/dev/null || {
            error "Failed to unmount sparse image"
            exit 1
        }
    fi

    # Remove sparse image if it exists (restore will create directory-based rootfs)
    if [ -f "$ROOTFS_IMG" ]; then
        log "Removing sparse image file..."
        rm -f "$ROOTFS_IMG" || { error "Failed to remove sparse image file"; exit 1; }
    fi

    # Remove existing rootfs directory
    if [ -d "$CHROOT_PATH" ]; then
        log "Removing existing rootfs directory..."
        rm -rf "$CHROOT_PATH" || { error "Failed to remove existing rootfs directory"; exit 1; }
    fi

    mkdir -p "$CHROOT_PATH"
    
    if busybox tar -xzf "$backup_file" -C "$CHROOT_PATH"; then
        log "Restore complete."
    else
        error "Restore failed."
        exit 1
    fi
}

uninstall_rootfs() {
    log "Uninstalling..."
    stop_rootfs
    
    # Remove sparse image if it exists
    if [ -f "$ROOTFS_IMG" ]; then
        log "Removing sparse image file..."
        rm -f "$ROOTFS_IMG" || { error "Failed to remove sparse image file."; exit 1; }
        log "Sparse image removed."
    fi

    if [ -d "$CHROOT_PATH" ]; then
        rm -rf "$CHROOT_PATH"
        log "Rootfs files removed."
    fi
    
    rm -f "$MOUNTED_FILE" "$HOLDER_PID_FILE" "$HOLDER_PID_FILE.flags"
}

# --- CLI Handling ---

case "$1" in
    start)
        start_rootfs
        # Auto-enter shell if running in interactive terminal
        if [ -t 1 ]; then
            enter_rootfs "${2:-root}"
        fi
        ;;
    stop)
        stop_rootfs
        ;;
    restart)
        log "Restarting rootfs..."
        stop_rootfs
        sleep 1
        sync
        start_rootfs
        # Auto-enter shell if running in interactive terminal
        if [ -t 1 ]; then
            enter_rootfs "${2:-root}"
        fi
        ;;
    status)
        if [ -f "$HOLDER_PID_FILE" ] && kill -0 "$(cat "$HOLDER_PID_FILE")" 2>/dev/null; then
            echo "Status: RUNNING (PID: $(cat "$HOLDER_PID_FILE"))"
        else
            echo "Status: STOPPED"
        fi
        ;;
    enter)
        enter_rootfs "$2"
        ;;
    run)
        shift
        [ -z "$1" ] && { error "Command required."; exit 1; }
        run_in_rootfs "$*"
        ;;
    backup)
        backup_rootfs "$2"
        ;;
    restore)
        restore_rootfs "$2"
        ;;
    uninstall)
        uninstall_rootfs
        ;;
    *)
        echo "Usage: $SCRIPT_NAME {start|stop|restart|status|enter [user]|run <cmd>|backup <file>|restore <file>|uninstall}"
        exit 1
        ;;
esac
