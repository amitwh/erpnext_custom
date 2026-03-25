ARG FRAPPE_BRANCH=version-16

# ── Builder stage ──────────────────────────────────────────────────────────────
# Uses frappe/build which has: Python, Node, bench CLI, wkhtmltopdf, chromium
FROM frappe/build:${FRAPPE_BRANCH} AS builder

ARG FRAPPE_BRANCH=version-16
ARG FRAPPE_PATH=https://github.com/frappe/frappe

USER frappe

# Increase Node.js memory limit to prevent OOM during asset builds
ENV NODE_OPTIONS=--max-old-space-size=4096

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
COPY --chown=frappe:frappe . /home/frappe/frappe-bench/apps/erpnext/

# 3. Register custom ERPNext in the bench virtualenv and install its JS deps
RUN cd /home/frappe/frappe-bench && \
    ./env/bin/pip install --no-cache-dir -e apps/erpnext && \
    cd apps/erpnext && yarn install --check-files && \
    cd /home/frappe/frappe-bench && bench build --app erpnext

# 4. Install additional Frappe apps (each in its own layer for caching).
#    bench get-app handles: git clone → pip install → yarn install → bench build
RUN cd /home/frappe/frappe-bench && \
    bench get-app --branch develop https://github.com/frappe/payments
RUN cd /home/frappe/frappe-bench && \
    bench get-app --branch version-16 https://github.com/frappe/hrms
RUN cd /home/frappe/frappe-bench && \
    bench get-app --branch main https://github.com/frappe/helpdesk
RUN cd /home/frappe/frappe-bench && \
    bench get-app --branch main https://github.com/frappe/crm
RUN cd /home/frappe/frappe-bench && \
    bench get-app --branch develop https://github.com/frappe/lms
RUN cd /home/frappe/frappe-bench && \
    bench get-app --branch main https://github.com/frappe/drive

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
