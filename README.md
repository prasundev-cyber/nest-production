# NestJS Production Stack

Production-grade deployment for NestJS on a dedicated VPS using Docker Compose,
Traefik, and a full Prometheus + Grafana + Loki observability stack.

## Stack Overview

| Layer | Tool | Purpose |
|---|---|---|
| Reverse Proxy | Traefik v3 | TLS termination, routing, rate limiting |
| API | NestJS (3 replicas) | Business logic, REST API |
| Database | PostgreSQL 16 | Primary data store |
| Cache / Sessions | Redis 7 | Caching, JWT blacklist, Bull queues |
| Object Storage | MinIO | S3-compatible file storage |
| Metrics | Prometheus + Grafana | Dashboards, alerting |
| Logs | Loki + Promtail | Structured log aggregation |
| Uptime | Uptime Kuma | Status page, external checks |
| CI/CD | GitHub Actions | Build, test, zero-downtime deploy |

## Why Traefik over Caddy?

Both are excellent. For this stack, Traefik wins because:
- Native Docker label integration (no file editing for new services)
- Built-in Prometheus metrics endpoint
- Dynamic config reload without restart
- Middleware composition (rate limit + auth + headers in one label)

Caddy is simpler and better for static sites or teams who prefer Caddyfile syntax.

## First-Time VPS Setup

```bash
# 1. Provision a fresh Ubuntu 22.04/24.04 VPS (min 2 vCPU, 4GB RAM)
# 2. Run the setup script as root:
curl -sSL https://your-repo/.../vps-setup.sh | sudo bash

# 3. Add your GitHub Actions SSH public key
echo "ssh-ed25519 AAAA..." >> /home/deploy/.ssh/authorized_keys

# 4. Create the Docker proxy network
docker network create proxy

# 5. Copy and edit your env file
cp .env.example /opt/app/.env
nano /opt/app/.env
```

## GitHub Actions Secrets Required

| Secret | Description |
|---|---|
| `VPS_HOST` | VPS IP address |
| `VPS_USER` | `deploy` |
| `VPS_SSH_KEY` | Private key for CI deploy |
| `VPS_PORT` | SSH port (default 2222) |
| `DOMAIN` | Your domain (e.g. example.com) |
| `SLACK_WEBHOOK` | Alert webhook URL |

## Generate Secrets

```bash
# JWT secrets
openssl rand -base64 64

# Passwords
openssl rand -base64 32

# Traefik BasicAuth
htpasswd -nB admin | sed -e 's/\$/\$\$/g'
```

## Deploy

Push to `main` — GitHub Actions handles the rest:
1. Run tests + linting
2. Build Docker image → push to GHCR
3. SSH to VPS → rolling update (1 replica at a time)
4. Health check → rollback if unhealthy
5. Smoke test the live endpoint

## URLs (after deploy)

- API: `https://api.yourdomain.com`
- Grafana: `https://grafana.yourdomain.com`
- Traefik: `https://traefik.yourdomain.com`
- Status: `https://status.yourdomain.com`
- Storage: `https://storage.yourdomain.com`

## Backup

Automated daily backup at 2am UTC:
```bash
# Add to crontab as deploy user
crontab -e
# Add: 0 2 * * * /opt/app/scripts/backup.sh >> /var/log/backup.log 2>&1
```

## Scaling

```bash
# Scale to 5 API replicas
docker compose -f docker-compose.prod.yml up -d --scale api=5
```
