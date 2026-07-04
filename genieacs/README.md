<!-- omit in toc -->
<p align="center">
  <img src="https://img.shields.io/badge/Dokploy-compose-blue?logo=docker" alt="Dokploy">
  <img src="https://img.shields.io/badge/GenieACS-1.2.16-green?logo=tr069" alt="GenieACS">
  <img src="https://img.shields.io/badge/SoftEtherVPN-connected-purple" alt="SoftEtherVPN">
  <img src="https://img.shields.io/github/license/manh21/dokploy-softether-vpn" alt="License">
</p>

# GenieACS on Dokploy — TR-069 ACS with VPN Connectivity

Deploy [GenieACS](https://genieacs.com/) (TR-069 Auto Configuration Server) in Dokploy, connected to your SoftEtherVPN network for bidirectional communication with CPE devices, VPN clients, and other Dokploy projects.

**What you'll get:**
- GenieACS core (CWMP, NBI, FS, UI) via `drumsergio/genieacs:1.2.16.0`
- MongoDB backend for device data and configuration
- [GenieACS Panel API](https://hub.docker.com/r/solusidigitalnet/genieacspanelapi) — web-based ONT/CPE management UI
- All services on the `shared-vpn` Docker network — reachable from VPN clients and other Dokploy projects

## Table of Contents

- [Architecture](#architecture)
- [Prerequisites](#prerequisites)
- [Step 1 — Deploy the GenieACS stack](#step-1--deploy-the-genieacs-stack)
- [Step 2 — First-time GenieACS setup](#step-2--first-time-genieacs-setup)
- [Step 3 — Verify the GenieACS Panel API](#step-3--verify-the-genieacs-panel-api)
- [Step 4 — Connect to VPN network](#step-4--connect-to-vpn-network)
- [Step 5 — Full connectivity matrix](#step-5--full-connectivity-matrix)
- [Port reference](#port-reference)
- [Troubleshooting](#troubleshooting)

---

## Architecture

```
┌─────────────────────────────────────────────────────────────────────────┐
│  Dokploy Host                                                           │
│                                                                         │
│  shared-vpn (Docker network)                                            │
│  ┌─────────────────────────────────────────────────────────────────┐    │
│  │                                                                  │    │
│  │  ┌─────────────────────┐     ┌────────────────┐                  │    │
│  │  │ softether-vpn       │     │ genieacs-panel │  :1997 (Web UI)  │    │
│  │  │ SecureNAT: 10.99.0.1│     │ (solusidigital) │                  │    │
│  │  │                     │     │ → genieacs:7557 │                  │    │
│  │  └─────────────────────┘     └────────────────┘                  │    │
│  │                                                                  │    │
│  │  ┌──────────────────────────────────────────┐                    │    │
│  │  │ genieacs (drumsergio/genieacs)            │                    │    │
│  │  │  :7547  CWMP  (TR-069 device connections) │                    │    │
│  │  │  :7557  NBI   (REST API)                  │                    │    │
│  │  │  :7567  FS    (File server for firmware)   │                    │    │
│  │  │  :3000  UI    (Built-in web interface)     │                    │    │
│  │  └──────────────┬───────────────────────────┘                    │    │
│  │                 │                                                │    │
│  │  ┌──────────────┴────┐                                           │    │
│  │  │ mongo-genieacs     │                                           │    │
│  │  │ MongoDB :27017     │                                           │    │
│  │  └────────────────────┘                                           │    │
│  │                                                                  │    │
│  │  ┌──────────────┐    ┌──────────────┐    ┌──────────────────┐    │    │
│  │  │ Project A    │    │ Project B    │    │ CPE Devices      │    │    │
│  │  │ web-app      │    │ api-service  │    │ (via VPN)        │    │    │
│  │  └──────────────┘    └──────────────┘    └──────────────────┘    │    │
│  └─────────────────────────────────────────────────────────────────┘    │
└─────────────────────────────────────────────────────────────────────────┘
```

### Service roles

| Service | Container | Port | Purpose |
|---------|-----------|------|---------|
| **MongoDB** | `mongo-genieacs` | 27017 | Device/configuration database |
| **GenieACS** | `genieacs` | 7547 | CWMP — CPE devices connect here (TR-069) |
| **GenieACS** | `genieacs` | 7557 | NBI — REST API for management |
| **GenieACS** | `genieacs` | 7567 | FS — File server (firmware, config files) |
| **GenieACS** | `genieacs` | 3000 | UI — Built-in web interface |
| **Panel API** | `genieacs-panel` | 1997 | Management web UI (connects to NBI) |

---

## Prerequisites

- Dokploy installed and running
- The `shared-vpn` Docker network already created (see [dokploy-softether-vpn guide](https://github.com/manh21/dokploy-softether-vpn#step-1--create-the-shared-docker-network))
- SoftEtherVPN server deployed (optional, but needed for VPN connectivity)

---

## Step 1 — Deploy the GenieACS stack

In the Dokploy dashboard:

1. Create a new project named **`genieacs`**
2. Add an **Application** (Docker Compose type)

### Compose file

```yaml
version: '3.8'

services:
  ### MongoDB — GenieACS database ###
  mongo:
    image: mongo:8.0
    container_name: mongo-genieacs
    restart: unless-stopped
    environment:
      MONGO_DATA_DIR: /data/db
      MONGO_LOG_DIR: /var/log/mongodb
    volumes:
      - mongo_db:/data/db
      - mongo_configdb:/data/configdb
    expose:
      - "27017"
    networks:
      - shared-vpn
    healthcheck:
      test: ["CMD", "mongosh", "--eval", "db.adminCommand('ping')"]
      interval: 10s
      timeout: 5s
      retries: 5
      start_period: 40s

  ### GenieACS core — all 4 services in one container ###
  genieacs:
    depends_on:
      mongo:
        condition: service_healthy
    image: drumsergio/genieacs:1.2.16.0
    container_name: genieacs
    restart: unless-stopped
    environment:
      GENIEACS_MONGODB_CONNECTION_URL: mongodb://mongo/genieacs?authSource=admin
      GENIEACS_UI_JWT_SECRET: changeme-to-a-random-string
      GENIEACS_CWMP_ACCESS_LOG_FILE: /var/log/genieacs/genieacs-cwmp-access.log
      GENIEACS_NBI_ACCESS_LOG_FILE: /var/log/genieacs/genieacs-nbi-access.log
      GENIEACS_FS_ACCESS_LOG_FILE: /var/log/genieacs/genieacs-fs-access.log
      GENIEACS_UI_ACCESS_LOG_FILE: /var/log/genieacs/genieacs-ui-access.log
      GENIEACS_DEBUG_FILE: /var/log/genieacs/genieacs-debug.yaml
      GENIEACS_EXT_DIR: /opt/genieacs/ext
      GENIEACS_FS_URL_PREFIX: http://genieacs:7567/
    ports:
      - "7547:7547"   # CWMP — CPE devices connect here
      - "7557:7557"   # NBI  — REST API
      - "7567:7567"   # FS   — File server
      - "3000:3000"   # UI   — Built-in web interface
    volumes:
      - genieacs_ext:/opt/genieacs/ext
    networks:
      - shared-vpn
    healthcheck:
      test: ["CMD", "wget", "--spider", "--quiet", "http://localhost:3000"]
      interval: 30s
      timeout: 10s
      retries: 3
      start_period: 60s

  ### GenieACS Panel API — web-based management UI ###
  genieacs-panel:
    depends_on:
      genieacs:
        condition: service_healthy
    image: solusidigitalnet/genieacspanelapi:latest
    container_name: genieacs-panel
    restart: unless-stopped
    ports:
      - "1997:1997"
    environment:
      JWT_SECRET: your-secret-key-change-me
      JWT_EXPIRES_IN: 1h
      REFRESH_TOKEN_EXPIRES_IN: 7d
      add_wan: "yes"
      NODE_ENV: production
      # Override: point to GenieACS NBI on the shared network
      ACS_URL: http://genieacs:7557
    networks:
      - shared-vpn

volumes:
  mongo_db:
  mongo_configdb:
  genieacs_ext:

networks:
  shared-vpn:
    external: true
```

### Dokploy settings

- **Turn OFF "Isolated Deployments"** for this project — it must join the `shared-vpn` external network.

Deploy the project. Wait for all three containers to show healthy (MongoDB ~40s, GenieACS ~60s, Panel ~10s).

---

## Step 2 — First-time GenieACS setup

### Access the built-in GenieACS UI

The GenieACS container runs a first-time setup wizard on port 3000. Open:

```
http://YOUR-SERVER-IP:3000
```

The wizard will:
1. Prompt you to create an admin user and password
2. Configure basic ACS settings
3. Redirect to the dashboard

### Generate a secure JWT secret

Replace the placeholder in your compose:

```bash
# Generate a random 64-char secret
openssl rand -base64 48
```

Update `GENIEACS_UI_JWT_SECRET` in the compose and redeploy.

### Test the NBI (REST API)

```bash
curl http://YOUR-SERVER-IP:7557/devices
```

Should return `[]` (no devices yet) — or the devices if you already have CPEs connecting.

---

## Step 3 — Verify the GenieACS Panel API

Open the management panel:

```
http://YOUR-SERVER-IP:1997
```

**Default credentials:**
| Field    | Value             |
|----------|-------------------|
| Username | `admin`           |
| Password | `solusidigitalnet` |

> ⚠️ Change the password immediately after first login.

If the panel shows "Cannot connect to ACS", check:
- `genieacs` container is healthy (`docker ps | grep genieacs`)
- The panel can reach NBI: `docker exec genieacs-panel wget -qO- http://genieacs:7557/devices`

---

## Step 4 — Connect to VPN network

These containers are already on `shared-vpn`, which is the same network the SoftEtherVPN server uses. This gives us:

### A. VPN clients → GenieACS

From any VPN-connected laptop (IP `10.99.0.x`), add iptables forwarding rules on the VPN server so VPN clients can reach GenieACS services:

```bash
docker exec softether-vpn sh -c "
  # GenieACS UI (built-in) — 10.99.0.1:3000 → genieacs:3000
  iptables -t nat -A PREROUTING -p tcp --dport 3000 -j DNAT --to-destination genieacs:3000
  iptables -t nat -A POSTROUTING -p tcp -d genieacs --dport 3000 -j MASQUERADE
  iptables -A FORWARD -p tcp -d genieacs --dport 3000 -j ACCEPT

  # GenieACS Panel API — 10.99.0.1:1997 → genieacs-panel:1997
  iptables -t nat -A PREROUTING -p tcp --dport 1997 -j DNAT --to-destination genieacs-panel:1997
  iptables -t nat -A POSTROUTING -p tcp -d genieacs-panel --dport 1997 -j MASQUERADE
  iptables -A FORWARD -p tcp -d genieacs-panel --dport 1997 -j ACCEPT

  # GenieACS NBI (API) — 10.99.0.1:7557 → genieacs:7557
  iptables -t nat -A PREROUTING -p tcp --dport 7557 -j DNAT --to-destination genieacs:7557
  iptables -t nat -A POSTROUTING -p tcp -d genieacs --dport 7557 -j MASQUERADE
  iptables -A FORWARD -p tcp -d genieacs --dport 7557 -j ACCEPT
"
```

VPN clients then use:
```
http://10.99.0.1:3000    → GenieACS built-in UI
http://10.99.0.1:1997    → GenieACS Panel API
http://10.99.0.1:7557    → GenieACS NBI (REST API)
```

### B. GenieACS → VPN clients (e.g., TR-069 to CPE behind VPN)

CPE devices (routers, ONUs) can be behind the VPN. For the GenieACS CWMP service to connect to them, the CPE devices must have a reachable IP from the ACS. Two patterns:

1. **CPE initiates the connection** (standard TR-069): The CPE device contacts the ACS at `http://10.99.0.1:7547`. GenieACS doesn't need to reach the CPE — the CPE reaches the ACS. This works automatically through SecureNAT.

2. **ACS initiates a Connection Request** (TR-069 Connection Request): GenieACS needs to reach the CPE on port 7547 (or custom). For this, the CPE must have a static VPN IP (e.g., `10.99.0.50`) and that IP must be reachable from the ACS container. Since both are on `shared-vpn` via SecureNAT, add a direct route:

   ```bash
   docker exec genieacs sh -c "
     ip route add 10.99.0.0/24 via softether-vpn
   "
   ```

### C. Other Dokploy projects → GenieACS

Any project on `shared-vpn` can reach GenieACS by container name:

```
http://genieacs:7557    # NBI REST API — provision devices, query data
http://genieacs:3000    # Built-in UI
http://genieacs-panel:1997  # Management panel
```

Add these as environment variables in dependent projects:

```yaml
services:
  my-app:
    environment:
      ACS_API_URL: http://genieacs:7557
      ACS_PANEL_URL: http://genieacs-panel:1997
    networks:
      - shared-vpn

networks:
  shared-vpn:
    external: true
```

---

## Step 5 — Full connectivity matrix

| From / To | GenieACS NBI | GenieACS UI | Panel API | MongoDB | CPE (VPN) | Project A/B |
|-----------|-------------|-------------|-----------|---------|-----------|-------------|
| **VPN client (10.99.0.x)** | `10.99.0.1:7557` | `10.99.0.1:3000` | `10.99.0.1:1997` | ❌ (not exposed) | Direct VPN IP | `10.99.0.1:<port>` |
| **Project A/B (Docker)** | `genieacs:7557` | `genieacs:3000` | `genieacs-panel:1997` | `mongo:27017` | Via softether-vpn DNAT | Container name |
| **Internet (public)** | `host:7557` | `host:3000` | `host:1997` | ❌ | N/A | Per project ports |
| **CPE device** | `genieacs:7547` (or host:7547) | N/A | N/A | N/A | Local | N/A |

> For CPE devices connecting from the internet, they hit your host's port 7547 which is mapped directly to `genieacs:7547`. If the CPE is behind the VPN, it connects to `10.99.0.1:7547`.

---

## Port reference

| Port  | Protocol | Service | Exposed to host? | Exposed to VPN? |
|-------|----------|---------|------------------|-----------------|
| 27017 | TCP      | MongoDB (internal) | ❌ expose only | ❌ |
| 7547  | TCP      | GenieACS CWMP | ✅ `host:7547` | ✅ `10.99.0.1:7547` |
| 7557  | TCP      | GenieACS NBI (API) | ✅ `host:7557` | ✅ `10.99.0.1:7557` |
| 7567  | TCP      | GenieACS FS (files) | ✅ `host:7567` | Via ACS |
| 3000  | TCP      | GenieACS UI (built-in) | ✅ `host:3000` | ✅ `10.99.0.1:3000` |
| 1997  | TCP      | Panel API (management) | ✅ `host:1997` | ✅ `10.99.0.1:1997` |

### Firewall rules (cloud provider)

Open on your VPS security group:

```
7547/tcp   — TR-069 CPE device connections (required)
7557/tcp   — NBI API (if accessed externally)
3000/tcp   — Built-in UI (optional, better behind VPN)
1997/tcp   — Management panel (optional, better behind VPN)
```

> **Recommendation:** Don't expose 3000 and 1997 to the public internet. Access them only through the VPN (`10.99.0.1:3000`, `10.99.0.1:1997`). Expose only 7547 for CPE devices if they're on the public internet.

---

## Troubleshooting

### Panel API shows "Cannot connect to ACS"

The panel container uses `ACS_URL` to reach the GenieACS NBI. Verify:

```bash
# Check the panel can resolve and reach genieacs
docker exec genieacs-panel wget -qO- http://genieacs:7557/devices

# If it fails, check DNS resolution inside the panel container
docker exec genieacs-panel getent hosts genieacs

# If DNS works but connection fails, check the NBI is running
docker exec genieacs wget -qO- http://localhost:7557/devices
```

### GenieACS UI shows blank page after deploy

The container may take up to 60 seconds to start all 4 services. Check:

```bash
docker logs genieacs --tail 20
# Should show all 4 services started without errors
```

### MongoDB connection refused

```bash
docker logs mongo-genieacs --tail 10
docker exec genieacs wget -qO- http://mongo:27017
```

If MongoDB isn't ready when GenieACS starts, redeploy the stack — the `depends_on` with `condition: service_healthy` handles this ordering.

### CPE device can't reach ACS on port 7547

From the CPE device (or a VPN client simulating it):

```bash
curl http://10.99.0.1:7547/
```

Should return a GenieACS response. If not, verify the iptables rule on the VPN server:

```bash
docker exec softether-vpn iptables -t nat -L PREROUTING -n | grep 7547
```

### Panel API login fails with default credentials

The default credentials are hardcoded in the panel image. If they don't work, the image may have been updated. Check the container logs:

```bash
docker logs genieacs-panel --tail 30
```

Look for any initialization or seeding messages.

### GenieACS UI wizard loops

If the first-time setup wizard keeps looping after you complete it:
1. Clear browser cache
2. Check MongoDB has the admin user: `docker exec mongo-genieacs mongosh genieacs --eval "db.users.find()"`
3. If the users collection is empty, the write to MongoDB failed — check the `GENIEACS_MONGODB_CONNECTION_URL` is correct

---

## Appendices

### Appendix A — Production hardening

Before going to production:

1. **Enable MongoDB authentication:**
   ```yaml
   mongo:
     environment:
       MONGO_INITDB_ROOT_USERNAME: admin
       MONGO_INITDB_ROOT_PASSWORD: strongpassword
   
   genieacs:
     environment:
       GENIEACS_MONGODB_CONNECTION_URL: mongodb://admin:strongpassword@mongo/genieacs?authSource=admin
   ```

2. **Set a strong JWT secret:**
   ```bash
   openssl rand -base64 48
   ```
   Set both `GENIEACS_UI_JWT_SECRET` and the panel's `JWT_SECRET`.

3. **Don't expose ports publicly** — use the VPN gateway (`10.99.0.1`) for all admin access.

4. **Backup MongoDB** regularly:
   ```bash
   docker exec mongo-genieacs mongodump --out /tmp/backup
   docker cp mongo-genieacs:/tmp/backup ./genieacs-backup-$(date +%Y%m%d)
   ```

### Appendix B — Update the iptables script

Add the GenieACS forwarding rules to your persistent `iptables-setup.sh`:

```sh
# === GenieACS forwarding rules ===

# GenieACS UI → accessible as softether-vpn:3000
iptables -t nat -A PREROUTING -p tcp --dport 3000 -j DNAT --to-destination genieacs:3000
iptables -t nat -A POSTROUTING -p tcp -d genieacs --dport 3000 -j MASQUERADE
iptables -A FORWARD -p tcp -d genieacs --dport 3000 -j ACCEPT

# GenieACS Panel → accessible as softether-vpn:1997
iptables -t nat -A PREROUTING -p tcp --dport 1997 -j DNAT --to-destination genieacs-panel:1997
iptables -t nat -A POSTROUTING -p tcp -d genieacs-panel --dport 1997 -j MASQUERADE
iptables -A FORWARD -p tcp -d genieacs-panel --dport 1997 -j ACCEPT

# GenieACS NBI → accessible as softether-vpn:7557
iptables -t nat -A PREROUTING -p tcp --dport 7557 -j DNAT --to-destination genieacs:7557
iptables -t nat -A POSTROUTING -p tcp -d genieacs --dport 7557 -j MASQUERADE
iptables -A FORWARD -p tcp -d genieacs --dport 7557 -j ACCEPT

# GenieACS CWMP → accessible as softether-vpn:7547 (for CPE behind VPN)
iptables -t nat -A PREROUTING -p tcp --dport 7547 -j DNAT --to-destination genieacs:7547
iptables -t nat -A POSTROUTING -p tcp -d genieacs --dport 7547 -j MASQUERADE
iptables -A FORWARD -p tcp -d genieacs --dport 7547 -j ACCEPT
```

### Appendix C — Integrating with Project A and Project B

If your other projects need to interact with GenieACS programmatically (e.g., auto-provision devices when a customer signs up), use the NBI REST API:

```javascript
// Example: Provision a new device via NBI
fetch('http://genieacs:7557/devices', {
  method: 'POST',
  headers: {
    'Content-Type': 'application/json',
  },
  body: JSON.stringify({
    _id: 'DEVICE-SERIAL-001',
    _deviceId: {
      _Manufacturer: 'ZTE',
      _OUI: '000000',
      _ProductClass: 'F660',
      _SerialNumber: 'DEVICE-SERIAL-001',
    },
    'InternetGatewayDevice.ManagementServer.ConnectionRequestURL': '',
    'InternetGatewayDevice.ManagementServer.ConnectionRequestUsername': 'admin',
    'InternetGatewayDevice.ManagementServer.ConnectionRequestPassword': 'password',
  }),
});
```

API docs: https://docs.genieacs.com/en/latest/api-reference.html

---

## References

- [GenieACS Documentation](https://docs.genieacs.com/en/latest/)
- [GenieACS Container (GeiserX)](https://github.com/GeiserX/genieacs-container)
- [GenieACS Docker Image](https://hub.docker.com/r/drumsergio/genieacs)
- [GenieACS Panel API](https://hub.docker.com/r/solusidigitalnet/genieacspanelapi)
- [SoftEtherVPN on Dokploy Guide](https://github.com/manh21/dokploy-softether-vpn)
