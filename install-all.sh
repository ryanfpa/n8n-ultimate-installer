#!/usr/bin/env bash
#
# n8n ULTIMATE INSTALLER - Ryan F.P.A (Host-level Auto Edition)
# -------------------------------------------------------------
# Mục tiêu:
# - 1 lệnh duy nhất: cài, cấu hình, tự vận hành như n8n host.
# - BẮT BUỘC: DOMAIN + (Cloudflare Named Tunnel token HOẶC Quick Tunnel).
# - Docker + Postgres, dữ liệu /opt/n8n.
# - Tự tạo:
#     - n8n-status / n8n-backup / n8n-update / n8n-health
#     - cron backup định kỳ
#     - cron health-check (tự restart nếu chết)
# - Idempotent: chạy lại không phá DB, không nhân cron, không ghi đè config.
#
# Cách dùng:
#   bash <(curl -fsSL https://raw.githubusercontent.com/ryanfpa/n8n-ultimate-installer/main/install-all.sh)
#

set -euo pipefail

### CONFIG CỐ ĐỊNH #####################################################

N8N_DIR="/opt/n8n"
N8N_IMAGE="n8nio/n8n:latest"
POSTGRES_IMAGE="postgres:16-alpine"
N8N_PORT="5678"
N8N_TIMEZONE="Asia/Ho_Chi_Minh"

CF_SERVICE_NAME="cloudflared-n8n"
BIN_DIR="/usr/local/bin"
CRON_FILE="/etc/cron.d/n8n-maintenance"

### LOG ###############################################################

log()  { echo -e "\e[32m[OK]\e[0m $*"; }
info() { echo -e "\e[34m[INFO]\e[0m $*"; }
warn() { echo -e "\e[33m[WARN]\e[0m $*"; }
err()  { echo -e "\e[31m[ERR]\e[0m $*" >&2; }

### CHECKS ############################################################

require_root() {
  if [ "$(id -u)" -ne 0 ]; then
    err "Vui lòng chạy với sudo/root."
    exit 1
  fi
}

check_os() {
  if [ -f /etc/os-release ]; then
    . /etc/os-release
    if [ "${ID:-}" != "ubuntu" ]; then
      warn "Script tối ưu cho Ubuntu. Hiện tại: ${ID:-unknown}"
    fi
  fi
}

run_apt() {
  info "apt-get update..."
  apt-get update -y -qq
}

install_base_packages() {
  info "Cài Docker & tools cần thiết..."
  DEBIAN_FRONTEND=noninteractive apt-get install -y -qq \
    ca-certificates curl gnupg lsb-release jq \
    docker.io docker-compose-plugin || {
      err "Cài package thất bại."
      exit 1
    }

  systemctl enable --now docker >/dev/null 2>&1 || true

  command -v docker >/dev/null 2>&1 || { err "Docker chưa chạy."; exit 1; }
  docker compose version >/dev/null 2>&1 || { err "docker compose plugin chưa có."; exit 1; }

  log "Docker & docker compose OK."
}

install_cloudflared() {
  if command -v cloudflared >/dev/null 2>&1; then
    log "cloudflared đã có."
    return
  fi

  info "Cài cloudflared..."
  local TMP_DEB="/tmp/cloudflared.deb"
  curl -fsSL "https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-amd64.deb" -o "$TMP_DEB"
  dpkg -i "$TMP_DEB" >/dev/null 2>&1 || DEBIAN_FRONTEND=noninteractive apt-get install -f -y -qq
  rm -f "$TMP_DEB"

  command -v cloudflared >/dev/null 2>&1 || { err "Không cài được cloudflared."; exit 1; }
  log "cloudflared OK."
}

### INPUT: DOMAIN + CHẾ ĐỘ TUNNEL #####################################

