#!/usr/bin/env bash
# =============================================================================
# TesseraBX production deploy / update script (overlay model).
#
# This is the heart of the tesserabx-deploy repo. On the production host it:
#   1. Syncs the upstream TesseraBX repo into a persistent working dir.
#   2. Vendors private add-ons (cloned with the host's git credentials)
#      into the upstream tree's modules/ folder.
#   3. Overlays this repo's files (overlay/, e.g. box.addons.json and
#      compose.override.yaml) onto the upstream tree.
#   4. Materializes the production .env.
#   5. Takes a best-effort pre-deploy database backup.
#   6. Builds and (re)starts the stack with docker compose.
#   7. Waits for the app container to report healthy.
#
# It is idempotent and safe to re-run. The GitHub workflow at
# .github/workflows/deploy.yml runs it on a self-hosted runner that lives
# on the production host; you can also run it by hand on that host.
#
# Configuration is via environment variables (see the block below); the
# workflow sets them from repo variables and secrets.
# =============================================================================
set -euo pipefail

# --- resolve the deploy repo root (this script lives in scripts/) ------------
DEPLOY_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# --- configuration (override via env; defaults suit this repo) ---------------
# Upstream product repo. Change for your own upstream or a mirror.
UPSTREAM_REPO="${UPSTREAM_REPO:-git@github.com:oistechnologies/tesserabx.git}"
# Floating by default: deploy whatever tesserabx.version says, else main.
UPSTREAM_REF="${UPSTREAM_REF_OVERRIDE:-$(tr -d '[:space:]' < "${DEPLOY_DIR}/tesserabx.version" 2>/dev/null || true)}"
UPSTREAM_REF="${UPSTREAM_REF:-main}"
# Persistent working dir on the prod host. MUST live outside the runner's
# ephemeral workspace so the upstream checkout, vendored add-ons, and the
# named docker volumes survive between jobs. Must be writable by the runner.
WORKDIR="${WORKDIR:-/opt/tesserabx}"
# Stable compose project name so the db_data / redis_data named volumes are
# the SAME across every deploy, regardless of which directory runs compose.
export COMPOSE_PROJECT_NAME="${COMPOSE_PROJECT_NAME:-tesserabx}"
# Number of cbq worker replicas (scheduler is always a single replica).
WORKER_SCALE="${WORKER_SCALE:-1}"
# Where to keep pre-deploy DB dumps on the host.
BACKUP_DIR="${BACKUP_DIR:-${WORKDIR}/.deploy-backups}"
# Fallback .env source on the host, used only when TESSERABX_DOTENV is unset.
ENV_FILE="${ENV_FILE:-${DEPLOY_DIR}/.env}"

log(){ printf '\n[deploy] %s\n' "$*"; }

# Read a single KEY=value out of the materialized .env without executing it.
env_get(){
    grep -E "^$1=" "${WORKDIR}/.env" 2>/dev/null | tail -1 | cut -d= -f2- \
        | sed -e 's/^"//' -e 's/"$//' -e "s/^'//" -e "s/'\$//"
}

# --- GitHub auth (HTTPS) for cloning private repos ---------------------------
# When GH_TOKEN is set (a PAT or GitHub App token with read access to the
# upstream and any private add-on repos), rewrite GitHub SSH/HTTPS URLs to
# authenticated HTTPS for THIS process only. One token can read multiple
# private repos, which SSH deploy keys cannot (a deploy key is single-repo),
# and it avoids any SSH host-key / known_hosts setup on the runner. The token
# is passed via env (GIT_CONFIG_*), never written to ~/.gitconfig or a
# .git/config, and is not echoed (log lines print the clean SSH URL).
if [ -n "${GH_TOKEN:-}" ]; then
    export GIT_CONFIG_COUNT=2
    export GIT_CONFIG_KEY_0="url.https://x-access-token:${GH_TOKEN}@github.com/.insteadOf"
    export GIT_CONFIG_VALUE_0="git@github.com:"
    export GIT_CONFIG_KEY_1="url.https://x-access-token:${GH_TOKEN}@github.com/.insteadOf"
    export GIT_CONFIG_VALUE_1="https://github.com/"
fi

# --- 1. sync upstream --------------------------------------------------------
log "Upstream: ${UPSTREAM_REPO} @ ${UPSTREAM_REF}  ->  ${WORKDIR}"
if [ ! -d "${WORKDIR}/.git" ]; then
    mkdir -p "$(dirname "${WORKDIR}")"
    git clone "${UPSTREAM_REPO}" "${WORKDIR}"
fi
git -C "${WORKDIR}" fetch --prune origin
# reset --hard touches only TRACKED upstream files; our untracked overlay
# files and vendored add-ons under modules/ survive (we re-apply them below).
if git -C "${WORKDIR}" rev-parse --verify --quiet "origin/${UPSTREAM_REF}" >/dev/null; then
    git -C "${WORKDIR}" checkout -B "${UPSTREAM_REF}" "origin/${UPSTREAM_REF}"
    git -C "${WORKDIR}" reset --hard "origin/${UPSTREAM_REF}"
else
    git -C "${WORKDIR}" checkout --force "${UPSTREAM_REF}"   # a tag or SHA
