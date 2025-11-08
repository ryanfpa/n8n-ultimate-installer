#!/usr/bin/env bash
#
# n8n ULTIMATE INSTALLER - Ryan F.P.A Edition
# ------------------------------------------
# Dành cho: Ubuntu 22.04+ máy sạch, chỉ chạy n8n.
# Tính chất:
# - 1 lệnh duy nhất để cài mới hoặc chạy lại.
# - Không phá hệ thống, không auto "apt upgrade" toàn máy.
# - Dùng Docker + Postgres, dữ liệu persistent.
# - Optional: Cloudflare Tunnel với 1 token.
# - Kèm tiện ích: n8n-status, n8n-update, n8n-backup.
#
# Cách dùng:
#   sudo bash install-all.sh
# Hoặc:
#   bash <(curl -fsSL https://raw.githubusercontent.com/ryanfpa/n8n-ultimate-installer/main/install-all.sh)
#

set -euo pipefail

### CONFIG CƠ BẢN ##############################################################

N8N_DIR="/opt/n8n"
N8N_IMAGE="n8nio/n8n:latest"
POSTGRES_IMAGE="postgres:16-alpine"
N8N_PORT="5678"
N8N_TIMEZONE="Asia/Ho_Chi_Minh"

CF_SERVICE_NAME="cloudflared-n8n"
BIN_DIR="/usr/local/bin"

### HÀM TIỆN ÍCH ###############################################################

log()  { echo -e "\e[32m[OK]\e[0m $*"; }
info() { echo -e "\e[34m[INFO]\e[0m $*"; }
warn() { echo -e "\e[33m[WARN]\e[0m $*"; }
err()  { echo -e "\e[31m[ERR]\e[0m $*" >&2; }

require_root() {
  if [ "$(id -u)" -ne 0 ]; then
    err "Vui lòng chạy với quyền root (sudo)."
    exit 1
  fi
}

check_os() {
  if [ -f /etc/os-release ]; then
    # shellcheck disable=SC1091
    . /etc/os-release
    if [ "${ID:-}" != "ubuntu" ]; then
      warn "Script này tối ưu cho Ubuntu. Hệ hiện tại: ${ID:-unknown}"
    fi
  else
    warn "/etc/os-release không tồn tại. Bỏ qua kiểm tra OS."
  fi
}

run_apt() {
  info "Cập nhật danh sách gói (apt-get update)..."
  apt-get update -y -qq
}

install_base_packages() {
  info "Cài đặt các gói cần thiết (không nâng cấp toàn hệ thống)..."
  DEBIAN_FRONTEND=noninteractive apt-get install -y -qq \
    ca-certificates curl gnupg lsb-release jq \
    docker.io docker-compose-plugin || {
      err "Cài đặt package thất bại."
      exit 1
    }

  systemctl enable --now docker >/dev/null 2>&1 || true

  if ! command -v docker >/dev/null 2>&1; then
    err "Docker chưa sẵn sàng."
    exit 1
  fi

  if ! docker compose version >/dev/null 2>&1; then
    err "docker compose plugin chưa hoạt động. Kiểm tra gói docker-compose-plugin."
    exit 1
  fi

  log "Docker & docker compose đã sẵn sàng."
}

install_cloudflared_binary() {
  if command -v cloudflared >/dev/null 2>&1; then
    log "cloudflared đã có, bỏ qua cài đặt."
    return
  fi

  info "Cài đặt cloudflared (Cloudflare Tunnel)..."
  local TMP_DEB="/tmp/cloudflared.deb"
  curl -fsSL "https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-amd64.deb" -o "$TMP_DEB"
  dpkg -i "$TMP_DEB" >/dev/null 2>&1 || DEBIAN_FRONTEND=noninteractive apt-get install -f -y -qq
  rm -f "$TMP_DEB"

  if command -v cloudflared >/dev/null 2>&1; then
    log "Đã cài cloudflared."
  else
    warn "Không cài được cloudflared. Bạn vẫn dùng n8n nội bộ được."
  fi
}

ensure_dirs() {
  mkdir -p "${N8N_DIR}"/{n8n_data,postgres_data,backups,scripts}
  log "Đã tạo thư mục: ${N8N_DIR}"
}

create_env_file() {
  local ENV_FILE="${N8N_DIR}/.env"

  if [ -f "$ENV_FILE" ]; then
    log ".env đã tồn tại, giữ nguyên (không ghi đè)."
    return
  fi

  cat > "$ENV_FILE" <<EOF
# n8n base config
N8N_HOST=localhost
N8N_PORT=${N8N_PORT}
N8N_PROTOCOL=http
N8N_EDITOR_BASE_URL=http://localhost:${N8N_PORT}
WEBHOOK_URL=http://localhost:${N8N_PORT}

DB_TYPE=postgresdb
DB_POSTGRESDB_HOST=db
DB_POSTGRESDB_PORT=5432
DB_POSTGRESDB_DATABASE=n8n
DB_POSTGRESDB_USER=n8n
DB_POSTGRESDB_PASSWORD=n8npassword

GENERIC_TIMEZONE=${N8N_TIMEZONE}
EOF

  log "Đã tạo .env mặc định."
}

create_docker_compose() {
  local DC_FILE="${N8N_DIR}/docker-compose.yml"

  if [ -f "$DC_FILE" ]; then
    log "docker-compose.yml đã tồn tại, giữ nguyên (không ghi đè)."
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
  info "Kéo image & khởi động n8n stack..."
  (cd "$N8N_DIR" && docker compose pull && docker compose up -d)
  log "n8n stack đã chạy."
}

