export ZIPFILE="$ZIPFILE"
export TMPDIR="$TMPDIR"

# source our functions
unzip -o "$ZIPFILE" 'META-INF/*' -d $TMPDIR >&2
. "$TMPDIR/META-INF/com/google/android/util_functions.sh"

SKIPMOUNT=false
PROPFILE=false
POSTFSDATA=false
LATESTARTSERVICE=true

print_modname() {
    echo "-   LXC on Android   - "
    echo "    by @ravindu644     "
    echo " "
}

on_install() {
    # Check required kernel features first (before touching anything)
    if ! check_devtmpfs; then
        exit 1
    fi

    if ! check_cgroup_devices; then
        exit 1
    fi

    if ! check_pid_namespace; then
        exit 1
    fi

    # Detect root method and show warnings
    detect_root

    # Extract web interface files
    unzip -oj "$ZIPFILE" 'service.sh' -d $MODPATH >&2

    # Extract and setup Alpine rootfs for LXC
    setup_rootfs
    extract_rootfs && \
        echo -e "\n- Use command 'lxcmgr' to manage LXC\n"

    # Clear package cache to avoid conflicts
    rm -rf /data/system/package_cache/*
}

set_permissions() {
    # Set permissions for module files
    set_perm_recursive $MODPATH 0 0 0755 0644

    # Set permissions for LXC management scripts
    set_perm "$MODPATH/system/bin/lxcmgr" 0 0 0755

    # Set permissions for LXC wrapper scripts
    for script in lxc-attach lxc-autostart lxc-cgroup lxc-checkconfig \
                  lxc-checkpoint lxc-config lxc-console lxc-copy lxc-create lxc-destroy \
                  lxc-device lxc-execute lxc-freeze lxc-info lxc-ls lxc-monitor \
                  lxc-snapshot lxc-start lxc-stop lxc-top lxc-unfreeze lxc-unshare \
                  lxc-update-config lxc-usernsexec lxc-wait; do
        set_perm "$MODPATH/system/bin/$script" 0 0 0755
    done

    # Set permissions for module service script
    set_perm "$MODPATH/service.sh" 0 0 0755
}
