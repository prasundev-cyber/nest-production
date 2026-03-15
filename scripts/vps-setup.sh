#!/bin/bash
# scripts/vps-setup.sh
# Run ONCE on a fresh Ubuntu 22.04/24.04 VPS as root.
# Usage: curl -sSL https://your-repo/scripts/vps-setup.sh | sudo bash
set -euo pipefail

# ── Config ───────────────────────────────────────────────────
APP_USER="deploy"
APP_DIR="/opt/app"
SSH_PORT=2222                   # Change default SSH port
TIMEZONE="UTC"

echo "==> Setting timezone"
timedatectl set-timezone "$TIMEZONE"

echo "==> System update"
apt-get update -qq
apt-get upgrade -y -qq
apt-get install -y -qq \
  curl wget git unzip jq \
  ufw fail2ban \
  htop iotop \
  logrotate \
  ca-certificates gnupg lsb-release

# ── Docker ───────────────────────────────────────────────────
echo "==> Installing Docker"
install -m 0755 -d /etc/apt/keyrings
curl -fsSL https://download.docker.com/linux/ubuntu/gpg \
  | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
chmod a+r /etc/apt/keyrings/docker.gpg

echo \
  "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] \
  https://download.docker.com/linux/ubuntu $(lsb_release -cs) stable" \
  | tee /etc/apt/sources.list.d/docker.list > /dev/null

apt-get update -qq
apt-get install -y -qq docker-ce docker-ce-cli containerd.io docker-compose-plugin

systemctl enable docker
systemctl start docker

# Docker daemon hardening
cat > /etc/docker/daemon.json << 'EOF'
{
  "log-driver": "json-file",
  "log-opts": {
    "max-size": "100m",
    "max-file": "5"
  },
  "no-new-privileges": true,
  "live-restore": true,
  "userland-proxy": false,
  "ipv6": false
}
EOF
systemctl daemon-reload
systemctl restart docker

# ── Deploy user ──────────────────────────────────────────────
echo "==> Creating deploy user"
useradd -m -s /bin/bash "$APP_USER" || true
usermod -aG docker "$APP_USER"
mkdir -p /home/$APP_USER/.ssh
chmod 700 /home/$APP_USER/.ssh

# Paste your CI/CD public key here or copy from authorized_keys
# echo "ssh-ed25519 AAAA..." > /home/$APP_USER/.ssh/authorized_keys
chmod 600 /home/$APP_USER/.ssh/authorized_keys
chown -R $APP_USER:$APP_USER /home/$APP_USER/.ssh

# ── App directory ────────────────────────────────────────────
mkdir -p "$APP_DIR"
chown $APP_USER:$APP_USER "$APP_DIR"

# ── Firewall (UFW) ───────────────────────────────────────────
echo "==> Configuring UFW firewall"
ufw --force reset
ufw default deny incoming
ufw default allow outgoing

# SSH on custom port
ufw allow "$SSH_PORT/tcp" comment "SSH custom port"
# Web traffic
ufw allow 80/tcp  comment "HTTP"
ufw allow 443/tcp comment "HTTPS"
# Allow UDP for HTTP/3 (QUIC)
ufw allow 443/udp comment "HTTPS/QUIC"

ufw --force enable
ufw status verbose

# ── SSH Hardening ────────────────────────────────────────────
echo "==> Hardening SSH"
cat > /etc/ssh/sshd_config.d/99-hardening.conf << EOF
Port $SSH_PORT
PermitRootLogin no
PasswordAuthentication no
ChallengeResponseAuthentication no
PubkeyAuthentication yes
AuthorizedKeysFile .ssh/authorized_keys
MaxAuthTries 3
LoginGraceTime 20
X11Forwarding no
AllowTcpForwarding no
AllowUsers $APP_USER
ClientAliveInterval 300
ClientAliveCountMax 2
EOF

systemctl restart sshd

# ── Fail2ban ─────────────────────────────────────────────────
echo "==> Configuring fail2ban"
cat > /etc/fail2ban/jail.local << EOF
[DEFAULT]
bantime  = 1h
findtime = 10m
maxretry = 5
backend = systemd

[sshd]
enabled = true
port = $SSH_PORT
maxretry = 3
bantime = 24h

[traefik-auth]
enabled = true
filter = traefik-auth
logpath = /var/log/traefik/access.log
maxretry = 10
EOF

systemctl enable fail2ban
systemctl restart fail2ban

# ── Kernel tuning ────────────────────────────────────────────
echo "==> Kernel tuning for high-traffic"
cat >> /etc/sysctl.d/99-nestjs-prod.conf << 'EOF'
# Network
net.core.somaxconn = 65535
net.ipv4.tcp_max_syn_backlog = 65535
net.ipv4.tcp_fin_timeout = 15
net.ipv4.tcp_tw_reuse = 1
net.core.netdev_max_backlog = 65535
net.ipv4.ip_local_port_range = 1024 65535

# Memory
vm.swappiness = 10
vm.dirty_ratio = 15
vm.dirty_background_ratio = 5

# File descriptors
fs.file-max = 1000000
EOF
sysctl --system

# ── Log rotation ─────────────────────────────────────────────
cat > /etc/logrotate.d/docker-containers << 'EOF'
/var/lib/docker/containers/*/*.log {
  rotate 7
  daily
  compress
  missingok
  delaycompress
  copytruncate
}
EOF

# ── Create Docker proxy network ──────────────────────────────
docker network create proxy 2>/dev/null || true

# ── Automatic security updates ───────────────────────────────
apt-get install -y unattended-upgrades
cat > /etc/apt/apt.conf.d/50unattended-upgrades << 'EOF'
Unattended-Upgrade::Allowed-Origins {
  "${distro_id}:${distro_codename}-security";
};
Unattended-Upgrade::Remove-Unused-Packages "true";
Unattended-Upgrade::Automatic-Reboot "false";
EOF

echo ""
echo "=================================================="
echo " VPS Setup Complete!"
echo "=================================================="
echo " Next steps:"
echo "  1. Add your CI SSH public key to /home/$APP_USER/.ssh/authorized_keys"
echo "  2. Copy your .env.production file to $APP_DIR/.env"
echo "  3. Push to main branch to trigger the first deploy"
echo "  4. SSH is now on port $SSH_PORT"
echo "=================================================="