create_helper_scripts() {
  local SCRIPTS_DIR="${N8N_DIR}/scripts"

  # n8n-status
  cat > "${SCRIPTS_DIR}/n8n-status.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
cd /opt/n8n
echo "== Docker Compose PS =="
docker compose ps
echo
echo "== Disk usage =="
du -sh n8n_data postgres_data 2>/dev/null || true
EOF
  chmod +x "${SCRIPTS_DIR}/n8n-status.sh"

  # n8n-update
  cat > "${SCRIPTS_DIR}/n8n-update.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
cd /opt/n8n
echo "[INFO] Backup nhanh trước khi update..."
TS=$(date +"%Y%m%d-%H%M%S")
tar -czf "backups/backup-before-update-${TS}.tar.gz" n8n_data postgres_data .env docker-compose.yml 2>/dev/null || true
echo "[INFO] Kéo image mới & restart..."
docker compose pull
docker compose up -d
docker compose ps
EOF
  chmod +x "${SCRIPTS_DIR}/n8n-update.sh"

  # n8n-backup
  cat > "${SCRIPTS_DIR}/n8n-backup.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
cd /opt/n8n
TS=$(date +"%Y%m%d-%H%M%S")
mkdir -p backups
tar -czf "backups/n8n-backup-${TS}.tar.gz" n8n_data postgres_data .env docker-compose.yml
echo "[OK] Đã tạo backup: backups/n8n-backup-${TS}.tar.gz"
EOF
  chmod +x "${SCRIPTS_DIR}/n8n-backup.sh"

  # link tiện ích global
  ln -sf "${SCRIPTS_DIR}/n8n-status.sh" "${BIN_DIR}/n8n-status"
  ln -sf "${SCRIPTS_DIR}/n8n-update.sh" "${BIN_DIR}/n8n-update"
  ln -sf "${SCRIPTS_DIR}/n8n-backup.sh" "${BIN_DIR}/n8n-backup"

  log "Đã tạo tiện ích: n8n-status, n8n-update, n8n-backup."
}

setup_cloudflare_tunnel_service() {
  if ! command -v cloudflared >/dev/null 2>&1; then
    warn "cloudflared chưa có, bỏ qua cấu hình Cloudflare Tunnel."
    return
  fi

  # Nếu service đã tồn tại, không hỏi lại, giữ nguyên.
  if systemctl list-unit-files | grep -q "^${CF_SERVICE_NAME}.service"; then
    log "Service ${CF_SERVICE_NAME} đã tồn tại, giữ nguyên."
    return
  fi

  echo
  info "Thiết lập Cloudflare Tunnel (tùy chọn)."
  echo "Tạo Tunnel Token trong Cloudflare Zero Trust -> Access -> Tunnels."
  echo "Token dạng: eyJhIjoi... (1 dòng dài)."
  read -rp "Nhập Cloudflare Tunnel Token (Enter để bỏ qua): " CF_TOKEN || true

  if [ -z "${CF_TOKEN:-}" ]; then
    info "Không cấu hình Cloudflare Tunnel. Bạn có thể tự cấu hình sau."
    return
  fi

  cat > "/etc/systemd/system/${CF_SERVICE_NAME}.service" <<EOF
[Unit]
Description=Cloudflare Tunnel for n8n
After=network-online.target docker.service
Wants=network-online.target

[Service]
Type=simple
ExecStart=/usr/bin/cloudflared tunnel --no-autoupdate run --token ${CF_TOKEN}
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF

  systemctl daemon-reload
  systemctl enable --now "${CF_SERVICE_NAME}.service"

  log "Đã tạo & chạy service Cloudflare Tunnel: ${CF_SERVICE_NAME}"
  info "Hãy đảm bảo Tunnel trong Cloudflare map tới http://127.0.0.1:${N8N_PORT}"
}

print_summary() {
  echo
  echo "==============================================="
  echo " ✅ N8N ULTIMATE INSTALLER - HOÀN TẤT"
  echo "==============================================="
  echo "- Thư mục chính: ${N8N_DIR}"
  echo "- Data n8n     : ${N8N_DIR}/n8n_data"
  echo "- Data Postgres: ${N8N_DIR}/postgres_data"
  echo "- Backup       : ${N8N_DIR}/backups"
  echo
  echo "- Truy cập nội bộ trên máy:  http://127.0.0.1:${N8N_PORT}"
  echo "- Tiện ích CLI:"
  echo "    n8n-status  - xem trạng thái container & dung lượng"
  echo "    n8n-backup  - tạo backup full (data + config)"
  echo "    n8n-update  - backup nhanh + pull image mới + restart"
  echo
  if systemctl is-active --quiet "${CF_SERVICE_NAME}.service"; then
    echo "- Cloudflare Tunnel: ĐÃ BẬT (${CF_SERVICE_NAME})"
    echo "  → Dùng domain đã cấu hình trong Cloudflare để truy cập từ mọi nơi."
  else
    echo "- Cloudflare Tunnel: chưa bật hoặc không cấu hình."
  fi
  echo
  echo "🔁 Muốn sửa lỗi / dựng lại:"
  echo "- Chạy lại CHÍNH LỆNH NÀY:"
  echo "  bash <(curl -fsSL https://raw.githubusercontent.com/ryanfpa/n8n-ultimate-installer/main/install-all.sh)"
  echo "- Script thiết kế idempotent: không xoá data, không ghi đè cấu hình quan trọng."
  echo "==============================================="
}

### MAIN #######################################################################

main() {
  echo "==============================================="
  echo "   n8n ULTIMATE INSTALLER - Ryan F.P.A"
  echo "==============================================="

  require_root
  check_os
  run_apt
  install_base_packages
  install_cloudflared_binary
  ensure_dirs
  create_env_file
  create_docker_compose
  start_n8n_stack
  create_helper_scripts
  setup_cloudflare_tunnel_service
  print_summary
}

main "$@"