prompt_domain_and_tunnel_mode() {
  local EXIST_ENV="${N8N_DIR}/.env"
  local PRESET_DOMAIN=""

  if [ -f "$EXIST_ENV" ]; then
    PRESET_DOMAIN=$(grep -E '^N8N_HOST=' "$EXIST_ENV" | cut -d'=' -f2- || true)
  fi

  if [ -n "$PRESET_DOMAIN" ]; then
    info "Phát hiện DOMAIN từ .env: $PRESET_DOMAIN"
    DOMAIN="$PRESET_DOMAIN"
  else
    read -rp "Nhập DOMAIN cho n8n (vd: n8n.ryanfpa.com): " DOMAIN || true
  fi

  if [ -z "${DOMAIN:-}" ]; then
    err "DOMAIN là bắt buộc để quản lý mọi nơi bằng 1 link."
    exit 1
  fi

  echo
  echo "Chọn chế độ Cloudflare Tunnel:"
  echo "  1) Named Tunnel (Token)  - ổn định, dùng cho domain chính (khuyên dùng)"
  echo "  2) Quick Tunnel fallback - nếu chưa có token, script tự tạo link .trycloudflare.com"
  read -rp "Chọn [1/2] (mặc định: 1): " CF_MODE || true
  CF_MODE="${CF_MODE:-1}"

  if [ "$CF_MODE" = "1" ]; then
    if systemctl list-unit-files | grep -q "^${CF_SERVICE_NAME}.service"; then
      info "Đã có service Tunnel, giữ token & cấu hình cũ."
      CF_TUNNEL_TOKEN=""
      return
    fi

    read -rp "Nhập Cloudflare Tunnel Token (Named Tunnel) cho DOMAIN này: " CF_TUNNEL_TOKEN || true
    if [ -z "${CF_TUNNEL_TOKEN:-}" ]; then
      err "Chọn mode 1 thì TOKEN là bắt buộc."
      exit 1
    fi
  else
    CF_TUNNEL_TOKEN=""
  fi
}

### N8N CORE FILES ####################################################

ensure_dirs() {
  mkdir -p "${N8N_DIR}"/{n8n_data,postgres_data,backups,scripts}
  log "Thư mục ${N8N_DIR} OK."
}

create_env_file() {
  local ENV_FILE="${N8N_DIR}/.env"

  if [ -f "$ENV_FILE" ]; then
    log ".env đã có, không ghi đè."
    return
  fi

  cat > "$ENV_FILE" <<EOF
N8N_HOST=${DOMAIN}
N8N_PORT=${N8N_PORT}
N8N_PROTOCOL=https
N8N_EDITOR_BASE_URL=https://${DOMAIN}
WEBHOOK_URL=https://${DOMAIN}

DB_TYPE=postgresdb
DB_POSTGRESDB_HOST=db
DB_POSTGRESDB_PORT=5432
DB_POSTGRESDB_DATABASE=n8n
DB_POSTGRESDB_USER=n8n
DB_POSTGRESDB_PASSWORD=n8npassword

GENERIC_TIMEZONE=${N8N_TIMEZONE}
EOF

  log "Đã tạo .env với DOMAIN=${DOMAIN}."
}

create_docker_compose() {
  local DC_FILE="${N8N_DIR}/docker-compose.yml"

  if [ -f "$DC_FILE" ]; then
    log "docker-compose.yml đã có, không ghi đè."
    return
  fi

  cat > "$DC_FILE" <<EOF
version: "3.8"

services:
  db:
    image: ${POSTGRES_IMAGE}
    restart: unless-stopped
    environment:
      - POSTGRES_USER=n8n
      - POSTGRES_PASSWORD=n8npassword
      - POSTGRES_DB=n8n
    volumes:
      - ./postgres_data:/var/lib/postgresql/data

  n8n:
    image: ${N8N_IMAGE}
    restart: unless-stopped
    env_file:
      - .env
    depends_on:
      - db
    ports:
      - "127.0.0.1:${N8N_PORT}:${N8N_PORT}"
    volumes:
      - ./n8n_data:/home/node/.n8n
EOF

  log "Đã tạo docker-compose.yml."
}

start_n8n_stack() {
  info "Khởi động n8n stack..."
  (cd "$N8N_DIR" && docker compose pull && docker compose up -d)
  log "n8n stack đang chạy."
}

### HELPER SCRIPTS (STATUS / BACKUP / UPDATE / HEALTH) ################

