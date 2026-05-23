#!/usr/bin/env bash
# -----------------------------------------------------------------------------
# Multica — Oracle Cloud Always Free bootstrap script
#
# Tested on: Ubuntu 22.04 / 24.04 (Ampere A1 ARM64 and x86_64)
#
# Usage (run as the default OCI user, e.g. ubuntu):
#   curl -fsSL https://raw.githubusercontent.com/<your-fork>/multica/main/deploy/oracle-cloud/setup.sh | bash
#
# Or clone the repo first, then:
#   bash deploy/oracle-cloud/setup.sh
#
# After the script finishes:
#   1. Edit ~/multica/.env  (set DOMAIN, email options, etc.)
#   2. Edit ~/multica/Caddyfile  (replace placeholder domain)
#   3. sudo systemctl reload caddy
# -----------------------------------------------------------------------------
set -euo pipefail

REPO_URL="${MULTICA_REPO_URL:-https://github.com/holovkoserhii/multica.git}"
INSTALL_DIR="${MULTICA_INSTALL_DIR:-$HOME/multica}"
BRANCH="${MULTICA_BRANCH:-main}"

GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

log()  { echo -e "${GREEN}[multica]${NC} $*"; }
warn() { echo -e "${YELLOW}[warn]${NC} $*"; }
die()  { echo -e "${RED}[error]${NC} $*" >&2; exit 1; }

# ---------------------------------------------------------------------------
# 1. System packages
# ---------------------------------------------------------------------------
log "Updating package lists..."
sudo apt-get update -q

log "Installing prerequisites..."
sudo apt-get install -yq \
  ca-certificates \
  curl \
  gnupg \
  lsb-release \
  ufw \
  git \
  jq

# ---------------------------------------------------------------------------
# 2. Docker CE
# ---------------------------------------------------------------------------
if ! command -v docker &>/dev/null; then
  log "Installing Docker CE..."
  curl -fsSL https://get.docker.com | sudo sh
  sudo usermod -aG docker "$USER"
  warn "You were added to the 'docker' group. Changes take effect in your next login session."
  warn "For this script, continuing with sudo for Docker commands."
  DOCKER="sudo docker"
  COMPOSE="sudo docker compose"
else
  log "Docker already installed: $(docker --version)"
  DOCKER="docker"
  COMPOSE="docker compose"
fi

# Docker Compose v2 is bundled with Docker CE as the 'compose' plugin.
if ! $DOCKER compose version &>/dev/null 2>&1; then
  die "Docker Compose plugin not found. Install Docker CE 20.10+ which includes it."
fi

# ---------------------------------------------------------------------------
# 3. Caddy
# ---------------------------------------------------------------------------
if ! command -v caddy &>/dev/null; then
  log "Installing Caddy..."
  sudo apt-get install -yq debian-keyring debian-archive-keyring apt-transport-https
  curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/gpg.key' \
    | sudo gpg --dearmor -o /usr/share/keyrings/caddy-stable-archive-keyring.gpg
  curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/debian.deb.txt' \
    | sudo tee /etc/apt/sources.list.d/caddy-stable.list
  sudo apt-get update -q
  sudo apt-get install -yq caddy
else
  log "Caddy already installed: $(caddy version)"
fi

# ---------------------------------------------------------------------------
# 4. UFW firewall
# ---------------------------------------------------------------------------
log "Configuring UFW firewall..."
sudo ufw --force reset
sudo ufw default deny incoming
sudo ufw default allow outgoing
sudo ufw allow ssh
sudo ufw allow 80/tcp
sudo ufw allow 443/tcp
sudo ufw allow 443/udp
sudo ufw --force enable
log "UFW status:"
sudo ufw status verbose

# NOTE: You must also open ports 80 and 443 in the OCI Security List / Network Security Group
# for your VCN subnet via the OCI Console or CLI. The script cannot do this for you.
warn "IMPORTANT: Open ports 80 and 443 in your OCI Security List / NSG (OCI Console → VCN → Security Lists)."

# ---------------------------------------------------------------------------
# 5. Clone / update repository
# ---------------------------------------------------------------------------
if [[ -d "$INSTALL_DIR/.git" ]]; then
  log "Repository already exists at $INSTALL_DIR, pulling latest..."
  git -C "$INSTALL_DIR" pull --ff-only
