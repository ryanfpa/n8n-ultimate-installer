#!/bin/bash

# ============================================
# N8N ULTIMATE INSTALLER - ALL-IN-ONE
# Chỉ cần: Domain + Cloudflare Tunnel Token
# Làm HẾT: Install + Security + Monitoring + Optimization
# ============================================

set -e  # Exit on error

if [[ $EUID -ne 0 ]]; then
   echo "❌ Script cần quyền root: sudo $0"
   exit 1
fi

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
PURPLE='\033[0;35m'
CYAN='\033[0;36m'
NC='\033[0m'

# Banner
clear
echo -e "${CYAN}"
cat << "EOF"
╔══════════════════════════════════════════════════════════════╗
║                                                              ║
║   ███╗   ██╗ █████╗ ███╗   ██╗    ██╗   ██╗██╗██████╗       ║
║   ████╗  ██║██╔══██╗████╗  ██║    ██║   ██║██║██╔══██╗      ║
║   ██╔██╗ ██║╚█████╔╝██╔██╗ ██║    ██║   ██║██║██████╔╝      ║
║   ██║╚██╗██║██╔══██╗██║╚██╗██║    ╚██╗ ██╔╝██║██╔═══╝       ║
║   ██║ ╚████║╚█████╔╝██║ ╚████║     ╚████╔╝ ██║██║           ║
║   ╚═╝  ╚═══╝ ╚════╝ ╚═╝  ╚═══╝      ╚═══╝  ╚═╝╚═╝           ║
║                                                              ║
║              ULTIMATE ALL-IN-ONE INSTALLER                   ║
║   Install + Security + Monitoring + Optimization            ║
║                                                              ║
╚══════════════════════════════════════════════════════════════╝
EOF
echo -e "${NC}"

# ============================================
# INPUT: Chỉ cần 2 thông tin
# ============================================
echo -e "${YELLOW}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${YELLOW}           📝 NHẬP THÔNG TIN CẤU HÌNH (CHỈ 2 DÒNG)            ${NC}"
echo -e "${YELLOW}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo ""

read -p "🌐 Domain (vd: n8n.yourdomain.com): " DOMAIN
read -p "🔑 Cloudflare Tunnel Token: " CF_TUNNEL_TOKEN

if [ -z "$DOMAIN" ] || [ -z "$CF_TUNNEL_TOKEN" ]; then
    echo -e "${RED}❌ Domain và Token không được để trống!${NC}"
    echo ""
    echo -e "${CYAN}💡 Hướng dẫn lấy Cloudflare Tunnel Token:${NC}"
    echo "   1. https://one.dash.cloudflare.com/"
    echo "   2. Zero Trust > Networks > Tunnels"
    echo "   3. Create tunnel > Copy token"
    exit 1
fi

# Auto-detect network info
echo ""
echo -e "${CYAN}🔍 Đang phát hiện cấu hình mạng...${NC}"
INTERFACE=$(ip route | grep default | awk '{print $5}' | head -1)
CURRENT_IP=$(ip addr show $INTERFACE | grep "inet " | awk '{print $2}' | cut -d/ -f1)
GATEWAY=$(ip route | grep default | awk '{print $3}')
CIDR=$(ip addr show $INTERFACE | grep "inet " | awk '{print $2}' | cut -d/ -f2)

# Tự động đặt IP tĩnh = IP hiện tại
STATIC_IP=$CURRENT_IP
STATIC_GATEWAY=$GATEWAY
STATIC_CIDR=$CIDR
STATIC_DNS="1.1.1.1,8.8.8.8"

