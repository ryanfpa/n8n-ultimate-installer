#!/bin/bash
# ====================================================================
# N8N VIP PRO - CLOUDFLARE TUNNEL - FINAL SAFE EDITION
# ====================================================================

set -e

# 1. Root check
if [[ $EUID -ne 0 ]]; then
  echo "❌ This script must be run as root. Use: sudo $0"
  exit 1
fi

# 2. Nhập thông tin
read -p "🌐 Public domain cho N8N (ví dụ: n8mini.h2d.site): " DOMAIN
read -p "🔑 Cloudflare TUNNEL_TOKEN: " CF_TUNNEL_TOKEN

if [[ -z "$DOMAIN" || -z "$CF_TUNNEL_TOKEN" ]]; then
  echo "❌ Domain và Tunnel Token không được để trống."
  exit 1
fi

START_TIME=$(date +%s)

# 3. Thư mục
N8N_DIR="/home/n8n"
DATA_DIR="$N8N_DIR/data"
SCRIPTS_DIR="$N8N_DIR/scripts"
LOGS_DIR="$N8N_DIR/logs"
BACKUP_DIR="$N8N_DIR/backups"

mkdir -p "$DATA_DIR" "$SCRIPTS_DIR" "$LOGS_DIR" "$BACKUP_DIR"

# 4. Cài Docker nếu chưa có
echo "🐳 Checking / installing Docker..."
if ! command -v docker &>/dev/null; then
  apt-get update -qq
  apt-get install -y -qq ca-certificates curl gnupg lsb-release
  install -m 0755 -d /etc/apt/keyrings
  curl -fsSL https://download.docker.com/linux/ubuntu/gpg \
    | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
  echo \
    "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] \
    https://download.docker.com/linux/ubuntu $(lsb_release -cs) stable" \
    > /etc/apt/sources.list.d/docker.list
  apt-get update -qq
  apt-get install -y -qq docker-ce docker-ce-cli containerd.io docker-compose-plugin
  systemctl enable docker
  systemctl start docker
fi
echo "✅ Docker ready."

# 5. docker-compose.yml (n8n + cloudflared)
cat > "$N8N_DIR/docker-compose.yml" <<EOF
version: "3.8"

services:
  n8n:
    image: n8nio/n8n:latest
    container_name: n8n
    restart: unless-stopped
    environment:
      - N8N_HOST=${DOMAIN}
      - N8N_PORT=5678
      - N8N_PROTOCOL=https
      - WEBHOOK_URL=https://${DOMAIN}/
      - NODE_ENV=production
      - GENERIC_TIMEZONE=Asia/Ho_Chi_Minh
      - TZ=Asia/Ho_Chi_Minh
      - N8N_DIAGNOSTICS_ENABLED=false
      - N8N_PERSONALIZATION_ENABLED=false
    volumes:
      - ./data:/home/node/.n8n
    networks:
      - n8n_net
    healthcheck:
      test: ["CMD", "curl", "-f", "http://localhost:5678/healthz"]
      interval: 30s
      timeout: 10s
      retries: 5
      start_period: 40s

  cloudflared:
    image: cloudflare/cloudflared:latest
    container_name: cloudflared
    restart: unless-stopped
    command: tunnel --no-autoupdate run --token ${CF_TUNNEL_TOKEN}
    depends_on:
      - n8n
    networks:
      - n8n_net

networks:
  n8n_net:
    driver: bridge
EOF

# 6. Quyền thư mục (user 1000 trong container n8n)
chown -R 1000:1000 "$DATA_DIR"
chmod -R 755 "$N8N_DIR"

# 7. Systemd service để auto start
cat > /etc/systemd/system/n8n.service <<EOF
[Unit]
Description=N8N + Cloudflare Tunnel (Docker)
Requires=docker.service
After=docker.service

[Service]
Type=oneshot
RemainAfterExit=yes
WorkingDirectory=${N8N_DIR}
ExecStart=/usr/bin/docker compose up -d
ExecStop=/usr/bin/docker compose down
TimeoutStartSec=60
TimeoutStopSec=60

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable n8n.service

