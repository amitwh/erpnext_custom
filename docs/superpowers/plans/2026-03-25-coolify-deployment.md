# Coolify Deployment Implementation Plan

> **For agentic workers:** REQUIRED: Use superpowers:subagent-driven-development (if subagents available) or superpowers:executing-plans to implement this plan. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add all files needed to build and deploy this custom ERPNext v16 instance on Coolify, with shared MariaDB and Redis in a separate Coolify project.

**Architecture:** Coolify builds a custom Docker image from `Containerfile` in this repo (copies local ERPNext source + installs 6 additional Frappe apps). The app is deployed via `docker-compose.yml` which connects to shared MariaDB and Redis services defined in `deploy/shared/docker-compose.yml`. Coolify's built-in Traefik handles SSL for `erp.concreteinfo.co.in`.

**Tech Stack:** Docker multi-stage build, frappe/build:version-16, frappe/base:version-16, MariaDB 11.8, Redis 6.2-alpine, Docker Compose v2, Coolify

**Spec:** `docs/superpowers/specs/2026-03-25-coolify-deployment-design.md`

---

## File Map

| File | Action | Responsibility |
|------|--------|---------------|
| `.dockerignore` | Create | Exclude .git, docs, node_modules from build context |
| `Containerfile` | Create | Multi-stage build: bench init + copy app + install deps |
| `docker-compose.yml` | Create | ERPNext services (backend, frontend, workers, scheduler) |
| `deploy/shared/docker-compose.yml` | Create | Shared MariaDB + Redis infrastructure |
| `.env.example` | Create | Reference for all env vars needed in Coolify UI |
| `deploy/COOLIFY_SETUP.md` | Create | Step-by-step Coolify UI setup guide |

---

## Chunk 1: Build Context and Containerfile

### Task 1: Create .dockerignore

**Files:**
- Create: `.dockerignore`

- [ ] **Step 1: Create .dockerignore**

```
# Version control
.git
.github
.gitignore
.git-blame-ignore-revs

# Python cache
__pycache__
*.pyc
*.pyo
*.pyd
.Python
*.egg-info

# Node
node_modules
.npm

# Linting / editor config
.eslintrc
.editorconfig
.flake8
.pre-commit-config.yaml
.semgrepignore
.coderabbit.yml
.stylelintrc
sider.yml
codecov.yml

# Secrets and local env
.env
.env.*
!.env.example

# Deploy and docs (infrastructure YAML + markdown, not needed in image)
docs/
deploy/
*.md

# Test artifacts
.pytest_cache
coverage.xml
htmlcov/

# Misc root files not needed at runtime
yarn.lock
babel_extractors.csv
CODEOWNERS
crowdin.yml
commitlint.config.js
license.txt
package.json
sponsors.md
TRADEMARK_POLICY.md
transaction-deletion-import-logic-summary.md
```

- [ ] **Step 2: Verify build context is lean**

```bash
# From repo root — check how many files would be sent to Docker daemon
find . -not -path './.git/*' | wc -l
# With .dockerignore in place, this count is just informational.
# Key: .git directory must NOT appear in `docker build --no-cache .` output
```

- [ ] **Step 3: Commit**

```bash
git add .dockerignore
git commit -m "build: add .dockerignore for lean Docker build context"
```

---

### Task 2: Create Containerfile

**Files:**
- Create: `Containerfile`

- [ ] **Step 1: Create Containerfile**

