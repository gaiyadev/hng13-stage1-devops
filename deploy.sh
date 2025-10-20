#!/usr/bin/env bash
# deploy.sh - Automated deployment script for Dockerized applications
# Requirements: bash, ssh, scp/rsync, curl
# Usage: ./deploy.sh
#        ./deploy.sh --cleanup
set -euo pipefail

####################################################################
# Configuration / Defaults
####################################################################
LOG_DIR="./logs"
TIMESTAMP="$(date +'%Y%m%d_%H%M%S')"
LOG_FILE="${LOG_DIR}/deploy_${TIMESTAMP}.log"
DEFAULT_BRANCH="main"
SSH_TIMEOUT=10
CLEANUP_MODE=0

####################################################################
# Helper functions
####################################################################
mkdir -p "${LOG_DIR}"

log() {
  printf '%s %s\n' "$(date +'%Y-%m-%dT%H:%M:%S%z')" "$*" | tee -a "${LOG_FILE}"
}

die() {
  local code="${2:-1}"
  log "ERROR: $1"
  exit "${code}"
}

info() { log "INFO: $*"; }
success() { log "SUCCESS: $*"; }

trap 'die "Unexpected error at line ${LINENO}" 2' ERR
trap 'log "Script interrupted"; exit 130' INT

usage() {
  cat <<EOF
Usage: $0 [--cleanup]

Interactively collects:
 - Git repo URL
 - Personal Access Token (PAT)
 - Branch (defaults to ${DEFAULT_BRANCH})
 - Remote SSH user
 - Remote server IP
 - SSH key path
 - Application container internal port (container_port)
 - Remote project path (optional; defaults to /home/<user>/app_<repo_name>)

Options:
  --cleanup    Remove deployed containers, nginx config, and project files (idempotent)
EOF
}

####################################################################
# Parse args
####################################################################
for arg in "$@"; do
  case "$arg" in
    --cleanup) CLEANUP_MODE=1 ;;
    -h|--help) usage; exit 0 ;;
    *) ;;
  esac
done

####################################################################
# Input collection (interactive)
####################################################################
read_input() {
  : "${GIT_URL:=$(printf '' ; read -p 'Git repository URL (https://...): ' REPLY && printf '%s' "$REPLY")}"
  : "${PAT:=$(printf '' ; read -s -p 'Personal Access Token (input hidden): ' REPLY && printf '%s' "$REPLY" && echo) }"
  if [ -z "${PAT}" ]; then
    echo
    die "Personal Access Token cannot be empty"
  fi
  : "${BRANCH:=$(printf '' ; read -p "Branch [${DEFAULT_BRANCH}]: " REPLY && printf '%s' "${REPLY:-$DEFAULT_BRANCH}")}"
  : "${REMOTE_USER:=$(printf '' ; read -p 'Remote SSH username: ' REPLY && printf '%s' "$REPLY")}"
  : "${REMOTE_HOST:=$(printf '' ; read -p 'Remote server IP/hostname: ' REPLY && printf '%s' "$REPLY")}"
  : "${SSH_KEY:=$(printf '' ; read -p 'SSH key path (e.g. ~/.ssh/id_rsa): ' REPLY && printf '%s' "$REPLY")}"
  : "${CONTAINER_PORT:=$(printf '' ; read -p 'Application internal container port (e.g. 3000): ' REPLY && printf '%s' "$REPLY")}"
  : "${REMOTE_PROJECT_DIR:=$(printf '' ; read -p 'Remote project directory (optional, leave blank for default): ' REPLY && printf '%s' "$REPLY")}"

  if [ -z "${GIT_URL}" ] || [ -z "${REMOTE_USER}" ] || [ -z "${REMOTE_HOST}" ] || [ -z "${SSH_KEY}" ] || [ -z "${CONTAINER_PORT}" ]; then
    die "One or more required inputs are missing."
  fi

  # Derive repo name
  REPO_NAME="$(basename -s .git "${GIT_URL}")"
  if [ -z "${REMOTE_PROJECT_DIR}" ]; then
    REMOTE_PROJECT_DIR="/home/${REMOTE_USER}/${REPO_NAME}"
  fi
}

