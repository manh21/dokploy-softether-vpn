# Extracted FreeRADIUS Configuration

These files were extracted from the production FreeRADIUS 3.2 server running
alongside SoftEtherVPN on `prid-relay` (Debian).

## What was customized vs default

### Files in `sites-enabled/` and `mods-enabled/`

All files are **symlinks** to `../sites-available/` or `../mods-available/` EXCEPT:

| File | Type | Status |
|------|------|--------|
| `mods-enabled/sqlcounter` | **Regular file** (1319 bytes) | **Custom** — not a symlink, manually written |
| `mods-enabled/sql` | Symlink (abs path) | Points to `mods-available/sql` which IS custom |
| `sites-enabled/default` | Symlink | Points to `sites-available/default` which IS custom |
| `sites-enabled/inner-tunnel` | Symlink | Points to stock default |
| All other mods-enabled/* | Symlinks | Stock defaults |

### Summary

| File | Status | What changed |
|------|--------|-------------|
| `dictionary` | **Custom** | Added `Max-Data`, `Data-Remaining`, `Data-Quota` (integer64), `FUP-Rate` (string) |
| `clients.conf` | **Custom** | Added `overlay` client for VPN subnet `10.9.0.0/24` |
| `mods-available/sql` | **Custom** | PostgreSQL dialect, driver, and connection to remote DB |
| `mods-enabled/sqlcounter` | **Custom** | Custom `accessperiod` and `uptimelimit` counters; `quotalimit` commented out |
| `sites-available/default` | **Custom** | Fair Usage Policy block in `post-auth` |
| `sites-available/inner-tunnel` | Default | Stock — `-sql` disabled |
| `radiusd.conf` | Default | No changes |
| `users` (authorize) | Default | No custom users — all managed via PostgreSQL |
| All other mods/sites | Default | Symlinks to stock defaults |

### Data Quota / FUP mechanism

The custom `post-auth` section in `sites-available/default` implements:

1. Reads `Data-Quota` and `FUP-Rate` from `radcheck` (loaded into `&control` by the SQL authorize step)
2. Queries current monthly usage from `radacct`
3. If usage exceeds quota:
   - With `FUP-Rate` → throttles to reduced speed via `Mikrotik-Rate-Limit`
   - Without `FUP-Rate` → redirects to top-up page via `Mikrotik-Address-List := "isolir"`

## Architecture

```
SoftEtherVPN (native, not Docker)
  │
  │  RADIUS Access-Request (UDP 1812)
  ▼
FreeRADIUS 3.2 (native, not Docker)
  │
  │  PostgreSQL queries
  ▼
PostgreSQL at 101.32.114.196:5432
  │
  ├── radcheck  (user credentials)
  ├── radreply  (reply attributes)
  ├── radgroupcheck / radgroupreply (group policies)
  ├── radacct   (accounting logs)
  └── radpostauth (auth logs)
```

## How to use these files

If you're migrating from native to Docker:

1. Copy `mods-available/sql` to your Docker RADIUS config directory
2. Copy `clients.conf` — update IPs from `10.9.0.0/24` to your VPN subnet
3. The rest is stock — no need to copy, the Docker image already has defaults
