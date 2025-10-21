#!/usr/bin/env bash
# deploy.sh — HNG DevOps Stage 1 automated deploy script
set -euo pipefail

########################################
# Setup / logging (always absolute)
########################################
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LOG_DIR="$SCRIPT_DIR/logs"
mkdir -p "$LOG_DIR"
TIMESTAMP="$(date +%Y%m%d_%H%M%S)"
LOG_FILE="$LOG_DIR/deploy_${TIMESTAMP}.log"

log()   { printf '%s %s\n' "$(date -u +%Y-%m-%dT%H:%M:%S%z)" "$*" | tee -a "$LOG_FILE"; }
info()  { log "INFO: $*"; }
error() { log "ERROR: $*"; }
succ()  { log "SUCCESS: $*"; }
die()   { error "$*"; exit "${2:-1}"; }

trap 'error "Unexpected error at line $LINENO. See $LOG_FILE"; exit 2' ERR
trap 'log "Interrupted"; exit 130' INT

########################################
# Args
########################################
CLEANUP_MODE=0
for a in "$@"; do
  case "$a" in
    --cleanup) CLEANUP_MODE=1 ;;
    -h|--help) echo "Usage: $0 [--cleanup]"; exit 0 ;;
  esac
done

########################################
# Interactive input (if needed)
########################################
read_input() {
  : "${GIT_URL:=$(printf '' ; read -p 'Git repository URL (https://...): ' REPLY && printf '%s' "$REPLY")}"
  : "${PAT:=$(printf '' ; read -s -p 'Personal Access Token (press Enter if public): ' REPLY && printf '%s' "$REPLY" && echo)}"
  : "${BRANCH:=$(printf '' ; read -p "Branch [main]: " REPLY && printf '%s' "${REPLY:-main}")}"
  : "${REMOTE_USER:=$(printf '' ; read -p 'Remote SSH username: ' REPLY && printf '%s' "$REPLY")}"
  : "${REMOTE_HOST:=$(printf '' ; read -p 'Remote server IP/hostname: ' REPLY && printf '%s' "$REPLY")}"
  : "${SSH_KEY:=$(printf '' ; read -p 'SSH key path (e.g. ~/.ssh/id_rsa): ' REPLY && printf '%s' "$REPLY")}"
  : "${CONTAINER_PORT:=$(printf '' ; read -p 'Application internal container port (e.g. 3000): ' REPLY && printf '%s' "$REPLY")}"
  : "${REMOTE_PROJECT_DIR:=$(printf '' ; read -p 'Remote project directory (optional, leave blank for default): ' REPLY && printf '%s' "$REPLY")}"

  # basic validation
  if [ -z "$GIT_URL" ] || [ -z "$REMOTE_USER" ] || [ -z "$REMOTE_HOST" ] || [ -z "$SSH_KEY" ] || [ -z "$CONTAINER_PORT" ]; then
    die "Missing required input (git url, remote user/host, ssh key, or container port)."
  fi

  # derive repo name and default remote dir
  REPO_NAME="$(basename -s .git "$GIT_URL")"
  if [ -z "$REMOTE_PROJECT_DIR" ]; then
    REMOTE_PROJECT_DIR="/home/${REMOTE_USER}/${REPO_NAME}"
  fi
}

########################################
# Local prereqs
########################################
check_local_prereqs() {
  for c in git ssh rsync curl; do
    command -v "$c" >/dev/null 2>&1 || die "$c is required locally"
  done
  info "Local prerequisites satisfied"
}

