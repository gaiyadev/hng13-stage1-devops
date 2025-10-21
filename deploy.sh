#!/usr/bin/env bash
# deploy.sh — HNG DevOps Stage 1 automated deploy script
# Author: assistant (adapt for your name)
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
# Prepare remote environment (install docker/nginx)
########################################
remote_prepare() {
  info "Preparing remote environment"
  ssh -i "$SSH_KEY" -o StrictHostKeyChecking=no "${REMOTE_USER}@${REMOTE_HOST}" /bin/bash <<'REMOTE'
set -euo pipefail
LOG=/tmp/remote_setup.log
echo "remote prepare start: $(date)" > "$LOG"
if command -v apt-get >/dev/null 2>&1; then
  sudo apt-get update -y >> "$LOG" 2>&1
  sudo apt-get install -y ca-certificates curl gnupg lsb-release >> "$LOG" 2>&1 || true
  if ! command -v docker >/dev/null 2>&1; then
    curl -fsSL https://get.docker.com -o get-docker.sh && sudo sh get-docker.sh >> "$LOG" 2>&1 || true
  fi
  sudo apt-get install -y docker-compose nginx >> "$LOG" 2>&1 || true
elif command -v yum >/dev/null 2>&1; then
  sudo yum install -y yum-utils device-mapper-persistent-data lvm2 >> "$LOG" 2>&1 || true
  if ! command -v docker >/dev/null 2>&1; then
    curl -fsSL https://get.docker.com -o get-docker.sh && sudo sh get-docker.sh >> "$LOG" 2>&1 || true
  fi
  sudo yum install -y docker-compose nginx >> "$LOG" 2>&1 || true
else
  echo "Unsupported package manager" >> "$LOG"
  exit 1
fi
sudo systemctl enable --now docker || true
sudo systemctl enable --now nginx || true
echo "Docker: $(docker --version 2>/dev/null || echo 'n/a')" >> "$LOG"
echo "Docker Compose: $(docker-compose --version 2>/dev/null || echo 'n/a')" >> "$LOG"
echo "Nginx: $(nginx -v 2>/dev/null || echo 'n/a')" >> "$LOG"
cat "$LOG"
REMOTE
  succ "Remote environment preparation attempted (see remote logs)"
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
# ensure old containers removed
if [ -f docker-compose.yml ]; then
  sudo docker-compose down || true
  sudo docker-compose pull || true
  sudo docker-compose up -d --build
else
  # image name safe derived
  IMG="${REPO_NAME}:latest"
  sudo docker build -t "\$IMG" . || true
  sudo docker ps -a --filter "ancestor=\$IMG" --format '{{.ID}}' | xargs -r sudo docker rm -f || true
  sudo docker run -d --name "${REPO_NAME}_service" -p ${CONTAINER_PORT}:${CONTAINER_PORT} "\$IMG" || true
fi
sudo docker ps --format 'table {{.Names}}\t{{.Image}}\t{{.Status}}' || true
REMOTE_DEPLOY
  succ "Remote deployment attempted"
}

########################################
# Nginx config
########################################
configure_nginx() {
  info "Configuring Nginx reverse proxy"
  NGINX_CONF="/etc/nginx/sites-available/${REPO_NAME}.conf"
  NGINX_LINK="/etc/nginx/sites-enabled/${REPO_NAME}.conf"
ssh -i "$SSH_KEY" "$REMOTE_USER@$REMOTE_HOST" sudo tee /etc/nginx/sites-available/${REPO_NAME}.conf > /dev/null <<'NGINX_CONF'
server {
    listen 80;
    server_name _;
    location / {
        proxy_pass http://127.0.0.1:3000;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
    }
}
NGINX_CONF
  ssh -i "$SSH_KEY" -o StrictHostKeyChecking=no "${REMOTE_USER}@${REMOTE_HOST}" "sudo ln -sf '${NGINX_CONF}' '${NGINX_LINK}' && sudo nginx -t" >>"$LOG_FILE" 2>&1 || die "Nginx config test failed"
  ssh -i "$SSH_KEY" -o StrictHostKeyChecking=no "${REMOTE_USER}@${REMOTE_HOST}" "sudo systemctl reload nginx" >>"$LOG_FILE" 2>&1 || die "Failed to reload Nginx"
  succ "Nginx configured and reloaded"
}

########################################
# Validation
########################################
validate_deployment() {
  info "Validating deployment"
  ssh -i "$SSH_KEY" -o StrictHostKeyChecking=no "${REMOTE_USER}@${REMOTE_HOST}" "sudo systemctl is-active docker" >/dev/null 2>&1 || die "Docker is not active on remote"
  ssh -i "$SSH_KEY" -o StrictHostKeyChecking=no "${REMOTE_USER}@${REMOTE_HOST}" "docker ps --format '{{.Names}} {{.Status}}'" >>"$LOG_FILE" 2>&1 || die "Failed to list containers"
  # remote loopback check
  ssh -i "$SSH_KEY" -o StrictHostKeyChecking=no "${REMOTE_USER}@${REMOTE_HOST}" "curl -sfS http://127.0.0.1:${CONTAINER_PORT} || echo 'REMOTE_CURL_FAILED'" >>"$LOG_FILE" 2>&1 || info "Remote curl may have failed"
  # public reachability
  if curl -sfS "http://${REMOTE_HOST}" >/dev/null 2>&1; then
    succ "Application reachable via http://${REMOTE_HOST}"
  else
    info "Application not reachable from this network (http://${REMOTE_HOST}) — check firewall/security groups"
  fi
}

########################################
# Cleanup (optional)
########################################
cleanup_remote() {
  info "Running cleanup on remote host"
  ssh -i "$SSH_KEY" -o StrictHostKeyChecking=no "${REMOTE_USER}@${REMOTE_HOST}" /bin/bash <<REMOTE_CLEAN
set -euo pipefail
sudo systemctl stop nginx || true
sudo rm -f /etc/nginx/sites-enabled/${REPO_NAME}.conf || true
sudo rm -f /etc/nginx/sites-available/${REPO_NAME}.conf || true
sudo nginx -t || true
sudo systemctl reload nginx || true
docker ps -a --format '{{.Names}}' | grep -E '${REPO_NAME}' | xargs -r docker rm -f || true
docker images --format '{{.Repository}}:{{.Tag}}' | grep -E '${REPO_NAME}' | xargs -r docker rmi -f || true
sudo rm -rf "${REMOTE_PROJECT_DIR}" || true
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

  succ "Deployment completed. Local log: $LOG_FILE"
}

main "$@"
