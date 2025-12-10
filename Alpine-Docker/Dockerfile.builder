# Dockerfile.builder
# Stage 1: Build minimal Alpine rootfs with LXC
FROM --platform=linux/arm64 alpine:latest AS customizer

# Install packages and clean cache in a single layer
RUN apk update && \
    apk add --no-cache \
    bash \
    lxc \
    lxc-templates \
    lxc-download \
    gzip \
    iptables-legacy && \
    rm -rf /var/cache/apk/*

# Configure LXC default settings
RUN mkdir -p /etc/lxc && \
    cat > /etc/lxc/default.conf << 'EOF'
lxc.net.0.type = none
lxc.namespace.share.net = /proc/1/ns/net
lxc.cgroup.devices.allow = c 10:200 rwm
lxc.mount.entry = /dev/net dev/net none bind,create=dir 0 0
lxc.mount.entry = /dev/net/tun dev/net/tun none bind,create=file
EOF

# Stage 2: Export to scratch for extraction
FROM scratch AS export

# Copy the entire filesystem from the customizer stage
COPY --from=customizer / /