```dockerfile
ARG FRAPPE_BRANCH=version-16

# ── Builder stage ──────────────────────────────────────────────────────────────
# Uses frappe/build which has: Python, Node, bench CLI, wkhtmltopdf, chromium
FROM frappe/build:${FRAPPE_BRANCH} AS builder

ARG FRAPPE_BRANCH=version-16
ARG FRAPPE_PATH=https://github.com/frappe/frappe

USER frappe

# 1. Initialise bench with Frappe framework only (no ERPNext from upstream)
RUN bench init \
    --frappe-branch=${FRAPPE_BRANCH} \
    --frappe-path=${FRAPPE_PATH} \
    --no-procfile \
    --no-backups \
    --skip-redis-config-generation \
    --verbose \
    /home/frappe/frappe-bench && \
    cd /home/frappe/frappe-bench && \
    echo "{}" > sites/common_site_config.json

# 2. Inject this custom ERPNext as the erpnext app
#    The build context is the repo root (Coolify checks out the repo before building)
COPY --chown=frappe:frappe . /home/frappe/frappe-bench/apps/erpnext/

# 3. Register custom ERPNext in the bench virtualenv
RUN /home/frappe/frappe-bench/env/bin/pip install \
    --no-cache-dir \
    -e /home/frappe/frappe-bench/apps/erpnext

# 4. Install additional Frappe apps in dependency order:
#    payments first (required_apps dependency of hrms)
#    then hrms, then standalone apps
RUN cd /home/frappe/frappe-bench && \
    bench get-app --branch develop  https://github.com/frappe/payments  && \
    bench get-app --branch version-16 https://github.com/frappe/hrms     && \
    bench get-app --branch main     https://github.com/frappe/helpdesk  && \
    bench get-app --branch main     https://github.com/frappe/crm       && \
    bench get-app --branch develop  https://github.com/frappe/lms       && \
    bench get-app --branch main     https://github.com/frappe/drive

# 5. Strip .git directories to reduce final image size
RUN find /home/frappe/frappe-bench/apps -mindepth 1 -path "*/.git" | xargs rm -fr

# ── Runtime stage ──────────────────────────────────────────────────────────────
# Uses frappe/base which is a lean Debian image with runtime dependencies only
FROM frappe/base:${FRAPPE_BRANCH} AS backend

USER frappe

COPY --from=builder --chown=frappe:frappe \
    /home/frappe/frappe-bench \
    /home/frappe/frappe-bench

WORKDIR /home/frappe/frappe-bench

VOLUME [ \
    "/home/frappe/frappe-bench/sites", \
    "/home/frappe/frappe-bench/logs" \
]

CMD [ \
    "/home/frappe/frappe-bench/env/bin/gunicorn", \
    "--chdir=/home/frappe/frappe-bench/sites", \
    "--bind=0.0.0.0:8000", \
    "--threads=4", \
    "--workers=2", \
    "--worker-class=gthread", \
    "--worker-tmp-dir=/dev/shm", \
    "--timeout=120", \
    "--preload", \
    "frappe.app:application" \
]
```

- [ ] **Step 2: Lint the Containerfile (if hadolint is available)**

```bash
hadolint Containerfile || echo "hadolint not installed — skip"
# Common issues to check manually:
# - COPY --chown flag present (required for frappe user permissions)
# - No RUN as root after USER frappe
# - pip install has --no-cache-dir
```

- [ ] **Step 3: Commit**

```bash
git add Containerfile
git commit -m "build: add Containerfile for custom ERPNext v16 with all apps"
```

---

## Chunk 2: Application Docker Compose

### Task 3: Create docker-compose.yml

**Files:**
- Create: `docker-compose.yml`

Note: This compose file is designed for Coolify. It has NO bundled reverse proxy — Coolify's
Traefik handles SSL termination for `erp.concreteinfo.co.in`. The `frontend` service exposes
port 8080 internally; Coolify routes the domain to it.

- [ ] **Step 1: Create docker-compose.yml**

