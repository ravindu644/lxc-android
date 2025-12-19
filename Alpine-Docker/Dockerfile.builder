# Dockerfile.builder
# Stage 1: Build minimal Alpine rootfs with LXC
FROM --platform=linux/arm64 alpine:3.10 AS customizer

# Configure Alpine v3.12 repository
RUN echo "http://dl-cdn.alpinelinux.org/alpine/v3.10/main" > /etc/apk/repositories && \
    echo "http://dl-cdn.alpinelinux.org/alpine/v3.10/community" >> /etc/apk/repositories

# Install packages and clean cache in a single layer
RUN apk update && \
    apk add --no-cache \
    bash \
    lxc \
    lxc-templates \
    lxc-download \
    gzip \
    iptables && \
    rm -rf /var/cache/apk/*

# Configure LXC default settings
RUN mkdir -p /etc/lxc && \
    cat > /etc/lxc/default.conf << 'EOF'
lxc.net.0.type = none
lxc.cgroup.devices.allow = c 10:200 rwm
lxc.mount.entry = /dev/net dev/net none bind,create=dir 0 0
lxc.mount.entry = /dev/net/tun dev/net/tun none bind,create=file
EOF

# Set custom environment variables
RUN mkdir -p /etc/profile.d && \
    cat > /etc/profile.d/alpine-custom-env.sh << 'EOF' && \
    chmod +x /etc/profile.d/alpine-custom-env.sh
#!/bin/sh
export DOWNLOAD_KEYSERVER="hkp://keyserver.ubuntu.com"
export PS1="\[\033[1;94m\]\u@\h\[\033[0m\]:\[\033[1;94m\]\w\[\033[0m\]\$ "
EOF

# Stage 2: Export to scratch for extraction
FROM scratch AS export

# Copy the entire filesystem from the customizer stage
COPY --from=customizer / /