# Xác nhận
echo ""
echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${GREEN}✅ Cấu hình tự động phát hiện:${NC}"
echo -e "${GREEN}   • Domain:      ${DOMAIN}${NC}"
echo -e "${GREEN}   • CF Token:    ${CF_TUNNEL_TOKEN:0:30}...${NC}"
echo -e "${GREEN}   • IP tĩnh:     ${STATIC_IP}/${STATIC_CIDR}${NC}"
echo -e "${GREEN}   • Gateway:     ${STATIC_GATEWAY}${NC}"
echo -e "${GREEN}   • DNS:         ${STATIC_DNS}${NC}"
echo -e "${GREEN}   • Interface:   ${INTERFACE}${NC}"
echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo ""
echo -e "${YELLOW}⏱️  Thời gian ước tính: 5-7 phút${NC}"
echo ""
read -p "🚀 Bắt đầu cài đặt? (y/n): " CONFIRM
if [[ ! "$CONFIRM" =~ ^[Yy]$ ]]; then
    echo "❌ Đã hủy"
    exit 0
fi

# Variables
N8N_DIR="/home/n8n"
N8N_DATA_DIR="$N8N_DIR/data"
START_TIME=$(date +%s)

# Progress function
progress() {
    echo ""
    echo -e "${PURPLE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${PURPLE}[$1/12] $2${NC}"
    echo -e "${PURPLE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
}

# ============================================
# 1. CÀI ĐẶT DOCKER
# ============================================
progress "1" "Cài đặt Docker & Docker Compose..."

if ! command -v docker &> /dev/null; then
    apt-get update -qq
    apt-get install -y -qq apt-transport-https ca-certificates curl software-properties-common jq sqlite3 bc
    curl -fsSL https://download.docker.com/linux/ubuntu/gpg | apt-key add -
    add-apt-repository -y "deb [arch=amd64] https://download.docker.com/linux/ubuntu $(lsb_release -cs) stable" 
    apt-get update -qq
    apt-get install -y -qq docker-ce docker-ce-cli containerd.io docker-compose-plugin
    systemctl enable docker
    systemctl start docker
fi

# Docker optimization
mkdir -p /etc/docker
cat > /etc/docker/daemon.json << EOF
{
  "storage-driver": "overlay2",
  "log-driver": "json-file",
  "log-opts": {
    "max-size": "10m",
    "max-file": "3"
  },
  "live-restore": true,
  "userland-proxy": false
}
EOF
systemctl restart docker

echo -e "${GREEN}✅ Docker installed${NC}"

# ============================================
# 2. TẠO CẤU HÌNH N8N
# ============================================
progress "2" "Tạo cấu hình N8N với Cloudflare Tunnel..."

mkdir -p $N8N_DATA_DIR

cat > $N8N_DIR/docker-compose.yml << EOF
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
      - WEBHOOK_URL=https://${DOMAIN}
      - GENERIC_TIMEZONE=Asia/Ho_Chi_Minh
      - TZ=Asia/Ho_Chi_Minh
      - NODE_ENV=production
      - N8N_DIAGNOSTICS_ENABLED=false
      - N8N_PERSONALIZATION_ENABLED=false
      - N8N_VERSION_NOTIFICATIONS_ENABLED=false
      - N8N_TEMPLATES_ENABLED=true
      - EXECUTIONS_PROCESS=main
      - EXECUTIONS_TIMEOUT=300
      - EXECUTIONS_TIMEOUT_MAX=600
      - N8N_PAYLOAD_SIZE_MAX=16
      - NODE_OPTIONS=--max-old-space-size=2048
      - N8N_LOG_LEVEL=info
      - N8N_LOG_OUTPUT=console
      - DB_SQLITE_ENABLE_WAL=true
      - DB_SQLITE_VACUUM_ON_STARTUP=false
    volumes:
      - ${N8N_DATA_DIR}:/home/node/.n8n
    networks:
      - n8n_network
    dns:
      - 1.1.1.1
      - 8.8.8.8
    healthcheck:
      test: ["CMD", "wget", "--spider", "-q", "http://localhost:5678/healthz"]
      interval: 30s
      timeout: 10s
      retries: 3
      start_period: 40s
    deploy:
      resources:
        limits:
          cpus: '2'
          memory: 2G
        reservations:
          cpus: '0.5'
          memory: 512M

  cloudflared:
    image: cloudflare/cloudflared:latest
    container_name: cloudflared
    restart: unless-stopped
    command: tunnel run
    environment:
      - TUNNEL_TOKEN=${CF_TUNNEL_TOKEN}
    depends_on:
      n8n:
        condition: service_healthy
    networks:
      - n8n_network

