# Deploy Multica on Oracle Cloud Always Free

Deploy the full Multica stack (backend, frontend, PostgreSQL) on Oracle Cloud's
**Always Free** Ampere A1 instance — 4 vCPUs, 24 GB RAM, free forever.

Official Docker images from GHCR are multi-arch (amd64 **and** arm64), so they
run natively on the Ampere A1 without emulation.

---

## Prerequisites

- An [Oracle Cloud account](https://cloud.oracle.com) (free, credit card for identity verification)
- A free domain or subdomain (see [DNS setup](#3-dns-setup) below)
- SSH key pair (create with `ssh-keygen -t ed25519`)

---

## 1. Provision the VM

### 1a. Create an Ampere A1 instance

In the OCI Console → **Compute → Instances → Create Instance**:

| Field | Value |
|-------|-------|
| **Name** | `multica` |
| **Image** | Canonical Ubuntu 22.04 (or 24.04) |
| **Shape** | `VM.Standard.A1.Flex` — set **4 OCPUs, 24 GB RAM** |
| **Boot volume** | 50 GB (free allowance is 200 GB total) |
| **SSH keys** | Paste your public key |

> Always Free allows up to 4 Ampere A1 OCPUs and 24 GB RAM shared across all
> A1 instances in your tenancy. Allocate all to one instance for maximum
> headroom.

### 1b. Open firewall ports in OCI Security List

OCI has a network-level firewall (Security List / Network Security Group) that
is **separate from the VM's OS firewall**. You must open ports at both layers.

Go to: **Networking → Virtual Cloud Networks → your VCN → Security Lists → Default Security List**

Add **Ingress Rules**:

| Stateless | Source | Protocol | Dest Port | Description |
|-----------|--------|----------|-----------|-------------|
| No | 0.0.0.0/0 | TCP | 80 | HTTP (Let's Encrypt challenge) |
| No | 0.0.0.0/0 | TCP | 443 | HTTPS |

Port 22 (SSH) is already open by default. Do **not** expose ports 3000 or 8080
directly — Caddy handles TLS termination and proxies to the local services.

### 1c. Note the public IP

After the instance starts, copy its **Public IP address** from the instance
details page. You'll need it for DNS.

---

## 2. Run the setup script

SSH into the VM:
```bash
ssh ubuntu@<public-ip>
```

Run the bootstrap script (one command):
```bash
curl -fsSL \
  https://raw.githubusercontent.com/<YOUR_GITHUB_USERNAME>/multica/main/deploy/oracle-cloud/setup.sh \
  | bash
```

The script will:
1. Install Docker CE, Caddy, and UFW
2. Configure the OS-level firewall (ports 22, 80, 443)
3. Clone the repo to `~/multica`
4. Generate a random `JWT_SECRET` and `POSTGRES_PASSWORD` in `.env`
5. Pull the official multi-arch Docker images
6. Start the stack with `docker compose -f docker-compose.selfhost.yml up -d`
7. Register Caddy as a system service

> **Using your fork with custom changes?**  
> See [Using your fork's images](#using-your-forks-images) below.

---

## 3. DNS setup

You need two subdomains pointing to your VM's public IP:
- `app.yourdomain` → frontend (port 3000 via Caddy)
- `api.yourdomain` → backend API for CLI/daemon (port 8080 via Caddy)

### Free option: DuckDNS

1. Go to [duckdns.org](https://www.duckdns.org) and sign in with GitHub/Google.
2. Create two subdomains:
   - `multica-app.duckdns.org` → your VM's public IP
   - `multica-api.duckdns.org` → your VM's public IP
3. Note the token shown on the dashboard (needed for auto-renewal cron, optional).

### Custom domain

If you already own a domain, add two `A` records:
```
app    A  <public-ip>   TTL 300
api    A  <public-ip>   TTL 300
```

---

## 4. Configure domains in Caddyfile

On the VM:
```bash
cd ~/multica
nano Caddyfile   # or vim/your editor of choice
```

Replace both occurrences of `YOUR_DOMAIN` with your actual domain:
```
app.multica-app.duckdns.org {  ← replace
    ...
}

api.multica-api.duckdns.org {  ← replace
    ...
}
```

Reload Caddy to apply and obtain TLS certificates:
```bash
sudo systemctl reload caddy
```

Caddy will automatically obtain Let's Encrypt certificates. Check status:
```bash
sudo systemctl status caddy
sudo journalctl -u caddy -f
```

---

## 5. Configure environment variables

On the VM:
```bash
cd ~/multica
nano .env
```

### Minimum changes

```bash
# Set your frontend URL (used for CORS and links in emails)
FRONTEND_ORIGIN=https://app.multica-app.duckdns.org
MULTICA_APP_URL=https://app.multica-app.duckdns.org

# Public API URL (for CLI/daemon webhook URLs)
MULTICA_PUBLIC_URL=https://api.multica-api.duckdns.org
```

### Email (required for production login)

Without email, verification codes print to the backend container log:
```bash
docker compose -f docker-compose.selfhost.yml logs backend | grep "Verification code"
```

**Option A — Resend (easiest, free tier: 3,000 emails/month):**
```bash
RESEND_API_KEY=re_xxxxxxxxxxxx
RESEND_FROM_EMAIL=noreply@yourdomain.com
```

**Option B — Gmail SMTP relay:**
1. Enable 2FA on your Google account.
2. Create an App Password: Google Account → Security → App Passwords.
```bash
SMTP_HOST=smtp.gmail.com
SMTP_PORT=587
SMTP_USERNAME=you@gmail.com
SMTP_PASSWORD=<app-password>
```

**No email (dev/test only):**
```bash
APP_ENV=development
MULTICA_DEV_VERIFICATION_CODE=888888
```
> ⚠️ Never set a fixed verification code on a publicly reachable instance.

### Restart after .env changes

```bash
cd ~/multica
docker compose -f docker-compose.selfhost.yml up -d
```

---

## 6. First login

1. Open `https://app.yourdomain` in your browser.
2. Enter your email and submit.
3. Check your email for the verification code (or copy it from logs if email isn't configured).
4. You're in — create your workspace and start using Multica.

---

## 7. Install CLI and start the daemon (local machine)

Each team member who wants to run AI agents locally needs the CLI:

```bash
# macOS / Linux (Homebrew)
brew install multica-ai/tap/multica

# Linux (direct download)
curl -fsSL https://raw.githubusercontent.com/multica-ai/multica/main/scripts/install.sh | bash
```

Configure the CLI to point to your self-hosted instance:
```bash
multica setup self-host \
  --server-url https://api.yourdomain \
  --app-url https://app.yourdomain
```

This authenticates, discovers your workspace, and starts the local daemon.

---

## Using your fork's images

If you've made changes to the backend or frontend and want to deploy your own code (not the upstream images):

### Option A — Build from source on the VM (simple, slower)

```bash
cd ~/multica
docker compose \
  -f docker-compose.selfhost.yml \
  -f docker-compose.selfhost.build.yml \
  up -d --build
```

This builds both images locally on the VM. The A1's 4 vCPUs make this
reasonable (~5–10 min for a cold build).

### Option B — Build via GitHub Actions and push to GHCR (recommended)

Your fork includes `.github/workflows/docker-build.yml`, which builds
multi-arch images and pushes them to your GHCR namespace on every push to
`main` or on a tag.

1. Push to `main` (or tag a release).
2. After the workflow completes, set in `~/multica/.env`:
   ```bash
   MULTICA_BACKEND_IMAGE=ghcr.io/<YOUR_GITHUB_USERNAME>/multica-backend
   MULTICA_WEB_IMAGE=ghcr.io/<YOUR_GITHUB_USERNAME>/multica-web
   MULTICA_IMAGE_TAG=latest
   ```
3. Pull and restart:
   ```bash
   cd ~/multica
   docker compose -f docker-compose.selfhost.yml pull
   docker compose -f docker-compose.selfhost.yml up -d
   ```

> GHCR packages from public repos are public by default. If your fork is
> private, either make the packages public in GitHub settings or `docker login
> ghcr.io` on the VM with a personal access token.

---

## Useful commands

```bash
cd ~/multica

# View logs
docker compose -f docker-compose.selfhost.yml logs -f

# View individual service logs
docker compose -f docker-compose.selfhost.yml logs -f backend
docker compose -f docker-compose.selfhost.yml logs -f frontend
docker compose -f docker-compose.selfhost.yml logs -f postgres

# Restart after .env changes
docker compose -f docker-compose.selfhost.yml up -d

# Stop everything
docker compose -f docker-compose.selfhost.yml down

# Upgrade to latest images
docker compose -f docker-compose.selfhost.yml pull
docker compose -f docker-compose.selfhost.yml up -d

# Database shell
docker compose -f docker-compose.selfhost.yml exec postgres \
  psql -U multica -d multica

# Check Caddy TLS
curl -I https://app.yourdomain
sudo journalctl -u caddy -n 50
```

---

## Backup

Back up the PostgreSQL data volume regularly:

```bash
# Dump database to a file
docker compose -f docker-compose.selfhost.yml exec postgres \
  pg_dump -U multica multica > multica_backup_$(date +%Y%m%d).sql

# Restore
cat multica_backup_20260101.sql | docker compose -f docker-compose.selfhost.yml exec -T postgres \
  psql -U multica -d multica
```

For automated backups, add a cron job:
```bash
crontab -e
# Add:
0 3 * * * cd ~/multica && docker compose -f docker-compose.selfhost.yml exec -T postgres pg_dump -U multica multica > ~/backups/multica_$(date +\%Y\%m\%d).sql 2>/dev/null
```

---

## Troubleshooting

| Symptom | Fix |
|---------|-----|
| Caddy returns 502 | Services not running — check `docker compose ... logs` |
| Let's Encrypt fails | Port 80 not open in OCI Security List, or DNS not propagated yet |
| Login code not received | Check backend logs; configure `RESEND_API_KEY` or `SMTP_HOST` |
| "connection refused" on CLI | `api.yourdomain` not reachable — check Caddy config and OCI NSG |
| Images fail to pull | `docker login ghcr.io` for private fork packages |
| Out of memory | Default A1 shape may need more RAM — use 4 vCPUs / 24 GB allocation |