####################################################################
# Validate local prerequisites
####################################################################
check_local_prereqs() {
  command -v ssh >/dev/null 2>&1 || die "ssh is required on your local machine"
  command -v rsync >/dev/null 2>&1 || command -v scp >/dev/null 2>&1 || die "rsync or scp is required"
  command -v curl >/dev/null 2>&1 || die "curl is required"
  info "Local prerequisites satisfied"
}

####################################################################
# Clone or update repo locally
####################################################################

####################################################################
# Clone or update repo locally
####################################################################
prepare_local_repo() {
  info "Preparing local repository..."

  # If PAT is empty, skip authentication and clone publicly
  if [ -z "${PAT}" ]; then
    info "No Personal Access Token provided — cloning as a public repository"
    AUTH_GIT_URL="${GIT_URL}"
  else
    # Use token for authentication if HTTPS remote
    if printf '%s' "${GIT_URL}" | grep -qE '^https?://'; then
      AUTH_GIT_URL="$(printf '%s' "${GIT_URL}" | sed -E "s#https?://#https://${PAT}@#")"
    else
      AUTH_GIT_URL="${GIT_URL}"
    fi
  fi

  if [ -d "${REPO_NAME}/.git" ]; then
    info "Repository exists locally, pulling latest changes"
    (cd "${REPO_NAME}" && git fetch --all --prune) >>"${LOG_FILE}" 2>&1 || die "Failed to fetch repository"
    (cd "${REPO_NAME}" && git checkout "${BRANCH}") >>"${LOG_FILE}" 2>&1 || die "Failed to checkout ${BRANCH}"
    (cd "${REPO_NAME}" && git pull origin "${BRANCH}") >>"${LOG_FILE}" 2>&1 || die "Failed to pull latest changes"
  else
    info "Cloning repository ${AUTH_GIT_URL} ..."
    git clone --branch "${BRANCH}" "${AUTH_GIT_URL}" "${REPO_NAME}" >>"${LOG_FILE}" 2>&1 || die "Git clone failed"
  fi

  # Verify Dockerfile or docker-compose.yml exists
  if [ -f "${REPO_NAME}/Dockerfile" ] || [ -f "${REPO_NAME}/docker-compose.yml" ]; then
    success "Found Dockerfile or docker-compose.yml"
  else
    die "No Dockerfile or docker-compose.yml found in repo root"
  fi
}


####################################################################
# Remote helpers (execute commands via SSH)
####################################################################
ssh_exec() {
  local cmd="$1"
  ssh -i "${SSH_KEY}" -o StrictHostKeyChecking=no -o ConnectTimeout=${SSH_TIMEOUT} "${REMOTE_USER}@${REMOTE_HOST}" "${cmd}"
}

ssh_exec_heredoc() {
  ssh -i "${SSH_KEY}" -o StrictHostKeyChecking=no -o ConnectTimeout=${SSH_TIMEOUT} "${REMOTE_USER}@${REMOTE_HOST}" 'bash -s' <<'REMOTE_EOF'
'"$1"'
REMOTE_EOF
}

check_ssh_connectivity() {
  info "Checking SSH connectivity to ${REMOTE_USER}@${REMOTE_HOST}"
  ssh -i "${SSH_KEY}" -o BatchMode=yes -o ConnectTimeout=${SSH_TIMEOUT} "${REMOTE_USER}@${REMOTE_HOST}" "echo connected" >/dev/null 2>&1 || die "SSH connectivity failed. Check credentials and network."
  success "SSH connectivity OK"
}

