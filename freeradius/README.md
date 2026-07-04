<!-- omit in toc -->
<p align="center">
  <img src="https://img.shields.io/badge/SoftEtherVPN-stable-green" alt="SoftEtherVPN">
  <img src="https://img.shields.io/badge/FreeRADIUS-3.2-blue?logo=radius" alt="FreeRADIUS">
  <img src="https://img.shields.io/badge/Dokploy-compose-blue?logo=docker" alt="Dokploy">
  <img src="https://img.shields.io/github/license/manh21/dokploy-softether-vpn" alt="License">
</p>

# FreeRADIUS + SoftEtherVPN — Centralised AAA for VPN Users

Deploy FreeRADIUS alongside SoftEtherVPN in Docker, then configure the VPN server to authenticate users via RADIUS instead of its built-in user database. This gives you centralised AAA (Authentication, Authorisation, Accounting) for all VPN users — and the same RADIUS server can later authenticate CPE devices for GenieACS.

**What you'll get:**
- FreeRADIUS 3.2 running in Docker (official Alpine image, ~20 MB)
- VPN user authentication moved from SoftEther's native DB to RADIUS
- RADIUS accounting logs for every VPN session (connect/disconnect/data usage)
- Same RADIUS server usable by GenieACS for TR-069 CPE auth
- All on the `shared-vpn` Docker network

## Table of Contents