networks:
  n8n_network:
    driver: bridge
    ipam:
      config:
        - subnet: 172.28.0.0/16
EOF

chown -R 1000:1000 $N8N_DATA_DIR
chmod -R 755 $N8N_DIR

echo -e "${GREEN}✅ N8N configured${NC}"

# ============================================
# 3. BẢO VỆ CHỐNG MẤT ĐIỆN
# ============================================
progress "3" "Cấu hình bảo vệ chống mất điện..."

# Journal optimization
mkdir -p /etc/systemd/journald.conf.d/
cat > /etc/systemd/journald.conf.d/power-safe.conf << EOF
[Journal]
SystemMaxUse=200M
SystemMaxFileSize=50M
RuntimeMaxUse=100M
SyncIntervalSec=60s
MaxRetentionSec=3day
MaxFileSec=1day
Storage=volatile
EOF
systemctl restart systemd-journald

# Fstab optimization
cp /etc/fstab /etc/fstab.backup
ROOT_PART=$(df / | tail -1 | awk '{print $1}')
ROOT_UUID=$(blkid -s UUID -o value $ROOT_PART)
if ! grep -q "noatime" /etc/fstab; then
    sed -i "s|UUID=${ROOT_UUID}.*|UUID=${ROOT_UUID} / ext4 defaults,noatime,errors=remount-ro 0 1|g" /etc/fstab
fi

# Log rotation
cat > /etc/logrotate.d/n8n << EOF
/home/n8n/data/logs/*.log {
    daily
    missingok
    rotate 7
    compress
    delaycompress
    notifempty
    create 0644 1000 1000
}
EOF

echo -e "${GREEN}✅ Power protection enabled${NC}"

# ============================================
# 4. BACKUP SCRIPTS
# ============================================
progress "4" "Tạo backup system..."

# Backup script
cat > $N8N_DIR/backup.sh << 'EOFBACKUP'
#!/bin/bash
BACKUP_DIR="/home/n8n/backups"
DATE=$(date +%Y%m%d_%H%M%S)
mkdir -p $BACKUP_DIR
tar -czf $BACKUP_DIR/n8n_backup_$DATE.tar.gz -C /home/n8n/data .
ls -t $BACKUP_DIR/n8n_backup_*.tar.gz | tail -n +8 | xargs -r rm
echo "✅ Backup: n8n_backup_$DATE.tar.gz"
EOFBACKUP
chmod +x $N8N_DIR/backup.sh

# Emergency backup on shutdown
cat > $N8N_DIR/backup-on-shutdown.sh << 'EOFSHUTDOWN'
#!/bin/bash
BACKUP_DIR="/home/n8n/emergency-backups"
DATE=$(date +%Y%m%d_%H%M%S)
mkdir -p $BACKUP_DIR
tar -czf $BACKUP_DIR/emergency_backup_$DATE.tar.gz \
    -C /home/n8n/data \
    database.sqlite database.sqlite-wal database.sqlite-shm \
    credentials.json config 2>/dev/null
ls -t $BACKUP_DIR/emergency_backup_*.tar.gz | tail -n +11 | xargs -r rm
EOFSHUTDOWN
chmod +x $N8N_DIR/backup-on-shutdown.sh

# Systemd service
cat > /etc/systemd/system/n8n-backup-shutdown.service << EOF
[Unit]
Description=N8N Emergency Backup on Shutdown
DefaultDependencies=no
Before=shutdown.target reboot.target halt.target

[Service]
Type=oneshot
ExecStart=$N8N_DIR/backup-on-shutdown.sh
TimeoutStartSec=30s

[Install]
WantedBy=halt.target reboot.target shutdown.target
EOF

systemctl daemon-reload
systemctl enable n8n-backup-shutdown.service

# Cron backup every 6 hours
(crontab -l 2>/dev/null; echo "0 */6 * * * $N8N_DIR/backup.sh >> /var/log/n8n-backup.log 2>&1") | crontab -

echo -e "${GREEN}✅ Backup system created${NC}"

