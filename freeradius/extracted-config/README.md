# Extracted FreeRADIUS Configuration

These files were extracted from the production FreeRADIUS 3.2 server running
alongside SoftEtherVPN on `prid-relay` (Debian).

## What was customized vs default

| File | Status | What changed |
|------|--------|-------------|
| `dictionary` | **Custom** | Added `Max-Data`, `Data-Remaining`, `Data-Quota` (integer64), `FUP-Rate` (string) |
| `clients.conf` | **Custom** | Added `overlay` client for VPN subnet `10.9.0.0/24` |
| `mods-available/sql` | **Custom** | PostgreSQL dialect, driver, and connection to remote DB |
| `sites-available/default` | **Custom** | Fair Usage Policy block in `post-auth` — enforces data quota via SQL, sets `Mikrotik-Rate-Limit` and `Mikrotik-Address-List` |
| `sites-enabled/inner-tunnel` | Default | Standard — `-sql` disabled in authorize |
| `radiusd.conf` | Default | No changes |
| `users` (authorize) | Default | No custom users — all users managed via PostgreSQL |
| `mods-config/sql/main/postgresql/queries.conf` | Default | Standard FreeRADIUS 3.2 queries |
| `mods-config/sql/main/postgresql/schema.sql` | Default | Standard FreeRADIUS 3.2 schema |

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
