# run this inside the container
# Edit resolved config
mkdir -p /etc/systemd/resolved.conf.d/
cat > /etc/systemd/resolved.conf.d/dns.conf << EOF
[Resolve]
DNS=8.8.8.8 8.8.4.4
FallbackDNS=1.1.1.1
EOF

# Restart resolved
systemctl restart systemd-resolved

# Link resolv.conf properly
ln -sf /run/systemd/resolve/resolv.conf /etc/resolv.conf