####################################################################
# Remote environment preparation
####################################################################
remote_prepare() {
  info "Preparing remote environment on ${REMOTE_HOST}"
  # Determine package manager and install docker/docker-compose/nginx
  ssh -i "${SSH_KEY}" -o StrictHostKeyChecking=no "${REMOTE_USER}@${REMOTE_HOST}" /bin/bash <<'REMOTE_SETUP'
set -euo pipefail
LOG="/tmp/remote_deploy_setup.log"
echo "Starting remote setup" > "${LOG}"
if command -v apt-get >/dev/null 2>&1; then
  PKG_UPDATE="sudo apt-get update -y"
  INSTALL="sudo apt-get install -y"
  DOCKER_PKG="docker.io"
  DOCKER_CLI="docker"
  # install prerequisites
  sudo apt-get update -y >> "${LOG}" 2>&1
  sudo apt-get install -y apt-transport-https ca-certificates curl software-properties-common gnupg lsb-release >> "${LOG}" 2>&1 || true
  # install docker from repository (recommended)
  if ! command -v docker >/dev/null 2>&1; then
    curl -fsSL https://get.docker.com -o get-docker.sh && sudo sh get-docker.sh >> "${LOG}" 2>&1 || true
  fi
  sudo apt-get install -y docker-compose nginx >> "${LOG}" 2>&1 || true
elif command -v yum >/dev/null 2>&1; then
  sudo yum install -y yum-utils device-mapper-persistent-data lvm2 >> "${LOG}" 2>&1 || true
  if ! command -v docker >/dev/null 2>&1; then
    curl -fsSL https://get.docker.com -o get-docker.sh && sudo sh get-docker.sh >> "${LOG}" 2>&1 || true
  fi
  sudo yum install -y docker-compose nginx >> "${LOG}" 2>&1 || true
else
  echo "Unsupported package manager. Please install Docker, Docker Compose and Nginx manually." >> "${LOG}"
  exit 1
fi

# Add user to docker group if docker exists
if command -v docker >/dev/null 2>&1; then
  sudo usermod -aG docker "$USER" || true
  sudo systemctl enable --now docker || true
fi

# Start nginx
if command -v nginx >/dev/null 2>&1; then
  sudo systemctl enable --now nginx || true
fi

# Print versions
echo "Docker: $(docker --version 2>/dev/null || echo 'not installed')" >> "${LOG}"
echo "Docker Compose: $(docker-compose --version 2>/dev/null || echo 'not installed')" >> "${LOG}"
echo "Nginx: $(nginx -v 2>&1 || echo 'not installed')" >> "${LOG}"
cat "${LOG}"
REMOTE_SETUP
  success "Remote environment prepared (Docker/Nginx installation attempted)."
}

####################################################################
# Transfer project files to remote
####################################################################
transfer_project() {
  info "Transferring project files to ${REMOTE_HOST}:${REMOTE_PROJECT_DIR}"
  # Ensure remote dir exists
  ssh -i "${SSH_KEY}" -o StrictHostKeyChecking=no "${REMOTE_USER}@${REMOTE_HOST}" "mkdir -p '${REMOTE_PROJECT_DIR}' && chown ${REMOTE_USER}:${REMOTE_USER} '${REMOTE_PROJECT_DIR}'" || die "Failed to create remote project directory"

  # Use rsync if available
  if command -v rsync >/dev/null 2>&1; then
    rsync -avz --delete -e "ssh -i ${SSH_KEY} -o StrictHostKeyChecking=no" "${REPO_NAME}/" "${REMOTE_USER}@${REMOTE_HOST}:${REMOTE_PROJECT_DIR}/" >>"${LOG_FILE}" 2>&1 || die "rsync transfer failed"
  else
    # Fallback to scp
    scp -i "${SSH_KEY}" -r "${REPO_NAME}/" "${REMOTE_USER}@${REMOTE_HOST}:${REMOTE_PROJECT_DIR}/" >>"${LOG_FILE}" 2>&1 || die "scp transfer failed"
  fi
  success "Project files transferred"
}

####################################################################
# Deploy application on remote host
####################################################################
remote_deploy() {
  info "Deploying application on remote host"
  ssh -i "${SSH_KEY}" -o StrictHostKeyChecking=no "${REMOTE_USER}@${REMOTE_HOST}" /bin/bash <<REMOTE_EOF
set -euo pipefail
cd "${REMOTE_PROJECT_DIR}"
# Stop and remove old containers if present (try docker-compose then docker)
if [ -f docker-compose.yml ]; then
  docker-compose down || true
  docker-compose pull || true
  docker-compose up -d --build || true
elif [ -f Dockerfile ]; then
  # Find image tag from repo name and recreate container
  IMAGE_NAME="${REPO_NAME}:latest"
  docker build -t "\${IMAGE_NAME}" . || true
  # Stop and remove any containers using this image name
  docker ps -a --filter "ancestor=\${IMAGE_NAME}" --format '{{.ID}}' | xargs -r docker rm -f || true
  docker run -d --name "\${REPO_NAME}_service" -p ${CONTAINER_PORT}:${CONTAINER_PORT} "\${IMAGE_NAME}" || true
else
  echo "No Dockerfile or docker-compose.yml found during remote deploy"
  exit 1
fi

# Confirm containers are running
docker ps --format 'table {{.Names}}\t{{.Image}}\t{{.Status}}' || true

REMOTE_EOF
  success "Remote deployment commands executed"
}

