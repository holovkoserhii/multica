#!/bin/bash
# Deploy/update Multica on the GCP VM (run ON the VM, from ~/multica).
# Prerequisites (already done on the VM): Docker, Caddy, UFW, repo cloned to ~/multica.
#
# First run:   DATABASE_URL='postgresql://...neon.tech/neondb?sslmode=require' \
#              ALLOWED_EMAILS='me@example.com' ./deploy/gcp/deploy.sh
# Later runs:  ./deploy/gcp/deploy.sh          (pulls repo + images, keeps .env)
#
# Images come from the fork's own CI (ghcr.io/holovkoserhii/*), not upstream.
set -euo pipefail
cd "$(dirname "$0")/../.."

IP=$(curl -fsS -H 'Metadata-Flavor: Google' \
  http://metadata.google.internal/computeMetadata/v1/instance/network-interfaces/0/access-configs/0/external-ip)
HOST="${MULTICA_HOST:-${IP//./-}.sslip.io}"
APP="https://app.$HOST"; API="https://api.$HOST"
COMPOSE="docker compose -f docker-compose.selfhost.yml -f deploy/gcp/docker-compose.neon.yml"

# Back up DB + uploads before anything changes: a new image may run irreversible
# migrations on startup. Skipped on the very first deploy (no .env yet) or with
# SKIP_BACKUP=1.
if [[ -f .env && "${SKIP_BACKUP:-0}" != 1 ]]; then
  ./deploy/gcp/backup.sh
fi

git pull -q --ff-only

set_env() { # key value — replace or append in .env
  if grep -q "^$1=" .env; then sed -i "s|^$1=.*|$1=$2|" .env; else echo "$1=$2" >> .env; fi
}

if [[ ! -f .env ]]; then
  : "${DATABASE_URL:?set DATABASE_URL (Neon direct connection string) for the first run}"
  : "${ALLOWED_EMAILS:?set ALLOWED_EMAILS (comma-separated) for the first run}"
  cp .env.example .env && chmod 600 .env
  set_env JWT_SECRET "$(openssl rand -hex 32)"
  set_env MULTICA_VCS_SECRET_KEY "$(openssl rand -hex 32)"
fi
[[ -n "${DATABASE_URL:-}" ]] && set_env DATABASE_URL "$DATABASE_URL"
[[ -n "${ALLOWED_EMAILS:-}" ]] && set_env ALLOWED_EMAILS "$ALLOWED_EMAILS"

set_env APP_ENV production
set_env FRONTEND_ORIGIN "$APP"
set_env MULTICA_APP_URL "$APP"
set_env GOOGLE_REDIRECT_URI "$APP/auth/callback"
set_env MULTICA_PUBLIC_URL "$API"
set_env MULTICA_DAEMON_SERVER_URL "$API"
set_env MULTICA_TRUSTED_PROXIES "127.0.0.1/32,172.16.0.0/12"
set_env RATE_LIMIT_TRUSTED_PROXIES "127.0.0.1/32,172.16.0.0/12"
set_env MULTICA_BACKEND_IMAGE ghcr.io/holovkoserhii/multica-backend
set_env MULTICA_WEB_IMAGE ghcr.io/holovkoserhii/multica-web
set_env MULTICA_COLLAB_IMAGE ghcr.io/holovkoserhii/multica-collab
set_env DO_NOT_TRACK 1

# The caddy user cannot read /home/ubuntu, so the rendered config goes to /etc/caddy.
sed "s|__HOST__|$HOST|g" deploy/gcp/Caddyfile.template | sudo tee /etc/caddy/Caddyfile >/dev/null
sudo caddy validate --config /etc/caddy/Caddyfile --adapter caddyfile >/dev/null
sudo systemctl enable --now caddy >/dev/null 2>&1
sudo systemctl reload caddy

$COMPOSE pull backend frontend
$COMPOSE up -d --remove-orphans backend frontend
docker image prune -f >/dev/null

echo "App: $APP"
echo "API: $API   (multica config set server_url $API)"
echo "Login code (no email provider): docker logs multica-backend-1 2>&1 | grep 'Verification code'"
