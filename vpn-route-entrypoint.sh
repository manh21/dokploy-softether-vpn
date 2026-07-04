#!/bin/sh
# vpn-route-entrypoint.sh
# Entrypoint wrapper for DEPENDENT containers that need direct routing
# to VPN clients (Approach B from the guide).
#
# Usage in docker-compose:
#   entrypoint: ["/bin/sh", "/vpn-route-entrypoint.sh"]
#   command: ["/your-real-command", "arg1", "arg2"]
#
# Requires: NET_ADMIN capability in the container.

set -e

VPN_SUBNET="${VPN_SUBNET:-10.99.0.0/24}"
VPN_GATEWAY_HOSTNAME="${VPN_GATEWAY_HOSTNAME:-softether-vpn}"

# Resolve the VPN gateway hostname to an IP
VPN_IP=$(getent hosts "$VPN_GATEWAY_HOSTNAME" | awk '{print $1}')

if [ -n "$VPN_IP" ]; then
    echo "[vpn-route] Adding route: ${VPN_SUBNET} via ${VPN_IP}"
    ip route add "$VPN_SUBNET" via "$VPN_IP" 2>/dev/null || {
        echo "[vpn-route] WARNING: Failed to add route (may already exist or no NET_ADMIN)"
    }
    # Verify
    ip route get "${VPN_SUBNET%.*}.1" 2>/dev/null || true
else
    echo "[vpn-route] ERROR: Could not resolve ${VPN_GATEWAY_HOSTNAME}. Is it on the same Docker network?"
    # Non-fatal — container will still start but VPN clients won't be reachable
fi

echo "[vpn-route] Starting application..."
exec "$@"