```yaml
# ERPNext v16 — Coolify deployment
# Project: concreteinfo | App: erpnext-16
#
# Prerequisites (set in Coolify environment editor):
#   DB_HOST, DB_PORT, DB_PASSWORD
#   REDIS_CACHE, REDIS_QUEUE
#
# Coolify builds the image from Containerfile at repo root.
# SSL and domain routing handled by Coolify's built-in Traefik.
# Shared MariaDB + Redis defined in deploy/shared/docker-compose.yml.

x-customizable-image: &customizable_image
  image: ${CUSTOM_IMAGE:-erpnext-16}:${CUSTOM_TAG:-latest}
  pull_policy: ${PULL_POLICY:-never}
  restart: ${RESTART_POLICY:-unless-stopped}

x-depends-on-configurator: &depends_on_configurator
  depends_on:
    configurator:
      condition: service_completed_successfully

x-backend-defaults: &backend_defaults
  <<: [*depends_on_configurator, *customizable_image]
  platform: linux/amd64
  volumes:
    - sites:/home/frappe/frappe-bench/sites
  networks:
    - bench-network
    - shared-network

services:

  # One-shot service: writes common_site_config.json with DB/Redis connection info.
  # All other services wait for this to complete before starting.
  # Note: only *customizable_image is merged here — NOT *depends_on_configurator,
  # since configurator must not depend on itself.
  configurator:
    <<: *customizable_image
    platform: linux/amd64
    entrypoint:
      - bash
      - -c
    command:
      - >
        ls -1 apps > sites/apps.txt;
        bench set-config -g db_host $$DB_HOST;
        bench set-config -gp db_port $$DB_PORT;
        bench set-config -g redis_cache "redis://$$REDIS_CACHE";
        bench set-config -g redis_queue "redis://$$REDIS_QUEUE";
        bench set-config -g redis_socketio "redis://$$REDIS_QUEUE";
        bench set-config -gp socketio_port $$SOCKETIO_PORT;
    environment:
      DB_HOST: ${DB_HOST}
      DB_PORT: ${DB_PORT:-3306}
      REDIS_CACHE: ${REDIS_CACHE}
      REDIS_QUEUE: ${REDIS_QUEUE}
      SOCKETIO_PORT: 9000
    depends_on: {}
    restart: on-failure
    volumes:
      - sites:/home/frappe/frappe-bench/sites
    networks:
      - bench-network
      - shared-network

  backend:
    <<: *backend_defaults

  frontend:
    <<: *customizable_image
    platform: linux/amd64
    command:
      - nginx-entrypoint.sh
    environment:
      BACKEND: backend:8000
      SOCKETIO: websocket:9000
      # Site name must match the Frappe site created with bench new-site
      FRAPPE_SITE_NAME_HEADER: ${FRAPPE_SITE_NAME_HEADER:-erp.concreteinfo.co.in}
      # Real IP passthrough: trust Coolify's Traefik on the Docker bridge network
      UPSTREAM_REAL_IP_ADDRESS: ${UPSTREAM_REAL_IP_ADDRESS:-172.0.0.0/8}
      UPSTREAM_REAL_IP_HEADER: ${UPSTREAM_REAL_IP_HEADER:-X-Forwarded-For}
      UPSTREAM_REAL_IP_RECURSIVE: ${UPSTREAM_REAL_IP_RECURSIVE:-on}
      PROXY_READ_TIMEOUT: ${PROXY_READ_TIMEOUT:-120}
      CLIENT_MAX_BODY_SIZE: ${CLIENT_MAX_BODY_SIZE:-50m}
    volumes:
      - sites:/home/frappe/frappe-bench/sites
    networks:
      - bench-network
      # shared-network required so Coolify's Traefik (which attaches to shared-network)
      # can reach the frontend container to route erp.concreteinfo.co.in traffic.
      - shared-network
    depends_on:
      - backend
      - websocket
    # Port 8080 is exposed internally — Coolify's Traefik routes the domain here.
    # Do NOT bind to a host port; let Coolify manage the routing.
    expose:
      - "8080"

  websocket:
    <<: [*depends_on_configurator, *customizable_image]
    platform: linux/amd64
    command:
      - node
      - /home/frappe/frappe-bench/apps/frappe/socketio.js
    volumes:
      - sites:/home/frappe/frappe-bench/sites
    networks:
      - bench-network
      - shared-network

  queue-short:
    <<: *backend_defaults
    command: bench worker --queue short,default

  queue-long:
    <<: *backend_defaults
    # long worker also consumes short,default as fallback coverage
    command: bench worker --queue long,default,short

  scheduler:
    <<: *backend_defaults
    command: bench schedule

volumes:
  sites:

networks:
  # Internal network for service-to-service communication within this bench
  bench-network:
    name: erpnext-16-bench

  # External network shared with MariaDB and Redis (defined in deploy/shared/)
  shared-network:
    name: shared-network
    external: true
```

