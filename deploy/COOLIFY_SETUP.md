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