fi
log "Upstream now at $(git -C "${WORKDIR}" rev-parse --short HEAD)"

# --- 2. vendor private add-ons -----------------------------------------------
# Private add-ons cannot be installed from inside the docker build (no git
# credentials there), so the runner clones them on the host (where it has
# SSH access) directly into the upstream tree's modules/. They are then
# COPYed into the image by the upstream Dockerfile. Public / ForgeBox
# add-ons go in overlay/box.addons.json instead (installed during the build).
PRIVATE_ADDONS="${DEPLOY_DIR}/addons.private"
if [ -f "${PRIVATE_ADDONS}" ]; then
    while read -r url ref slug || [ -n "${url:-}" ]; do
        case "${url}" in ''|'#'*) continue ;; esac          # skip blanks/comments
        ref="${ref:-main}"
        slug="${slug:-$(basename "${url%.git}")}"
        target="${WORKDIR}/modules/${slug}"
        log "Vendoring private add-on '${slug}' (${url} @ ${ref})"
        rm -rf "${target}"
        if ! git clone --depth 1 --branch "${ref}" "${url}" "${target}" 2>/dev/null; then
            git clone "${url}" "${target}"
            git -C "${target}" checkout --force "${ref}"
        fi
        rm -rf "${target}/.git"                              # not a nested repo
    done < "${PRIVATE_ADDONS}"
fi

# --- 3. overlay this repo's files --------------------------------------------
log "Overlaying deploy files onto ${WORKDIR}"
if [ -d "${DEPLOY_DIR}/overlay" ]; then
    cp -a "${DEPLOY_DIR}/overlay/." "${WORKDIR}/"
fi

# --- 4. materialize .env -----------------------------------------------------
log "Materializing ${WORKDIR}/.env"
if [ -n "${TESSERABX_DOTENV:-}" ]; then
    printf '%s' "${TESSERABX_DOTENV}" > "${WORKDIR}/.env"
elif [ -f "${ENV_FILE}" ]; then
    cp "${ENV_FILE}" "${WORKDIR}/.env"
else
    echo "[deploy] ERROR: no .env source. Set the TESSERABX_DOTENV secret or place a file at ${ENV_FILE}." >&2
    exit 1
fi
chmod 600 "${WORKDIR}/.env"

# --- 5. preflight: external proxy network must exist -------------------------
PROXY_NETWORK="$(env_get PROXY_NETWORK)"
if [ -n "${PROXY_NETWORK}" ] && ! docker network inspect "${PROXY_NETWORK}" >/dev/null 2>&1; then
    echo "[deploy] ERROR: external docker network '${PROXY_NETWORK}' (PROXY_NETWORK) does not exist." >&2
    echo "[deploy]        Create it, or point PROXY_NETWORK at your reverse proxy's network." >&2
    echo "[deploy]        e.g.  docker network create ${PROXY_NETWORK}" >&2
    exit 1
fi

cd "${WORKDIR}"

# --- 6. pre-deploy database backup (best effort) -----------------------------
log "Pre-deploy database backup (best effort)"
mkdir -p "${BACKUP_DIR}"
db_cid="$(docker compose ps -q db 2>/dev/null || true)"
if [ -n "${db_cid}" ] && [ "$(docker inspect -f '{{.State.Running}}' "${db_cid}" 2>/dev/null || echo false)" = "true" ]; then
    stamp="$(date -u +%Y%m%d-%H%M%SZ)"
    out="${BACKUP_DIR}/predeploy-${stamp}.sql.gz"
    if docker compose exec -T -e PGPASSWORD="$(env_get DB_PASSWORD)" db \
         pg_dump -U "$(env_get DB_USER)" "$(env_get DB_NAME)" | gzip > "${out}"; then
        log "Backup written: ${out}"
    else
        log "WARNING: pre-deploy backup failed; continuing."
        rm -f "${out}"
    fi
else
    log "db container not running yet; skipping backup (first deploy)."
fi

# --- 7. build and (re)start --------------------------------------------------
# compose auto-loads compose.yaml + compose.override.yaml from WORKDIR. We do
# NOT pass compose.dev.yaml, so this is a production composition.
log "docker compose up -d --build  (project: ${COMPOSE_PROJECT_NAME}, worker scale: ${WORKER_SCALE})"
docker compose up -d --build --remove-orphans --scale "worker=${WORKER_SCALE}"

# --- 8. wait for app health --------------------------------------------------
log "Waiting for app to report healthy..."
deadline=$(( $(date +%s) + 300 ))
app_cid="$(docker compose ps -q app)"
while :; do
    status="$(docker inspect -f '{{ if .State.Health }}{{ .State.Health.Status }}{{ else }}none{{ end }}' "${app_cid}" 2>/dev/null || echo unknown)"
    [ "${status}" = "healthy" ] && { log "app is healthy."; break; }
    if [ "$(date +%s)" -ge "${deadline}" ]; then
        log "ERROR: app did not become healthy in time. Recent logs:"
        docker compose logs --tail=60 app || true
        exit 1
    fi
    sleep 5
done

log "Deploy complete: upstream $(git rev-parse --short HEAD), project ${COMPOSE_PROJECT_NAME}."