- [ ] **Step 2: Validate compose syntax**

```bash
# Requires a .env file with dummy values to resolve variables
cat > /tmp/test.env <<'EOF'
CUSTOM_IMAGE=erpnext-16
CUSTOM_TAG=latest
PULL_POLICY=never
DB_HOST=mariadb-shared
DB_PORT=3306
DB_PASSWORD=test
REDIS_CACHE=redis-cache-shared:6379
REDIS_QUEUE=redis-queue-shared:6379
EOF

docker compose --env-file /tmp/test.env -f docker-compose.yml config > /dev/null
echo "Exit code: $?"
# Expected: Exit code: 0
# If it fails with "network shared-network declared as external but could not be found"
# that is expected in a local environment without the shared network — the YAML is valid.
```

- [ ] **Step 3: Commit**

```bash
git add docker-compose.yml
git commit -m "deploy: add docker-compose.yml for Coolify erpnext-16 app"
```

---

## Chunk 3: Shared Infrastructure

### Task 4: Create deploy/shared/docker-compose.yml

**Files:**
- Create: `deploy/shared/docker-compose.yml`

This compose file is deployed in Coolify's **"shared"** project. It creates the `shared-network`
Docker network that the ERPNext compose connects to as `external: true`.

- [ ] **Step 1: Create deploy/shared/docker-compose.yml**

```bash
mkdir -p deploy/shared
```

```yaml
# Shared infrastructure for all Frappe/ERPNext benches on this server.
# Deploy this in Coolify project: "shared"
#
# Creates:
#   mariadb-shared     — MariaDB 11.8 database server
#   redis-cache-shared — Redis for Frappe caching (ephemeral)
#   redis-queue-shared — Redis for background job queues (persistent)
#   shared-network     — Docker network bridging shared services to app benches
#
# Required env var in Coolify:
#   DB_PASSWORD — root password for MariaDB

services:

  mariadb:
    image: mariadb:11.8
    container_name: mariadb-shared
    restart: unless-stopped
    healthcheck:
      test: ["CMD", "healthcheck.sh", "--connect", "--innodb_initialized"]
      start_period: 10s
      interval: 10s
      timeout: 5s
      retries: 10
    command:
      - --character-set-server=utf8mb4
      - --collation-server=utf8mb4_unicode_ci
      - --skip-character-set-client-handshake
      - --skip-innodb-read-only-compressed
    environment:
      MYSQL_ROOT_PASSWORD: ${DB_PASSWORD}
      # Allow root connections from any host (required so bench new-site can connect
      # from the backend container across the Docker network)
      MARIADB_ROOT_HOST: "%"
      MARIADB_AUTO_UPGRADE: "1"
    volumes:
      - mariadb-data:/var/lib/mysql
    networks:
      - shared-network

  redis-cache:
    image: redis:6.2-alpine
    container_name: redis-cache-shared
    restart: unless-stopped
    # No persistence — cache data is ephemeral by design
    networks:
      - shared-network

  redis-queue:
    image: redis:6.2-alpine
    container_name: redis-queue-shared
    restart: unless-stopped
    # Persist queue data so background jobs survive container restarts
    volumes:
      - redis-queue-data:/data
    networks:
      - shared-network

volumes:
  mariadb-data:
    # MariaDB data — back this up regularly
    # Coolify volume backup: Settings → Backup
  redis-queue-data:

networks:
  shared-network:
    # This network is created here. The ERPNext compose references it as external: true.
    # Name must match exactly: shared-network
    name: shared-network
```

- [ ] **Step 2: Validate compose syntax**

```bash
echo "DB_PASSWORD=test" > /tmp/shared-test.env
docker compose --env-file /tmp/shared-test.env \
    -f deploy/shared/docker-compose.yml config > /dev/null
echo "Exit code: $?"
# Expected: Exit code: 0
```

- [ ] **Step 3: Commit**

