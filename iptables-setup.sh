#!/bin/sh
# iptables-setup.sh
# Apply DNAT port forwarding rules to expose VPN client services
# Mount this file at /docker-entrypoint-init.d/iptables.sh
# or call it from a custom entrypoint wrapper.
#
# Edit the forwarding table below to match your VPN client IPs and ports.

set -e

# Enable IP forwarding (already set via sysctls in compose, but safe to repeat)
echo 1 > /proc/sys/net/ipv4/ip_forward

echo "[iptables-setup] Applying VPN forwarding rules..."

# ---------------------------------------------------------------------------
# FORWARDING TABLE
# Format: host_port → vpn_client_ip:client_port
# ---------------------------------------------------------------------------

# Service A: web app on VPN client 10.99.0.10 port 3000 → exposed as :8080
iptables -t nat -A PREROUTING -p tcp --dport 8080 -j DNAT --to-destination 10.99.0.10:3000
iptables -t nat -A POSTROUTING -p tcp -d 10.99.0.10 --dport 3000 -j MASQUERADE
iptables -A FORWARD -p tcp -d 10.99.0.10 --dport 3000 -j ACCEPT

# Service B: PostgreSQL on VPN client 10.99.0.11 → exposed as :8081
iptables -t nat -A PREROUTING -p tcp --dport 8081 -j DNAT --to-destination 10.99.0.11:5432
iptables -t nat -A POSTROUTING -p tcp -d 10.99.0.11 --dport 5432 -j MASQUERADE
iptables -A FORWARD -p tcp -d 10.99.0.11 --dport 5432 -j ACCEPT

# ---------------------------------------------------------------------------
# Add more rules above as needed.
# Always use distinct host-side ports (8080, 8081, 8082, ...).
# ---------------------------------------------------------------------------

echo "[iptables-setup] Done."
