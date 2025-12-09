#!/system/bin/sh

# Alphine rootfs manager
# Made to run LXC installed on a minimal Alpine rootfs

# --- Configuration ---
BASE_CHROOT_DIR="/data/local/alpine-chroot"
CHROOT_PATH="${BASE_CHROOT_DIR}/rootfs"
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
        # Prevent Android from killing the chroot process
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

run_in_chroot() {
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
    [ ! -d "$tgt" ] && _execute_in_ns mkdir -p "$tgt" 2>/dev/null
    
    if [ "$type" = "bind" ]; then
        _execute_in_ns mount --bind "$src" "$tgt"
    else
        _execute_in_ns mount -t "$type" $opts "$type" "$tgt"
    fi

    if [ $? -eq 0 ]; then
        echo "$tgt" >> "$MOUNTED_FILE"
    else
        warn "Failed to mount $tgt"
    fi
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

    run_in_chroot "echo '$C_HOSTNAME' > /etc/hostname"
    run_in_chroot "echo '127.0.0.1 localhost $C_HOSTNAME' > /etc/hosts"
    run_in_chroot hostname "$C_HOSTNAME"
    run_in_chroot "echo -e '$dns_servers' > /etc/resolv.conf"

    # 1.5. Disable IPv6 completely
    run_in_chroot "echo 1 > /proc/sys/net/ipv6/conf/all/disable_ipv6 2>/dev/null || true"
    run_in_chroot "echo 1 > /proc/sys/net/ipv6/conf/default/disable_ipv6 2>/dev/null || true"

    # 2. Android GIDs (Permissions)
    # Using busybox syntax or raw file append to be distro-agnostic
    run_in_chroot "grep -q '^aid_inet:' /etc/group || echo 'aid_inet:x:3003:root' >> /etc/group"
    run_in_chroot "grep -q '^aid_net_raw:' /etc/group || echo 'aid_net_raw:x:3004:root' >> /etc/group"

    # 3. Fix root groups if usermod exists, otherwise we rely on manual /etc/group editing above
    run_in_chroot "command -v usermod >/dev/null && usermod -a -G aid_inet,aid_net_raw root 2>/dev/null || true"
}

start_chroot() {
    if [ -f "$HOLDER_PID_FILE" ] && kill -0 "$(cat "$HOLDER_PID_FILE")" 2>/dev/null; then
        log "Chroot already running."
        return
    fi

    [ ! -d "$CHROOT_PATH" ] && { error "Directory $CHROOT_PATH not found"; exit 1; }

    log "Starting Alpine Chroot..."
    setenforce 0 2>/dev/null

    # 1. Create Namespace
    create_namespace "$HOLDER_PID_FILE" || exit 1
    log "Namespace created (PID: $(cat "$HOLDER_PID_FILE"))"

    # 2. Prepare Mounts
    rm -f "$MOUNTED_FILE"

    # Standard Linux Mounts
    advanced_mount "proc" "$CHROOT_PATH/proc" "proc" "-o rw,nosuid,nodev,noexec,relatime"
    advanced_mount "sysfs" "$CHROOT_PATH/sys" "sysfs" "-o rw,nosuid,nodev,noexec,relatime"

    # Essential for LXC functionality
    log "Setting up minimal cgroups for Docker..."

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
    else
        warn "Failed to mount cgroup tmpfs."
    fi

    # Dev Mounts
    if grep -q devtmpfs /proc/filesystems; then
        advanced_mount "devtmpfs" "$CHROOT_PATH/dev" "devtmpfs" "-o mode=755"
        run_in_chroot "umount /dev/fd 2>/dev/null || true && rm -rf /dev/fd && ln -sf /proc/self/fd /dev/ 2>/dev/null || true"
    else
        advanced_mount "/dev" "$CHROOT_PATH/dev" "bind"
    fi
    
    advanced_mount "devpts" "$CHROOT_PATH/dev/pts" "devpts" "-o rw,nosuid,noexec,relatime,gid=5,mode=620,ptmxmode=000"
    advanced_mount "tmpfs" "$CHROOT_PATH/tmp" "tmpfs" "-o rw,nosuid,nodev,relatime,size=256M"
    advanced_mount "tmpfs" "$CHROOT_PATH/run" "tmpfs" "-o rw,nosuid,nodev,relatime,size=64M"
    advanced_mount "tmpfs" "$CHROOT_PATH/dev/shm" "tmpfs" "-o mode=1777"

    # Make root rprivate to prevent mount leakage
    _execute_in_ns busybox mount --make-rprivate "$CHROOT_PATH" "$CHROOT_PATH" 2>/dev/null || true

    # 3. Optimizations & Fixes
    apply_internet_fix
    android_optimizations --enable

    log "Chroot started successfully."
}