```bash
git add deploy/shared/docker-compose.yml
git commit -m "deploy: add shared MariaDB + Redis docker-compose for Coolify shared project"
```

---

## Chunk 4: Environment Reference and Setup Guide

### Task 5: Create .env.example

**Files:**
- Create: `.env.example`

- [ ] **Step 1: Create .env.example**

```bash
# ERPNext v16 — Coolify Environment Variables Reference
# Copy relevant variables into Coolify's environment editor for the erpnext-16 app.
# Never commit real secrets. This file documents variable names and defaults only.
#
# Coolify builds the image and injects CUSTOM_IMAGE / CUSTOM_TAG automatically.
# The variables below are for the docker-compose.yml runtime configuration.

# ── Image (managed by Coolify build) ──────────────────────────────────────────
# Coolify sets CUSTOM_IMAGE and CUSTOM_TAG from the build configuration.
# PULL_POLICY=never because Coolify builds the image locally (not pulled from registry).
CUSTOM_IMAGE=erpnext-16
CUSTOM_TAG=latest
PULL_POLICY=never
RESTART_POLICY=unless-stopped

# ── Database ──────────────────────────────────────────────────────────────────
# DB_HOST: container_name of MariaDB from deploy/shared/docker-compose.yml
DB_HOST=mariadb-shared
DB_PORT=3306
# DB_PASSWORD: must match the DB_PASSWORD set in the "shared" project
DB_PASSWORD=

# ── Redis ─────────────────────────────────────────────────────────────────────
# Container names from deploy/shared/docker-compose.yml
REDIS_CACHE=redis-cache-shared:6379
REDIS_QUEUE=redis-queue-shared:6379

# ── Site ──────────────────────────────────────────────────────────────────────
# Must match the site name used in: bench new-site erp.concreteinfo.co.in
FRAPPE_SITE_NAME_HEADER=erp.concreteinfo.co.in

# ── Nginx tuning (optional — defaults shown) ──────────────────────────────────
# Increase PROXY_READ_TIMEOUT if print formats or reports time out
PROXY_READ_TIMEOUT=120
# Increase CLIENT_MAX_BODY_SIZE if users upload large files/attachments
CLIENT_MAX_BODY_SIZE=50m

# ── Real IP (Coolify Traefik passthrough) ─────────────────────────────────────
# Coolify's Traefik proxy forwards traffic from its own container IP on the Docker
# network. Set to the Docker bridge CIDR so nginx trusts X-Forwarded-For from Traefik.
# The 172.0.0.0/8 range covers the default Docker network subnets used by Coolify.
# If Coolify is configured with a custom network CIDR, update this accordingly.
UPSTREAM_REAL_IP_ADDRESS=172.0.0.0/8
UPSTREAM_REAL_IP_HEADER=X-Forwarded-For
UPSTREAM_REAL_IP_RECURSIVE=on
```

- [ ] **Step 2: Verify .env.example is in .gitignore allowlist**

```bash
# .env (no extension) should be gitignored, but .env.example should NOT be.
# Check current .gitignore:
grep "env" .gitignore
# Expected: .env or *.env should appear, but NOT .env.example
# If .env.example is being ignored, add an exception:
# echo '!.env.example' >> .gitignore
```

- [ ] **Step 3: Commit**

```bash
git add .env.example
git commit -m "deploy: add .env.example with all Coolify environment variables documented"
```

---

### Task 6: Create Coolify Setup Guide

**Files:**
- Create: `deploy/COOLIFY_SETUP.md`

- [ ] **Step 1: Create deploy/COOLIFY_SETUP.md**

