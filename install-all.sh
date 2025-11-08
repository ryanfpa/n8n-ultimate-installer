#!/bin/bash
# ====================================================================
# N8N VIP PRO v4 - FINAL SAFE EDITION
# by Ryan F.P.A & ChatGPT
# ====================================================================
set -e

if [[ $EUID -ne 0 ]]; then
  echo "❌ Chạy: sudo $0"; exit 1
fi

CYAN='\033[0;36m'; GREEN='\033[0;32m'; NC='\033[0m'

clear
echo -e "${CYAN}========== N8N VIP PRO v4 • FINAL SAFE EDITION ==========${NC}"
read -p "🌐 Domain public cho N8N (vd: n8mini.h2d.site): " DOMAIN
read -p "🔑 Cloudflare TUNNEL_TOKEN: " CF_TUNNEL_TOKEN
[[ -z "$DOMAIN" || -z "$CF_TUNNEL_TOKEN" ]] && { echo "❌ Thiếu Domain hoặc Token."; exit 1; }

START=$(date +%s)
N8N_DIR="/home/n8n"; DATA_DIR="$N8N_DIR/n8n_data"; SCRIPTS="$N8N_DIR/scripts"; LOGS="$N8N_DIR/logs"
mkdir -p "$DATA_DIR" "$SCRIPTS" "$LOGS" "$N8N_DIR/backups"

echo -e "${CYAN}→ Cài đặt Docker (nếu chưa có)...${NC}"
if ! command -v docker &>/dev/null; then
  apt update -qq
  apt install -y -qq ca-certificates curl gnupg lsb-release
  install -m 0755 -d /etc/apt/keyrings
  curl -fsSL https://download.docker.com/linux/ubuntu/gpg | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
  echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu $(lsb_release -cs) stable" > /etc/apt/sources.list.d/docker.list
  apt update -qq && apt install -y -qq docker-ce docker-ce-cli containerd.io docker-compose-plugin
  systemctl enable docker && systemctl start docker
fi
echo -e "${GREEN}✅ Docker OK${NC}"

# ---------------- docker-compose.yml ----------------
echo -e "${CYAN}→ Tạo docker-compose.yml...${NC}"
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
      - GENERIC_TIMEZONE=Asia/Ho_Chi_Minh
      - TZ=Asia/Ho_Chi_Minh
    volumes:
      - ./n8n_data:/home/node/.n8n
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
EOF

# ---------------- Systemd ----------------
echo -e "${CYAN}→ Tạo systemd service...${NC}"
cat > /etc/systemd/system/n8n.service <<EOF
[Unit]
Description=N8N VIP PRO v4
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
systemctl daemon-reload && systemctl enable n8n.service

# ---------------- Utility Scripts ----------------
echo -e "${CYAN}→ Tạo scripts thông minh...${NC}"

# Backup
cat > "$SCRIPTS/backup.sh" <<'EOF'
#!/bin/bash
BACKUP_DIR="/home/n8n/backups"
mkdir -p $BACKUP_DIR
FILE="$BACKUP_DIR/n8n_backup_$(date +%Y%m%d_%H%M%S).tar.gz"
tar -czf "$FILE" -C /home/n8n n8n_data
ls -t $BACKUP_DIR/n8n_backup_*.tar.gz | tail -n +8 | xargs -r rm
echo "✅ Backup: $FILE"
EOF
chmod +x "$SCRIPTS/backup.sh"

# Update only N8N
cat > "$SCRIPTS/update.sh" <<'EOF'
#!/bin/bash
cd /home/n8n || exit 1
echo "📦 Pulling latest N8N..."
docker pull n8nio/n8n:latest
echo "🧹 Cleaning old images..."
docker image prune -f > /dev/null
echo "🔄 Restarting N8N container..."
docker compose stop n8n && docker compose rm -f n8n
docker compose up -d n8n
echo "✅ N8N updated successfully!"
EOF
chmod +x "$SCRIPTS/update.sh"

# Health-check (optional)
cat > "$SCRIPTS/health-check.sh" <<'EOF'
#!/bin/bash
if ! docker ps | grep -q n8n; then
  echo "⚠️ N8N stopped, restarting..."
  cd /home/n8n && docker compose up -d n8n
fi
if ! docker ps | grep -q cloudflared; then
  echo "⚠️ Tunnel stopped, restarting..."
  cd /home/n8n && docker compose up -d cloudflared
fi
EOF
chmod +x "$SCRIPTS/health-check.sh"

# Dashboard CLI
cat > /usr/local/bin/n8nstatus <<'EOF'
#!/bin/bash
clear
echo "╔════════════════════════════════════════════════════╗"
echo "║                N8N STATUS DASHBOARD               ║"
echo "╚════════════════════════════════════════════════════╝"
IP=$(hostname -I | awk '{print $1}')
echo "🌐 IP: $IP"
echo "⏰ Uptime: $(uptime -p)"
free -h | awk '/Mem/{print "📊 RAM: " $3 " / " $2}'
df -h / | awk 'NR==2{print "💾 Disk: "$3" / "$2" ("$5")"}'
docker ps --format "table {{.Names}}\t{{.Status}}\t{{.Ports}}"
LATEST=$(ls -t /home/n8n/backups/n8n_backup_*.tar.gz 2>/dev/null | head -1)
[ -n "$LATEST" ] && echo "💾 Last backup: $(basename $LATEST)"
EOF
chmod +x /usr/local/bin/n8nstatus

# Aliases
cat >> /root/.bashrc <<'EOF'

alias n8nupdate='/home/n8n/scripts/update.sh'
alias n8nbackup='/home/n8n/scripts/backup.sh'
alias n8nrestart='cd /home/n8n && docker compose restart'
alias n8nlogs='cd /home/n8n && docker compose logs -f n8n'
alias n8nstatus='/usr/local/bin/n8nstatus'
EOF
source /root/.bashrc

# ---------------- Start containers ----------------
echo -e "${CYAN}→ Khởi động stack N8N + Cloudflared...${NC}"
cd "$N8N_DIR" && docker compose up -d
(crontab -l 2>/dev/null; echo "0 */6 * * * $SCRIPTS/backup.sh" ; echo "*/5 * * * * $SCRIPTS/health-check.sh") | crontab -

END=$(date +%s)
DUR=$((END-START))
echo -e "${GREEN}✅ Cài đặt hoàn tất (${DUR}s)${NC}"
echo -e "🌐 Truy cập: https://${DOMAIN}"
echo -e "🔹 Kiểm tra: n8nstatus"
echo -e "🔹 Backup:   n8nbackup"
echo -e "🔹 Update:   n8nupdate (chỉ update n8n)"