else
  log "Cloning repository to $INSTALL_DIR..."
  git clone --branch "$BRANCH" --depth 1 "$REPO_URL" "$INSTALL_DIR"
fi

cd "$INSTALL_DIR"

# ---------------------------------------------------------------------------
# 6. Environment file
# ---------------------------------------------------------------------------
if [[ ! -f .env ]]; then
  log "Creating .env from .env.example..."
  cp .env.example .env

  # Generate a secure JWT secret
  JWT_SECRET=$(openssl rand -hex 32)
  # Generate a postgres password
  PG_PASSWORD=$(openssl rand -hex 16)

  # Patch the .env file in-place
  sed -i "s|^JWT_SECRET=.*|JWT_SECRET=${JWT_SECRET}|" .env
  sed -i "s|^POSTGRES_PASSWORD=.*|POSTGRES_PASSWORD=${PG_PASSWORD}|" .env
  sed -i "s|postgres://multica:multica@|postgres://multica:${PG_PASSWORD}@|g" .env
  sed -i "s|^APP_ENV=.*|APP_ENV=production|" .env

  log "Generated JWT_SECRET and POSTGRES_PASSWORD → .env"
else
  warn ".env already exists — skipping regeneration. Verify JWT_SECRET is set."
fi

# ---------------------------------------------------------------------------
# 7. Caddyfile
# ---------------------------------------------------------------------------
if [[ ! -f Caddyfile ]]; then
  log "Installing Caddyfile template..."
  cp deploy/oracle-cloud/Caddyfile.template Caddyfile
  warn "Edit Caddyfile and replace 'app.YOUR_DOMAIN' / 'api.YOUR_DOMAIN' with your actual domain."
else
  warn "Caddyfile already exists — not overwriting."
fi

# Tell Caddy to use our project Caddyfile instead of the system default
sudo tee /etc/caddy/Caddyfile > /dev/null <<'CADDY_REDIRECT'
# Redirect to the project Caddyfile
import /home/ubuntu/multica/Caddyfile
CADDY_REDIRECT

# Adjust home dir if user is not ubuntu
CADDYFILE_REAL="$INSTALL_DIR/Caddyfile"
sudo sed -i "s|/home/ubuntu/multica/Caddyfile|${CADDYFILE_REAL}|" /etc/caddy/Caddyfile

# ---------------------------------------------------------------------------
# 8. Pull images and start the stack
# ---------------------------------------------------------------------------
log "Pulling Multica Docker images (this may take a few minutes)..."
$COMPOSE -f docker-compose.selfhost.yml pull

log "Starting Multica stack..."
$COMPOSE -f docker-compose.selfhost.yml up -d

# ---------------------------------------------------------------------------
# 9. Enable services on boot
# ---------------------------------------------------------------------------
sudo systemctl enable caddy
sudo systemctl enable docker

# ---------------------------------------------------------------------------
# Done
# ---------------------------------------------------------------------------
echo ""
echo -e "${GREEN}============================================================${NC}"
echo -e "${GREEN}  Multica is running!${NC}"
echo -e "${GREEN}============================================================${NC}"
echo ""
echo "  Frontend: http://localhost:3000"
echo "  Backend:  http://localhost:8080"
echo ""
echo "Next steps:"
echo "  1. Set up a domain (e.g. DuckDNS: https://www.duckdns.org)"
echo "     Point 'app.yourdomain.duckdns.org' and 'api.yourdomain.duckdns.org'"
echo "     to this VM's public IP."
echo ""
echo "  2. Edit ~/multica/.env — add FRONTEND_ORIGIN, MULTICA_APP_URL, etc."
echo "     See deploy/oracle-cloud/README.md for the full checklist."
echo ""
echo "  3. Edit ~/multica/Caddyfile — replace placeholder domains."
echo ""
echo "  4. sudo systemctl reload caddy"
echo ""
echo "  5. Open ports 80 and 443 in your OCI Security List if you haven't."
echo ""
echo "Logs: $COMPOSE -f docker-compose.selfhost.yml logs -f"
echo ""