########################################
# Prepare local repo (clone or pull)
########################################
prepare_local_repo() {
  info "Preparing local repo for $GIT_URL (branch: $BRANCH)"
  if [ -n "$PAT" ] && printf '%s' "$GIT_URL" | grep -qE '^https?://'; then
    AUTH_GIT_URL="$(printf '%s' "$GIT_URL" | sed -E "s#https?://#https://${PAT}@#")"
  else
    AUTH_GIT_URL="$GIT_URL"
  fi

  if [ -d "$SCRIPT_DIR/$REPO_NAME/.git" ]; then
    info "Repo exists locally — pulling latest"
    (cd "$SCRIPT_DIR/$REPO_NAME" && git fetch --all --prune >>"$LOG_FILE" 2>&1 && git checkout "$BRANCH" >>"$LOG_FILE" 2>&1 && git pull origin "$BRANCH" >>"$LOG_FILE" 2>&1) || die "Git pull failed"
  else
    info "Cloning $AUTH_GIT_URL ..."
    (cd "$SCRIPT_DIR" && git clone --branch "$BRANCH" "$AUTH_GIT_URL" >>"$LOG_FILE" 2>&1) || die "Git clone failed"
  fi

  # change to repo dir for local checks
  cd "$SCRIPT_DIR/$REPO_NAME"
  if [ -f "docker-compose.yml" ] || [ -f "Dockerfile" ]; then
    succ "Found Dockerfile or docker-compose.yml"
  else
    info "No Dockerfile/docker-compose.yml detected — will auto-generate a default Dockerfile (Node) unless you prefer to provide one."
    cat > Dockerfile <<'DOCKER'
# Auto-generated Dockerfile (Node.js)
FROM node:18-alpine
WORKDIR /app
COPY package*.json ./
RUN npm ci --only=production || npm install --production || true
COPY . .
EXPOSE 3000
CMD ["npm","start"]
DOCKER
    succ "Default Dockerfile created"
  fi
}

########################################
# Check SSH connectivity
########################################
check_ssh_connectivity() {
  info "Checking SSH to ${REMOTE_USER}@${REMOTE_HOST}"
  ssh -i "$SSH_KEY" -o BatchMode=yes -o ConnectTimeout=10 -o StrictHostKeyChecking=no "${REMOTE_USER}@${REMOTE_HOST}" "echo connected" >/dev/null 2>&1 || die "SSH connectivity failed. Ensure key is authorized on remote."
  succ "SSH connectivity OK"
}

########################################
# Install Docker if not exists
########################################
install_docker_if_needed() {
  info "Checking Docker installation..."
  ssh -i "$SSH_KEY" -o StrictHostKeyChecking=no "${REMOTE_USER}@${REMOTE_HOST}" /bin/bash <<'DOCKER_CHECK'
set -euo pipefail

if command -v docker >/dev/null 2>&1; then
    echo "Docker is already installed: $(docker --version)"
    exit 0
fi

echo "Installing Docker..."
LOG=/tmp/docker_install.log

# Install using official Docker script
curl -fsSL https://get.docker.com -o get-docker.sh && sudo sh get-docker.sh >> "$LOG" 2>&1

# Start and enable Docker
sudo systemctl enable --now docker >> "$LOG" 2>&1
sudo usermod -aG docker "$USER" >> "$LOG" 2>&1 || true

echo "Docker installed: $(docker --version)"
DOCKER_CHECK
  succ "Docker installation verified"
}

########################################
# Install Docker Compose if not exists
########################################
install_docker_compose_if_needed() {
  info "Checking Docker Compose installation..."
  ssh -i "$SSH_KEY" -o StrictHostKeyChecking=no "${REMOTE_USER}@${REMOTE_HOST}" /bin/bash <<'COMPOSE_CHECK'
set -euo pipefail

if command -v docker-compose >/dev/null 2>&1; then
    echo "Docker Compose is already installed: $(docker-compose --version)"
    exit 0
fi

echo "Installing Docker Compose..."
sudo curl -L "https://github.com/docker/compose/releases/latest/download/docker-compose-$(uname -s)-$(uname -m)" -o /usr/local/bin/docker-compose
sudo chmod +x /usr/local/bin/docker-compose

# Create symlink for broader compatibility
sudo ln -sf /usr/local/bin/docker-compose /usr/bin/docker-compose 2>/dev/null || true

echo "Docker Compose installed: $(docker-compose --version)"
COMPOSE_CHECK
  succ "Docker Compose installation verified"
}

########################################
# Install Nginx if not exists
########################################
install_nginx_if_needed() {
  info "Checking Nginx installation..."
  ssh -i "$SSH_KEY" -o StrictHostKeyChecking=no "${REMOTE_USER}@${REMOTE_HOST}" /bin/bash <<'NGINX_CHECK'
set -euo pipefail

if command -v nginx >/dev/null 2>&1; then
    echo "Nginx is already installed: $(nginx -v 2>&1)"
    exit 0
fi

echo "Installing Nginx..."
LOG=/tmp/nginx_install.log

# Detect package manager
if command -v apt-get >/dev/null 2>&1; then
    sudo apt-get update -y >> "$LOG" 2>&1
    sudo apt-get install -y nginx >> "$LOG" 2>&1
elif command -v yum >/dev/null 2>&1; then
    sudo yum install -y epel-release >> "$LOG" 2>&1
    sudo yum install -y nginx >> "$LOG" 2>&1
else
    echo "Unsupported package manager"
    exit 1
fi

# Start and enable Nginx
sudo systemctl enable --now nginx >> "$LOG" 2>&1

echo "Nginx installed: $(nginx -v 2>&1)"
NGINX_CHECK
  succ "Nginx installation verified"
}