```markdown
# Coolify Setup Guide — ERPNext v16

This guide walks through setting up the full ERPNext v16 stack on Coolify.

## Prerequisites

- Coolify instance running (v4+)
- DNS `A` record: `erp.concreteinfo.co.in` → your server IP
- This repo pushed to a git remote accessible by Coolify

---

## Step 1: Deploy Shared Infrastructure ("shared" project)

1. In Coolify, create project **"shared"** (if not already exists)
2. Add a new **Docker Compose** resource in "shared"
3. Point it to this repo, set compose file path: `deploy/shared/docker-compose.yml`
4. In the environment editor, set:
   ```
   DB_PASSWORD=<strong-random-password>
   ```
5. Deploy. Verify all 3 containers are running:
   - `mariadb-shared`
   - `redis-cache-shared`
   - `redis-queue-shared`
6. Note the `DB_PASSWORD` value — you will need it in Step 2.

---

## Step 2: Create ERPNext App ("concreteinfo" project)

1. In Coolify, create project **"concreteinfo"**
2. Add a new **Docker Compose** resource, app name: **erpnext-16**
3. Source: this git repo, compose file: `docker-compose.yml`
4. Build: set Dockerfile path to `Containerfile` (Coolify builds the image on push)
5. Set domain: `https://erp.concreteinfo.co.in` on the `frontend` service (port `8080`)

### Environment Variables

In Coolify's environment editor, add all variables from `.env.example`.
**Required values to set (no defaults):**

| Variable | Value |
|----------|-------|
| `DB_PASSWORD` | Same password set in Step 1 |
| `DB_HOST` | `mariadb-shared` |
| `DB_PORT` | `3306` |
| `REDIS_CACHE` | `redis-cache-shared:6379` |
| `REDIS_QUEUE` | `redis-queue-shared:6379` |

6. Deploy. The first build will take ~10–20 minutes (cloning 6 Frappe apps).

---

## Step 3: Create the ERPNext Site

After containers are running, exec into the `backend` container:

```bash
# In Coolify UI: erpnext-16 → backend container → Terminal
# OR via SSH on the server:
docker exec -it <backend-container-name> bash
```

Run:

```bash
bench new-site \
  --mariadb-user-host-login-scope=% \
  --db-root-password <DB_PASSWORD> \
  --install-app erpnext \
  --admin-password <admin-password> \
  erp.concreteinfo.co.in
```

Install additional apps to the site (optional, run separately):

```bash
# HR & Payroll
bench --site erp.concreteinfo.co.in install-app hrms

# Customer Support
bench --site erp.concreteinfo.co.in install-app helpdesk

# CRM
bench --site erp.concreteinfo.co.in install-app crm

# Learning Management
bench --site erp.concreteinfo.co.in install-app lms

# File Storage
bench --site erp.concreteinfo.co.in install-app drive
```

---

## Step 4: Verify

1. Open `https://erp.concreteinfo.co.in` in a browser
2. Log in with `Administrator` / `<admin-password>`
3. Confirm installed apps: Settings → Installed Apps

---

## Updating ERPNext

To update after code changes:

1. Push to the branch Coolify tracks
2. Coolify rebuilds the image and redeploys automatically
3. After redeploy, run bench migrate if schema changed:

```bash
# In backend container terminal:
bench --site erp.concreteinfo.co.in migrate
```

---

## Troubleshooting

**Containers restart-loop on startup:**
Check configurator logs. Likely cause: DB_HOST or REDIS_CACHE env vars not set,
or shared-network doesn't exist yet (shared project not deployed first).

**Site not loading / 502:**
- Check frontend and backend container logs in Coolify
- Verify `bench new-site` was run (Step 3)
- Confirm FRAPPE_SITE_NAME_HEADER matches the site name exactly

**Database connection refused:**
- Confirm `mariadb-shared` container is healthy in Coolify
- Confirm both projects are on `shared-network`
- In Coolify: both resources must be in the same server
```

- [ ] **Step 2: Commit**

```bash
git add deploy/COOLIFY_SETUP.md
git commit -m "docs: add step-by-step Coolify setup guide"
```

---

## Final Step: Push Branch

- [ ] **Push coolify-deployment branch for review**

```bash
git push -u origin coolify-deployment
```

Review all 5 committed files:
- `.dockerignore`
- `Containerfile`
- `docker-compose.yml`
- `deploy/shared/docker-compose.yml`
- `.env.example`
- `deploy/COOLIFY_SETUP.md`

When satisfied, merge to your default branch (e.g. `develop`).
