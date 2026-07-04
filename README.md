<!-- omit in toc -->
<p align="center">
  <img src="https://img.shields.io/badge/Dokploy-compose-blue?logo=docker" alt="Dokploy">
  <img src="https://img.shields.io/badge/SoftEtherVPN-stable-green?logo=wireguard" alt="SoftEtherVPN">
  <img src="https://img.shields.io/github/license/manh21/dokploy-softether-vpn" alt="License">
</p>

# SoftEtherVPN on Dokploy — Cross-Project VPN Networking

Deploy [SoftEtherVPN](https://github.com/SoftEtherVPN/SoftetherVPN-docker) as a Dokploy Docker Compose service, then enable **bidirectional communication** between VPN clients and services across separate Dokploy projects.

**What you'll get:**
- VPN server running inside Dokploy (Alpine-based, ~15 MB image)
- VPN clients can reach your Dokploy services via `http://10.99.0.1:8080`
- Docker containers in other projects can reach VPN clients behind the SecureNAT
- SoftEther native protocol, OpenVPN, L2TP/IPsec — all supported

## Table of Contents

- [Architecture](#architecture)
- [Prerequisites](#prerequisites)
- [Step 1 — Create the shared Docker network](#step-1--create-the-shared-docker-network)
- [Step 2 — Deploy the VPN server project](#step-2--deploy-the-vpn-server-project)
- [Step 3 — Initial VPN configuration](#step-3--initial-vpn-configuration)
- [Step 4 — Make VPN clients reachable from other projects](#step-4--make-vpn-clients-reachable-from-other-projects)
- [Step 5 — Connect other Dokploy projects](#step-5--connect-other-dokploy-projects)
- [Step 5b — Connect from VPN clients to Dokploy projects](#step-5b--connect-from-vpn-clients-to-dokploy-projects)
- [Step 6 — Verification](#step-6--verification)
- [Port reference](#port-reference)
- [Connecting VPN clients](#connecting-vpn-clients)
- [Troubleshooting](#troubleshooting)
- [Appendices](#appendices)

## Overview

[SoftEtherVPN](https://github.com/SoftEtherVPN/SoftetherVPN-docker) is an ultra-lightweight (~15 MB) multi-protocol VPN server built on Alpine Linux. It supports SoftEther native protocol, OpenVPN, L2TP/IPsec, and SSTP.

This guide covers:

- Deploying the VPN server as a Dokploy Docker Compose project
- Configuring SecureNAT for virtual DHCP
- Making VPN clients reachable from **other** Dokploy projects (cross-project networking)
- Two routing strategies: port forwarding (simple) and direct routing (full bidirectional)

## Architecture

```
┌──────────────────────────────────────────────────────────┐
│  Dokploy Host                                            │
│                                                          │
│  shared-vpn (Docker network, external: true)             │
│  ┌────────────────────────────────────────────────────┐  │
│  │                                                    │  │
│  │  ┌──────────────┐     ┌──────────────────┐         │  │
│  │  │ softether-vpn │────▶│ VPN Client A     │         │  │
│  │  │  (server)    │     │  10.99.0.10      │         │  │
│  │  │              │◀────│  (laptop/server)  │         │  │
│  │  │  SecureNAT   │     └──────────────────┘         │  │
│  │  │  10.99.0.1   │                                  │  │
│  │  │              │     ┌──────────────────┐         │  │
│  │  │              │────▶│ VPN Client B     │         │  │
│  │  │              │◀────│  10.99.0.11      │         │  │
│  │  └──────┬───────┘     └──────────────────┘         │  │
│  │         │ port 8080 → 10.99.0.10:3000              │  │
│  │         │                                          │  │
│  │  ┌──────┴───────┐    ┌──────────────────┐         │  │
│  │  │ Project A    │    │ Project B        │         │  │
│  │  │ web-app      │    │ api-service      │         │  │
│  │  │              │    │                  │         │  │
│  │  │ curl vpn:8080│    │ curl vpn:8081    │         │  │
│  │  └──────────────┘    └──────────────────┘         │  │
│  │                                                    │  │
│  └────────────────────────────────────────────────────┘  │
└──────────────────────────────────────────────────────────┘
```

## Prerequisites

- Dokploy installed and running (official or manual installation)
- SSH access to the Dokploy host
- A publicly accessible host with open ports (see [port reference](#port-reference))

---

## Step 1 — Create the shared Docker network

SSH into the Dokploy host and create a network that all cross-communicating projects will join:

```bash
docker network create shared-vpn
```

Verify:

```bash
docker network ls | grep shared-vpn
```

This network will be referenced as `external: true` in every project's compose file.

---

## Step 2 — Deploy the VPN server project

In the Dokploy dashboard:

1. Create a new project named **`vpn-server`**
2. Add an **Application** (Docker Compose type)

### Compose file

```yaml
version: '3'

services:
  softether:
    image: softethervpn/vpnserver:stable
    container_name: softether-vpn
    cap_add:
      - NET_ADMIN
    restart: always
    ports:
      - 8443:443/tcp     # SoftEther SSTP + management
      - 992:992/tcp       # Alternative HTTPS tunneling
      - 5555:5555/tcp     # Alternative HTTPS tunneling
      - 1194:1194/udp     # OpenVPN
      - 500:500/udp       # IPsec IKEv2
      - 4500:4500/udp     # IPsec NAT traversal
      - 1701:1701/udp     # L2TP
    volumes:
      - softether_data:/var/lib/softether
      - softether_log:/var/log/softether
      - ./iptables-setup.sh:/docker-entrypoint-init.d/iptables.sh:ro
    networks:
      - shared-vpn
    sysctls:
      - net.ipv4.ip_forward=1

volumes:
  softether_data:
  softether_log:

networks:
  shared-vpn:
    external: true
```

> **Why port 8443→443?** Dokploy's Traefik reverse proxy already binds host port 443. Mapping the VPN server's internal port 443 to host port 8443 avoids the conflict. SoftEther clients should connect to `your-host:8443`.

### Dokploy settings

In the project's **Utilities** tab:

- **Turn OFF "Isolated Deployments"** — if left on, Dokploy wraps the compose in its own isolated network, and the `shared-vpn` external network may not attach properly.

Deploy the project.

---

## Step 3 — Initial VPN configuration

After the container is running, SSH into the host and launch `vpncmd`:

```bash
docker exec -it softether-vpn vpncmd localhost /server
```

### Set admin password

```
ServerPasswordSet
```

Enter and confirm a strong password.

### Create a virtual hub

Hubs are isolated virtual network segments. Create one for your VPN users:

```
HubCreate VPN /PASSWORD:yourhubpassword
```

### Enable SecureNAT

SecureNAT is SoftEther's built-in virtual NAT + DHCP server. It assigns IPs to VPN clients and provides internet access.

```
Hub VPN
SecureNatEnable
```

### Configure DHCP

Pick a private subnet for VPN clients (example: `10.99.0.0/24`):

```
DhcpSet /START:10.99.0.10 /END:10.99.0.200 /MASK:255.255.255.0 /EXPIRE:7200 /GW:10.99.0.1 /DNS:10.99.0.1
```

Verify:

```
DhcpGet
SecureNatStatusGet
```

Expected output shows Virtual MAC address, IP `10.99.0.1/24`, and NAT enabled.

### Create a test user

```
UserCreate alice /GROUP:none /REALNAME:none /NOTE:none
UserPasswordSet alice /PASSWORD:strongpassword
```

### Exit

```
Exit
```

---

## Step 4 — Make VPN clients reachable from other projects

VPN clients sit behind the SecureNAT on the `10.99.0.0/24` subnet. Other Docker containers on the `shared-vpn` network can reach `softether-vpn` (the container) but **not** the VPN clients directly. You need an additional routing layer.

Two approaches:

| Approach | Complexity | Use case |
|----------|-----------|----------|
| A. Port forwarding (iptables DNAT) | Low | Specific services on VPN clients need to be exposed |
| B. Direct routing | High | Full bidirectional IP connectivity to all VPN clients |

### Approach A — Port forwarding via iptables DNAT (recommended)

This is the simpler, more portable approach. The VPN server container acts as a reverse proxy — other containers hit `softether-vpn:<port>` and get forwarded to the VPN client.

#### Inside the container, run:

```bash
docker exec -it softether-vpn sh
```

Enable forwarding and add DNAT rules. Example: forward port `8080` on the VPN server to a web service on VPN client `10.99.0.10:3000`:

```sh
# Enable IP forwarding (also set via sysctls in compose)
echo 1 > /proc/sys/net/ipv4/ip_forward

# DNAT: incoming port 8080 → VPN client 10.99.0.10:3000
iptables -t nat -A PREROUTING -p tcp --dport 8080 -j DNAT --to-destination 10.99.0.10:3000

# MASQUERADE the reply so it routes back correctly
iptables -t nat -A POSTROUTING -p tcp -d 10.99.0.10 --dport 3000 -j MASQUERADE

# Allow the forward
iptables -A FORWARD -p tcp -d 10.99.0.10 --dport 3000 -j ACCEPT
```

> Repeat for each service you want to expose. Use distinct host-side ports (8080, 8081, 8082, ...).

#### Making rules persistent

Create `iptables-setup.sh` and mount it into the container so rules survive restarts:

Create a file mounted at `/docker-entrypoint-init.d/iptables.sh` in the compose (already included above). The file:

```sh
#!/bin/sh
# iptables-setup.sh — mount at /docker-entrypoint-init.d/iptables.sh

echo 1 > /proc/sys/net/ipv4/ip_forward

# Flush existing NAT rules (optional, be careful in prod)
# iptables -t nat -F PREROUTING

# === Forwarding rules ===
# Service A on VPN client 10.99.0.10 → exposed as softether-vpn:8080
iptables -t nat -A PREROUTING -p tcp --dport 8080 -j DNAT --to-destination 10.99.0.10:3000
iptables -t nat -A POSTROUTING -p tcp -d 10.99.0.10 --dport 3000 -j MASQUERADE
iptables -A FORWARD -p tcp -d 10.99.0.10 --dport 3000 -j ACCEPT

# Service B on VPN client 10.99.0.11 → exposed as softether-vpn:8081
iptables -t nat -A PREROUTING -p tcp --dport 8081 -j DNAT --to-destination 10.99.0.11:5432
iptables -t nat -A POSTROUTING -p tcp -d 10.99.0.11 --dport 5432 -j MASQUERADE
iptables -A FORWARD -p tcp -d 10.99.0.11 --dport 5432 -j ACCEPT

echo "iptables VPN forwarding rules applied"
```

Make it executable on the host:

```bash
chmod +x /path/to/iptables-setup.sh
```

> **Note:** The SoftEtherVPN Docker image does not have a built-in init.d hook. You'll need a custom entrypoint wrapper or run the script via `command:` in compose. See [appendices](#appendix-a--custom-entrypoint-for-persistent-iptables).

### Approach B — Direct routing (full subnet access)

If you need other containers to reach *any* VPN client IP directly without per-port forwarding, add a static route to each dependent container.

#### In each dependent project's compose:

```yaml
services:
  myapp:
    # ...
    cap_add:
      - NET_ADMIN                     # required for ip route
    command: >
      sh -c "ip route add 10.99.0.0/24 via softether-vpn 2>/dev/null || true;
             exec /your-real-entrypoint"
    networks:
      - shared-vpn
```

If `softether-vpn` resolves to `172.18.0.2` (check with `docker inspect softether-vpn | grep IPAddress`), the route becomes: all traffic to `10.99.0.0/24` goes through the VPN server container, which forwards it into the SecureNAT.

**Caveats:**

- Every dependent container needs `NET_ADMIN` capability — a security consideration.
- The route must survive container restarts (hence the `command` wrapper).
- Docker DNS resolves `softether-vpn` to an IP; `ip route` needs the numeric IP. The wrapper above uses the hostname, but `ip route add` requires an IP. Use a startup script that resolves it:

```sh
#!/bin/sh
VPN_IP=$(getent hosts softether-vpn | awk '{print $1}')
if [ -n "$VPN_IP" ]; then
  ip route add 10.99.0.0/24 via "$VPN_IP" 2>/dev/null || true
fi
exec /your-real-entrypoint
```

---

## Step 5 — Connect other Dokploy projects

For every project that needs VPN access, add the shared network to its compose:

```yaml
version: '3'

services:
  web-app:
    image: your-app:latest
    networks:
      - shared-vpn
    environment:
      # Using Approach A (port forwarding):
      # VPN client A's service exposed as softether-vpn:8080
      VPN_SERVICE_URL: http://softether-vpn:8080
      VPN_DATABASE_URL: postgresql://softether-vpn:8081/db

networks:
  shared-vpn:
    external: true
```

**Dokploy settings for these projects:**

- Turn OFF "Isolated Deployments" unless you explicitly add `shared-vpn` alongside the auto-created isolated network.

---

## Step 5b — Connect from VPN clients to Dokploy projects

The previous sections cover **Docker → VPN client** direction. Now the reverse: how a laptop connected as a VPN client reaches services inside your Dokploy projects.

### Traffic path

```
Your laptop (VPN client, e.g. 10.99.0.10)
  → VPN tunnel (SSTP/OpenVPN/etc.)
  → SoftEther server container
  → SecureNAT (SNAT — rewrites source IP to VPN server's Docker IP)
  → shared-vpn Docker network
  → web-app container (resolved via Docker DNS)
```

SecureNAT is already doing source-NAT for outbound traffic, so VPN clients can initiate connections to Docker containers **without extra rules** — the reply packets are NAT'd back automatically. The question is only what IP/hostname to target from the VPN client side.

### Option A — Direct Docker IP (quick dev access)

Find the target container's IP on `shared-vpn`:

```bash
docker inspect web-app | jq -r '.[].NetworkSettings.Networks["shared-vpn"].IPAddress'
# → 172.18.0.3
```

From your VPN client browser:
```
http://172.18.0.3:3000
```

Works instantly. **Downside:** Docker IPs change on every redeploy. Good for dev/debugging, bad for permanent configs.

### Option B — Port forwarding on the VPN gateway (stable)

Use the SecureNAT gateway IP `10.99.0.1`. This is static — all VPN clients see it as their default route. Add iptables DNAT rules on the VPN server so hitting `10.99.0.1:<host_port>` forwards to the target Docker container:

```bash
docker exec softether-vpn sh -c "
  # Project A: 10.99.0.1:8080 → web-app container on port 3000
  iptables -t nat -A PREROUTING -p tcp --dport 8080 -j DNAT --to-destination web-app:3000
  iptables -t nat -A POSTROUTING -p tcp -d web-app --dport 3000 -j MASQUERADE
  iptables -A FORWARD -p tcp -d web-app --dport 3000 -j ACCEPT

  # Project B: 10.99.0.1:8081 → api container on port 8080
  iptables -t nat -A PREROUTING -p tcp --dport 8081 -j DNAT --to-destination api-service:8080
  iptables -t nat -A POSTROUTING -p tcp -d api-service --dport 8080 -j MASQUERADE
  iptables -A FORWARD -p tcp -d api-service --dport 8080 -j ACCEPT
"
```

> Notice `--to-destination web-app:3000` uses Docker DNS names instead of IPs — these won't change across redeploys as long as both containers share the `shared-vpn` network.

Then from any VPN client:
```
http://10.99.0.1:8080    → Project A (web-app)
http://10.99.0.1:8081    → Project B (api-service)
```

The gateway IP `10.99.0.1` is set in your SecureNAT DHCP config and never changes.

### Option C — Reverse proxy (production-ready)

Add a lightweight reverse proxy (Caddy or nginx) as a Dokploy compose project on the `shared-vpn` network. This gives you path-based routing and TLS without touching iptables.

**Compose for the proxy project:**

```yaml
version: '3'

services:
  proxy:
    image: caddy:alpine
    container_name: vpn-proxy
    restart: always
    networks:
      shared-vpn:
        aliases:
          - proxy.vpn.internal
    volumes:
      - ./Caddyfile:/etc/caddy/Caddyfile:ro

networks:
  shared-vpn:
    external: true
```

**Caddyfile:**

```
# Internal reverse proxy for VPN clients
# Reach it from VPN: http://10.99.0.1:8080/project-a/

:80 {
    # Project A — web app
    handle /project-a/* {
        uri strip_prefix /project-a
        reverse_proxy web-app:3000
    }

    # Project B — API
    handle /project-b/* {
        uri strip_prefix /project-b
        reverse_proxy api-service:8080
    }

    # Default: health check
    respond "vpn-proxy OK" 200
}
```

Deploy this as a separate Dokploy project (also on `shared-vpn`). Then add one iptables rule to forward a port on the VPN gateway to the proxy:

```bash
docker exec softether-vpn sh -c "
  iptables -t nat -A PREROUTING -p tcp --dport 8080 -j DNAT --to-destination vpn-proxy:80
  iptables -t nat -A POSTROUTING -p tcp -d vpn-proxy --dport 80 -j MASQUERADE
  iptables -A FORWARD -p tcp -d vpn-proxy --dport 80 -j ACCEPT
"
```

VPN clients now use:
```
http://10.99.0.1:8080/project-a/login
http://10.99.0.1:8080/project-b/api/users
```

> This scales cleanly — add new projects by updating the Caddyfile and redeploying the proxy. No more iptables rules needed.

### Full bidirectional summary

| Direction | Method | Target from... |
|-----------|--------|---------------|
| Docker → VPN client | iptables DNAT on VPN server (`softether-vpn:8080 → 10.99.0.10:3000`) | Other Dokploy containers |
| VPN client → Docker | SecureNAT already handles this. Use gateway `10.99.0.1` with port forwarding or reverse proxy | VPN-connected laptop |

---

## Step 6 — Verification

### From the VPN server, can I reach a VPN client?

```bash
docker exec softether-vpn ping 10.99.0.10
```

### From another container on shared-vpn, can I reach the VPN server?

```bash
docker exec <your-container> ping softether-vpn
```

### Port forwarding working?

```bash
# From a container on the shared network:
docker exec <your-container> curl http://softether-vpn:8080
```

### Check SecureNAT status

```bash
docker exec softether-vpn vpncmd localhost /server /password:yourpass /cmd Hub VPN /cmd NatGet
```

### Check connected VPN clients

```bash
docker exec softether-vpn vpncmd localhost /server /password:yourpass /cmd Hub VPN /cmd SessionList
```

---

## Port reference

Open these on your cloud firewall / VPS provider:

| Port  | Protocol | Purpose                      | Required?                         |
|-------|----------|------------------------------|-----------------------------------|
| 8443  | TCP      | SoftEther SSTP + management  | ✅ Yes (native clients)          |
| 992   | TCP      | Alternative HTTPS tunneling  | Optional (fallback)              |
| 5555  | TCP      | Alternative HTTPS tunneling  | Optional (fallback)              |
| 1194  | UDP      | OpenVPN                       | Only if using OpenVPN clients    |
| 500   | UDP      | IPsec IKEv2                   | Only if using IPsec/L2TP         |
| 4500  | UDP      | IPsec NAT traversal           | Only if using IPsec/L2TP         |
| 1701  | UDP      | L2TP                          | Only if using IPsec/L2TP         |

At minimum, open **8443/TCP** for SoftEther native clients. Add others only if you need those protocols.

---

## Connecting VPN clients

### SoftEther native client

1. Install [SoftEther VPN Client](https://www.softether.org/5-download) on the client machine
2. Add a new VPN connection:
   - Hostname: `your-server-ip`
   - Port: `8443`
   - Virtual Hub: `VPN`
   - Username: `alice`
   - Password: `strongpassword`

### OpenVPN client

You need to generate an OpenVPN config from the server first:

```bash
# Inside the container
docker exec -it softether-vpn vpncmd localhost /server /password:yourpass

Hub VPN
OpenVpnMakeConfig /PATH:/var/lib/softether/openvpn_config.zip
```

Then copy the zip to your client and import the `.ovpn` file.

---

## Troubleshooting

### VPN clients can't reach the internet

Verify SecureNAT is enabled and has a proper DHCP config:

```bash
docker exec softether-vpn vpncmd localhost /server /password:yourpass /cmd Hub VPN /cmd SecureNatStatusGet
```

If disabled: `SecureNatEnable`

### Port forwarding not working

Check iptables rules inside the container:

```bash
docker exec softether-vpn iptables -t nat -L PREROUTING -n -v
docker exec softether-vpn iptables -L FORWARD -n -v
```

Verify IP forwarding is on:

```bash
docker exec softether-vpn sysctl net.ipv4.ip_forward
# Should output: net.ipv4.ip_forward = 1
```

### Other projects can't resolve `softether-vpn`

Ensure both containers are on the `shared-vpn` network:

```bash
docker inspect <your-container> | jq '.[0].NetworkSettings.Networks'
# Should include "shared-vpn"
```

### "Isolated Deployments" interference

If Dokploy isolates the project, the external network may not attach. Check:

```bash
docker inspect softether-vpn | jq '.[0].NetworkSettings.Networks | keys'
```

If `shared-vpn` is missing, turn off "Isolated Deployments" and redeploy.

### IPsec/L2TP not working

The container needs the `af_key` kernel module loaded on the host:

```bash
modprobe af_key
```

Consider adding `SYS_MODULE` capability and mounting `/lib/modules`.

---

## Appendices

### Appendix A — Custom entrypoint for persistent iptables

If the SoftEther image doesn't process init scripts, wrap the CMD with a custom entrypoint. Create `entrypoint.sh`:

```sh
#!/bin/sh
# entrypoint.sh — apply iptables rules then start VPN server

# Apply iptables rules
echo 1 > /proc/sys/net/ipv4/ip_forward

iptables -t nat -A PREROUTING -p tcp --dport 8080 -j DNAT --to-destination 10.99.0.10:3000
iptables -t nat -A POSTROUTING -p tcp -d 10.99.0.10 --dport 3000 -j MASQUERADE
iptables -A FORWARD -p tcp -d 10.99.0.10 --dport 3000 -j ACCEPT

# Start the real VPN server
exec /usr/local/bin/vpnserver execsvc
```

Then override the compose:

```yaml
services:
  softether:
    # ...
    volumes:
      - ./entrypoint.sh:/entrypoint.sh:ro
    entrypoint: ["/bin/sh", "/entrypoint.sh"]
```

### Appendix B — Multi-hub setup

You can create multiple virtual hubs for different teams/projects, each with its own SecureNAT and subnet:

```
HubCreate TEAM-A /PASSWORD:pass-a
Hub TEAM-A
SecureNatEnable
DhcpSet /START:10.99.1.10 /END:10.99.1.200 /MASK:255.255.255.0 /EXPIRE:7200 /GW:10.99.1.1 /DNS:10.99.1.1

HubCreate TEAM-B /PASSWORD:pass-b
Hub TEAM-B
SecureNatEnable
DhcpSet /START:10.99.2.10 /END:10.99.2.200 /MASK:255.255.255.0 /EXPIRE:7200 /GW:10.99.2.1 /DNS:10.99.2.1
```

Each hub's clients are isolated from each other by default. To bridge hubs, use a Layer-3 switch via `vpncmd`.

### Appendix C — Dokploy single-app (non-compose) projects

If some of your projects are **single-app deployments** (not Compose), they automatically sit on the `dokploy` default network — **not** `shared-vpn`. To connect them:

1. Convert them to Compose (recommended — add the `shared-vpn` external network)
2. Or manually attach them to `shared-vpn` after deployment:
   ```bash
   docker network connect shared-vpn <container-name>
   ```
   But this won't survive redeploys.

---

## References

- [SoftEtherVPN Docker repository](https://github.com/SoftEtherVPN/SoftetherVPN-docker)
- [SoftEther VPN manual](https://www.softether.org/4-docs/1-manual)
- [SoftEther port reference](https://www.softether.org/4-docs/1-manual/1/1.6)
- [Dokploy networking discussions](https://github.com/Dokploy/dokploy/discussions/2945)
- [Dokploy Docker Compose utilities](https://docs.dokploy.com/docs/core/docker-compose/utilities)
- [Dokploy cross-project networking](https://github.com/Dokploy/dokploy/discussions/4258)
