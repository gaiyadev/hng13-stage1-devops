#!/bin/bash
# ============================================
# HNG DevOps Stage 1 — Automated Deployment Script
# Author: Obed Gaiya
# ============================================

set -euo pipefail

# ============================================
# 🧾 Setup Logging (Local + Remote)
# ============================================
LOG_DIR="./logs"
mkdir -p "$LOG_DIR"  # ✅ Ensure logs directory exists before writing
TIMESTAMP="$(date +%Y%m%d_%H%M%S)"
LOG_FILE="$LOG_DIR/deploy_${TIMESTAMP}.log"

# --- Logging Helpers ---
log() {
  echo "$(date -u '+%Y-%m-%dT%H:%M:%S+0000') $1" | tee -a "$LOG_FILE"
}
info()    { log "INFO: $1"; }
error()   { log "ERROR: $1"; }
success() { log "SUCCESS: $1"; }
die()     { error "$1"; exit 1; }

trap 'error "Unexpected error occurred. Check logs: $LOG_FILE"' ERR

# ============================================
# 1️⃣ Collect User Inputs
# ============================================
read -p "Git Repository URL: " GIT_URL
read -s -p "Personal Access Token (press Enter if public repo): " PAT; echo
read -p "Branch (default: main): " BRANCH
read -p "Remote SSH Username: " SSH_USER
read -p "Remote Server IP: " SSH_HOST
read -p "SSH Key Path (e.g. ~/.ssh/id_rsa): " SSH_KEY
read -p "Application internal port (e.g. 3000): " APP_PORT
read -p "Remote project directory (default: ~/hng13-stage1): " REMOTE_DIR

BRANCH="${BRANCH:-main}"
REMOTE_DIR="${REMOTE_DIR:-~/hng13-stage1}"

# ============================================
# 2️⃣ Validate Local Environment
# ============================================
for cmd in git ssh scp docker; do
  command -v "$cmd" >/dev/null 2>&1 || die "$cmd is required but not installed."
done
success "Local prerequisites satisfied."

# ============================================
# 3️⃣ Clone Repository
# ============================================
info "Cloning repository $GIT_URL ..."
if [ -n "$PAT" ]; then
  AUTH_GIT_URL="$(echo "$GIT_URL" | sed -E "s#https://#https://${PAT}@#")"
else
  info "No Personal Access Token provided — cloning as a public repository."
  AUTH_GIT_URL="$GIT_URL"
fi

REPO_NAME=$(basename -s .git "$GIT_URL")

if [ -d "$REPO_NAME" ]; then
  info "Repository already exists. Pulling latest changes..."
  cd "$REPO_NAME" && git pull origin "$BRANCH" || die "Git pull failed"
else
  git clone --branch "$BRANCH" "$AUTH_GIT_URL" || die "Git clone failed"
  cd "$REPO_NAME"
fi
success "Repository ready on branch $BRANCH"

# ============================================
# 4️⃣ Check for Dockerfile / Compose
# ============================================
if [ -f "docker-compose.yml" ] || [ -f "Dockerfile" ]; then
  success "Found Dockerfile or docker-compose.yml"
else
  die "No Dockerfile or docker-compose.yml found in project."
fi

# ============================================
# 5️⃣ Prepare Remote Server
# ============================================
info "Connecting to remote server..."
ssh -i "$SSH_KEY" -o StrictHostKeyChecking=no "$SSH_USER@$SSH_HOST" "echo Connected ✅" || die "SSH connection failed."

info "Preparing remote environment..."
ssh -i "$SSH_KEY" -o StrictHostKeyChecking=no "$SSH_USER@$SSH_HOST" <<EOF
sudo mkdir -p /var/log/hng/
sudo touch /var/log/hng/deploy_${TIMESTAMP}.log
{
  echo "---- HNG DevOps Stage 1 Deployment Log ----"
  date
  sudo apt update -y
  sudo apt install -y docker.io docker-compose nginx
  sudo systemctl enable docker nginx
  sudo systemctl start docker nginx
  sudo usermod -aG docker $USER || true
  docker --version
  docker-compose --version
} | tee -a /var/log/hng/deploy_${TIMESTAMP}.log
EOF
success "Remote environment prepared and logged to /var/log/hng/deploy_${TIMESTAMP}.log"

# ============================================
# 6️⃣ Transfer and Deploy App
# ============================================
info "Deploying application on remote server..."
ssh -i "$SSH_KEY" "$SSH_USER@$SSH_HOST" "mkdir -p $REMOTE_DIR"
scp -i "$SSH_KEY" -r . "$SSH_USER@$SSH_HOST:$REMOTE_DIR"

ssh -i "$SSH_KEY" "$SSH_USER@$SSH_HOST" <<EOF
cd $REMOTE_DIR
if [ -f docker-compose.yml ]; then
  sudo docker-compose down || true
  sudo docker-compose up -d --build
else
  sudo docker stop app_container || true
  sudo docker rm app_container || true
  sudo docker build -t app_image .
  sudo docker run -d -p $APP_PORT:$APP_PORT --name app_container app_image
fi
EOF
success "Dockerized app deployed successfully."

# ============================================
# 7️⃣ Configure Nginx Reverse Proxy
# ============================================
info "Configuring Nginx reverse proxy..."
NGINX_CONF="
server {
    listen 80;
    server_name _;
    location / {
        proxy_pass http://127.0.0.1:$APP_PORT;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
    }
}
"
ssh -i "$SSH_KEY" "$SSH_USER@$SSH_HOST" <<EOF
echo "$NGINX_CONF" | sudo tee /etc/nginx/sites-available/app.conf > /dev/null
sudo ln -sf /etc/nginx/sites-available/app.conf /etc/nginx/sites-enabled/app.conf
sudo nginx -t && sudo systemctl reload nginx
EOF
success "Nginx configured successfully."

# ============================================
# 8️⃣ Validate Deployment
# ============================================
info "Validating deployment..."
ssh -i "$SSH_KEY" "$SSH_USER@$SSH_HOST" <<EOF
sudo docker ps
curl -I http://localhost
EOF

success "Deployment validated and complete! 🚀"
info "Local logs saved to: $LOG_FILE"
info "Remote logs saved to: /var/log/hng/deploy_${TIMESTAMP}.log"
