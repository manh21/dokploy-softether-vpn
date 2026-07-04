# iptables-setup-genieacs.sh
# Add these rules to your existing VPN server iptables script
# to forward GenieACS services through the VPN gateway (10.99.0.1).
#
# Run on the VPN server container:
#   docker exec -it softether-vpn sh -c "$(cat iptables-setup-genieacs.sh)"

set -e

echo "[iptables-genieacs] Applying GenieACS forwarding rules..."

# GenieACS built-in UI → VPN clients access at http://10.99.0.1:3000
iptables -t nat -A PREROUTING -p tcp --dport 3000 -j DNAT --to-destination genieacs:3000
iptables -t nat -A POSTROUTING -p tcp -d genieacs --dport 3000 -j MASQUERADE
iptables -A FORWARD -p tcp -d genieacs --dport 3000 -j ACCEPT

# GenieACS Panel API → VPN clients access at http://10.99.0.1:1997
iptables -t nat -A PREROUTING -p tcp --dport 1997 -j DNAT --to-destination genieacs-panel:1997
iptables -t nat -A POSTROUTING -p tcp -d genieacs-panel --dport 1997 -j MASQUERADE
iptables -A FORWARD -p tcp -d genieacs-panel --dport 1997 -j ACCEPT

# GenieACS NBI REST API → other projects access at http://softether-vpn:7557
iptables -t nat -A PREROUTING -p tcp --dport 7557 -j DNAT --to-destination genieacs:7557
iptables -t nat -A POSTROUTING -p tcp -d genieacs --dport 7557 -j MASQUERADE
iptables -A FORWARD -p tcp -d genieacs --dport 7557 -j ACCEPT

# GenieACS CWMP → CPE devices behind VPN connect at http://10.99.0.1:7547
iptables -t nat -A PREROUTING -p tcp --dport 7547 -j DNAT --to-destination genieacs:7547
iptables -t nat -A POSTROUTING -p tcp -d genieacs --dport 7547 -j MASQUERADE
iptables -A FORWARD -p tcp -d genieacs --dport 7547 -j ACCEPT

echo "[iptables-genieacs] Done. GenieACS accessible via VPN gateway at 10.99.0.1"
