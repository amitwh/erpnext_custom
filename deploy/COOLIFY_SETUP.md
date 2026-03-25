# Coolify Setup Guide — ERPNext v16

This guide walks through setting up ERPNext v16 on your existing Coolify instance.

## Prerequisites

- Coolify instance running (v4+) with Traefik proxy
- DNS `A` record: `erp.concreteinfo.co.in` → your server IP
- Existing `shared-mariadb` database in the **"shared"** Coolify project
- This repo pushed to GitHub (`amitwh/erpnext_custom`)

---

## Existing Infrastructure

This deployment connects to your existing shared resources:

| Resource | Location | Container UUID |
|----------|----------|---------------|
| MariaDB 11 | shared → shared-mariadb | `i80wocgogs4cc0kc0owokk4s` |
| Traefik proxy | Coolify managed | `coolify-proxy` |

Redis cache and queue are **embedded** in this app's docker-compose (bench-specific).

---

## Step 1: Create ERPNext App ("concreteinfo" project)

1. In Coolify, open existing project **"concreteinfo"**
2. Add a new **Docker Compose** resource, app name: **erpnext-16**
3. Source: `amitwh/erpnext_custom`, branch: `coolify-deployment`
4. Compose file path: `docker-compose.yml`
5. Build: set Dockerfile/Containerfile path to `Containerfile`
6. Set domain: `https://erp.concreteinfo.co.in` on the `frontend` service (port `8080`)

### Environment Variables

In Coolify's environment editor, set the following:

```env
# Image (Coolify build manages these — set explicitly if auto-detection fails)
CUSTOM_IMAGE=erpnext-16
CUSTOM_TAG=latest
PULL_POLICY=never

# Database — points to existing shared-mariadb via coolify network
DB_HOST=i80wocgogs4cc0kc0owokk4s
DB_PORT=3306

# Redis — uses embedded services (defaults work, no change needed)
# REDIS_CACHE=redis-cache:6379
# REDIS_QUEUE=redis-queue:6379

# Site
FRAPPE_SITE_NAME_HEADER=erp.concreteinfo.co.in
```

7. Deploy. The first build will take ~10–20 minutes (building from Containerfile, cloning 6 Frappe apps).

---

## Step 2: Create the ERPNext Site

After all containers are running, exec into the `backend` container:

```bash
# In Coolify UI: erpnext-16 → backend container → Terminal
# OR via SSH on the server:
docker exec -it <backend-container-id> bash
```

Get the MariaDB root password from Coolify:
**shared → shared-mariadb → Root Password**

Run:

```bash
bench new-site \
  --mariadb-user-host-login-scope=% \
  --db-root-password <MARIADB_ROOT_PASSWORD> \
  --install-app erpnext \
  --admin-password <your-admin-password> \
  erp.concreteinfo.co.in
```

Install additional apps to the site:

```bash
bench --site erp.concreteinfo.co.in install-app hrms
bench --site erp.concreteinfo.co.in install-app helpdesk
bench --site erp.concreteinfo.co.in install-app crm
bench --site erp.concreteinfo.co.in install-app lms
bench --site erp.concreteinfo.co.in install-app drive
```

---

## Step 3: Verify

1. Open `https://erp.concreteinfo.co.in` in a browser
2. Log in with `Administrator` / `<your-admin-password>`
3. Confirm installed apps: Settings → Installed Apps

---

## Updating ERPNext

To update after code changes:

1. Push to the branch Coolify tracks (`coolify-deployment`)
2. Coolify rebuilds the image and redeploys automatically
3. After redeploy, run bench migrate if schema changed:

```bash
# In backend container terminal:
bench --site erp.concreteinfo.co.in migrate
```

---

## Architecture

```
Coolify "concreteinfo" project
└── erpnext-16 (Docker Compose)
    ├── redis-cache          (Redis 6.2, ephemeral — bench-specific)
    ├── redis-queue          (Redis 6.2, persisted — bench-specific)
    ├── configurator         (one-shot: writes site config)
    ├── backend              (gunicorn :8000)
    ├── frontend             (nginx :8080) ← Traefik routes erp.concreteinfo.co.in
    ├── websocket            (socketio :9000)
    ├── queue-short          (bench worker)
    ├── queue-long           (bench worker)
    └── scheduler            (bench schedule)
    ├── network: erpnext-16-bench (internal)
    └── network: coolify (external — reaches shared-mariadb + Traefik)

Coolify "shared" project (pre-existing)
└── shared-mariadb           (MariaDB 11, on coolify network)
```

---

## Troubleshooting

**Containers restart-loop on startup:**
Check configurator logs. Likely cause: DB_HOST env var not set or MariaDB unreachable.
Verify the backend container can reach MariaDB: `mysql -h i80wocgogs4cc0kc0owokk4s -u root -p`

**Site not loading / 502:**
- Check frontend and backend container logs in Coolify
- Verify `bench new-site` was run (Step 2)
- Confirm FRAPPE_SITE_NAME_HEADER matches the site name exactly

**Database connection refused:**
- Confirm `shared-mariadb` is healthy in Coolify
- Both the ERPNext compose and MariaDB must be on the `coolify` network
- MariaDB root must allow remote connections (`MARIADB_ROOT_HOST: %`)

**Redis connection issues:**
- Redis is embedded — check `redis-cache` and `redis-queue` container logs
- Both are on `bench-network` along with all app services