########################################
# Prepare SSL certificates (placeholder for Certbot)
########################################
setup_ssl_placeholder() {
  info "Setting up SSL readiness..."
  ssh -i "$SSH_KEY" -o StrictHostKeyChecking=no "${REMOTE_USER}@${REMOTE_HOST}" /bin/bash <<'SSL_SETUP'
set -euo pipefail

# Create SSL directory structure
sudo mkdir -p /etc/nginx/ssl

# Create placeholder SSL configuration comment
if [ ! -f /etc/nginx/ssl/README ]; then
sudo tee /etc/nginx/ssl/README > /dev/null <<'EOF'
# SSL Certificate Directory
# 
# To enable SSL:
# 1. Install Certbot: sudo apt-get install certbot python3-certbot-nginx
# 2. Get certificate: sudo certbot --nginx -d yourdomain.com
# 3. Certbot will automatically update Nginx configuration
#
# For self-signed certificates (testing):
# sudo openssl req -x509 -nodes -days 365 -newkey rsa:2048 \
#   -keyout /etc/nginx/ssl/selfsigned.key \
#   -out /etc/nginx/ssl/selfsigned.crt
EOF
fi

echo "SSL directory structure prepared"
echo "To enable SSL later, run: sudo certbot --nginx -d your-domain.com"
SSL_SETUP
  succ "SSL readiness configured"
}

########################################
# Prepare remote environment (SMART INSTALL)
########################################
remote_prepare() {
  info "Preparing remote environment (smart install)"
  
  install_docker_if_needed
  install_docker_compose_if_needed
  install_nginx_if_needed
  setup_ssl_placeholder
  
  # Verify all services
  ssh -i "$SSH_KEY" -o StrictHostKeyChecking=no "${REMOTE_USER}@${REMOTE_HOST}" /bin/bash <<'VERIFY'
set -euo pipefail
echo "=== Service Verification ==="
echo "Docker: $(docker --version 2>/dev/null || echo 'NOT_FOUND')"
echo "Docker Compose: $(docker-compose --version 2>/dev/null || echo 'NOT_FOUND')"
echo "Nginx: $(nginx -v 2>&1 2>/dev/null || echo 'NOT_FOUND')"
echo "Docker Service: $(systemctl is-active docker 2>/dev/null || echo 'INACTIVE')"
echo "Nginx Service: $(systemctl is-active nginx 2>/dev/null || echo 'INACTIVE')"
VERIFY

  succ "Remote environment prepared successfully"
}

########################################
# Transfer project
########################################
transfer_project() {
  info "Transferring project to ${REMOTE_USER}@${REMOTE_HOST}:${REMOTE_PROJECT_DIR}"
  ssh -i "$SSH_KEY" -o StrictHostKeyChecking=no "${REMOTE_USER}@${REMOTE_HOST}" "mkdir -p '${REMOTE_PROJECT_DIR}' && chown ${REMOTE_USER}:${REMOTE_USER} '${REMOTE_PROJECT_DIR}'" || die "Failed to create remote directory"
  if command -v rsync >/dev/null 2>&1; then
    rsync -avz --delete -e "ssh -i ${SSH_KEY} -o StrictHostKeyChecking=no" "$SCRIPT_DIR/$REPO_NAME/" "${REMOTE_USER}@${REMOTE_HOST}:${REMOTE_PROJECT_DIR}/" >>"$LOG_FILE" 2>&1 || die "rsync failed"
  else
    scp -i "$SSH_KEY" -r "$SCRIPT_DIR/$REPO_NAME/" "${REMOTE_USER}@${REMOTE_HOST}:${REMOTE_PROJECT_DIR}/" >>"$LOG_FILE" 2>&1 || die "scp failed"
  fi
  succ "Project files transferred"
}