create_helper_scripts() {
  local SCRIPTS_DIR="${N8N_DIR}/scripts"

  # n8n-status
  cat > "${SCRIPTS_DIR}/n8n-status.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
cd /opt/n8n
echo "== n8n / db containers =="
docker compose ps || true
echo
echo "== Disk usage =="
du -sh n8n_data postgres_data 2>/dev/null || true
EOF
  chmod +x "${SCRIPTS_DIR}/n8n-status.sh"

  # n8n-backup
  cat > "${SCRIPTS_DIR}/n8n-backup.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
cd /opt/n8n
TS=$(date +"%Y%m%d-%H%M%S")
mkdir -p backups
tar -czf "backups/n8n-backup-${TS}.tar.gz" n8n_data postgres_data .env docker-compose.yml
echo "[OK] Backup: backups/n8n-backup-${TS}.tar.gz"
EOF
  chmod +x "${SCRIPTS_DIR}/n8n-backup.sh"

  # n8n-update (manual, không auto)
  cat > "${SCRIPTS_DIR}/n8n-update.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
cd /opt/n8n
TS=$(date +"%Y%m%d-%H%M%S")
mkdir -p backups
echo "[INFO] Backup trước update..."
tar -czf "backups/backup-before-update-${TS}.tar.gz" n8n_data postgres_data .env docker-compose.yml 2>/dev/null || true
echo "[INFO] Pull image mới & restart..."
docker compose pull
docker compose up -d
docker compose ps
EOF
  chmod +x "${SCRIPTS_DIR}/n8n-update.sh"

  # n8n-health (tự kiểm tra & tự sửa)
  cat > "${SCRIPTS_DIR}/n8n-health.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
cd /opt/n8n

# Check containers
if ! docker compose ps >/dev/null 2>&1; then
  echo "[WARN] docker compose lỗi, thử restart stack..."
  docker compose up -d || exit 1
  exit 0
fi

DB_STATUS=$(docker compose ps db 2>/dev/null | awk 'NR==3{print $4}' || true)
N8N_STATUS=$(docker compose ps n8n 2>/dev/null | awk 'NR==3{print $4}' || true)

if [[ "$DB_STATUS" != "Up"* ]]; then
  echo "[WARN] db không up. Restart..."
  docker compose up -d db
fi

if [[ "$N8N_STATUS" != "Up"* ]]; then
  echo "[WARN] n8n không up. Restart..."
  docker compose up -d n8n
  exit 0
fi

# HTTP check
STATUS_CODE=$(curl -sk -o /dev/null -w "%{http_code}" http://127.0.0.1:5678 || echo "000")
if [ "$STATUS_CODE" != "200" ] && [ "$STATUS_CODE" != "301" ] && [ "$STATUS_CODE" != "302" ]; then
  echo "[WARN] n8n HTTP ${STATUS_CODE}, restart service..."
  docker compose restart n8n || true
else
  echo "[OK] n8n healthy (${STATUS_CODE})."
fi
EOF
  chmod +x "${SCRIPTS_DIR}/n8n-health.sh"

  # symlink global
  ln -sf "${SCRIPTS_DIR}/n8n-status.sh"  "${BIN_DIR}/n8n-status"
  ln -sf "${SCRIPTS_DIR}/n8n-backup.sh"  "${BIN_DIR}/n8n-backup"
  ln -sf "${SCRIPTS_DIR}/n8n-update.sh"  "${BIN_DIR}/n8n-update"
  ln -sf "${SCRIPTS_DIR}/n8n-health.sh"  "${BIN_DIR}/n8n-health"

  log "Đã tạo: n8n-status, n8n-backup, n8n-update, n8n-health."
}

### CRON TỰ ĐỘNG (BACKUP + HEALTH) ####################################

setup_cron_jobs() {
  info "Thiết lập cron tự động (health-check + backup)..."

  # Ghi đè file cron riêng cho n8n (idempotent)
  cat > "$CRON_FILE" <<EOF
# n8n auto maintenance - Ryan F.P.A
# Health-check mỗi 5 phút
*/5 * * * * root /usr/local/bin/n8n-health >/var/log/n8n-health.log 2>&1

# Backup full mỗi ngày lúc 03:00
0 3 * * * root /usr/local/bin/n8n-backup >/var/log/n8n-backup.log 2>&1
EOF

  chmod 644 "$CRON_FILE"
  log "Cron maintenance đã cấu hình."
}

### CLOUDFLARE TUNNEL (NAMED / QUICK) #################################

setup_cloudflare_tunnel_service() {
  # Nếu đã có service (Named Tunnel cũ), giữ nguyên.
  if systemctl list-unit-files | grep -q "^${CF_SERVICE_NAME}.service"; then
    log "Service ${CF_SERVICE_NAME} đã tồn tại, không thay đổi."
    systemctl enable --now "${CF_SERVICE_NAME}.service" || true
    return
  fi

  if [ -n "${CF_TUNNEL_TOKEN:-}" ]; then
    # Named Tunnel
    cat > "/etc/systemd/system/${CF_SERVICE_NAME}.service" <<EOF
[Unit]
Description=Cloudflare Named Tunnel for n8n (${DOMAIN})
After=network-online.target docker.service
Wants=network-online.target

[Service]
Type=simple
ExecStart=/usr/bin/cloudflared tunnel --no-autoupdate run --token ${CF_TUNNEL_TOKEN}
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload
    systemctl enable --now "${CF_SERVICE_NAME}.service"
    log "Đã bật Named Tunnel cho ${DOMAIN}."
  else
    # Quick Tunnel fallback: không cố định domain, nhưng auto tạo link
    cat > "/etc/systemd/system/${CF_SERVICE_NAME}.service" <<EOF
[Unit]
Description=Cloudflare Quick Tunnel for n8n (auto .trycloudflare.com)
After=network-online.target docker.service
Wants=network-online.target

[Service]
Type=simple
ExecStart=/usr/bin/cloudflared tunnel --no-autoupdate --url http://127.0.0.1:${N8N_PORT}
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload
    systemctl enable --now "${CF_SERVICE_NAME}.service"
    log "Đã bật Quick Tunnel (xem URL trong: journalctl -u ${CF_SERVICE_NAME}.service | grep 'https://')."
  fi
}

### SUMMARY ###########################################################

print_summary() {
  echo
  echo "================================================"
  echo " ✅ n8n HOST AUTO EDITION - HOÀN TẤT"
  echo "================================================"
  echo "- Folder chính : ${N8N_DIR}"
  echo "- n8n data     : ${N8N_DIR}/n8n_data"
  echo "- Postgres data: ${N8N_DIR}/postgres_data"
  echo "- Backups      : ${N8N_DIR}/backups"
  echo
  echo "- Lệnh hữu ích:"
  echo "    n8n-status  -> xem trạng thái"
  echo "    n8n-backup  -> backup thủ công"
  echo "    n8n-update  -> backup + pull image mới (manual)"
  echo "    n8n-health  -> chạy health-check thủ công"
  echo
  echo "- Tự động:"
  echo "    Health-check mỗi 5 phút (cron)"
  echo "    Backup mỗi ngày lúc 03:00 (cron)"
  echo
  if systemctl is-active --quiet "${CF_SERVICE_NAME}.service"; then
    echo "- Cloudflare Tunnel service đang chạy: ${CF_SERVICE_NAME}"
    if [ -n "${CF_TUNNEL_TOKEN:-}" ]; then
      echo "  Mode: Named Tunnel → dùng https://${DOMAIN} ở mọi nơi."
    else
      echo "  Mode: Quick Tunnel → xem URL bằng:"
      echo "        journalctl -u ${CF_SERVICE_NAME}.service | grep 'https://'"
    fi
  else
    echo "- Cloudflare Tunnel: chưa chạy (kiểm tra service/log)."
  fi
  echo
  echo "🔁 Chạy lại cùng lệnh cài đặt bất cứ lúc nào:"
  echo "- Đảm bảo stack chạy lại, cron giữ nguyên, data an toàn."
  echo "================================================"
}

### MAIN ##############################################################

main() {
  echo "================================================"
  echo "   n8n ULTIMATE INSTALLER - Ryan F.P.A"
  echo "   (Host-level Auto Edition)"
  echo "================================================"

  require_root
  check_os
  run_apt
  install_base_packages
  install_cloudflared
  prompt_domain_and_tunnel_mode
  ensure_dirs
  create_env_file
  create_docker_compose
  start_n8n_stack
  create_helper_scripts
  setup_cron_jobs
  setup_cloudflare_tunnel_service
  print_summary
}

main "$@"