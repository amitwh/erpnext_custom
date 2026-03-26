# Coolify Setup Guide — ERPNext v16

Live at: https://erp.concreteinfo.co.in/

## Architecture

```
Coolify "concreteinfo" project → erpnext-16 (Docker Compose)
├── redis-cache          (Redis 6.2, ephemeral)
├── redis-queue          (Redis 6.2, persisted)
├── configurator         (one-shot: writes site config)
├── backend              (gunicorn :8000)
├── frontend             (nginx :8080) ← Traefik routes erp.concreteinfo.co.in
├── websocket            (socketio :9000)
├── queue-short / queue-long / scheduler
├── network: erpnext-16-bench (internal)
└── network: coolify (external — reaches shared-mariadb + Traefik)

Coolify "shared" project (pre-existing)
└── shared-mariadb (MariaDB 11, UUID: i80wocgogs4cc0kc0owokk4s)
```

## Installed Apps

| App | Version | Branch | Notes |
|-----|---------|--------|-------|
| Frappe | 16.12.1 | version-16 | Framework |
| ERPNext | 16.11.0 | version-16 | Custom fork (this repo) |
| Payments | 0.0.1 | develop | Payment integrations |
| HRMS | 16.4.5 | version-16 | HR & Payroll |
| Telephony | 0.0.1 | develop | Required by Helpdesk |
| Helpdesk | 1.21.3 | main | Customer support |
| CRM | 1.62.2 | main | Sales CRM |
| LMS | 2.45.2 | develop | Learning management |

**Drive** was removed — requires Rust compiler for `pycrdt` dependency.

## What's in the Docker Image vs Post-Deploy

**Image (Containerfile):** Frappe + ERPNext + Payments only.
Apps with complex vite frontends fail during Docker BuildKit parallel builds.

**Post-deploy (on running container):** HRMS, Telephony, Helpdesk, CRM, LMS are installed
via `bench get-app` on the backend container. A post-deployment command in Coolify
automatically runs `bench build` + asset sync after each deploy.

## Key Coolify Settings

| Setting | Value |
|---------|-------|
| App UUID | `o6ei61rlqc24bbdl22lb8rnc` |
| Build pack | `dockercompose` |
| Compose file | `/docker-compose.yml` |
| `docker_compose_domains` | `frontend` → `https://erp.concreteinfo.co.in:8080` |
| `docker_compose_location` | `/docker-compose.yml` |
| Post-deploy command | `bench build` + asset copy (on `backend` container) |

## Environment Variables (in Coolify)

```
DB_HOST=i80wocgogs4cc0kc0owokk4s
DB_PORT=3306
REDIS_CACHE=redis-cache:6379
REDIS_QUEUE=redis-queue:6379
FRAPPE_SITE_NAME_HEADER=erp.concreteinfo.co.in
UPSTREAM_REAL_IP_ADDRESS=172.0.0.0/8
UPSTREAM_REAL_IP_RECURSIVE=on
SERVICE_FQDN_FRONTEND_8080=https://erp.concreteinfo.co.in
```

## Post-Deploy: Adding New Apps

After a fresh deploy (or if apps are missing), exec into the backend container:

```bash
BACKEND=$(docker ps --format '{{.Names}}' | grep "backend.*o6ei61rlqc24bbdl22lb8rnc")
docker exec -it $BACKEND bash

# Install apps
bench get-app --branch version-16 https://github.com/frappe/hrms
bench get-app --branch develop https://github.com/frappe/telephony
bench get-app --branch main https://github.com/frappe/helpdesk
bench get-app --branch main https://github.com/frappe/crm
bench get-app --branch develop https://github.com/frappe/lms

# Install on site
bench --site erp.concreteinfo.co.in install-app hrms
bench --site erp.concreteinfo.co.in install-app helpdesk
bench --site erp.concreteinfo.co.in install-app crm
bench --site erp.concreteinfo.co.in install-app lms

# Migrate and rebuild assets
bench --site erp.concreteinfo.co.in migrate
bench build

# Sync assets to shared volume (required for nginx/frontend)
cd sites/assets
for app in $(ls -1 /home/frappe/frappe-bench/apps/); do
    if [ -L "$app" ]; then
        target=$(readlink "$app")
        rm "$app"
        cp -r "$target" "$app" 2>/dev/null
    fi
done
```

## Troubleshooting

**CSS/JS not loading (404):**
Assets are symlinked to per-container app dirs. After `bench build`, run the asset
sync loop above to copy actual files into the shared sites volume.

**"No available server" (503):**
Traefik can't reach the frontend. Ensure `traefik.docker.network=coolify` label
is on the frontend service in docker-compose.yml.

**500 Internal Server Error after installing apps:**
Run `bench --site erp.concreteinfo.co.in migrate` and restart the backend container.

**Database connection refused:**
MariaDB is on the `coolify` network. Check `DB_HOST` matches the MariaDB container UUID.
