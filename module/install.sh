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

    # Set permissions for module service script
    set_perm "$MODPATH/service.sh" 0 0 0755
}
