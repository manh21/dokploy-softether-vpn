#!/bin/sh
# entrypoint.sh
# Custom entrypoint wrapper for SoftEtherVPN Docker container.
# Applies iptables forwarding rules before starting the VPN server.
# Override the container CMD in docker-compose:
#   entrypoint: ["/bin/sh", "/entrypoint.sh"]

set -e

echo "[entrypoint] Starting initialization..."

# Enable IP forwarding
echo 1 > /proc/sys/net/ipv4/ip_forward

# === Apply port forwarding rules ===
# Edit these to match your VPN client IPs and services.
# host_port → vpn_client_ip:client_port

iptables -t nat -A PREROUTING -p tcp --dport 8080 -j DNAT --to-destination 10.99.0.10:3000
iptables -t nat -A POSTROUTING -p tcp -d 10.99.0.10 --dport 3000 -j MASQUERADE
iptables -A FORWARD -p tcp -d 10.99.0.10 --dport 3000 -j ACCEPT

iptables -t nat -A PREROUTING -p tcp --dport 8081 -j DNAT --to-destination 10.99.0.11:5432
iptables -t nat -A POSTROUTING -p tcp -d 10.99.0.11 --dport 5432 -j MASQUERADE
iptables -A FORWARD -p tcp -d 10.99.0.11 --dport 5432 -j ACCEPT

echo "[entrypoint] iptables rules applied. Starting VPN server..."

# Start SoftEther VPN server
exec /usr/local/bin/vpnserver execsvc
