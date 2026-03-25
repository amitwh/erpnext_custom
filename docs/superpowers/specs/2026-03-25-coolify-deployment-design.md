# Coolify Deployment Design — ERPNext v16 (concreteinfo)

**Date:** 2026-03-25
**Status:** Approved
**Domain:** https://cierp.concreteinfo.co.in

---

## Context

This repository is a custom fork of ERPNext v16. The goal is to deploy it on Coolify with:
- Coolify project **"concreteinfo"**, app **"erpnext-16"** — the ERPNext application stack
- Coolify project **"shared"** — MariaDB and Redis shared infrastructure

Coolify builds the Docker image from the `Containerfile` in this repo on every git push, then deploys via the `docker-compose.yml` at the repo root.

---

## Architecture

```
Coolify: "shared" project
└── deploy/shared/docker-compose.yml
    ├── mariadb-shared     (MariaDB 11.8, port 3306)
    ├── redis-cache-shared (Redis 6.2-alpine, no persistence)
    └── redis-queue-shared (Redis 6.2-alpine, persisted volume)
    └── network: shared-network

Coolify: "concreteinfo" project — app: "erpnext-16"
├── Containerfile          ← Coolify builds image here
└── docker-compose.yml     ← Coolify deploys this
    ├── configurator       (one-shot: writes common_site_config.json)
    ├── backend            (gunicorn :8000)
    ├── frontend           (nginx :8080) ← Coolify routes cierp.concreteinfo.co.in
    ├── websocket          (socketio :9000)
    ├── queue-short        (bench worker)
    ├── queue-long         (bench worker)
    └── scheduler          (bench schedule)
    ├── network: erpnext-16-bench  (internal, service-to-service)
    └── network: shared-network    (external, bridges to shared project)
```

---

## Files to Create

| File | Purpose |
|------|---------|
| `Containerfile` | Multi-stage Docker build — custom ERPNext + all apps |
| `docker-compose.yml` | ERPNext services for Coolify erpnext-16 app |
| `deploy/shared/docker-compose.yml` | MariaDB + Redis for Coolify shared project |
| `.env.example` | All env vars documented, no secrets committed |
| `deploy/COOLIFY_SETUP.md` | Step-by-step Coolify UI setup instructions |

---

## Containerfile Design

**Builder stage:** `frappe/build:version-16` — has Python, Node, bench CLI

Build sequence:
1. `bench init` — installs Frappe framework only (from `FRAPPE_PATH`)
2. `COPY . → apps/erpnext/` — injects this repo as the `erpnext` app
3. `pip install -e apps/erpnext` — registers custom ERPNext in virtualenv
4. `bench get-app` for each additional app (in dependency order):
   - `payments` @ `develop` — payment integrations, required by HRMS
   - `hrms` @ `version-16` — HR & Payroll (explicit v16 branch)
   - `helpdesk` @ `main` — customer support
   - `crm` @ `main` — standalone CRM
   - `lms` @ `develop` — learning management
   - `drive` @ `main` — file storage
5. Strip `.git` dirs to reduce image size

**Final stage:** `frappe/base:version-16` — lean runtime only

**Exposed build args:**
- `FRAPPE_BRANCH` (default: `version-16`)
- `FRAPPE_PATH` (default: `https://github.com/frappe/frappe`)

---

## docker-compose.yml Design

- No bundled reverse proxy — Coolify's Traefik handles SSL termination
- `FRAPPE_SITE_NAME_HEADER` defaults to `cierp.concreteinfo.co.in`
- `UPSTREAM_REAL_IP_HEADER: X-Forwarded-For` for correct client IP behind Coolify's Traefik
- `platform: linux/amd64` on all services
- `configurator` is one-shot (`restart: on-failure`); all other services depend on it completing
- `sites` named volume shared across all services

**Required env vars (set in Coolify UI):**
```
DB_HOST=mariadb-shared
DB_PORT=3306
DB_PASSWORD=<secret>
REDIS_CACHE=redis-cache-shared:6379
REDIS_QUEUE=redis-queue-shared:6379
```

---

## deploy/shared/docker-compose.yml Design

- `mariadb-shared` — MariaDB 11.8, utf8mb4 collation, healthcheck, `MARIADB_AUTO_UPGRADE=1`
- `redis-cache-shared` — ephemeral cache, no persistence needed
- `redis-queue-shared` — persisted volume for job queue durability
- `shared-network` created here as non-external; referenced as `external: true` in erpnext compose

---

## App Compatibility Matrix

| App | Branch | Frappe v16 Constraint |
|-----|--------|----------------------|
| erpnext (this repo) | version-16 | `>=16.0.0,<17.0.0` |
| hrms | version-16 | `>=16.0.0,<17.0.0` |
| helpdesk | main | `>=16.0.0,<17.0.0` |
| crm | main | `>=16.0.0,<17.0.0` |
| lms | develop | `<=17.0.0-dev` |
| drive | main | `>=15.0.0,<17.0.0` |
| payments | develop | no explicit constraint (works with v16) |

---

## Coolify Setup Summary

1. Deploy `deploy/shared/docker-compose.yml` in "shared" project first
2. In "concreteinfo" project, create app "erpnext-16" pointing to this repo
3. Set Coolify to build from `Containerfile` at repo root
4. Set domain `cierp.concreteinfo.co.in` on the `frontend` service (port 8080)
5. Add all env vars from `.env.example` in Coolify's environment editor
6. After first deploy, exec into `backend` to run `bench new-site`
