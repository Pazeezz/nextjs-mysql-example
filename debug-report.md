# Debug Report

Issues encountered during deployment of the Next.js + MySQL application on Ubuntu server (`54.251.231.146`).

***

## Issue 1 — App container starts before MySQL is ready

| Field | Detail |
|---|---|
| **Problem** | The `app` container crashed immediately after starting with `Error: connect ECONNREFUSED 127.0.0.1:3306`. The Next.js app tried to connect to MySQL before the database had finished initializing. |
| **Root cause** | `depends_on: db` in docker-compose only waits for the container to *start*, not for MySQL to actually accept connections. MySQL takes 20–30 seconds to initialize on first boot. |
| **How found** | `docker compose logs app` showed `ECONNREFUSED` on port 3306. `docker compose ps` showed `db` as `Up` but not yet healthy. |
| **Fix applied** | Added a `healthcheck` to the `db` service using `mysqladmin ping`. Changed `depends_on` in the `app` service to use `condition: service_healthy` so the app only starts after the DB is confirmed ready. |
| **Result** | App waits for the DB healthcheck to pass before starting. No more connection refused errors. |

```yaml
# docker-compose.yml fix
db:
  healthcheck:
    test: ["CMD", "mysqladmin", "ping", "-h", "127.0.0.1", "--silent"]
    interval: 10s
    timeout: 5s
    retries: 5
    start_period: 30s

app:
  depends_on:
    db:
      condition: service_healthy
```

***

## Issue 2 — Knex migration fails in Docker: ts-node not found

| Field | Detail |
|---|---|
| **Problem** | The entrypoint script failed with `sh: ts-node: not found` when running `npx knex migrate:latest --knexfile knexfile.ts`. Migrations could not run and the app would not start. |
| **Root cause** | The production Docker image only installed dependencies with `--omit=dev`. `ts-node` was not in `package.json` at all, so it was never installed in the image. |
| **How found** | `docker compose logs app` showed `sh: ts-node: not found`. Confirmed by running `docker exec weblankan_app which ts-node` — returned nothing. |
| **Fix applied** | Added `npm install ts-node` as a separate step in the `deps` stage of the Dockerfile. Added `tsconfig.knex.json` with `"module": "commonjs"` so ts-node can compile the TypeScript knexfile. Updated `entrypoint.sh` to use `TS_NODE_PROJECT=tsconfig.knex.json`. |
| **Result** | ts-node is present in the runner image. Migrations execute successfully on every container startup. |

```dockerfile
# Dockerfile deps stage fix
RUN npm ci --omit=dev && npm install ts-node
```

```sh
# entrypoint.sh fix
TS_NODE_PROJECT=tsconfig.knex.json npx knex migrate:latest --knexfile knexfile.ts
```

***

## Issue 3 — Knex missing `client` configuration option in production

| Field | Detail |
|---|---|
| **Problem** | App container kept restarting with `knex: Required configuration option 'client' is missing`. Migrations failed completely and the app never started. |
| **Root cause** | `knexfile.ts` only defined a `development` environment block. When the container ran with `NODE_ENV=production`, Knex looked for a `production` config block and found none — so `client` was undefined. |
| **How found** | `docker compose logs app --tail=50` showed repeated `knex: Required configuration option 'client' is missing` errors. Inspected `knexfile.ts` and confirmed only `development` key existed. |
| **Fix applied** | Added a `production` block to `knexfile.ts` with `client: 'mysql2'` and the same connection config reading from environment variables. Also changed `MYSQL_HOST` in `.env` from `localhost` to `db` (the Docker service name). |
| **Result** | Knex correctly loads production config. Migrations run with `Using environment: production`. App starts successfully. |

```typescript
// knexfile.ts fix — added production block
const knexConfig = {
  development: {
    client: 'mysql2',
    connection: connection,
    migrations: { tableName: 'migrations', directory: './database/migrations' },
    seeds: { directory: './database/seeds' }
  },
  production: {
    client: 'mysql2',
    connection: connection,
    migrations: { tableName: 'migrations', directory: './database/migrations' },
    seeds: { directory: './database/seeds' }
  }
};
```

```env
# .env fix — Docker service name not localhost
MYSQL_HOST=db
```

***

## Issue 4 — UFW firewall blocking port 80 after enabling

| Field | Detail |
|---|---|
| **Problem** | After enabling UFW (`sudo ufw enable`), the application became unreachable via the domain even though Nginx was running correctly. |
| **Root cause** | UFW was enabled without first allowing required ports. The default UFW policy is `deny incoming`, which blocked port 80 (HTTP), port 443 (HTTPS), and port 3000. SSH (port 22) was also at risk. |
| **How found** | `curl http://pasinduj.duckdns.org` timed out. SSH still worked because the session was already established. `sudo ufw status` showed only default rules with no allowed ports. |
| **Fix applied** | Added explicit allow rules before enabling UFW. Confirmed SSH was allowed first to avoid locking out of the server. |
| **Result** | Firewall active with only required ports open. Application accessible via domain. |