# ============================================
# 5. SYSTEMD SERVICE
# ============================================
progress "5" "Tạo systemd service..."

cat > /etc/systemd/system/n8n.service << EOF
[Unit]
Description=N8N Automation with Cloudflare Tunnel
Requires=docker.service
After=docker.service

[Service]
Type=oneshot
RemainAfterExit=yes
WorkingDirectory=$N8N_DIR
ExecStart=/usr/bin/docker compose up -d
ExecStop=/usr/bin/docker compose down
TimeoutStartSec=60s
TimeoutStopSec=60s

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable n8n.service

echo -e "${GREEN}✅ Systemd service created${NC}"

# ============================================
# 6. ĐẶT IP TĨNH
# ============================================
progress "6" "Đặt IP tĩnh..."

# Backup netplan
BACKUP_DIR="/root/netplan-backup"
mkdir -p $BACKUP_DIR
tar -czf $BACKUP_DIR/netplan-backup-$(date +%Y%m%d_%H%M%S).tar.gz /etc/netplan/ 2>/dev/null

# Xóa config cũ
rm -f /etc/netplan/*.yaml

# Tạo config mới
DNS_ARRAY=$(echo $STATIC_DNS | sed 's/,/\n          - /g')

cat > /etc/netplan/01-netcfg.yaml << EOF
network:
  version: 2
  renderer: networkd
  ethernets:
    ${INTERFACE}:
      dhcp4: no
      dhcp6: no
      addresses:
        - ${STATIC_IP}/${STATIC_CIDR}
      routes:
        - to: default
          via: ${STATIC_GATEWAY}
      nameservers:
        addresses:
          - ${DNS_ARRAY}
      optional: true
EOF

chmod 600 /etc/netplan/01-netcfg.yaml

echo -e "${GREEN}✅ Static IP configured${NC}"

# ============================================
# 7. SECURITY
# ============================================
progress "7" "Bảo mật hệ thống..."

apt-get install -y -qq fail2ban ufw

# Fail2ban
cat > /etc/fail2ban/jail.local << EOF
[DEFAULT]
bantime = 3600
findtime = 600
maxretry = 5

[sshd]
enabled = true
EOF

systemctl enable fail2ban
systemctl restart fail2ban

# Firewall
ufw --force reset
ufw default deny incoming
ufw default allow outgoing
ufw allow ssh
ufw --force enable

echo -e "${GREEN}✅ Security hardened${NC}"

# ============================================
# 8. SWAP
# ============================================
progress "8" "Tạo swap 4GB..."

CURRENT_SWAP=$(free -m | grep Swap | awk '{print $2}')
if [ "$CURRENT_SWAP" -lt 2048 ]; then
    swapoff -a
    rm -f /swapfile
    fallocate -l 4G /swapfile
    chmod 600 /swapfile
    mkswap /swapfile
    swapon /swapfile
    
    if ! grep -q "/swapfile" /etc/fstab; then
        echo "/swapfile none swap sw 0 0" >> /etc/fstab
    fi
    
    sysctl vm.swappiness=10
    sysctl vm.vfs_cache_pressure=50
    
    cat >> /etc/sysctl.conf << EOF

# Swap optimization
vm.swappiness=10
vm.vfs_cache_pressure=50
EOF
fi

echo -e "${GREEN}✅ Swap 4GB created${NC}"

# ============================================
# 9. AUTO UPDATES
# ============================================
progress "9" "Cấu hình auto updates..."

apt-get install -y -qq unattended-upgrades

cat > /etc/apt/apt.conf.d/50unattended-upgrades << EOF
Unattended-Upgrade::Allowed-Origins {
    "\${distro_id}:\${distro_codename}-security";
};
Unattended-Upgrade::AutoFixInterruptedDpkg "true";
Unattended-Upgrade::Remove-Unused-Dependencies "true";
Unattended-Upgrade::Automatic-Reboot "false";
EOF

cat > /etc/apt/apt.conf.d/20auto-upgrades << EOF
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Unattended-Upgrade "1";
EOF

echo -e "${GREEN}✅ Auto updates enabled${NC}"

# ============================================
# 10. MONITORING
# ============================================
progress "10" "Cài đặt monitoring tools..."

apt-get install -y -qq htop iotop nethogs ncdu sysstat lm-sensors

# Auto-detect sensors
yes | sensors-detect &>/dev/null

# Enable sysstat
sed -i 's/ENABLED="false"/ENABLED="true"/' /etc/default/sysstat
systemctl enable sysstat
systemctl start sysstat

echo -e "${GREEN}✅ Monitoring installed${NC}"

# ============================================
# 11. UTILITY SCRIPTS
# ============================================
progress "11" "Tạo utility scripts..."

# Update script
cat > $N8N_DIR/update.sh << 'EOFUPDATE'
#!/bin/bash
cd /home/n8n
docker compose pull
docker compose up -d
docker image prune -f
echo "✅ N8N updated"
EOFUPDATE
chmod +x $N8N_DIR/update.sh

# Logs script
cat > $N8N_DIR/logs.sh << 'EOFLOGS'
#!/bin/bash
cd /home/n8n
if [ "$1" = "n8n" ]; then
    docker compose logs -f n8n
elif [ "$1" = "tunnel" ]; then
    docker compose logs -f cloudflared
else
    docker compose logs -f
fi
EOFLOGS
chmod +x $N8N_DIR/logs.sh

# Health recovery
cat > /usr/local/bin/n8n-health-recovery.sh << 'EOFHEALTH'
#!/bin/bash
sleep 30
N8N_DB="/home/n8n/data/database.sqlite"
if [ -f "$N8N_DB" ]; then
    INTEGRITY=$(sqlite3 $N8N_DB "PRAGMA integrity_check;" 2>&1)
    if [[ "$INTEGRITY" != "ok" ]]; then
        echo "❌ Database corrupt! Restoring..."
        LATEST_BACKUP=$(ls -t /home/n8n/backups/n8n_backup_*.tar.gz 2>/dev/null | head -1)
        if [ -n "$LATEST_BACKUP" ]; then
            cd /home/n8n && docker compose stop n8n
            mv $N8N_DB ${N8N_DB}.corrupt.$(date +%s)
            tar -xzf $LATEST_BACKUP -C /home/n8n/data/
            cd /home/n8n && docker compose start n8n
            echo "✅ Restored from backup"
        fi
    fi
fi
EOFHEALTH
chmod +x /usr/local/bin/n8n-health-recovery.sh

# Health recovery service
cat > /etc/systemd/system/n8n-health-recovery.service << EOF
[Unit]
Description=N8N Health Check after Boot
After=n8n.service

[Service]
Type=oneshot
ExecStart=/usr/local/bin/n8n-health-recovery.sh

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable n8n-health-recovery.service

# Dashboard
cat > /usr/local/bin/n8ndash << 'EOFDASH'
#!/bin/bash
clear
echo "╔═══════════════════════════════════════════════════════════╗"
echo "║           N8N HOME SERVER DASHBOARD                      ║"
echo "╚═══════════════════════════════════════════════════════════╝"
echo ""
echo "🖥️  System: $(hostname) | IP: $(ip addr show $(ip route | grep default | awk '{print $5}') | grep "inet " | awk '{print $2}' | cut -d/ -f1)"
echo "⏰  Uptime: $(uptime -p)"
echo ""
free -h | grep Mem | awk '{print "📊 RAM:  " $3 " / " $2 " (" int($3/$2*100) "%)"}'
df -h / | tail -1 | awk '{print "💾 Disk: " $3 " / " $2 " (" $5 ")"}'
if [ -f /sys/class/thermal/thermal_zone0/temp ]; then
    echo "🌡️  Temp: $(($(cat /sys/class/thermal/thermal_zone0/temp)/1000))°C"
fi
echo ""
if docker ps | grep -q n8n; then
    echo "✅ N8N: Running"
else
    echo "❌ N8N: Stopped"
fi
echo ""
LATEST=$(ls -t /home/n8n/backups/*.tar.gz 2>/dev/null | head -1)
if [ -n "$LATEST" ]; then
    echo "💾 Backup: $(basename $LATEST) ($(du -h $LATEST | cut -f1))"
fi
echo ""
echo "Commands: n8nlogs | n8nbackup | n8nrestart | n8nupdate"
EOFDASH
chmod +x /usr/local/bin/n8ndash

# Bash aliases
cat >> /root/.bashrc << 'EOFBASH'

# N8N Shortcuts
alias n8ndash='/usr/local/bin/n8ndash'
alias n8nlogs='cd /home/n8n && docker compose logs -f n8n'
alias n8nbackup='/home/n8n/backup.sh'
alias n8nrestart='cd /home/n8n && docker compose restart'
alias n8nupdate='/home/n8n/update.sh'
EOFBASH

echo -e "${GREEN}✅ Utilities created${NC}"

# ============================================
# 12. KHỞI ĐỘNG N8N
# ============================================
progress "12" "Khởi động N8N & Cloudflare Tunnel..."

cd $N8N_DIR
docker compose up -d

# Wait for startup
echo -e "${CYAN}⏳ Đang chờ containers khởi động...${NC}"
for i in {1..30}; do
    echo -n "."
    sleep 1
done
echo ""

# Apply static IP
netplan apply &>/dev/null

# Calculate time
END_TIME=$(date +%s)
DURATION=$((END_TIME - START_TIME))
MINUTES=$((DURATION / 60))
SECONDS=$((DURATION % 60))

# ============================================
# FINAL SUCCESS MESSAGE
# ============================================
clear
echo -e "${GREEN}"
cat << "EOF"
╔══════════════════════════════════════════════════════════════╗
║                                                              ║
║                 ✅ CÀI ĐẶT HOÀN TẤT!                        ║
║                                                              ║
╚══════════════════════════════════════════════════════════════╝
EOF
echo -e "${NC}"

echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${CYAN}📊 THÔNG TIN HỆ THỐNG${NC}"
echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo ""
echo -e "${GREEN}🌐 N8N URL:     https://${DOMAIN}${NC}"
echo -e "${GREEN}🖥️  SSH:         ssh root@${STATIC_IP}${NC}"
echo -e "${GREEN}⏱️  Thời gian:   ${MINUTES} phút ${SECONDS} giây${NC}"
echo ""
echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${CYAN}✅ ĐÃ CÀI ĐẶT${NC}"
echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo ""
echo "  ✅ N8N + Cloudflare Tunnel"
echo "  ✅ IP tĩnh: ${STATIC_IP}"
echo "  ✅ Bảo vệ mất điện (SQLite WAL)"
echo "  ✅ Auto backup (6h/lần)"
echo "  ✅ Emergency backup on shutdown"
echo "  ✅ Security (Fail2ban + UFW)"
echo "  ✅ Swap 4GB"
echo "  ✅ Auto security updates"
echo "  ✅ Monitoring tools"
echo "  ✅ Auto recovery"
echo ""
echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${CYAN}🔧 LỆNH HỮU ÍCH${NC}"
echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo ""
echo "  n8ndash       Dashboard tổng quan"
echo "  n8nlogs       Xem logs real-time"
echo "  n8nbackup     Backup thủ công"
echo "  n8nrestart    Restart N8N"
echo "  n8nupdate     Update N8N"
echo ""
echo -e "${YELLOW}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${YELLOW}⚠️  LƯU Ý QUAN TRỌNG${NC}"
echo -e "${YELLOW}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo ""
echo "  1. Vào Cloudflare Dashboard:"
echo "     https://one.dash.cloudflare.com/"
echo ""
echo "  2. Cấu hình Public Hostname:"
echo "     • Domain: ${DOMAIN}"
echo "     • Service: http://n8n:5678"
echo ""
echo "  3. Reload bash để dùng shortcuts:"
echo "     source /root/.bashrc"
echo ""
echo "  4. Test dashboard:"
echo "     n8ndash"
echo ""
echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${GREEN}🎉 HỆ THỐNG ĐÃ SẴN SÀNG SỬ DỤNG!${NC}"
echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo ""