########################################
# Remote deploy (docker-compose or docker)
########################################
remote_deploy() {
  info "Deploying application on remote host"
  ssh -i "$SSH_KEY" -o StrictHostKeyChecking=no "${REMOTE_USER}@${REMOTE_HOST}" /bin/bash <<REMOTE_DEPLOY
set -euo pipefail
cd "${REMOTE_PROJECT_DIR}"

# Clean up any existing containers and images to prevent conflicts
echo "Cleaning up any existing containers..."
sudo docker ps -a --filter "name=app_container" --format '{{.ID}}' | xargs -r sudo docker rm -f || true
sudo docker ps -a --filter "name=${REPO_NAME}_service" --format '{{.ID}}' | xargs -r sudo docker rm -f || true
sudo docker ps -a --filter "name=${REPO_NAME}" --format '{{.ID}}' | xargs -r sudo docker rm -f || true

# Clean up any existing images to force rebuild
echo "Cleaning up existing images..."
sudo docker images --filter "reference=*${REPO_NAME}*" --format '{{.ID}}' | xargs -r sudo docker rmi -f || true
sudo docker images --filter "reference=app_image" --format '{{.ID}}' | xargs -r sudo docker rmi -f || true

if [ -f docker-compose.yml ]; then
  echo "Using docker-compose..."
  sudo docker-compose down 2>/dev/null || true
  sudo docker-compose pull || true
  sudo docker-compose up -d --build
else
  echo "Using Dockerfile..."
  # Build with a unique tag including timestamp to avoid conflicts
  IMG_TAG="${REPO_NAME}:latest"
  sudo docker build -t "\$IMG_TAG" .
  
  # Run the container with restart policy
  sudo docker run -d \
    --name "app_${REPO_NAME}_\$(date +%s)" \
    --restart unless-stopped \
    -p ${CONTAINER_PORT}:${CONTAINER_PORT} \
    "\$IMG_TAG"
fi

echo "Current running containers:"
sudo docker ps --format 'table {{.Names}}\t{{.Image}}\t{{.Status}}'
REMOTE_DEPLOY
  succ "Remote deployment completed"
}

########################################
# Nginx config with SSL readiness
########################################
configure_nginx() {
  info "Configuring Nginx reverse proxy with SSL readiness"
  
  # Create nginx config with SSL placeholder
  NGINX_CONFIG_FILE="/tmp/nginx_${REPO_NAME}.conf"
  cat > "$NGINX_CONFIG_FILE" <<EOF
# HTTP to HTTPS redirect (commented until SSL is configured)
# server {
#     listen 80;
#     server_name _;
#     return 301 https://\$server_name\$request_uri;
# }

server {
    listen 80;
    # listen 443 ssl http2;  # Uncomment when SSL is configured
    server_name _;
    
    # SSL placeholder (uncomment when certificates are available)
    # ssl_certificate /etc/nginx/ssl/selfsigned.crt;
    # ssl_certificate_key /etc/nginx/ssl/selfsigned.key;
    # ssl_protocols TLSv1.2 TLSv1.3;
    # ssl_ciphers ECDHE-RSA-AES256-GCM-SHA512:DHE-RSA-AES256-GCM-SHA512;
    
    location / {
        proxy_pass http://127.0.0.1:${CONTAINER_PORT};
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
        
        # WebSocket support
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";
    }
    
    # Security headers
    add_header X-Frame-Options DENY always;
    add_header X-Content-Type-Options nosniff always;
    add_header X-XSS-Protection "1; mode=block" always;
}
EOF

  # Copy the config file to remote server
  scp -i "$SSH_KEY" -o StrictHostKeyChecking=no "$NGINX_CONFIG_FILE" "${REMOTE_USER}@${REMOTE_HOST}:/tmp/nginx_config.conf" >>"$LOG_FILE" 2>&1 || die "Failed to copy nginx config"

  # Set up nginx on remote
  ssh -i "$SSH_KEY" -o StrictHostKeyChecking=no "${REMOTE_USER}@${REMOTE_HOST}" /bin/bash <<'NGINX_SETUP'
set -euo pipefail

# Move config to proper location
sudo mv /tmp/nginx_config.conf /etc/nginx/sites-available/app.conf

# Create symlink
sudo ln -sf /etc/nginx/sites-available/app.conf /etc/nginx/sites-enabled/

# Remove default config if it exists
sudo rm -f /etc/nginx/sites-enabled/default 2>/dev/null || true

# Test configuration
sudo nginx -t

# Reload nginx
sudo systemctl reload nginx
NGINX_SETUP

  # Clean up local temp file
  rm -f "$NGINX_CONFIG_FILE"
  
  succ "Nginx configured with SSL readiness"
}