```bash
# Correct order to avoid locking yourself out
sudo ufw allow 22/tcp      # SSH — ALWAYS do this first
sudo ufw allow 80/tcp      # HTTP
sudo ufw allow 443/tcp     # HTTPS
sudo ufw deny 3000/tcp     # Block direct app port — only Nginx should serve traffic
sudo ufw enable
sudo ufw status verbose
```

***

## Issue 5 — GitHub Actions deployment fails: `docker-compose: command not found`

| Field | Detail |
|---|---|
| **Problem** | The GitHub Actions workflow failed during the SSH deployment step with `bash: docker-compose: command not found` (exit status 127). |
| **Root cause** | The server uses Docker Compose v2 which is invoked as `docker compose` (space, as a plugin). The workflow was using the old v1 syntax `docker-compose` (hyphen) which is a separate binary not installed on this server. |
| **How found** | GitHub Actions logs showed `exit status 127` on the `docker-compose down` line. Confirmed by running `docker-compose --version` on server — `command not found`. Running `docker compose version` worked correctly. |
| **Fix applied** | Replaced all instances of `docker-compose` with `docker compose` in `.github/workflows/deploy.yml`. Also removed `--remove-orphans` flag which was not supported in this Docker version. Hardcoded the app path as `/home/pasindu/app` instead of using `${{ secrets.SSH_USER }}` which doesn't expand inside script blocks. |
| **Result** | GitHub Actions successfully pulls code, rebuilds Docker images, and restarts containers automatically on every push to `main`. |

```yaml
# deploy.yml fix — use docker compose (v2 syntax)
script: |
  set -e
  cd /home/pasindu/app
  git pull origin main
  docker compose down
  docker compose build --no-cache
  docker compose up -d
  docker image prune -f
  docker compose ps
  echo "==> Deployment complete!"
```

***

## Issue 6 — SSH authorized_keys overwritten accidentally

| Field | Detail |
|---|---|
| **Problem** | After creating the `pasindu` deploy user, SSH login was denied with `Permission denied (publickey)` even though the key was copied. |
| **Root cause** | During setup, the command `echo "PASTE_KEY_HERE" > /home/pasindu/.ssh/authorized_keys` was run literally instead of replacing `PASTE_KEY_HERE` with the actual public key. This overwrote the real key with the literal string. |
| **How found** | `cat /home/pasindu/.ssh/authorized_keys` showed the text `PASTE_KEY_HERE` instead of a real ECDSA public key. |
| **Fix applied** | Restored the correct ECDSA public key from `/root/.ssh/authorized_keys`. Reset permissions: `chmod 700 ~/.ssh && chmod 600 ~/.ssh/authorized_keys`. |
| **Result** | SSH key authentication restored for `pasindu` user. |

```bash
# Restore correct key
echo "ecdsa-sha2-nistp521 AAAA..." > /home/pasindu/.ssh/authorized_keys
chown -R pasindu:pasindu /home/pasindu/.ssh
chmod 700 /home/pasindu/.ssh
chmod 600 /home/pasindu/.ssh/authorized_keys
```

***

## Issue 7 — Certbot SSL certificate fails for DuckDNS domain

| Field | Detail |
|---|---|
| **Problem** | `sudo certbot --nginx -d pasinduj.duckdns.org` failed with `DNS problem: SERVFAIL looking up A for pasinduj.duckdns.org`. |
| **Root cause** | DuckDNS nameservers returned SERVFAIL to Let's Encrypt's DNS validation servers — a known intermittent issue with DuckDNS and Let's Encrypt [documented in community forums]. The domain resolved correctly from the server itself (`ping pasinduj.duckdns.org` worked) but Let's Encrypt's external DNS resolvers could not verify it. |
| **How found** | Certbot output showed `Type: dns` error. Verified domain resolves locally with `ping pasinduj.duckdns.org` (returned correct IP). Confirmed this is a known DuckDNS/Let's Encrypt intermittent issue. |
| **Fix applied** | Documented the issue. HTTP site remains fully accessible at `http://pasinduj.duckdns.org`. Certbot is installed and configured — retry with `sudo certbot --nginx -d pasinduj.duckdns.org` when DuckDNS DNS propagates fully. |
| **Result** | HTTP working. HTTPS pending DuckDNS DNS resolution stabilizing. Auto-renewal is pre-configured via `certbot.timer` systemd service. |

```bash
# Retry command when DNS resolves
sudo certbot --nginx -d pasinduj.duckdns.org

# Verify auto-renewal once cert is obtained
sudo certbot renew --dry-run
```