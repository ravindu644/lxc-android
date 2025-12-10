# Find the active internet interface (e.g., wlan0 or rmnet0)
DEFAULT_IFACE=$(ip route get 8.8.8.8 | awk '{for(i=1;i<=NF;i++) if($i=="dev") print $(i+1)}')

# Check if we found an interface
if [ -z "$DEFAULT_IFACE" ]; then
    echo "[ERROR] Could not detect default internet interface."
else
    echo "[INFO] Internet interface detected: $DEFAULT_IFACE"
    # Apply the NAT rule using the LEGACY iptables command
    iptables-legacy -t nat -A POSTROUTING -s 10.0.3.0/24 -o "$DEFAULT_IFACE" -j MASQUERADE
    echo "[INFO] NAT rule applied successfully using iptables-legacy."
fi
