#!/bin/bash
# scripts/azure-setup.sh
# Tailored for Azure Ubuntu 22.04/24.04 VMs
#
# Azure-specific differences handled:
#   1. SSH port stays 22 — Azure NSG controls firewall, NOT UFW for SSH
#   2. UFW is secondary to Azure NSG — we configure both
#   3. Azure VM Agent (waagent) must not be broken — we don't touch it
#   4. Docker GPG key already may exist — overwrite safely
#   5. 'deploy' user may already exist (Azure creates users via cloud-init)
#   6. SSH service is 'ssh' not 'sshd' on Ubuntu 22.04+
#   7. Azure serial console uses port 22 — changing SSH port needs NSG update first
#
# BEFORE running this script:
#   - Open port 2222 in your Azure NSG (Network Security Group)
#     Portal → VM → Networking → Add inbound rule → Port 2222, TCP
#   - Or keep SSH on port 22 and set SSH_PORT=22 below
#
# Usage: sudo bash azure-setup.sh
set -euo pipefail

# ── Config ───────────────────────────────────────────────────
APP_USER="deploy"
APP_DIR="/opt/app"
SSH_PORT=22        # Azure: open new port in NSG BEFORE changing this to 2222
TIMEZONE="UTC"

# ── Detect Azure environment ─────────────────────────────────
echo "==> Detecting Azure environment"
if curl -s -H "Metadata:true" \
  "http://169.254.169.254/metadata/instance?api-version=2021-02-01" \
  --connect-timeout 2 | grep -q "azEnvironment"; then
  echo "    Running on Azure VM"
  IS_AZURE=true
else
  echo "    Not detected as Azure (continuing anyway)"
  IS_AZURE=false
fi

echo "==> Setting timezone"
timedatectl set-timezone "$TIMEZONE"

echo "==> System update"
apt-get update -qq
DEBIAN_FRONTEND=noninteractive apt-get upgrade -y -qq
apt-get install -y -qq \
  curl wget git unzip jq \
  ufw fail2ban \
  htop iotop \
  logrotate \
  ca-certificates gnupg lsb-release

# ── Docker ───────────────────────────────────────────────────
echo "==> Installing Docker"

# Azure images sometimes have conflicting packages — remove them first
for pkg in docker.io docker-doc docker-compose podman-docker containerd runc; do
  apt-get remove -y $pkg 2>/dev/null || true
done

install -m 0755 -d /etc/apt/keyrings

# --yes flag avoids the interactive "Overwrite?" prompt you saw
curl -fsSL https://download.docker.com/linux/ubuntu/gpg \
  | gpg --dearmor --yes -o /etc/apt/keyrings/docker.gpg
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
cat > /etc/docker/daemon.json << 'DOCKEREOF'
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
DOCKEREOF
systemctl daemon-reload
systemctl restart docker

# ── Deploy user ──────────────────────────────────────────────
echo "==> Creating deploy user"

# Azure may have created the user via cloud-init — safe to run with || true
useradd -m -s /bin/bash "$APP_USER" 2>/dev/null || echo "    User $APP_USER already exists, skipping"
usermod -aG docker "$APP_USER"

mkdir -p /home/$APP_USER/.ssh
chmod 700 /home/$APP_USER/.ssh

# Create authorized_keys if it doesn't exist
touch /home/$APP_USER/.ssh/authorized_keys
chmod 600 /home/$APP_USER/.ssh/authorized_keys
chown -R $APP_USER:$APP_USER /home/$APP_USER/.ssh

echo "    NOTE: Add your GitHub Actions SSH public key:"
echo "    echo 'ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIMakkmXoUp3KbI9+cDDjnhDDFA8qUoGRCmwWVAAuxLEs github-actions' >> /home/$APP_USER/.ssh/authorized_keys"

# ── App directory ────────────────────────────────────────────
mkdir -p "$APP_DIR"
chown $APP_USER:$APP_USER "$APP_DIR"