########################################
# Validation
########################################
validate_deployment() {
  info "Validating deployment"
  sleep 5  # Give services time to start
  
  # Check Docker status
  ssh -i "$SSH_KEY" -o StrictHostKeyChecking=no "${REMOTE_USER}@${REMOTE_HOST}" "sudo systemctl is-active docker" >/dev/null 2>&1 || die "Docker is not active on remote"
  
  # List containers
  info "Current Docker containers:"
  ssh -i "$SSH_KEY" -o StrictHostKeyChecking=no "${REMOTE_USER}@${REMOTE_HOST}" "docker ps --format 'table {{.Names}}\t{{.Image}}\t{{.Status}}'" >>"$LOG_FILE" 2>&1 || die "Failed to list containers"
  
  # Check if nginx is running
  ssh -i "$SSH_KEY" -o StrictHostKeyChecking=no "${REMOTE_USER}@${REMOTE_HOST}" "sudo systemctl is-active nginx" >/dev/null 2>&1 || die "Nginx is not active on remote"
  
  # Test nginx configuration
  ssh -i "$SSH_KEY" -o StrictHostKeyChecking=no "${REMOTE_USER}@${REMOTE_HOST}" "sudo nginx -t" >>"$LOG_FILE" 2>&1 || die "Nginx configuration test failed"
  
  # Test application health
  info "Testing application health..."
  ssh -i "$SSH_KEY" -o StrictHostKeyChecking=no "${REMOTE_USER}@${REMOTE_HOST}" "curl -sfS --connect-timeout 10 http://127.0.0.1:${CONTAINER_PORT} >/dev/null 2>&1 && echo '✅ Application is healthy' || echo '❌ Application health check failed'" >>"$LOG_FILE" 2>&1
  
  # public reachability
  info "Testing public reachability at http://${REMOTE_HOST}"
  if curl -sfS --connect-timeout 10 "http://${REMOTE_HOST}" >/dev/null 2>&1; then
    succ "✅ Application reachable via http://${REMOTE_HOST}"
  else
    info "⚠️  Application not reachable from this network (http://${REMOTE_HOST}) — check firewall/security groups"
  fi
}

########################################
# Cleanup (optional)
########################################
cleanup_remote() {
  info "Running cleanup on remote host"
  ssh -i "$SSH_KEY" -o StrictHostKeyChecking=no "${REMOTE_USER}@${REMOTE_HOST}" /bin/bash <<REMOTE_CLEAN
set -euo pipefail

# Stop and remove all project-related containers
sudo docker ps -a --format '{{.Names}}' | grep -E 'app_|${REPO_NAME}' | xargs -r sudo docker rm -f || true

# Remove all project-related images
sudo docker images --format '{{.Repository}}:{{.Tag}}' | grep -E 'app_|${REPO_NAME}' | xargs -r sudo docker rmi -f || true

# Clean up nginx (only our config, not nginx itself)
sudo rm -f /etc/nginx/sites-enabled/app.conf || true
sudo rm -f /etc/nginx/sites-available/app.conf || true
sudo nginx -t && sudo systemctl reload nginx || true

# Remove project directory
sudo rm -rf "${REMOTE_PROJECT_DIR}" || true

echo "Cleanup completed"
REMOTE_CLEAN
  succ "Remote cleanup completed"
}

########################################
# Main
########################################
main() {
  if [ "$CLEANUP_MODE" -eq 1 ]; then
    read_input
    check_local_prereqs
    check_ssh_connectivity
    cleanup_remote
    succ "Cleanup finished"
    exit 0
  fi

  read_input
  check_local_prereqs
  prepare_local_repo
  check_ssh_connectivity
  remote_prepare
  transfer_project
  remote_deploy
  configure_nginx
  validate_deployment

  succ "Deployment completed successfully! 🚀"
  info "Your application is accessible at: http://${REMOTE_HOST}"
  info "SSL is ready for configuration - see /etc/nginx/ssl/README on the server"
  info "Detailed logs: $LOG_FILE"
}

main "$@"