####################################################################
# Configure Nginx reverse proxy
####################################################################
configure_nginx() {
  info "Configuring Nginx to reverse proxy to application port ${CONTAINER_PORT}"
  NGINX_CONF="/etc/nginx/sites-available/${REPO_NAME}.conf"
  NGINX_LINK="/etc/nginx/sites-enabled/${REPO_NAME}.conf"

  # Create nginx config remotely
  ssh -i "${SSH_KEY}" -o StrictHostKeyChecking=no "${REMOTE_USER}@${REMOTE_HOST}" sudo tee "${NGINX_CONF}" > /dev/null <<NGINX_CONF
server {
    listen 80;
    server_name _;

    location / {
        proxy_pass http://127.0.0.1:${CONTAINER_PORT};
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
    }
}
NGINX_CONF

  ssh -i "${SSH_KEY}" -o StrictHostKeyChecking=no "${REMOTE_USER}@${REMOTE_HOST}" "sudo ln -sf '${NGINX_CONF}' '${NGINX_LINK}' && sudo nginx -t" >>"${LOG_FILE}" 2>&1 || die "Nginx config test failed"
  ssh -i "${SSH_KEY}" -o StrictHostKeyChecking=no "${REMOTE_USER}@${REMOTE_HOST}" "sudo systemctl reload nginx" >>"${LOG_FILE}" 2>&1 || die "Failed to reload Nginx"
  success "Nginx configured and reloaded"
}

####################################################################
# Validate deployment
####################################################################
validate_deployment() {
  info "Validating deployment locally and remotely"

  # Check Docker service remote
  ssh -i "${SSH_KEY}" -o StrictHostKeyChecking=no "${REMOTE_USER}@${REMOTE_HOST}" "sudo systemctl is-active docker" >/dev/null 2>&1 || die "Docker service is not active on remote host"

  # List containers and check status
  ssh -i "${SSH_KEY}" -o StrictHostKeyChecking=no "${REMOTE_USER}@${REMOTE_HOST}" "docker ps --format '{{.Names}} {{.Status}}'" >>"${LOG_FILE}" 2>&1 || die "Failed to list docker containers on remote"

  # Test endpoint from remote host (loopback)
  ssh -i "${SSH_KEY}" -o StrictHostKeyChecking=no "${REMOTE_USER}@${REMOTE_HOST}" "curl -sfS http://127.0.0.1:${CONTAINER_PORT} || echo 'REMOTE_CURL_FAILED'" >>"${LOG_FILE}" 2>&1 || info "Remote curl may have failed (check app health)"

  # Test endpoint from local machine via public host
  if curl -sfS "http://${REMOTE_HOST}" >/dev/null 2>&1; then
    success "Application reachable via http://${REMOTE_HOST}"
  else
    info "Application not reachable from local network (http://${REMOTE_HOST}). This could be due to firewall or app start time. Check logs."
  fi
}

####################################################################
# Cleanup routine (optional)
####################################################################
cleanup_remote() {
  info "Running cleanup on remote host: removing nginx site, containers, and project dir"
  ssh -i "${SSH_KEY}" -o StrictHostKeyChecking=no "${REMOTE_USER}@${REMOTE_HOST}" /bin/bash <<REMOTE_CLEAN
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
  success "Remote cleanup completed"
}

####################################################################
# Main flow
####################################################################
main() {
  if [ "${CLEANUP_MODE}" -eq 1 ]; then
    read_input
    check_local_prereqs
    check_ssh_connectivity
    cleanup_remote
    success "Cleanup finished. Exiting."
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

  success "Deployment completed successfully. Log: ${LOG_FILE}"
}

main "$@"