# ── Firewall (UFW) ───────────────────────────────────────────
# IMPORTANT for Azure:
# Azure NSG is the primary firewall — it filters traffic BEFORE it reaches the VM.
# UFW is a secondary/defence-in-depth layer inside the VM.
# Always configure your NSG rules in Azure Portal first, then mirror them in UFW.
echo "==> Configuring UFW (secondary firewall — Azure NSG is primary)"
ufw --force reset
ufw default deny incoming
ufw default allow outgoing

# Azure VM Agent uses IMDS (169.254.169.254) — must not be blocked
# UFW allows outgoing by default so this is fine, but be aware.

ufw allow "$SSH_PORT/tcp"  comment "SSH"
ufw allow 80/tcp           comment "HTTP"
ufw allow 443/tcp          comment "HTTPS"
ufw allow 443/udp          comment "HTTPS QUIC"

ufw --force enable
ufw status verbose

# ── SSH Hardening ────────────────────────────────────────────
# Azure-specific notes:
#   - PasswordAuthentication is already 'no' on most Azure images
#   - AllowUsers: include your Azure admin user AND deploy
#     otherwise you'll lock out your admin user!
#   - If you change SSH_PORT to 2222, update NSG FIRST or you'll lose access
echo "==> Hardening SSH"

# Detect the Azure-created admin user (azureuser is the default)
AZURE_ADMIN=$(getent passwd | awk -F: '$3>=1000 && $3<65534 && $1!="deploy" {print $1; exit}')
echo "    Detected existing admin user: ${AZURE_ADMIN:-none}"

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
# Allow both the Azure admin user and deploy user
# IMPORTANT: never remove your admin user here or you'll be locked out
AllowUsers ${AZURE_ADMIN:-azureuser} $APP_USER
ClientAliveInterval 300
ClientAliveCountMax 2
EOF

# Restart SSH — Ubuntu 22.04+ uses 'ssh', older uses 'sshd'
SSH_SERVICE=""
if systemctl is-active --quiet ssh 2>/dev/null; then
  SSH_SERVICE="ssh"
elif systemctl is-active --quiet sshd 2>/dev/null; then
  SSH_SERVICE="sshd"
else
  # Not yet started — find by unit file
  if systemctl list-unit-files | grep -q "^ssh.service"; then
    SSH_SERVICE="ssh"
  elif systemctl list-unit-files | grep -q "^sshd.service"; then
    SSH_SERVICE="sshd"
  fi
fi

if [ -n "$SSH_SERVICE" ]; then
  echo "    Restarting $SSH_SERVICE..."
  systemctl restart "$SSH_SERVICE"
  echo "    SSH service restarted successfully"
else
  echo "    WARNING: SSH service not found. Reboot to apply SSH config."
fi

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
cat > /etc/sysctl.d/99-nestjs-prod.conf << 'EOF'
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

# ── Azure-specific: check VM Agent is still healthy ──────────
echo "==> Verifying Azure VM Agent"
if systemctl is-active --quiet walinuxagent 2>/dev/null; then
  echo "    walinuxagent is running (good)"
elif systemctl is-active --quiet waagent 2>/dev/null; then
  echo "    waagent is running (good)"
else
  echo "    WARNING: Azure VM Agent not detected. This may affect Azure monitoring."
fi

echo ""
echo "=================================================="
echo " Azure VM Setup Complete!"
echo "=================================================="
echo ""
echo " REQUIRED — do these now:"
echo "  1. Add GitHub Actions SSH public key:"
echo "     echo 'ssh-ed25519 AAAA...' >> /home/$APP_USER/.ssh/authorized_keys"
echo ""
echo "  2. Copy your env file:"
echo "     cp .env.example $APP_DIR/.env && nano $APP_DIR/.env"
echo ""
if [ "$SSH_PORT" != "22" ]; then
echo "  3. SSH port changed to $SSH_PORT"
echo "     Make sure Azure NSG has port $SSH_PORT open BEFORE logging out!"
echo "     Portal → VM → Networking → Add inbound security rule"
fi
echo ""
echo " Azure NSG rules needed (Portal → VM → Networking):"
echo "   Port 22   TCP   SSH (or $SSH_PORT if changed)"
echo "   Port 80   TCP   HTTP"
echo "   Port 443  TCP   HTTPS"
echo "   Port 443  UDP   HTTP/3 QUIC"
echo "=================================================="