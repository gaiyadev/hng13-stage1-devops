#!/bin/bash
# ============================================
# HNG DevOps Stage 1 — Automated Deployment Script
# Author: Obed Gaiya
# ============================================

set -euo pipefail

# -------------------------------
# Setup Logging
# -------------------------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LOG_DIR="$SCRIPT_DIR/logs"
mkdir -p "$LOG_DIR"
LOG_FILE="$LOG_DIR/deploy_$(date +%Y%m%d_%H%M%S).log"

log() {
    echo "$(date -u '+%Y-%m-%dT%H:%M:%S+0000') $1" | tee -a "$LOG_FILE"
}
info() { log "INFO: $1"; }
error() { log "ERROR: $1"; }
success() { log "SUCCESS: $1"; }
die() { error "$1"; exit 1; }

trap 'error "Unexpected error occurred. Check logs: $LOG_FILE"' ERR

# -------------------------------
# 1️⃣ Collect User Inputs
# -------------------------------
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

# Expand ~ in SSH key path
SSH_KEY="${SSH_KEY/#\~/$HOME}"

# -------------------------------
# 2️⃣ Local Environment Validation
# -------------------------------
info "Validating local environment..."
for cmd in git ssh scp docker; do
    command -v $cmd >/dev/null 2>&1 || die "$cmd is required but not installed."
done

if [ ! -f "$SSH_KEY" ]; then
    die "SSH key not found: $SSH_KEY"
fi
success "Local prerequisites satisfied."

# -------------------------------
# 3️⃣ Clone Repository
# -------------------------------
info "Cloning repository $GIT_URL ..."
if [ -n "$PAT" ]; then
    AUTH_GIT_URL="$(echo "$GIT_URL" | sed -E "s#https://#https://${PAT}@#")"
else
    info "No Personal Access Token provided — cloning as a public repository."
    AUTH_GIT_URL="$GIT_URL"
fi

REPO_NAME=$(basename -s .git "$GIT_URL")
START_DIR="$PWD"

if [ -d "$REPO_NAME" ]; then
    info "Repository already exists. Pulling latest changes..."
    cd "$REPO_NAME"
    git checkout "$BRANCH" 2>/dev/null || true
    git pull origin "$BRANCH" || die "Git pull failed"
else
    git clone --branch "$BRANCH" "$AUTH_GIT_URL" || die "Git clone failed"
    cd "$REPO_NAME"
fi

success "Repository ready on branch $BRANCH"

# -------------------------------
# 4️⃣ Check for Dockerfile / Compose
# -------------------------------
if [ -f "docker-compose.yml" ] || [ -f "docker-compose.yaml" ] || [ -f "Dockerfile" ]; then
    success "Found Docker configuration"
else
    die "No Dockerfile or docker-compose.yml found in project."
fi

# -------------------------------
# 5️⃣ Prepare Remote Server
# -------------------------------
info "Testing SSH connection to remote server..."
ssh -i "$SSH_KEY" -o StrictHostKeyChecking=no -o ConnectTimeout=10 "$SSH_USER@$SSH_HOST" "echo 'SSH Connection successful ✅'" || die "SSH connection failed."

info "Preparing remote environment..."
ssh -i "$SSH_KEY" -o StrictHostKeyChecking=no "$SSH_USER@$SSH_HOST" <<'EOF'
set -e
sudo apt update -y
sudo apt install -y docker.io docker-compose nginx
sudo systemctl enable docker nginx
sudo systemctl start docker nginx
sudo usermod -aG docker $USER || true
EOF
success "Remote environment prepared."

# -------------------------------
# 6️⃣ Transfer and Deploy App
# -------------------------------
info "Deploying application on remote server..."
ssh -i "$SSH_KEY" "$SSH_USER@$SSH_HOST" "mkdir -p $REMOTE_DIR"

# Create a tarball for more reliable transfer
tar -czf ../app.tar.gz . || die "Failed to create deployment package"
scp -i "$SSH_KEY" ../app.tar.gz "$SSH_USER@$SSH_HOST:$REMOTE_DIR/" || die "File transfer failed"

ssh -i "$SSH_KEY" "$SSH_USER@$SSH_HOST" <<EOF
set -e
cd $REMOTE_DIR
tar -xzf app.tar.gz
rm -f app.tar.gz

if [ -f docker-compose.yml ] || [ -f docker-compose.yaml ]; then
    sudo docker compose down 2>/dev/null || true
    sudo docker compose up -d --build
else
    sudo docker stop app_container 2>/dev/null || true
    sudo docker rm app_container 2>/dev/null || true
    sudo docker build -t app_image .
    sudo docker run -d -p $APP_PORT:$APP_PORT --name app_container app_image
fi
EOF

# Clean up local tarball
rm -f "$START_DIR/app.tar.gz"

success "Dockerized app deployed successfully."

# -------------------------------
# 7️⃣ Configure Nginx Reverse Proxy
# -------------------------------
info "Configuring Nginx reverse proxy..."
NGINX_CONF="
server {
    listen 80;
    server_name _;
    location / {
        proxy_pass http://127.0.0.1:$APP_PORT;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
    }
}
"

ssh -i "$SSH_KEY" "$SSH_USER@$SSH_HOST" "echo '$NGINX_CONF' | sudo tee /etc/nginx/sites-available/app.conf > /dev/null"
ssh -i "$SSH_KEY" "$SSH_USER@$SSH_HOST" "sudo ln -sf /etc/nginx/sites-available/app.conf /etc/nginx/sites-enabled/app.conf && sudo nginx -t && sudo systemctl reload nginx"

success "Nginx configured successfully."

# -------------------------------
# 8️⃣ Validate Deployment
# -------------------------------
info "Validating deployment..."
sleep 10  # Give services time to start

ssh -i "$SSH_KEY" "$SSH_USER@$SSH_HOST" <<'EOF'
echo "=== Docker Containers ==="
sudo docker ps
echo "=== Nginx Status ==="
sudo systemctl status nginx --no-pager
echo "=== Application Health Check ==="
curl -s -o /dev/null -w "HTTP Status: %{http_code}\n" http://localhost || echo "Health check failed"
EOF

success "Deployment validated and complete! 🚀"
info "Logs saved to: $LOG_FILE"
info "Application should be accessible at: http://$SSH_HOST"