- [How SoftEther + RADIUS works](#how-softether--radius-works)
- [Prerequisites](#prerequisites)
- [Step 1 — Create RADIUS configuration files](#step-1--create-radius-configuration-files)
- [Step 2 — Add FreeRADIUS to the Docker Compose](#step-2--add-freeradius-to-the-docker-compose)
- [Step 3 — Configure SoftEtherVPN to use RADIUS](#step-3--configure-softethervpn-to-use-radius)
- [Step 4 — Verify RADIUS authentication](#step-4--verify-radius-authentication)
- [Step 5 — RADIUS accounting](#step-5--radius-accounting)
- [Step 6 — GenieACS integration (preview)](#step-6--genieacs-integration-preview)
- [Full compose file](#full-compose-file)
- [Troubleshooting](#troubleshooting)

---

## How SoftEther + RADIUS works

```
VPN Client (10.99.0.10)
  │
  │  VPN connection attempt (username + password)
  ▼
SoftEther VPN Server (softether-vpn)
  │
  │  RADIUS Access-Request
  ▼
FreeRADIUS (freeradius:1812)
  │
  │  Check users file / SQL / LDAP
  ▼
  ├── Access-Accept  → VPN connection allowed
  ├── Access-Reject  → VPN connection denied
  └── Accounting-Request (session start/stop/update)
```

FreeRADIUS becomes the single source of truth for who can connect. When SoftEther is configured for RADIUS auth:

1. A client connects with username + password
2. SoftEther sends a RADIUS `Access-Request` to FreeRADIUS
3. FreeRADIUS checks credentials and returns `Accept` or `Reject`
4. On connect/disconnect, SoftEther sends `Accounting-Request` packets
5. FreeRADIUS logs everything to detail files or a database

---

## Prerequisites

- The SoftEtherVPN Docker setup from the [main guide](../README.md)
- The `shared-vpn` Docker network already created
- A directory for RADIUS config files (we'll mount them as volumes)

---

## Step 1 — Create RADIUS configuration files

Create a directory for RADIUS config:

```bash
mkdir -p /path/to/radius-config/mods-config/files
```

### 1a — `clients.conf`

This defines which devices can talk to the RADIUS server. The SoftEtherVPN container and your VPN subnet:

```conf
# /path/to/radius-config/clients.conf

# SoftEtherVPN container (the NAS)
client softether {
    ipaddr          = softether-vpn
    secret          = testing123
    shortname       = softether
    nas_type        = other
}

# VPN clients subnet — allows the local bridge to proxy auth
client vpn-subnet {
    ipaddr          = 10.99.0.0/24
    secret          = testing123
    shortname       = vpn-clients
    nas_type        = other
}

# GenieACS (for TR-069 CPE auth later)
client genieacs {
    ipaddr          = genieacs
    secret          = testing123
    shortname       = genieacs
    nas_type        = other
}

# Local testing
client localhost {
    ipaddr          = 127.0.0.1
    secret          = testing123
}
```

> Change `testing123` to a strong random secret: `openssl rand -base64 24`

### 1b — `users` (authorize file)

Define VPN users. Each user needs a cleartext password:

```conf
# /path/to/radius-config/mods-config/files/authorize

# VPN user — standard access
alice   Cleartext-Password := "strongpassword"
        Service-Type = Framed-User,
        Reply-Message = "Welcome to the VPN, %{User-Name}"

# Another user
bob     Cleartext-Password := "anotherpassword"
        Service-Type = Framed-User

# Default: reject all unlisted users
DEFAULT Auth-Type := Reject
        Reply-Message = "Access denied — user not found"
```

### 1c — Enable the `files` module

Create a minimal mods-enable override. The official image ships with files enabled by default, but let's be explicit:

```conf
# /path/to/radius-config/mods-enabled/files
# (Empty file — its presence tells FreeRADIUS to load the 'files' module)
```

Actually, the official image has all common modules enabled. We just need to provide the `authorize` file.

### Directory structure after this step:

```
radius-config/
├── clients.conf
└── mods-config/
    └── files/
        └── authorize
```

---

## Step 2 — Add FreeRADIUS to the Docker Compose

Extend the VPN server compose from the main guide. Add the FreeRADIUS service:

```yaml
version: '3.8'

services:
  ### SoftEther VPN Server ###
  softether:
    image: softethervpn/vpnserver:stable
    container_name: softether-vpn
    cap_add:
      - NET_ADMIN
    restart: always
    ports:
      - 8443:443/tcp
      - 992:992/tcp
      - 5555:5555/tcp
      - 1194:1194/udp
      - 500:500/udp
      - 4500:4500/udp
      - 1701:1701/udp
    volumes:
      - softether_data:/var/lib/softether
      - softether_log:/var/log/softether
      - ./entrypoint.sh:/entrypoint.sh:ro
    entrypoint: ["/bin/sh", "/entrypoint.sh"]
    networks:
      - shared-vpn
    sysctls:
      - net.ipv4.ip_forward=1

  ### FreeRADIUS Server ###
  freeradius:
    image: freeradius/freeradius-server:latest-3.2-alpine
    container_name: freeradius
    restart: unless-stopped
    ports:
      - "1812:1812/udp"    # Authentication
      - "1813:1813/udp"    # Accounting
    volumes:
      # Mount custom client config
      - ./radius-config/clients.conf:/etc/raddb/clients.conf:ro
      # Mount user database
      - ./radius-config/mods-config/files/authorize:/etc/raddb/mods-config/files/authorize:ro
      # Persist accounting logs
      - radius_logs:/var/log/radius
    networks:
      - shared-vpn
    # Override default sites to enable detail logging and files auth
    # The official image comes with 'default' and 'inner-tunnel' enabled by default
    command: >
      radiusd -f -l stdout

volumes:
  softether_data:
  softether_log:
  radius_logs:

networks:
  shared-vpn:
    external: true
```

**Key points:**
- FreeRADIUS binds to UDP 1812 (auth) and 1813 (acct) on the `shared-vpn` network
- The SoftEther container reaches it at `freeradius:1812`
- Config files are mounted read-only — edit them on the host and restart FreeRADIUS
- The official image already has `default` site enabled with `files` module for user lookup

---

## Step 3 — Configure SoftEtherVPN to use RADIUS

After deploying, connect to the VPN server's management console and switch the hub to RADIUS authentication.

### 3a — Access `vpncmd`

```bash
docker exec -it softether-vpn vpncmd localhost /server /password:your-admin-password
```

### 3b — Configure RADIUS on the hub

For each hub that should use RADIUS (e.g., `VPN`):

```
Hub VPN

# Set RADIUS server parameters
RadiusServerSet /SERVER:freeradius:1812 /SECRET:testing123

# Enable RADIUS authentication for this hub
RadiusServerSet /RETRYINTERVAL:30

# Optional: enable per-user RADIUS accounting
RadiusServerSet /USEACCOUNTSERVER:freeradius:1813

# Verify
RadiusServerGet
```

Expected output:
```
RadiusServerGet command - Get Radius Server Settings
Item                        |Value
----------------------------+----------------------
Radius Server Name          |freeradius
Radius Server Port          |1812
Radius Retry Interval       |30
Radius Secret               |testing123
Use Radius Accounting Server|Yes
```

### 3c — Verify the hub config

```
Hub VPN
HubGet
```

Look for `Radius Authentication Server` in the output. If it shows the FreeRADIUS address, RADIUS auth is active.

### 3d — Exit

```
Exit
```

**What changes:** After this, when a VPN client connects with username `alice` and password `strongpassword`, SoftEther sends a RADIUS request to FreeRADIUS instead of checking its own internal user database.

---

## Step 4 — Verify RADIUS authentication

### 4a — Test with `radtest` from the RADIUS container

```bash
docker exec freeradius radtest alice strongpassword freeradius 0 testing123
```

Expected: `Access-Accept`

Test a bad password:

```bash
docker exec freeradius radtest alice wrongpassword freeradius 0 testing123
```

Expected: `Access-Reject`

### 4b — Test from the SoftEther container

```bash
docker exec softether-vpn sh -c "echo 'User-Agent: test' | nc -u -w2 freeradius 1812" 2>/dev/null
# (nc UDP test is basic — use radtest from inside if available)
```

### 4c — Connect a real VPN client

Use the SoftEther client on your laptop. Connect with:
- **Host:** `your-server:8443`
- **Hub:** `VPN`
- **Username:** `alice`
- **Password:** `strongpassword`

The connection should succeed. Check RADIUS accounting logs:

```bash
docker exec freeradius cat /var/log/radius/radacct/*/detail-* 2>/dev/null | head -30
```

### 4d — Debug mode (if something fails)

Stop the RADIUS container and run it in debug:

```bash
docker compose stop freeradius
docker compose run --rm -p 1812:1812/udp -p 1813:1813/udp freeradius radiusd -X
```

Connect a VPN client and watch the console — every RADIUS packet is logged in detail.

---

## Step 5 — RADIUS accounting

FreeRADIUS logs accounting data to detail files. Enable them by ensuring `detail` is active in the default site (it is by default).

### View accounting logs

```bash
# List all accounting detail files
docker exec freeradius find /var/log/radius/radacct -type f 2>/dev/null

# View the latest
docker exec freeradius cat /var/log/radius/radacct/$(date +%Y%m%d)/detail-* 2>/dev/null
```

Example output:
```
Sat Jul  4 14:30:00 2026
    Acct-Status-Type = Start
    User-Name = "alice"
    Acct-Session-Id = "ABC123"
    NAS-IP-Address = 172.18.0.2
    Calling-Station-Id = "10.99.0.10"
    ...
```

### Optional: Store accounting in a database

To log accounting to MySQL/PostgreSQL for querying, add a SQL module. See [FreeRADIUS SQL HOWTO](https://wiki.freeradius.org/guide/SQL-HOWTO).

---

## Step 6 — GenieACS integration (preview)

The same FreeRADIUS server can also authenticate TR-069 CPE devices connecting to GenieACS. GenieACS's CWMP service supports RADIUS for CPE authentication.

In your GenieACS compose, set the environment variable:

```yaml
genieacs:
  environment:
    # Point CWMP to RADIUS for device auth
    GENIEACS_CWMP_AUTH_RADIUS_HOST: freeradius
    GENIEACS_CWMP_AUTH_RADIUS_PORT: 1812
    GENIEACS_CWMP_AUTH_RADIUS_SECRET: testing123
```

Then add CPE credentials to the RADIUS users file:

```conf
# /radius-config/mods-config/files/authorize

# TR-069 CPE device (authenticated by serial number)
ONT-ZTE-F660-001    Cleartext-Password := "devicepassword"
                    Service-Type = Outbound-User

# Allow any device from the VPN subnet with a shared password
DEFAULT Calling-Station-Id =~ "^10\.99\.0\..*"
        Cleartext-Password := "cpe-shared-secret"
        Service-Type = Outbound-User
```

This is covered in detail in the [GenieACS guide](../genieacs/README.md).

---

## Full compose file

```yaml
version: '3.8'

services:
  softether:
    image: softethervpn/vpnserver:stable
    container_name: softether-vpn
    cap_add:
      - NET_ADMIN
    restart: always
    ports:
      - 8443:443/tcp
      - 992:992/tcp
      - 5555:5555/tcp
      - 1194:1194/udp
      - 500:500/udp
      - 4500:4500/udp
      - 1701:1701/udp
    volumes:
      - softether_data:/var/lib/softether
      - softether_log:/var/log/softether
      - ./entrypoint.sh:/entrypoint.sh:ro
    entrypoint: ["/bin/sh", "/entrypoint.sh"]
    networks:
      - shared-vpn
    sysctls:
      - net.ipv4.ip_forward=1
    depends_on:
      - freeradius

  freeradius:
    image: freeradius/freeradius-server:latest-3.2-alpine
    container_name: freeradius
    restart: unless-stopped
    ports:
      - "1812:1812/udp"
      - "1813:1813/udp"
    volumes:
      - ./radius-config/clients.conf:/etc/raddb/clients.conf:ro
      - ./radius-config/mods-config/files/authorize:/etc/raddb/mods-config/files/authorize:ro
      - radius_logs:/var/log/radius
    networks:
      - shared-vpn

volumes:
  softether_data:
  softether_log:
  radius_logs:

networks:
  shared-vpn:
    external: true
```

---

## Troubleshooting

### RADIUS container won't start

Check logs:
```bash
docker logs freeradius
```

Common causes:
- **Config syntax error** — run `docker compose run --rm freeradius radiusd -XC` to check config
- **Permission denied on volumes** — ensure mounted files are world-readable
- **Port already in use** — `ss -uln | grep 1812`

### Access-Reject even with correct password

1. Check the user exists in `authorize`:
   ```bash
   docker exec freeradius cat /etc/raddb/mods-config/files/authorize
   ```
2. Check the client secret matches:
   ```bash
   docker exec freeradius cat /etc/raddb/clients.conf | grep secret
   ```
3. Run RADIUS in debug mode and watch:
   ```bash
   docker compose run --rm freeradius radiusd -X
   ```

### SoftEther can't reach RADIUS

From the SoftEther container:
```bash
docker exec softether-vpn sh -c "echo test | nc -u -w2 freeradius 1812"
```

If no response:
- Ensure both containers are on `shared-vpn` network
- Check DNS: `docker exec softether-vpn ping freeradius`

### Users file not being read

The official image needs `files` to be listed in the `authorize` section of the default site. Check:

```bash
docker exec freeradius grep -A5 "^authorize" /etc/raddb/sites-enabled/default
```

Should contain `files`. If not, the `files` module isn't in `mods-enabled/`. Create a custom site override.

### Certificate warnings

The official image ships with self-signed certs. For production, generate your own:
```bash
docker compose run --rm freeradius sh -c "cd /etc/raddb/certs && make"
```

---

## References

- [FreeRADIUS Official Docker Image](https://hub.docker.com/r/freeradius/freeradius-server)
- [FreeRADIUS Documentation](https://www.freeradius.org/documentation/)
- [SoftEther VPN Manual — RADIUS](https://www.softether.org/4-docs/1-manual/6/6.5)
- [SoftEtherVPN on Dokploy Guide](../README.md)
- [GenieACS on Dokploy Guide](../genieacs/README.md)