stop_chroot() {
    log "Stopping chroot..."
    
    # Kill processes inside chroot path
    local pids=$(lsof 2>/dev/null | grep "$CHROOT_PATH" | awk '{print $2}' | uniq)
    [ -n "$pids" ] && kill -9 $pids 2>/dev/null

    # Unmount mounts recorded in file
    if [ -f "$MOUNTED_FILE" ]; then
        # Unmount in reverse order
        tac "$MOUNTED_FILE" | while read -r mnt; do
            _execute_in_ns umount -l "$mnt" 2>/dev/null
        done
        rm -f "$MOUNTED_FILE"
    fi

    # Kill Namespace Holder
    if [ -f "$HOLDER_PID_FILE" ]; then
        kill "$(cat "$HOLDER_PID_FILE")" 2>/dev/null
        rm -f "$HOLDER_PID_FILE" "$HOLDER_PID_FILE.flags"
    fi

    android_optimizations --disable
    log "Stopped."
}

enter_chroot() {
    local user="${1:-root}"

    # Check for running Namespace
    if [ ! -f "$HOLDER_PID_FILE" ] || ! kill -0 "$(cat "$HOLDER_PID_FILE")" 2>/dev/null; then
        error "Chroot is not running. Use '$SCRIPT_NAME start' first."
        exit 1
    fi

    # Non-interactive shell detection
    if [ ! -t 1 ]; then
        error "Non-interactive environment detected. Cannot enter shell."
        exit 1
    fi

    log "Entering shell as $user..."
    
    # Alpine typically uses /bin/sh (ash). bash might not be installed.
    local common_exports="export PATH='/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin'; export TERM=xterm-256color"
    local shell_cmd="$common_exports; exec /bin/su - $user"
    
    _execute_in_ns chroot "$CHROOT_PATH" /bin/sh -c "$shell_cmd"
}

backup_chroot() {
    local backup_file="$1"
    [ -z "$backup_file" ] && { error "Usage: backup <path.tar.gz>"; exit 1; }
    
    log "Backing up to $backup_file..."
    stop_chroot
    
    local backup_dir=$(dirname "$backup_file")
    mkdir -p "$backup_dir"
    
    if busybox tar -czf "$backup_file" -C "$CHROOT_PATH" .; then
        log "Backup complete."
    else
        error "Backup failed."
        rm -f "$backup_file"
        exit 1
    fi
}

restore_chroot() {
    local backup_file="$1"
    [ ! -f "$backup_file" ] && { error "File not found: $backup_file"; exit 1; }
    
    log "Restoring from $backup_file..."
    stop_chroot
    
    rm -rf "$CHROOT_PATH"
    mkdir -p "$CHROOT_PATH"
    
    if busybox tar -xzf "$backup_file" -C "$CHROOT_PATH"; then
        log "Restore complete."
    else
        error "Restore failed."
        exit 1
    fi
}

uninstall_chroot() {
    log "Uninstalling..."
    stop_chroot
    
    if [ -d "$CHROOT_PATH" ]; then
        rm -rf "$CHROOT_PATH"
        log "Chroot files removed."
    fi
    
    rm -f "$SCRIPT_DIR/mount.points" "$SCRIPT_DIR/holder.pid" "$SCRIPT_DIR/holder.pid.flags"
}

# --- CLI Handling ---

case "$1" in
    start)
        start_chroot
        ;;
    stop)
        stop_chroot
        ;;
    status)
        if [ -f "$HOLDER_PID_FILE" ] && kill -0 "$(cat "$HOLDER_PID_FILE")" 2>/dev/null; then
            echo "Status: RUNNING (PID: $(cat "$HOLDER_PID_FILE"))"
        else
            echo "Status: STOPPED"
        fi
        ;;
    enter)
        enter_chroot "$2"
        ;;
    run)
        shift
        [ -z "$1" ] && { error "Command required."; exit 1; }
        run_in_chroot "$*"
        ;;
    backup)
        backup_chroot "$2"
        ;;
    restore)
        restore_chroot "$2"
        ;;
    uninstall)
        uninstall_chroot
        ;;
    *)
        echo "Usage: $SCRIPT_NAME {start|stop|status|enter|run <cmd>|backup <file>|restore <file>|uninstall}"
        exit 1
        ;;
esac
