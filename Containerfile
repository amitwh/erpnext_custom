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

# 4. Install additional Frappe apps in dependency order.
#    Each app is a separate RUN for Docker layer caching — if one fails,
#    previous apps don't need to be re-downloaded.
#    --skip-assets: defer asset building to a single bench build at the end
#    (avoids intermediate build failures from apps with complex frontend builds)
RUN cd /home/frappe/frappe-bench && \
    bench get-app --skip-assets --branch develop  https://github.com/frappe/payments
RUN cd /home/frappe/frappe-bench && \
    bench get-app --skip-assets --branch version-16 https://github.com/frappe/hrms
RUN cd /home/frappe/frappe-bench && \
    bench get-app --skip-assets --branch main https://github.com/frappe/helpdesk
RUN cd /home/frappe/frappe-bench && \
    bench get-app --skip-assets --branch main https://github.com/frappe/crm
RUN cd /home/frappe/frappe-bench && \
    bench get-app --skip-assets --branch develop https://github.com/frappe/lms
RUN cd /home/frappe/frappe-bench && \
    bench get-app --skip-assets --branch main https://github.com/frappe/drive

# 5. Install JS dependencies and build frontend assets
#    - yarn install in each app that has a package.json (onscan.js for ERPNext POS, etc.)
#    - bench build compiles all frontend assets (esbuild + vite)
RUN cd /home/frappe/frappe-bench && \
    for app in apps/*/; do \
        if [ -f "$app/package.json" ]; then \
            echo "Installing JS deps for $app" && \
            cd /home/frappe/frappe-bench/$app && yarn install --check-files 2>/dev/null; \
            cd /home/frappe/frappe-bench; \
        fi; \
    done && \
    bench build

# 6. Strip .git directories to reduce final image size
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
