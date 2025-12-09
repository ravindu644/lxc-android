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
    gzip && \
    rm -rf /var/cache/apk/*

# Stage 2: Export to scratch for extraction
FROM scratch AS export

# Copy the entire filesystem from the customizer stage
COPY --from=customizer / /