# 8. backup.sh
cat > "$SCRIPTS_DIR/backup.sh" <<'EOF'
#!/bin/bash
BACKUP_DIR="/home/n8n/backups"
mkdir -p "$BACKUP_DIR"
FILE="$BACKUP_DIR/n8n_backup_$(date +%Y%m%d_%H%M%S).tar.gz"
tar -czf "$FILE" -C /home/n8n data
ls -t $BACKUP_DIR/n8n_backup_*.tar.gz | tail -n +8 | xargs -r rm
echo "✅ Backup created: $FILE"
EOF
chmod +x "$SCRIPTS_DIR/backup.sh"

# 9. update-n8n.sh (CHỈ update n8n)
cat > "$SCRIPTS_DIR/update-n8n.sh" <<'EOF'
#!/bin/bash
cd /home/n8n || exit 1
echo "📦 Pulling latest n8n image..."
docker pull n8nio/n8n:latest
echo "🧹 Cleaning unused images..."
docker image prune -f > /dev/null
echo "🔄 Restarting only n8n container..."
docker compose stop n8n
docker compose rm -f n8n
docker compose up -d n8n
echo "✅ n8n updated successfully."
EOF
chmod +x "$SCRIPTS_DIR/update-n8n.sh"

# 10. health-check.sh (tự bật lại nếu container chết)
cat > "$SCRIPTS_DIR/health-check.sh" <<'EOF'
#!/bin/bash
cd /home/n8n || exit 0
if ! docker ps | grep -q "n8n"; then
  echo "⚠️  n8n not running, restarting..."
  docker compose up -d n8n
fi
if ! docker ps | grep -q "cloudflared"; then
  echo "⚠️  cloudflared not running, restarting..."
  docker compose up -d cloudflared
fi
EOF
chmod +x "$SCRIPTS_DIR/health-check.sh"

# 11. Alias tiện dụng
if ! grep -q "n8nupdate" /root/.bashrc 2>/dev/null; then
cat >> /root/.bashrc <<'EOF'

# N8N helpers
alias n8nupdate='/home/n8n/scripts/update-n8n.sh'
alias n8nbackup='/home/n8n/scripts/backup.sh'
alias n8nlogs='cd /home/n8n && docker compose logs -f n8n'
EOF
fi

# 12. Cron: backup 6h/lần + health-check 5 phút/lần
( crontab -l 2>/dev/null; \
  echo "0 */6 * * * /home/n8n/scripts/backup.sh >/home/n8n/logs/backup.log 2>&1"; \
  echo "*/5 * * * * /home/n8n/scripts/health-check.sh >/home/n8n/logs/health.log 2>&1" \
) | crontab -

# 13. Khởi động stack lần đầu
cd "$N8N_DIR"
echo "🚀 Starting N8N + Cloudflare Tunnel..."
docker compose up -d

END_TIME=$(date +%s)
DURATION=$((END_TIME - START_TIME))

echo ""
echo "╔══════════════════════════════════════════════════════╗"
echo "║           ✅ N8N INSTALLATION COMPLETED              ║"
echo "╠══════════════════════════════════════════════════════╣"
echo "║  🌐 Public URL (qua Cloudflare Tunnel): https://${DOMAIN}"
echo "║  📂 Data dir:      /home/n8n/data"
echo "║  🔁 Auto start:    systemctl status n8n"
echo "║  💾 Backup now:    n8nbackup"
echo "║  🔧 Update n8n:    n8nupdate  (ONLY n8n image)"
echo "╚══════════════════════════════════════════════════════╝"
echo ""
echo "👉 Trong Cloudflare Zero Trust:"
echo "   - Đảm bảo Tunnel dùng đúng TUNNEL_TOKEN này đang chạy."
echo "   - Tạo Application Route:"
echo "       Hostname: ${DOMAIN}"
echo "       Service:  http://n8n:5678"
echo ""